import Foundation
import CSQLite
import Mem0Core

/// SQLite destructor sentinel: tells SQLite to copy bound text/blob immediately.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func vectorToData(_ v: [Float]) -> Data {
    v.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func dataToVector(_ d: Data) -> [Float] {
    if d.isEmpty { return [] }
    return d.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Float.self))
    }
}

private func cosine(_ a: [Float], _ b: [Float]) -> Float {
    if a.count != b.count { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    if na == 0 || nb == 0 { return 0 }
    return dot / (sqrt(na) * sqrt(nb))
}

/// A single SQLite-backed store that satisfies BOTH the vector-store and the
/// history-store seams (one connection, one file). Vectors + payloads live in
/// `memories`; an in-memory cache mirrors that table so semantic (cosine) and
/// keyword (BM25) search run brute-force over the filtered candidate set —
/// exactly the validated `mem0-rs` embedded-store approach — while writes are
/// persisted through to SQLite. History + recent-messages use the mem0 schema.
/// Pass the same instance as both `vectorStore` and `historyStore` to
/// `Mem0Engine`.
///
/// NOTE: all prepared-statement work (the bodies that use `defer {
/// sqlite3_finalize }`) lives in NONISOLATED `static` helpers over an explicit
/// `db` handle. This is deliberate: Swift 6.0.x's `TransferNonSendable` SIL
/// pass crashes (assertion in `SILIsolationInfo::get`) when analyzing a `defer`
/// closure inside an actor-isolated method. Keeping the `defer`s in nonisolated
/// statics sidesteps that compiler bug; the actor methods are thin wrappers that
/// call the statics and update the in-memory cache.
public actor Mem0SQLiteStore: Mem0VectorStore, Mem0HistoryStore {
    private nonisolated(unsafe) let db: OpaquePointer
    private var cache: [String: VectorRecord] = [:]

    /// Enforce tenant scope at the STORE (defense in depth, gbrain.md Wave 0.6).
    /// A scope-less filter fails CLOSED (returns nothing) rather than matching
    /// every tenant's records — closing the cross-tenant leak a filter-construction
    /// bug could open (an empty filter matches ALL records). The engine always
    /// scopes (`buildFiltersAndMetadata` throws without a scope), so this never
    /// triggers in legitimate flow. Disable for admin/global tools with
    /// `CODEX_MEM0_ALLOW_UNSCOPED=1`, or toggle directly in tests.
    public var enforceTenantScope: Bool =
        ProcessInfo.processInfo.environment["CODEX_MEM0_ALLOW_UNSCOPED"] != "1"

    /// Tenant-scope keys: at least one must be present for a scoped read.
    static let tenantScopeKeys: Set<String> = ["user_id", "agent_id", "run_id"]

    /// True when `filters` carries a tenant scope — a direct scope key with a
    /// non-null value, or an `$or` whose every branch is itself scoped.
    static func hasTenantScope(_ filters: JSONObject) -> Bool {
        for k in tenantScopeKeys {
            if let v = filters[k], !v.isNull { return true }
        }
        if let branches = filters["$or"]?.arrayValue, !branches.isEmpty {
            return branches.allSatisfy { ($0.objectValue).map(hasTenantScope) ?? false }
        }
        return false
    }

    /// Admin/test hook to toggle store-level scope enforcement.
    public func setEnforceTenantScope(_ enabled: Bool) { enforceTenantScope = enabled }

    /// Open (or create) the database at `path` (`":memory:"` for ephemeral),
    /// create the schema, and load the memory cache.
    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw Mem0Error.database("failed to open SQLite at \(path)")
        }
        self.db = handle
        try Self.createSchema(handle)
        self.cache = try Self.loadCache(handle)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - low-level statics (over an explicit handle; nonisolated)

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw Mem0Error.database("exec failed: \(msg)")
        }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw Mem0Error.database("prepare failed: \(msg)")
        }
        return stmt
    }

    private static func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private static func columnTextOpt(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private static func createSchema(_ db: OpaquePointer) throws {
        try exec(db, """
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            vector BLOB NOT NULL,
            payload TEXT NOT NULL
        );
        """)
        try exec(db, """
        CREATE TABLE IF NOT EXISTS history (
            id TEXT PRIMARY KEY,
            memory_id TEXT,
            old_memory TEXT,
            new_memory TEXT,
            event TEXT,
            created_at DATETIME,
            updated_at DATETIME,
            is_deleted INTEGER,
            actor_id TEXT,
            role TEXT,
            user_id TEXT,
            agent_id TEXT,
            run_id TEXT
        );
        """)
        try addColumnIfMissing(db, table: "history", column: "user_id", declaration: "TEXT")
        try addColumnIfMissing(db, table: "history", column: "agent_id", declaration: "TEXT")
        try addColumnIfMissing(db, table: "history", column: "run_id", declaration: "TEXT")
        try exec(db, "CREATE INDEX IF NOT EXISTS history_scope ON history(memory_id, user_id, agent_id, run_id)")
        try exec(db, """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_scope TEXT,
            role TEXT,
            content TEXT,
            name TEXT,
            created_at DATETIME
        );
        """)
    }

    private static func addColumnIfMissing(_ db: OpaquePointer, table: String,
                                           column: String, declaration: String) throws {
        let stmt = try prepare(db, "PRAGMA table_info(\(table))")
        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnTextOpt(stmt, 1) == column {
                exists = true
                break
            }
        }
        sqlite3_finalize(stmt)
        if exists { return }
        try exec(db, "ALTER TABLE \(table) ADD COLUMN \(column) \(declaration)")
    }

    private static func loadCache(_ db: OpaquePointer) throws -> [String: VectorRecord] {
        var out: [String: VectorRecord] = [:]
        let stmt = try prepare(db, "SELECT id, vector, payload FROM memories")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idC)
            let vec: [Float]
            if let blob = sqlite3_column_blob(stmt, 1) {
                let bytes = Int(sqlite3_column_bytes(stmt, 1))
                vec = dataToVector(Data(bytes: blob, count: bytes))
            } else {
                vec = []
            }
            let payloadStr = columnTextOpt(stmt, 2) ?? "{}"
            let payload = JSONValue.parse(payloadStr)?.objectValue ?? [:]
            out[id] = VectorRecord(id: id, vector: vec, payload: payload)
        }
        return out
    }

    private static func upsertRow(_ db: OpaquePointer, _ r: VectorRecord) throws {
        let stmt = try prepare(db, "INSERT OR REPLACE INTO memories (id, vector, payload) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, r.id)
        let vdata = vectorToData(r.vector)
        vdata.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(vdata.count), SQLITE_TRANSIENT)
        }
        bindText(stmt, 3, JSONValue.object(r.payload).jsonString())
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Mem0Error.database("insert step failed")
        }
    }

    private static func deleteRow(_ db: OpaquePointer, _ id: String) throws {
        let stmt = try prepare(db, "DELETE FROM memories WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Mem0Error.database("delete step failed") }
    }

    private static func insertHistory(_ db: OpaquePointer, memoryID: String, oldMemory: String?,
                                      newMemory: String?, event: String, createdAt: String?,
                                      updatedAt: String?, isDeleted: Int, actorID: String?, role: String?,
                                      userID: String?, agentID: String?, runID: String?) throws {
        let stmt = try prepare(db, """
        INSERT INTO history (id, memory_id, old_memory, new_memory, event,
                             created_at, updated_at, is_deleted, actor_id, role,
                             user_id, agent_id, run_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, UUID().uuidString)
        bindText(stmt, 2, memoryID)
        bindText(stmt, 3, oldMemory)
        bindText(stmt, 4, newMemory)
        bindText(stmt, 5, event)
        bindText(stmt, 6, createdAt)
        bindText(stmt, 7, updatedAt)
        sqlite3_bind_int(stmt, 8, Int32(isDeleted))
        bindText(stmt, 9, actorID)
        bindText(stmt, 10, role)
        bindText(stmt, 11, userID)
        bindText(stmt, 12, agentID)
        bindText(stmt, 13, runID)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw Mem0Error.database("history insert failed")
        }
    }

    private static func queryHistory(_ db: OpaquePointer, _ memoryID: String) throws -> [HistoryRecord] {
        let stmt = try prepare(db, """
        SELECT id, memory_id, old_memory, new_memory, event,
               created_at, updated_at, is_deleted, actor_id, role,
               user_id, agent_id, run_id
        FROM history WHERE memory_id = ?
        ORDER BY created_at ASC, DATETIME(updated_at) ASC
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, memoryID)
        var out: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(HistoryRecord(
                id: columnTextOpt(stmt, 0) ?? "",
                memoryID: columnTextOpt(stmt, 1) ?? "",
                oldMemory: columnTextOpt(stmt, 2),
                newMemory: columnTextOpt(stmt, 3),
                event: columnTextOpt(stmt, 4) ?? "",
                createdAt: columnTextOpt(stmt, 5),
                updatedAt: columnTextOpt(stmt, 6),
                isDeleted: sqlite3_column_int(stmt, 7) != 0,
                actorID: columnTextOpt(stmt, 8),
                role: columnTextOpt(stmt, 9),
                userID: columnTextOpt(stmt, 10),
                agentID: columnTextOpt(stmt, 11),
                runID: columnTextOpt(stmt, 12)))
        }
        return out
    }

    private static func insertMessage(_ db: OpaquePointer, _ m: Message, _ scope: String, _ now: String) throws {
        let stmt = try prepare(db, """
        INSERT INTO messages (id, session_scope, role, content, name, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, UUID().uuidString)
        bindText(stmt, 2, scope)
        bindText(stmt, 3, m.role)
        bindText(stmt, 4, m.content)
        bindText(stmt, 5, m.name)
        bindText(stmt, 6, now)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Mem0Error.database("message insert failed") }
    }

    private static func evictMessages(_ db: OpaquePointer, _ scope: String) throws {
        let stmt = try prepare(db, """
        DELETE FROM messages WHERE session_scope = ? AND id NOT IN (
            SELECT id FROM (
                SELECT id FROM messages WHERE session_scope = ? ORDER BY created_at DESC LIMIT 10
            )
        )
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, scope)
        bindText(stmt, 2, scope)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Mem0Error.database("message eviction failed") }
    }

    private static func queryLastMessages(_ db: OpaquePointer, _ scope: String, _ limit: Int) throws -> [StoredMessage] {
        let stmt = try prepare(db, """
        SELECT role, content, name, created_at FROM (
            SELECT role, content, name, created_at
            FROM messages WHERE session_scope = ?
            ORDER BY created_at DESC LIMIT ?
        ) ORDER BY created_at ASC
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, scope)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [StoredMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(StoredMessage(
                role: columnTextOpt(stmt, 0),
                content: columnTextOpt(stmt, 1),
                name: columnTextOpt(stmt, 2),
                createdAt: columnTextOpt(stmt, 3)))
        }
        return out
    }

    // MARK: - Mem0VectorStore

    public func insert(_ records: [VectorRecord]) async throws {
        try Self.exec(db, "BEGIN")
        do {
            for r in records { try Self.upsertRow(db, r) }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
        for r in records { cache[r.id] = r }
    }

    private func candidates(_ filters: JSONObject) -> [VectorRecord] {
        // Fail closed: a scope-less read must never return cross-tenant data.
        if enforceTenantScope && !Self.hasTenantScope(filters) { return [] }
        return cache.values.filter { Mem0Filters.matchesFilters($0.payload, filters) }
    }

    public func search(_ query: String, _ vector: [Float], topK: Int, filters: JSONObject) async throws -> [SearchHit] {
        var idScores = candidates(filters).map {
            ($0.id, Double(max(cosine(vector, $0.vector), 0)))
        }
        idScores.sort { $0.1 > $1.1 }
        if idScores.count > topK { idScores = Array(idScores.prefix(topK)) }
        return idScores.compactMap { (id, score) in
            cache[id].map { SearchHit(id: id, score: score, payload: $0.payload) }
        }
    }

    public func get(_ id: String) async throws -> SearchHit? {
        guard let r = cache[id] else { return nil }
        return SearchHit(id: r.id, score: 0, payload: r.payload)
    }

    public func update(_ id: String, vector: [Float]?, payload: JSONObject?) async throws {
        guard var r = cache[id] else { return }
        if let v = vector { r.vector = v }
        if let p = payload { r.payload = p }
        try Self.upsertRow(db, r)
        cache[id] = r
    }

    public func delete(_ id: String) async throws {
        try Self.deleteRow(db, id)
        cache[id] = nil
    }

    public func list(_ filters: JSONObject, limit: Int?) async throws -> [SearchHit] {
        var recs = candidates(filters).map { ($0.payload["created_at"]?.stringValue ?? "", $0) }
        recs.sort { $0.0 > $1.0 }
        if let n = limit { recs = Array(recs.prefix(n)) }
        return recs.map { SearchHit(id: $0.1.id, score: 0, payload: $0.1.payload) }
    }

    public func deleteCol() async throws {
        try Self.exec(db, "DELETE FROM memories")
        cache.removeAll()
    }

    public func keywordSearch(_ query: String, topK: Int, filters: JSONObject) async throws -> [SearchHit]? {
        let corpus: [(String, String)] = candidates(filters).map {
            ($0.id, $0.payload["text_lemmatized"]?.stringValue ?? "")
        }
        let scores = Mem0Scoring.bm25Scores(query, corpus: corpus)
        if scores.isEmpty { return [] }
        var idScores = scores.map { ($0.key, $0.value) }
        idScores.sort { $0.1 > $1.1 }
        if idScores.count > topK { idScores = Array(idScores.prefix(topK)) }
        return idScores.compactMap { (id, score) in
            cache[id].map { SearchHit(id: id, score: score, payload: $0.payload) }
        }
    }

    // MARK: - Mem0HistoryStore

    public func addHistory(memoryID: String, oldMemory: String?, newMemory: String?, event: String,
                           createdAt: String?, updatedAt: String?, isDeleted: Int,
                           actorID: String?, role: String?, userID: String?,
                           agentID: String?, runID: String?) async throws {
        try Self.insertHistory(db, memoryID: memoryID, oldMemory: oldMemory, newMemory: newMemory,
                               event: event, createdAt: createdAt, updatedAt: updatedAt,
                               isDeleted: isDeleted, actorID: actorID, role: role,
                               userID: userID, agentID: agentID, runID: runID)
    }

    public func batchAddHistory(_ records: [NewHistory]) async throws {
        try Self.exec(db, "BEGIN")
        do {
            for r in records {
                try Self.insertHistory(db, memoryID: r.memoryID, oldMemory: r.oldMemory, newMemory: r.newMemory,
                                       event: r.event, createdAt: r.createdAt, updatedAt: r.updatedAt,
                                       isDeleted: r.isDeleted, actorID: r.actorID, role: r.role,
                                       userID: r.userID, agentID: r.agentID, runID: r.runID)
            }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    public func getHistory(_ memoryID: String) async throws -> [HistoryRecord] {
        try Self.queryHistory(db, memoryID)
    }

    public func saveMessages(_ messages: [Message], scope: String) async throws {
        if messages.isEmpty { return }
        let now = nowUTCRFC3339()
        try Self.exec(db, "BEGIN")
        do {
            for m in messages { try Self.insertMessage(db, m, scope, now) }
            try Self.evictMessages(db, scope)
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    public func getLastMessages(_ scope: String, limit: Int) async throws -> [StoredMessage] {
        try Self.queryLastMessages(db, scope, limit)
    }

    /// Full reset (satisfies both `Mem0VectorStore.reset` and
    /// `Mem0HistoryStore.reset`): clears memories, history, and messages.
    public func reset() async throws {
        try Self.exec(db, "DELETE FROM memories")
        try Self.exec(db, "DELETE FROM history")
        try Self.exec(db, "DELETE FROM messages")
        cache.removeAll()
    }
}
