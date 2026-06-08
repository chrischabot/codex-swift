import Foundation
import CSQLite
import CSQLiteVec
import InfraPrimitives

#if canImport(Accelerate)
import Accelerate
#endif

public enum MemoryStoreError: Error, Sendable, CustomStringConvertible {
    case open(String), exec(String), prepare(String), step(String), invalid(String)
    public var description: String {
        switch self {
        case .open(let s):    return "memory sqlite open: \(s)"
        case .exec(let s):    return "memory sqlite exec: \(s)"
        case .prepare(let s): return "memory sqlite prepare: \(s)"
        case .step(let s):    return "memory sqlite step: \(s)"
        case .invalid(let s): return "memory store invalid: \(s)"
        }
    }
}

/// Embedding storage width used end-to-end for the Memory Wiki. Local Nomic
/// embeddings are natively 768 floats and are zero-padded to this width by the
/// MLX provider; OpenAI `text-embedding-3-small` can emit this width directly.
/// The dimension and provider id are stamped into `meta` rows at first init so
/// accidental incompatible vector-space swaps are caught immediately.
public let memoryEmbeddingDimension: Int = 1536

/// Auto-extension registration is idempotent in sqlite-vec's static-link
/// pattern: register once before any handle is opened so every handle picks
/// it up. `codex_register_sqlite_vec` is a no-op when the amalgamation is
/// absent — the Swift layer falls back to in-process cosine.
private let sqliteVecRegisteredOnce: Bool = {
    _ = codex_register_sqlite_vec()
    return true
}()

private func ensureSqliteVecRegistered() { _ = sqliteVecRegisteredOnce }

/// Owns the raw `sqlite3*`. Same `@unchecked Sendable` discipline as the
/// existing `Persistence.StateDB`: the enclosing actor serializes every access
/// and the handle is opened with `SQLITE_OPEN_FULLMUTEX`.
final class MemorySQLiteHandle: @unchecked Sendable {
    let ptr: OpaquePointer
    init(_ p: OpaquePointer) { ptr = p }
    deinit { sqlite3_close_v2(ptr) }
}

/// Concrete configuration for the memory store. The default path lives under
/// `~/Library/Application Support/CodexKit` on macOS and the XDG equivalent
/// on Linux (`$XDG_DATA_HOME/codexkit` or `~/.local/share/codexkit`).
public struct MemoryStoreConfig: Sendable, Equatable {
    public var path: String
    public var mmapSize: Int64
    public var cachePages: Int
    public var embeddingDimension: Int
    public var embeddingProviderID: String?

    public init(path: String,
                mmapSize: Int64 = 8 << 30,
                cachePages: Int = -262_144,
                embeddingDimension: Int = memoryEmbeddingDimension,
                embeddingProviderID: String? = nil) {
        self.path = path
        self.mmapSize = mmapSize
        self.cachePages = cachePages
        self.embeddingDimension = embeddingDimension
        self.embeddingProviderID = embeddingProviderID
    }

    public static func defaultPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CODEX_MEMORY_DB"] { return override }
        let home = env["HOME"] ?? "/tmp"
        #if os(macOS)
        return home + "/Library/Application Support/CodexKit/memory.db"
        #else
        let xdg = env["XDG_DATA_HOME"] ?? (home + "/.local/share")
        return xdg + "/codexkit/memory.db"
        #endif
    }

    public static let `default` = MemoryStoreConfig(path: defaultPath())
}

/// Single-writer SQLite actor. All writes go through this actor; reads also
/// flow through it for serialisation simplicity (SQLite WAL allows concurrent
/// readers but the actor avoids the in-process lock entirely).
///
/// Vector search: prefers sqlite-vec's `vec0` virtual table when the
/// amalgamation is linked (detected via `codex_sqlite_vec_available()`);
/// otherwise stores embeddings as a Float32 blob in `chunk_embedding` and
/// performs cosine in Swift. Both branches share the same `searchVectors`
/// entry point so callers never observe the difference.
public actor MemoryStore {
    private let handle: MemorySQLiteHandle
    private var db: OpaquePointer { handle.ptr }
    private let config: MemoryStoreConfig
    /// True when sqlite-vec's vec0 virtual table is available on this build.
    nonisolated public let vecAvailable: Bool

    // MARK: - batched cosine (vDSP_mmul fast path)

    /// Compute `matrix · query` for `rowCount` row-major rows of `dim`-wide
    /// vectors. The result is an array of length `rowCount` where entry `r`
    /// is the dot product of row `r` and `query`. Used by the Swift-fallback
    /// branch of `searchVectors` to score every chunk in a single
    /// Accelerate matmul instead of one Swift loop per row.
    ///
    /// Pre-conditions: `query.count == dim`, `matrix.count == rowCount * dim`.
    /// On Accelerate-capable platforms this is a single `vDSP_mmul` call. On
    /// Linux / Windows we fall back to a tiled scalar loop that's still
    /// considerably faster than the per-row `cosineDistance` path because
    /// it avoids per-row `[Float]` allocation.
    nonisolated public static func batchedDot(query: [Float],
                                              matrix: [Float],
                                              rowCount: Int,
                                              dim: Int) -> [Float] {
        precondition(query.count == dim,
                     "batchedDot: query.count=\(query.count) dim=\(dim)")
        precondition(matrix.count == rowCount * dim,
                     "batchedDot: matrix.count=\(matrix.count) rowCount*dim=\(rowCount * dim)")
        if rowCount == 0 { return [] }
        var result = [Float](repeating: 0, count: rowCount)
        #if canImport(Accelerate)
        // matrix (rowCount × dim) · query (dim × 1) = result (rowCount × 1)
        matrix.withUnsafeBufferPointer { mp in
            query.withUnsafeBufferPointer { qp in
                result.withUnsafeMutableBufferPointer { rp in
                    vDSP_mmul(mp.baseAddress!, 1,
                              qp.baseAddress!, 1,
                              rp.baseAddress!, 1,
                              vDSP_Length(rowCount),
                              vDSP_Length(1),
                              vDSP_Length(dim))
                }
            }
        }
        #else
        matrix.withUnsafeBufferPointer { mp in
            query.withUnsafeBufferPointer { qp in
                for r in 0..<rowCount {
                    var s: Float = 0
                    let row = mp.baseAddress!.advanced(by: r * dim)
                    for d in 0..<dim {
                        s += row[d] * qp[d]
                    }
                    result[r] = s
                }
            }
        }
        #endif
        return result
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(_ config: MemoryStoreConfig = .default) throws {
        self.config = config
        ensureSqliteVecRegistered()
        try Self.ensureParentDirectory(config.path)
        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(config.path, &raw, flags, nil)
        guard rc == SQLITE_OK, let h = raw else {
            if let r = raw { sqlite3_close_v2(r) }
            throw MemoryStoreError.open("rc=\(rc) path=\(config.path)")
        }
        self.handle = MemorySQLiteHandle(h)
        // Per-connection init: Apple platforms deprecated `sqlite3_auto_extension`,
        // so we register sqlite-vec on each opened handle. Linux still benefits
        // from the `codex_register_sqlite_vec` auto-extension hook above; the
        // per-handle call below is idempotent.
        let initRC = codex_init_sqlite_vec_for(h)
        self.vecAvailable = (codex_sqlite_vec_available() != 0) && (initRC == SQLITE_OK)
        try Self.applyPragmas(h, config: config)
        try Self.runMigrations(h, config: config, vec: self.vecAvailable)
    }

    // MARK: - bring-up helpers (no `self`, runnable from init)

    private static func ensureParentDirectory(_ path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        guard !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
    }

    private static func applyPragmas(_ db: OpaquePointer,
                                     config: MemoryStoreConfig) throws {
        try execRaw(db, "PRAGMA journal_mode=WAL;")
        try execRaw(db, "PRAGMA synchronous=NORMAL;")
        try execRaw(db, "PRAGMA temp_store=MEMORY;")
        try execRaw(db, "PRAGMA mmap_size=\(config.mmapSize);")
        try execRaw(db, "PRAGMA cache_size=\(config.cachePages);")
        try execRaw(db, "PRAGMA busy_timeout=5000;")
        try execRaw(db, "PRAGMA foreign_keys=ON;")
    }

    private static func errMsg(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func execRaw(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? errMsg(db)
            sqlite3_free(err)
            throw MemoryStoreError.exec("\(m) [\(sql.prefix(80))]")
        }
    }

    // MARK: - schema

    private static func runMigrations(_ db: OpaquePointer,
                                      config: MemoryStoreConfig,
                                      vec: Bool) throws {
        try execRaw(db, MemorySchema.coreSQL)
        // Forward-compat ALTERs for fields added after first ship.
        try? execRaw(db, "ALTER TABLE source_cursor ADD COLUMN consecutive_failures INTEGER NOT NULL DEFAULT 0;")
        if vec {
            // Real sqlite-vec is linked — use the vec0 virtual table for
            // O(N·d) brute-force search in C.
            try execRaw(db, MemorySchema.vec0VirtualTableSQL(dim: config.embeddingDimension))
        } else {
            // Fallback: keep the embedding as a Float32 blob on `chunk_embedding`.
            try execRaw(db, MemorySchema.embeddingBlobTableSQL)
        }
        try execRaw(db, MemorySchema.ftsSQL)
        try execRaw(db, MemorySchema.metaSQL)
        // Stamp the dimension. If a future open finds a different dim, the
        // bring-up check below throws so a wrong-model embedder is caught
        // immediately rather than silently corrupting search.
        let dim = config.embeddingDimension
        try execRaw(db, """
        INSERT INTO meta(key,value) VALUES('embedding_dim','\(dim)')
        ON CONFLICT(key) DO UPDATE SET value=excluded.value
        WHERE meta.value=excluded.value;
        """)
        // Verify dim consistency.
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='embedding_dim';",
                                  -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MemoryStoreError.prepare(errMsg(db))
        }
        defer { sqlite3_finalize(s) }
        if sqlite3_step(s) == SQLITE_ROW,
           let raw = sqlite3_column_text(s, 0),
           let stored = Int(String(cString: raw)),
           stored != dim {
            throw MemoryStoreError.invalid(
                "embedding dim mismatch: store=\(stored) config=\(dim)")
        }
        if let providerID = config.embeddingProviderID, !providerID.isEmpty {
            let escaped = providerID.replacingOccurrences(of: "'", with: "''")
            try execRaw(db, """
            INSERT INTO meta(key,value) VALUES('embedding_provider_id','\(escaped)')
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            WHERE meta.value=excluded.value;
            """)
            var providerStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='embedding_provider_id';",
                                      -1, &providerStmt, nil) == SQLITE_OK, let ps = providerStmt else {
                throw MemoryStoreError.prepare(errMsg(db))
            }
            defer { sqlite3_finalize(ps) }
            if sqlite3_step(ps) == SQLITE_ROW,
               let raw = sqlite3_column_text(ps, 0) {
                let stored = String(cString: raw)
                if stored != providerID {
                    throw MemoryStoreError.invalid(
                        "embedding provider mismatch: store=\(stored) config=\(providerID)")
                }
            }
        }
    }

    // MARK: - low-level query helpers (actor-isolated)

    private enum Bind: Sendable {
        case text(String), int(Int64), real(Double), blob(Data), null
    }

    private func errMsg() -> String { Self.errMsg(db) }

    private func execRaw(_ sql: String) throws { try Self.execRaw(db, sql) }

    /// Prepares, binds, steps, finalises. Each query returns the raw rows so
    /// the caller can shape the result; large result sets stream out via a
    /// closure variant `runStream` below.
    @discardableResult
    private func run(_ sql: String, _ binds: [Bind] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MemoryStoreError.prepare(errMsg())
        }
        defer { sqlite3_finalize(s) }
        try bindAll(s, binds)
        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw MemoryStoreError.step(errMsg()) }
            rows.append(readRow(s))
        }
        return rows
    }

    private func runStream(_ sql: String,
                           _ binds: [Bind] = [],
                           _ each: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MemoryStoreError.prepare(errMsg())
        }
        defer { sqlite3_finalize(s) }
        try bindAll(s, binds)
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw MemoryStoreError.step(errMsg()) }
            each(s)
        }
    }

    private func bindAll(_ s: OpaquePointer, _ binds: [Bind]) throws {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch b {
            case .text(let t): rc = sqlite3_bind_text(s, idx, t, -1, Self.transient)
            case .int(let v):  rc = sqlite3_bind_int64(s, idx, v)
            case .real(let v): rc = sqlite3_bind_double(s, idx, v)
            case .blob(let d):
                rc = d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
                    sqlite3_bind_blob(s, idx, raw.baseAddress, Int32(d.count), Self.transient)
                }
            case .null: rc = sqlite3_bind_null(s, idx)
            }
            if rc != SQLITE_OK { throw MemoryStoreError.prepare("bind \(idx): \(errMsg())") }
        }
    }

    private func readRow(_ s: OpaquePointer) -> [String: Any] {
        var out: [String: Any] = [:]
        for col in 0..<sqlite3_column_count(s) {
            let name = String(cString: sqlite3_column_name(s, col))
            switch sqlite3_column_type(s, col) {
            case SQLITE_INTEGER: out[name] = sqlite3_column_int64(s, col)
            case SQLITE_FLOAT:   out[name] = sqlite3_column_double(s, col)
            case SQLITE_TEXT:
                if let c = sqlite3_column_text(s, col) { out[name] = String(cString: c) }
            case SQLITE_BLOB:
                if let p = sqlite3_column_blob(s, col) {
                    let n = Int(sqlite3_column_bytes(s, col))
                    out[name] = Data(bytes: p, count: n)
                }
            default: out[name] = nil
            }
        }
        return out
    }

    // MARK: - public CRUD: documents

    /// Insert or refresh a document row. Source URI is the dedupe key; an
    /// existing row's content_sha is overwritten only when changed, which lets
    /// the caller detect "same URI, new content" updates.
    ///
    /// `body_path` is refreshed alongside `content_sha` so the on-disk body
    /// archive and the SHA never drift apart — a re-ingest of the same URI
    /// with new content updates both atomically inside SQLite's UPDATE.
    @discardableResult
    public func upsertDocument(_ d: DocumentRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO document(source,source_uri,title,body_path,fetched_at,
                             published_at,content_sha,language,raw_bytes)
        VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(source_uri) DO UPDATE SET
          fetched_at=excluded.fetched_at,
          title=COALESCE(excluded.title,document.title),
          published_at=COALESCE(excluded.published_at,document.published_at),
          content_sha=excluded.content_sha,
          body_path=excluded.body_path,
          language=COALESCE(excluded.language,document.language),
          raw_bytes=excluded.raw_bytes
        RETURNING id;
        """, [
            .text(d.source.rawValue), .text(d.sourceURI),
            d.title.map(Bind.text) ?? .null, .text(d.bodyPath),
            .int(d.fetchedAt), d.publishedAt.map(Bind.int) ?? .null,
            .blob(d.contentSHA),
            d.language.map(Bind.text) ?? .null, .int(d.rawBytes),
        ])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func document(byURI uri: String) throws -> DocumentRow? {
        let rows = try run("SELECT * FROM document WHERE source_uri=?;", [.text(uri)])
        return rows.first.map(Self.rowToDocument)
    }

    public func document(id: Int64) throws -> DocumentRow? {
        let rows = try run("SELECT * FROM document WHERE id=?;", [.int(id)])
        return rows.first.map(Self.rowToDocument)
    }

    public func documents(limit: Int = 10_000) throws -> [DocumentRow] {
        try run("""
        SELECT * FROM document
         ORDER BY source_uri, id
         LIMIT ?;
        """, [.int(Int64(limit))]).map(Self.rowToDocument)
    }

    /// `orderByRecency` sorts newest-first by `fetched_at` (for "recent pages"
    /// surfaces); the default keeps the stable `source_uri` order. Either way the
    /// ORDER BY is applied BEFORE the LIMIT so the cap selects the right rows.
    public func documentChunkSummaries(limit: Int = 10_000,
                                       orderByRecency: Bool = false) throws -> [DocumentChunkSummary] {
        let order = orderByRecency ? "d.fetched_at DESC, d.id DESC" : "d.source_uri, d.id"
        let rows = try run("""
        SELECT d.*, COUNT(c.id) AS chunk_count
          FROM document d
          LEFT JOIN chunk c ON c.document_id=d.id
         GROUP BY d.id
         ORDER BY \(order)
         LIMIT ?;
        """, [.int(Int64(limit))])
        return rows.map { row in
            DocumentChunkSummary(
                document: Self.rowToDocument(row),
                chunkCount: Int((row["chunk_count"] as? Int64) ?? 0))
        }
    }

    /// Delete a document by id. New databases cascade mentions and clear edge
    /// evidence via FK actions, but older databases may have been created
    /// before those actions existed. Perform the dependent-row cleanup
    /// explicitly so document replacement is reliable across both shapes.
    /// Insight rows do not cascade; the schema keeps them as historical records
    /// by nulling `trigger_chunk_id`.
    public func deleteDocument(id: Int64) throws {
        try execRaw("BEGIN IMMEDIATE;")
        do {
            try purgeDocumentRows(id: id)
            try execRaw("COMMIT;")
        } catch {
            try? execRaw("ROLLBACK;")
            throw error
        }
    }

    /// Promote a fully processed staging document into a stable source URI.
    /// The old document, if present, and all of its search/vector side tables
    /// are purged in the same transaction that updates the staged document's
    /// `source_uri`. This lets importers preserve the last good index until a
    /// replacement has been completely processed.
    public func promoteStagedDocument(stagedId: Int64,
                                      sourceURI: String,
                                      bodyPath: String,
                                      title: String?) throws {
        try execRaw("BEGIN IMMEDIATE;")
        do {
            let existingRows = try run(
                "SELECT id FROM document WHERE source_uri=? AND id<>?;",
                [.text(sourceURI), .int(stagedId)])
            for row in existingRows {
                if let oldId = row["id"] as? Int64 {
                    try purgeDocumentRows(id: oldId)
                }
            }
            try run("""
            UPDATE document
            SET source_uri=?, body_path=?, title=COALESCE(?, title)
            WHERE id=?;
            """, [
                .text(sourceURI),
                .text(bodyPath),
                title.map(Bind.text) ?? .null,
                .int(stagedId),
            ])
            try execRaw("COMMIT;")
        } catch {
            try? execRaw("ROLLBACK;")
            throw error
        }
    }

    private func purgeDocumentRows(id: Int64) throws {
        // Purge the FTS5 (external-content) and vec0 virtual-table rows for
        // this document's chunks. Neither is reachable by a FK cascade and
        // there are no sync triggers, so without this they accumulate orphan
        // rows: stale BM25 hits in search, dangling ANN vectors, and —
        // because both index by chunk.id — desync when a re-imported document
        // reuses a recycled rowid. Must run while the chunk rows still exist,
        // because the FTS5 external-content 'delete' command needs the
        // originally-indexed text.
        try purgeChunks(documentId: id)
        try run("DELETE FROM document WHERE id=?;", [.int(id)])
    }

    /// Purge a document's chunk rows + their derived index rows (FTS5, vec0,
    /// chunk_embedding) and null any edge/insight references — WITHOUT deleting
    /// the document itself. Shared by `deleteDocument` (which then drops the doc)
    /// and `rewriteManualPage` (which then re-inserts fresh chunks). Must run
    /// while the chunk rows still exist (the FTS5 external-content 'delete' needs
    /// the originally-indexed text).
    private func purgeChunks(documentId id: Int64) throws {
        let staleChunks = try run(
            "SELECT id, text FROM chunk WHERE document_id=?;", [.int(id)])
        for row in staleChunks {
            guard let cid = row["id"] as? Int64 else { continue }
            let text = (row["text"] as? String) ?? ""
            try run(
                "INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES('delete', ?, ?);",
                [.int(cid), .text(text)])
            if vecAvailable {
                try run("DELETE FROM chunk_vec WHERE rowid=?;", [.int(cid)])
            }
        }
        try run("""
        UPDATE edge SET evidence_chunk_id=NULL
        WHERE evidence_chunk_id IN (
          SELECT id FROM chunk WHERE document_id=?
        );
        """, [.int(id)])
        try run("""
        UPDATE insight SET trigger_chunk_id=NULL
        WHERE trigger_chunk_id IN (
          SELECT id FROM chunk WHERE document_id=?
        );
        """, [.int(id)])
        try run("""
        DELETE FROM mention
        WHERE chunk_id IN (
          SELECT id FROM chunk WHERE document_id=?
        );
        """, [.int(id)])
        if !vecAvailable {
            try run("""
            DELETE FROM chunk_embedding
            WHERE chunk_id IN (
              SELECT id FROM chunk WHERE document_id=?
            );
            """, [.int(id)])
        }
        try run("DELETE FROM chunk WHERE document_id=?;", [.int(id)])
    }

    /// Insert-or-replace a manually-authored wiki page: upsert the document by
    /// `sourceURI`, then REPLACE its chunks with lexically-indexed chunks of the
    /// body (zero embedding vectors — BM25/FTS search works immediately; full
    /// embedding + entity extraction is a later background re-process). Returns
    /// the document id. The whole operation runs in one transaction.
    /// NOTE: not wrapped in an outer transaction — `insertChunk` opens its own
    /// `BEGIN IMMEDIATE` per chunk (SQLite has no nested transactions), so the
    /// sub-operations each commit independently. A mid-write failure can leave a
    /// partially re-chunked page; the next save corrects it (purgeChunks clears
    /// the prior set first). Acceptable for a single-operator edit surface.
    @discardableResult
    public func rewriteManualPage(sourceURI: String, title: String?, bodyPath: String,
                                  contentSHA: Data, rawBytes: Int64, now: Int64,
                                  chunkTexts: [String]) throws -> Int64 {
        let id = try upsertDocument(DocumentRow(
            source: .manual, sourceURI: sourceURI, title: title, bodyPath: bodyPath,
            fetchedAt: now, contentSHA: contentSHA, rawBytes: rawBytes))
        try purgeChunks(documentId: id)
        let zero = [Float](repeating: 0, count: config.embeddingDimension)
        var idx = 0
        for raw in chunkTexts {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            _ = try insertChunk(ChunkRow(
                documentId: id, idx: idx, text: t, rawText: t,
                tokenCount: max(1, t.split(whereSeparator: { $0 == " " || $0 == "\n" }).count),
                createdAt: now), embeddingValues: zero)
            idx += 1
        }
        return id
    }

    public func documentCount() throws -> Int {
        let rows = try run("SELECT COUNT(*) AS n FROM document;", [])
        return Int((rows.first?["n"] as? Int64) ?? 0)
    }

    // MARK: - public CRUD: chunks

    /// Insert a chunk plus its embedding values. Callers from MemoryInfer pass
    /// a `[Float]` directly so MemoryProcess doesn't have to disambiguate
    /// between the two top-level `Embedding` types (one per module).
    @discardableResult
    public func insertChunk(_ c: ChunkRow, embeddingValues: [Float]) throws -> Int64 {
        let embedding = Embedding(embeddingValues)
        guard embedding.dimension == config.embeddingDimension else {
            throw MemoryStoreError.invalid(
                "embedding dim \(embedding.dimension) != store dim \(config.embeddingDimension)")
        }
        try execRaw("BEGIN IMMEDIATE;")
        do {
            let rows = try run("""
            INSERT INTO chunk(document_id,idx,text,raw_text,token_count,
                              logprob_avg,created_at)
            VALUES(?,?,?,?,?,?,?)
            RETURNING id;
            """, [
                .int(c.documentId), .int(Int64(c.idx)),
                .text(c.text), .text(c.rawText), .int(Int64(c.tokenCount)),
                c.logprobAvg.map(Bind.real) ?? .null,
                .int(c.createdAt),
            ])
            let id = (rows.first?["id"] as? Int64) ?? 0

            // FTS row (content table; explicit rowid binds it to chunk.id).
            try run("INSERT INTO chunk_fts(rowid,text) VALUES(?,?);",
                    [.int(id), .text(c.text)])

            if vecAvailable {
                try run("INSERT INTO chunk_vec(rowid,embedding) VALUES(?,?);",
                        [.int(id), .blob(embedding.toBlob())])
            } else {
                try run("INSERT INTO chunk_embedding(chunk_id,embedding) VALUES(?,?);",
                        [.int(id), .blob(embedding.normalised().toBlob())])
            }
            try execRaw("COMMIT;")
            return id
        } catch {
            try? execRaw("ROLLBACK;")
            throw error
        }
    }

    public func chunk(id: Int64) throws -> ChunkRow? {
        let rows = try run("SELECT * FROM chunk WHERE id=?;", [.int(id)])
        return rows.first.map(Self.rowToChunk)
    }

    public func chunks(forDocument docId: Int64) throws -> [ChunkRow] {
        try run("SELECT * FROM chunk WHERE document_id=? ORDER BY idx;", [.int(docId)])
            .map(Self.rowToChunk)
    }

    public func chunkCount() throws -> Int {
        let rows = try run("SELECT COUNT(*) AS n FROM chunk;")
        return Int((rows.first?["n"] as? Int64) ?? 0)
    }

    public func chunkCount(documentId: Int64) throws -> Int {
        let rows = try run("SELECT COUNT(*) AS n FROM chunk WHERE document_id=?;",
                           [.int(documentId)])
        return Int((rows.first?["n"] as? Int64) ?? 0)
    }

    public func embedding(forChunk id: Int64) throws -> Embedding? {
        if vecAvailable {
            // Read back via vec0 — emit the raw bytes column.
            let rows = try run("SELECT embedding FROM chunk_vec WHERE rowid=?;", [.int(id)])
            guard let data = rows.first?["embedding"] as? Data else { return nil }
            return Embedding(blob: data)
        } else {
            let rows = try run("SELECT embedding FROM chunk_embedding WHERE chunk_id=?;",
                               [.int(id)])
            guard let data = rows.first?["embedding"] as? Data else { return nil }
            return Embedding(blob: data)
        }
    }

    // MARK: - search: vectors

    /// Convenience overload for callers that already have a `[Float]` from
    /// the MemoryInfer side. Bridges through the module-private `Embedding`
    /// type so callers don't need to disambiguate it from `MemoryInfer.Embedding`.
    public func searchVectorValues(_ values: [Float], k: Int) throws -> [VectorHit] {
        try searchVectors(Embedding(values), k: k)
    }

    /// Cosine-nearest top-k. When sqlite-vec is linked this hands off to the
    /// vec0 MATCH operator; otherwise it streams the blob column and computes
    /// cosine in Swift. The Swift fallback is correctness-equivalent — only
    /// the constant factor differs.
    public func searchVectors(_ query: Embedding, k: Int) throws -> [VectorHit] {
        guard query.dimension == config.embeddingDimension else {
            throw MemoryStoreError.invalid("vector search dim mismatch")
        }
        let normalised = query.normalised()
        if vecAvailable {
            // sqlite-vec's vec0 KNN syntax forbids both `k = ?` and `LIMIT`
            // in the same SELECT; `k` already caps the result count.
            let rows = try run("""
            SELECT rowid AS id, distance
              FROM chunk_vec
             WHERE embedding MATCH ?
               AND k = ?
             ORDER BY distance;
            """, [.blob(normalised.toBlob()), .int(Int64(k))])
            return rows.compactMap { r in
                guard let id = r["id"] as? Int64, let d = r["distance"] as? Double
                else { return nil }
                return VectorHit(chunkId: id, distance: d)
            }
        }
        // Fallback path: read every embedding, compute cosine in-process,
        // keep a top-k heap. At 200k chunks this is still <80 MB to stream
        // and a few hundred ms; for the production hot path the sqlite-vec
        // amalgamation is the documented upgrade.
        var heap = TopK<VectorHit>(capacity: k) { $0.distance < $1.distance }
        try runStream("SELECT chunk_id, embedding FROM chunk_embedding;", []) { s in
            let id = sqlite3_column_int64(s, 0)
            let n = Int(sqlite3_column_bytes(s, 1))
            guard let p = sqlite3_column_blob(s, 1), n > 0 else { return }
            let data = Data(bytes: p, count: n)
            guard let other = Embedding(blob: data) else { return }
            let d = normalised.cosineDistance(to: other)
            heap.insert(VectorHit(chunkId: id, distance: d))
        }
        return heap.sorted()
    }

    // MARK: - search: BM25 / FTS5

    public func searchLexical(_ query: String, k: Int) throws -> [LexicalHit] {
        // FTS5 rank is a negative score where smaller == better; invert so
        // callers can sort descending. Escape the query by stripping reserved
        // characters; the caller-side `MemoryRetrieve` does richer query
        // normalisation.
        let safe = Self.sanitizeFTSQuery(query)
        guard !safe.isEmpty else { return [] }
        let rows = try run("""
        SELECT rowid AS id, bm25(chunk_fts) AS rank
          FROM chunk_fts
         WHERE chunk_fts MATCH ?
         ORDER BY rank
         LIMIT ?;
        """, [.text(safe), .int(Int64(k))])
        return rows.compactMap { r in
            guard let id = r["id"] as? Int64,
                  let rank = r["rank"] as? Double else { return nil }
            return LexicalHit(chunkId: id, score: -rank)
        }
    }

    static func sanitizeFTSQuery(_ q: String) -> String {
        // FTS5 reserves a small set of punctuation. We strip them and split
        // on whitespace, OR-joining the bag-of-words; this matches how the
        // upstream Codex memory examples shape MATCH expressions.
        let stripped = q.unicodeScalars.map { ch -> Character in
            switch ch {
            case "\"", "'", ":", "(", ")", "*", "^", "+": return " "
            default: return Character(ch)
            }
        }
        let words = String(stripped)
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0)\"" }
        return words.joined(separator: " OR ")
    }

    // MARK: - entities

    /// Insert or refresh an entity by `(kind, canonical)`. Returns the row id.
    @discardableResult
    public func upsertEntity(_ e: EntityRow) throws -> Int64 {
        let aliasJSON = (try? JSONEncoder().encode(e.aliases))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let rows = try run("""
        INSERT INTO entity(kind,canonical,aliases,first_seen,last_seen,degree,
                           ego_betweenness_cached)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(kind,canonical) DO UPDATE SET
          aliases=excluded.aliases,
          last_seen=MAX(entity.last_seen,excluded.last_seen)
        RETURNING id;
        """, [
            .text(e.kind.rawValue), .text(e.canonical),
            .text(aliasJSON),
            .int(e.firstSeen), .int(e.lastSeen),
            .int(Int64(e.degree)),
            e.egoBetweennessCached.map(Bind.real) ?? .null,
        ])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func entity(id: Int64) throws -> EntityRow? {
        let rows = try run("SELECT * FROM entity WHERE id=?;", [.int(id)])
        return rows.first.map(Self.rowToEntity)
    }

    public func entity(kind: EntityKind, canonical: String) throws -> EntityRow? {
        let rows = try run("SELECT * FROM entity WHERE kind=? AND canonical=?;",
                           [.text(kind.rawValue), .text(canonical)])
        return rows.first.map(Self.rowToEntity)
    }

    public func entityCount() throws -> Int {
        let rows = try run("SELECT COUNT(*) AS n FROM entity;")
        return Int((rows.first?["n"] as? Int64) ?? 0)
    }

    public func entities(limit: Int = 10_000) throws -> [EntityRow] {
        try run("""
        SELECT * FROM entity
         ORDER BY kind, canonical, id
         LIMIT ?;
        """, [.int(Int64(limit))]).map(Self.rowToEntity)
    }

    /// Entities of a single `kind`, ordered by `degree` DESC (most-connected
    /// first). The WHERE filter is applied in SQL so the LIMIT can't starve the
    /// result (e.g. a tag cloud isn't crowded out by thousands of non-tag rows).
    public func entities(kind: EntityKind, limit: Int = 10_000) throws -> [EntityRow] {
        try run("""
        SELECT * FROM entity
         WHERE kind=?
         ORDER BY degree DESC, canonical, id
         LIMIT ?;
        """, [.text(kind.rawValue), .int(Int64(limit))]).map(Self.rowToEntity)
    }

    public func setEgoBetweenness(entityId: Int64, value: Double) throws {
        try run("UPDATE entity SET ego_betweenness_cached=? WHERE id=?;",
                [.real(value), .int(entityId)])
    }

    public func resetEgoBetweenness() throws {
        try execRaw("UPDATE entity SET ego_betweenness_cached=NULL;")
    }

    // MARK: - edges

    /// Insert an edge (idempotent on `(src,dst,relation)`).
    @discardableResult
    public func upsertEdge(_ e: EdgeRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO edge(src,dst,relation,first_seen,last_seen,weight,evidence_chunk_id)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(src,dst,relation) DO UPDATE SET
          last_seen=MAX(edge.last_seen,excluded.last_seen),
          weight=edge.weight+excluded.weight
        RETURNING id;
        """, [
            .int(e.src), .int(e.dst), .text(e.relation),
            .int(e.firstSeen), .int(e.lastSeen),
            .real(e.weight),
            e.evidenceChunkId.map(Bind.int) ?? .null,
        ])
        // Maintain the degree counters. A self-loop edge (src == dst)
        // contributes 2 to the entity's undirected degree, not 1 — `WHERE
        // src=id OR dst=id` would count the single edge row only once. Sum
        // the two halves separately so self-loops are reflected correctly.
        try run("""
        UPDATE entity SET degree = (
          (SELECT COUNT(*) FROM edge WHERE src=entity.id)
          + (SELECT COUNT(*) FROM edge WHERE dst=entity.id)
        ) WHERE id IN (?,?);
        """, [.int(e.src), .int(e.dst)])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func edges(fromOrTo entityId: Int64) throws -> [EdgeRow] {
        try run("SELECT * FROM edge WHERE src=? OR dst=? ORDER BY id;",
                [.int(entityId), .int(entityId)]).map(Self.rowToEdge)
    }

    public func edgesIntroducedAfter(_ ts: Int64) throws -> [EdgeRow] {
        try run("SELECT * FROM edge WHERE first_seen>=? ORDER BY id;",
                [.int(ts)]).map(Self.rowToEdge)
    }

    public func edgeCount() throws -> Int {
        let rows = try run("SELECT COUNT(*) AS n FROM edge;")
        return Int((rows.first?["n"] as? Int64) ?? 0)
    }

    public func edges(limit: Int = 10_000) throws -> [EdgeRow] {
        try run("""
        SELECT * FROM edge
         ORDER BY src, dst, relation, id
         LIMIT ?;
        """, [.int(Int64(limit))]).map(Self.rowToEdge)
    }

    /// 2-hop expansion from `seed`. The recursive CTE bounds the depth and
    /// breaks cycles with the canonical `instr(path, ',' || dst || ',') = 0`
    /// idiom; the design doc spells this out in §3.
    public func twoHopNeighbours(seed: Int64, depth: Int = 2) throws -> [(Int64, Int)] {
        // Untrusted MCP input lands here directly, so a precondition trap
        // would let any client crash the daemon. Throw instead.
        guard (1...4).contains(depth) else {
            throw MemoryStoreError.invalid("depth must be 1...4 (got \(depth))")
        }
        let rows = try run("""
        WITH RECURSIVE walk(node, depth, path) AS (
          SELECT ?, 0, ',' || ? || ','
          UNION ALL
          SELECT e.dst, w.depth + 1, w.path || e.dst || ','
            FROM edge e JOIN walk w ON e.src = w.node
           WHERE w.depth < ?
             AND instr(w.path, ',' || e.dst || ',') = 0
        )
        SELECT node, MIN(depth) AS d
          FROM walk GROUP BY node ORDER BY d;
        """, [.int(seed), .int(seed), .int(Int64(depth))])
        return rows.compactMap { r in
            guard let n = r["node"] as? Int64, let d = r["d"] as? Int64 else { return nil }
            return (n, Int(d))
        }
    }

    // MARK: - mentions

    public func insertMention(_ m: MentionRow) throws {
        try run("""
        INSERT OR IGNORE INTO mention(chunk_id,entity_id,span_start,span_end,salience)
        VALUES(?,?,?,?,?);
        """, [
            .int(m.chunkId), .int(m.entityId),
            m.spanStart.map { .int(Int64($0)) } ?? .null,
            m.spanEnd.map { .int(Int64($0)) } ?? .null,
            m.salience.map(Bind.real) ?? .null,
        ])
    }

    public func entitiesForChunk(_ chunkId: Int64) throws -> [Int64] {
        try run("SELECT entity_id FROM mention WHERE chunk_id=?;", [.int(chunkId)])
            .compactMap { $0["entity_id"] as? Int64 }
    }

    public func chunksMentioning(_ entityId: Int64, limit: Int = 50) throws -> [Int64] {
        try run("SELECT chunk_id FROM mention WHERE entity_id=? LIMIT ?;",
                [.int(entityId), .int(Int64(limit))])
            .compactMap { $0["chunk_id"] as? Int64 }
    }

    public func chunkEvidence(id: Int64) throws -> ChunkEvidenceRow? {
        let rows = try run("""
        SELECT c.id AS c_id, c.document_id AS c_document_id, c.idx AS c_idx,
               c.text AS c_text, c.raw_text AS c_raw_text,
               c.token_count AS c_token_count, c.logprob_avg AS c_logprob_avg,
               c.created_at AS c_created_at,
               d.id AS d_id, d.source AS d_source, d.source_uri AS d_source_uri,
               d.title AS d_title, d.body_path AS d_body_path,
               d.fetched_at AS d_fetched_at, d.published_at AS d_published_at,
               d.content_sha AS d_content_sha, d.language AS d_language,
               d.raw_bytes AS d_raw_bytes
          FROM chunk c
          LEFT JOIN document d ON d.id=c.document_id
         WHERE c.id=?;
        """, [.int(id)])
        guard let row = rows.first else { return nil }
        let chunk = ChunkRow(
            id: (row["c_id"] as? Int64) ?? 0,
            documentId: (row["c_document_id"] as? Int64) ?? 0,
            idx: Int((row["c_idx"] as? Int64) ?? 0),
            text: (row["c_text"] as? String) ?? "",
            rawText: (row["c_raw_text"] as? String) ?? "",
            tokenCount: Int((row["c_token_count"] as? Int64) ?? 0),
            logprobAvg: row["c_logprob_avg"] as? Double,
            createdAt: (row["c_created_at"] as? Int64) ?? 0)
        let document: DocumentRow?
        if row["d_id"] as? Int64 != nil {
            let source = MemorySource(rawValue: (row["d_source"] as? String) ?? "") ?? .manual
            document = DocumentRow(
                id: (row["d_id"] as? Int64) ?? 0,
                source: source,
                sourceURI: (row["d_source_uri"] as? String) ?? "",
                title: row["d_title"] as? String,
                bodyPath: (row["d_body_path"] as? String) ?? "",
                fetchedAt: (row["d_fetched_at"] as? Int64) ?? 0,
                publishedAt: row["d_published_at"] as? Int64,
                contentSHA: (row["d_content_sha"] as? Data) ?? Data(),
                language: row["d_language"] as? String,
                rawBytes: (row["d_raw_bytes"] as? Int64) ?? 0)
        } else {
            document = nil
        }
        return ChunkEvidenceRow(chunk: chunk, document: document)
    }

    // MARK: - insight cards + spend

    @discardableResult
    public func insertInsight(_ row: InsightRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO insight(trigger_chunk_id,model,input_tokens,output_tokens,
                            cached_input_tokens,cost_usd,score,card_md,created_at)
        VALUES(?,?,?,?,?,?,?,?,?)
        RETURNING id;
        """, [
            .int(row.triggerChunkId), .text(row.model),
            .int(row.inputTokens), .int(row.outputTokens),
            .int(row.cachedInputTokens), .real(row.costUSD),
            .real(row.score), .text(row.cardMD), .int(row.createdAt),
        ])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func recordSpend(_ row: SpendRow) throws {
        try run("""
        INSERT INTO spend(ts,bucket,units,unit_kind,cost_usd)
        VALUES(?,?,?,?,?);
        """, [
            .int(row.ts), .text(row.bucket),
            .real(row.units), .text(row.unitKind), .real(row.costUSD),
        ])
    }

    public struct RecentInterestingRow: Sendable, Equatable {
        public var insightId: Int64
        public var chunkId: Int64
        public var documentId: Int64
        public var documentURI: String
        public var snippet: String
        public var score: Double
        public var costUSD: Double
        public var createdAt: Int64
    }

    /// Recently-admitted gate hits: LEFT JOIN insight → chunk → document so a
    /// deleted chunk/document doesn't silently hide the insight row (the
    /// gate's spend ledger and the surfaceable insight history must stay in
    /// agreement even when retention cascades through chunks). Filter on
    /// score + window, return newest-first.
    public func recentInteresting(since ts: Int64,
                                  minScore: Double,
                                  limit: Int = 20) throws -> [RecentInterestingRow] {
        let rows = try run("""
        SELECT i.id AS insight_id,
               i.trigger_chunk_id AS chunk_id,
               c.document_id AS document_id,
               d.source_uri AS document_uri,
               substr(COALESCE(c.text, ''), 1, 280) AS snippet,
               i.score AS score,
               i.cost_usd AS cost_usd,
               i.created_at AS created_at
          FROM insight i
          LEFT JOIN chunk c ON c.id = i.trigger_chunk_id
          LEFT JOIN document d ON d.id = c.document_id
         WHERE i.created_at >= ? AND i.score >= ?
         ORDER BY i.created_at DESC, i.score DESC
         LIMIT ?;
        """, [.int(ts), .real(minScore), .int(Int64(limit))])
        return rows.compactMap { r in
            guard let iid = r["insight_id"] as? Int64,
                  let score = r["score"] as? Double,
                  let cost = r["cost_usd"] as? Double,
                  let createdAt = r["created_at"] as? Int64
            else { return nil }
            return RecentInterestingRow(
                insightId: iid,
                chunkId: (r["chunk_id"] as? Int64) ?? 0,
                documentId: (r["document_id"] as? Int64) ?? 0,
                documentURI: (r["document_uri"] as? String) ?? "(orphan)",
                snippet: (r["snippet"] as? String) ?? "",
                score: score, costUSD: cost, createdAt: createdAt)
        }
    }

    public func monthlySpend(bucket: String, monthStart ts: Int64) throws -> Double {
        let rows = try run("""
        SELECT COALESCE(SUM(cost_usd),0) AS total FROM spend
         WHERE bucket=? AND ts>=?;
        """, [.text(bucket), .int(ts)])
        return (rows.first?["total"] as? Double) ?? 0
    }

    // MARK: - source cursors

    public func upsertCursor(_ row: SourceCursorRow) throws {
        try run("""
        INSERT INTO source_cursor(source,last_etag,last_modified,
                                  high_watermark_id,next_eligible_at,
                                  consecutive_failures)
        VALUES(?,?,?,?,?,?)
        ON CONFLICT(source) DO UPDATE SET
          last_etag=excluded.last_etag,
          last_modified=excluded.last_modified,
          high_watermark_id=excluded.high_watermark_id,
          next_eligible_at=excluded.next_eligible_at,
          consecutive_failures=excluded.consecutive_failures;
        """, [
            .text(row.source),
            row.lastETag.map(Bind.text) ?? .null,
            row.lastModified.map(Bind.int) ?? .null,
            row.highWatermarkID.map(Bind.text) ?? .null,
            .int(row.nextEligibleAt),
            .int(Int64(row.consecutiveFailures)),
        ])
    }

    public func cursor(source: String) throws -> SourceCursorRow? {
        let rows = try run("SELECT * FROM source_cursor WHERE source=?;", [.text(source)])
        return rows.first.map(Self.rowToCursor)
    }

    public func dueCursors(now: Int64, limit: Int = 16) throws -> [SourceCursorRow] {
        try run("""
        SELECT * FROM source_cursor
         WHERE next_eligible_at <= ?
         ORDER BY next_eligible_at ASC
         LIMIT ?;
        """, [.int(now), .int(Int64(limit))]).map(Self.rowToCursor)
    }

    // MARK: - maintenance

    public func vacuumInto(_ path: String) throws {
        try execRaw("VACUUM INTO '\(path.replacingOccurrences(of: "'", with: "''"))';")
    }

    public func checkpoint() throws {
        try execRaw("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    public func indexHealth(sampleLimit: Int = 100) throws -> MemoryStoreIndexHealth {
        let documentCount = try documentCount()
        let chunkCount = try chunkCount()
        let entityCount = try entityCount()
        let edgeCount = try edgeCount()
        let limit = Int64(sampleLimit)

        let zeroDocs = try run("""
        SELECT d.id
          FROM document d
          LEFT JOIN chunk c ON c.document_id=d.id
         GROUP BY d.id
        HAVING COUNT(c.id)=0
         ORDER BY d.id
         LIMIT ?;
        """, [.int(limit)]).compactMap { $0["id"] as? Int64 }

        let orphanChunks = try run("""
        SELECT c.id
          FROM chunk c
          LEFT JOIN document d ON d.id=c.document_id
         WHERE d.id IS NULL
         ORDER BY c.id
         LIMIT ?;
        """, [.int(limit)]).compactMap { $0["id"] as? Int64 }

        let missingVector: [Int64]
        let staleVector: [Int64]
        if vecAvailable {
            missingVector = try run("""
            SELECT c.id
              FROM chunk c
             WHERE NOT EXISTS (SELECT 1 FROM chunk_vec v WHERE v.rowid=c.id)
             ORDER BY c.id
             LIMIT ?;
            """, [.int(limit)]).compactMap { $0["id"] as? Int64 }
            staleVector = try run("""
            SELECT v.rowid AS id
              FROM chunk_vec v
              LEFT JOIN chunk c ON c.id=v.rowid
             WHERE c.id IS NULL
             ORDER BY v.rowid
             LIMIT ?;
            """, [.int(limit)]).compactMap { $0["id"] as? Int64 }
        } else {
            missingVector = try run("""
            SELECT c.id
              FROM chunk c
             WHERE NOT EXISTS (
               SELECT 1 FROM chunk_embedding e WHERE e.chunk_id=c.id
             )
             ORDER BY c.id
             LIMIT ?;
            """, [.int(limit)]).compactMap { $0["id"] as? Int64 }
            staleVector = try run("""
            SELECT e.chunk_id AS id
              FROM chunk_embedding e
              LEFT JOIN chunk c ON c.id=e.chunk_id
             WHERE c.id IS NULL
             ORDER BY e.chunk_id
             LIMIT ?;
            """, [.int(limit)]).compactMap { $0["id"] as? Int64 }
        }

        let ftsOK: Bool
        let ftsError: String?
        do {
            try run("INSERT INTO chunk_fts(chunk_fts) VALUES('integrity-check');")
            ftsOK = true
            ftsError = nil
        } catch {
            ftsOK = false
            ftsError = String(describing: error)
        }

        return MemoryStoreIndexHealth(
            documentCount: documentCount,
            chunkCount: chunkCount,
            entityCount: entityCount,
            edgeCount: edgeCount,
            zeroChunkDocumentIds: zeroDocs,
            orphanChunkIds: orphanChunks,
            chunksMissingVector: missingVector,
            staleVectorRowIds: staleVector,
            ftsIntegrityOK: ftsOK,
            ftsIntegrityError: ftsError)
    }

    // MARK: - row decoders

    private static func rowToDocument(_ r: [String: Any]) -> DocumentRow {
        func s(_ k: String) -> String { (r[k] as? String) ?? "" }
        func i(_ k: String) -> Int64 { (r[k] as? Int64) ?? 0 }
        let source = MemorySource(rawValue: s("source")) ?? .manual
        return DocumentRow(
            id: i("id"), source: source, sourceURI: s("source_uri"),
            title: r["title"] as? String, bodyPath: s("body_path"),
            fetchedAt: i("fetched_at"), publishedAt: r["published_at"] as? Int64,
            contentSHA: (r["content_sha"] as? Data) ?? Data(),
            language: r["language"] as? String, rawBytes: i("raw_bytes"))
    }

    private static func rowToChunk(_ r: [String: Any]) -> ChunkRow {
        func s(_ k: String) -> String { (r[k] as? String) ?? "" }
        func i(_ k: String) -> Int64 { (r[k] as? Int64) ?? 0 }
        return ChunkRow(
            id: i("id"), documentId: i("document_id"),
            idx: Int(i("idx")), text: s("text"), rawText: s("raw_text"),
            tokenCount: Int(i("token_count")),
            logprobAvg: r["logprob_avg"] as? Double,
            createdAt: i("created_at"))
    }

    private static func rowToEntity(_ r: [String: Any]) -> EntityRow {
        func s(_ k: String) -> String { (r[k] as? String) ?? "" }
        func i(_ k: String) -> Int64 { (r[k] as? Int64) ?? 0 }
        let kind = EntityKind(rawValue: s("kind")) ?? .concept
        let aliases: [String]
        if let aj = r["aliases"] as? String,
           let data = aj.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            aliases = arr
        } else {
            aliases = []
        }
        return EntityRow(
            id: i("id"), kind: kind, canonical: s("canonical"),
            aliases: aliases,
            firstSeen: i("first_seen"), lastSeen: i("last_seen"),
            degree: Int(i("degree")),
            egoBetweennessCached: r["ego_betweenness_cached"] as? Double)
    }

    private static func rowToEdge(_ r: [String: Any]) -> EdgeRow {
        func s(_ k: String) -> String { (r[k] as? String) ?? "" }
        func i(_ k: String) -> Int64 { (r[k] as? Int64) ?? 0 }
        return EdgeRow(
            id: i("id"), src: i("src"), dst: i("dst"),
            relation: s("relation"),
            firstSeen: i("first_seen"), lastSeen: i("last_seen"),
            weight: (r["weight"] as? Double) ?? 1.0,
            evidenceChunkId: r["evidence_chunk_id"] as? Int64)
    }

    private static func rowToCursor(_ r: [String: Any]) -> SourceCursorRow {
        func s(_ k: String) -> String { (r[k] as? String) ?? "" }
        return SourceCursorRow(
            source: s("source"),
            lastETag: r["last_etag"] as? String,
            lastModified: r["last_modified"] as? Int64,
            highWatermarkID: r["high_watermark_id"] as? String,
            nextEligibleAt: (r["next_eligible_at"] as? Int64) ?? 0,
            consecutiveFailures: Int((r["consecutive_failures"] as? Int64) ?? 0))
    }
}

/// Tiny fixed-capacity max-heap-by-key for the in-Swift cosine fallback. A
/// dependency-free top-k that runs once per search call.
struct TopK<T> {
    private var items: [T] = []
    private let capacity: Int
    /// Returns true when `a` is *better* (lower distance, higher score, etc.).
    private let isBetter: (T, T) -> Bool

    init(capacity: Int, isBetter: @escaping (T, T) -> Bool) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.isBetter = isBetter
    }

    mutating func insert(_ item: T) {
        if items.count < capacity {
            items.append(item)
            return
        }
        // Find current worst; replace if `item` is better.
        var worstIdx = 0
        for i in 1..<items.count where isBetter(items[worstIdx], items[i]) {
            worstIdx = i
        }
        if isBetter(item, items[worstIdx]) {
            items[worstIdx] = item
        }
    }

    func sorted() -> [T] { items.sorted(by: isBetter) }
}
