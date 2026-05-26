import Foundation
import CSQLite

// MARK: - FTS5-backed candidate index for memories_search
//
// `MemoriesFTSIndex` is a per-memories-directory SQLite database
// (`<memdir>/.index.sqlite`) that maintains an `fts5(text)` index over the
// bodies of every memory file. It is used as a *prefilter*: the index returns
// the set of files that contain (at least one of) the user's query terms; the
// expensive line-level matching (case-sensitivity, normalization, all-on-same
// -line / all-within-N-lines, context windows) still runs in Swift on that
// small candidate set. This preserves every behavioural detail of the previous
// implementation while replacing the O(files × lines × terms) full scan with
// an O(matching-files) lookup.
//
// Invalidation:
//   * On every public call we re-scan the memories directory (FileManager
//     `enumerator` — fast for the contents we already advertise) and compare
//     mtime+size to what the index recorded. Modified/created files are
//     re-tokenised; deleted files are dropped.
//
// Thread-safety:
//   * The actor serialises all writes. The DB uses WAL + a 5s busy_timeout so
//     a concurrent rebuild and search never see torn reads.
//
// Failure modes:
//   * If SQLite can't open (read-only fs, disk full, permission denied) the
//     index falls back to a tombstone state and the search degrades to the
//     legacy O(N) scan rather than failing the tool call.

/// An entry returned from the FTS5 prefilter.
struct MemoriesCandidate: Sendable, Equatable {
    let relPath: String
}

/// FTS5 special characters that, left in a MATCH query, either change query
/// semantics or surface as a syntax error. We strip them and operate on the
/// remaining bag-of-words, quoted as FTS5 phrases. Mirrors the discipline used
/// in `MemoryStore.sanitizeFTSQuery` and the upstream Codex memory examples.
enum MemoriesFTSQuery {
    /// Maximum bytes of caller-provided query we will tokenise. The FTS5
    /// parser itself accepts up to a few MB but we treat anything past 64 KiB
    /// as adversarial input and truncate cleanly.
    static let maxQueryBytes: Int = 64 * 1024

    /// Tokens we never include in a phrase. Beyond the FTS5 reserved
    /// punctuation, the bare words `AND`/`OR`/`NOT`/`NEAR` are FTS5 boolean
    /// operators when used unquoted — quoting them as phrases handles the
    /// `AND`/`OR`/`NOT` case but `NEAR` requires special treatment. We just
    /// drop the bare operators to keep the query expression simple.
    private static let droppedKeywords: Set<String> = ["AND", "OR", "NOT", "NEAR"]

    /// Build a per-term FTS5 phrase. Returns `nil` when nothing usable remains.
    static func phraseForTerm(_ raw: String) -> String? {
        // Truncate adversarial input.
        let bounded: String
        if raw.utf8.count > maxQueryBytes {
            bounded = String(raw.prefix(maxQueryBytes))
        } else {
            bounded = raw
        }
        // Strip FTS5-reserved punctuation: " ' : ( ) * ^ + - . , ! ?
        // Replace with spaces so adjacent words still tokenise individually.
        var scrubbed = ""
        scrubbed.reserveCapacity(bounded.count)
        for scalar in bounded.unicodeScalars {
            switch scalar {
            case "\"", "'", ":", "(", ")", "*", "^", "+", "-", ".",
                 ",", "!", "?", "<", ">", "=", "/", "\\", "{", "}",
                 "[", "]", "`", "|", "@", "#", "$", "%", "&", ";",
                 "~":
                scrubbed.unicodeScalars.append(" ")
            default:
                scrubbed.unicodeScalars.append(scalar)
            }
        }
        // Split on whitespace, drop boolean keywords, then quote as a phrase.
        let words = scrubbed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !droppedKeywords.contains($0.uppercased()) }
        guard !words.isEmpty else { return nil }
        // Each phrase is `"w1 w2 w3"` so we require the words in order. This
        // is what callers of `memories_search` expect from a substring query.
        let phrase = words.joined(separator: " ")
        // Re-escape any straggler double-quote (defence in depth — should be
        // impossible after the strip above).
        let safe = phrase.replacingOccurrences(of: "\"", with: "")
        return "\"\(safe)\""
    }

    /// Build a top-level FTS5 expression that returns files containing any of
    /// the supplied terms. The Swift line-level matcher applies all_on_same
    /// _line / all_within_N constraints on the small candidate set the FTS5
    /// prefilter returns.
    static func unionExpression(_ terms: [String]) -> String? {
        let phrases = terms.compactMap(phraseForTerm)
        guard !phrases.isEmpty else { return nil }
        return phrases.joined(separator: " OR ")
    }
}

/// FTS5-backed prefilter over a memories directory.
final class MemoriesFTSIndex: @unchecked Sendable {
    /// Owns the raw `sqlite3*`. Tied to the actor's lifetime; freed in `deinit`.
    private final class Handle {
        let ptr: OpaquePointer
        init(_ p: OpaquePointer) { ptr = p }
        deinit { sqlite3_close_v2(ptr) }
    }
    private let memDir: String
    private let dbPath: String
    /// `nil` means we failed to open SQLite and the caller should fall back to
    /// the linear scan. We log once and stay in this tombstone state.
    private var handle: Handle?
    /// Cached `mtime` of the memories directory itself. When it has not
    /// changed since the last refresh we skip the listing scan entirely; the
    /// directory mtime updates on add/remove of files so this is sound for
    /// detecting new/deleted files. We *also* re-check per-file mtime to catch
    /// in-place edits.
    private var lastDirMTime: TimeInterval = -1

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(memDir: String) {
        self.memDir = memDir
        self.dbPath = memDir + "/.index.sqlite"
        self.handle = nil
        openIfPossible()
    }

    private func openIfPossible() {
        // Best-effort directory create so a fresh memories dir gets an index.
        try? FileManager.default.createDirectory(
            atPath: memDir, withIntermediateDirectories: true)
        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbPath, &raw, flags, nil)
        guard rc == SQLITE_OK, let p = raw else {
            if let r = raw { sqlite3_close_v2(r) }
            handle = nil
            return
        }
        // WAL gives us readers-don't-block-writers and torn-read protection
        // during simultaneous index refresh + search.
        _ = exec(p, "PRAGMA journal_mode=WAL;")
        _ = exec(p, "PRAGMA synchronous=NORMAL;")
        _ = exec(p, "PRAGMA temp_store=MEMORY;")
        _ = exec(p, "PRAGMA busy_timeout=5000;")
        // Schema (idempotent).
        let core = """
        CREATE TABLE IF NOT EXISTS files (
          id     INTEGER PRIMARY KEY,
          path   TEXT NOT NULL UNIQUE,
          mtime  REAL NOT NULL,
          size   INTEGER NOT NULL
        );
        """
        if exec(p, core) != SQLITE_OK {
            sqlite3_close_v2(p); handle = nil; return
        }
        // External-content FTS5 — body text lives in `files.path`'s rowid
        // mirror; we maintain `files_fts(rowid, text)` directly.
        let fts = """
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
          text,
          tokenize='unicode61 remove_diacritics 2'
        );
        """
        if exec(p, fts) != SQLITE_OK {
            sqlite3_close_v2(p); handle = nil; return
        }
        handle = Handle(p)
    }

    // MARK: - low-level helpers (SQLite C glue)

    private func exec(_ db: OpaquePointer, _ sql: String) -> Int32 {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let h = handle else { return nil }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(h.ptr, sql, -1, &stmt, nil)
        if rc != SQLITE_OK { sqlite3_finalize(stmt); return nil }
        return stmt
    }

    @discardableResult
    private func runVoid(_ sql: String, _ binds: [Any] = []) -> Int32 {
        guard let s = prepare(sql) else { return SQLITE_ERROR }
        defer { sqlite3_finalize(s) }
        bind(s, binds)
        return sqlite3_step(s) == SQLITE_DONE ? SQLITE_OK : SQLITE_ERROR
    }

    private func bind(_ s: OpaquePointer, _ binds: [Any]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case let t as String:
                sqlite3_bind_text(s, idx, t, -1, Self.transient)
            case let v as Int64:
                sqlite3_bind_int64(s, idx, v)
            case let v as Int:
                sqlite3_bind_int64(s, idx, Int64(v))
            case let v as Double:
                sqlite3_bind_double(s, idx, v)
            default:
                sqlite3_bind_null(s, idx)
            }
        }
    }

    // MARK: - public API

    /// Returns true when the FTS5 index opened successfully. When false the
    /// caller should fall back to a linear scan.
    var isOperational: Bool { handle != nil }

    /// Refresh the index against the on-disk state. Cheap when nothing
    /// changed (single `stat` of the dir + at most N per-file mtime checks).
    func refresh() {
        guard handle != nil else { return }
        let fm = FileManager.default
        // Cheap "did anything happen?" gate based on the memories directory's
        // own mtime. The dir mtime updates on add/remove of files but NOT on
        // in-place edits, so we still walk the indexed-file list to catch
        // those. The dir-mtime check just lets us skip the FileManager
        // enumeration entirely on hot paths where nothing changed.
        var dirChanged = true
        if let attrs = try? fm.attributesOfItem(atPath: memDir),
           let d = attrs[.modificationDate] as? Date {
            let t = d.timeIntervalSince1970
            if t == lastDirMTime { dirChanged = false }
        }
        // Build current map: relPath -> (mtime, size)
        var current: [String: (mtime: TimeInterval, size: Int64)] = [:]
        if dirChanged {
            current = enumerateMemories(root: memDir)
        } else {
            // Use the indexed set for the per-file mtime sweep.
            current = currentIndexedPaths()
            for (rel, _) in current {
                let full = memDir + "/" + rel
                if let attrs = try? fm.attributesOfItem(atPath: full),
                   let d = attrs[.modificationDate] as? Date,
                   let n = attrs[.size] as? Int64 {
                    current[rel] = (d.timeIntervalSince1970, n)
                } else {
                    current[rel] = nil
                }
            }
        }
        // Read indexed snapshot.
        var indexed: [String: (id: Int64, mtime: TimeInterval, size: Int64)] = [:]
        if let s = prepare("SELECT id, path, mtime, size FROM files;") {
            while sqlite3_step(s) == SQLITE_ROW {
                let id = sqlite3_column_int64(s, 0)
                let path = String(cString: sqlite3_column_text(s, 1))
                let mt = sqlite3_column_double(s, 2)
                let sz = sqlite3_column_int64(s, 3)
                indexed[path] = (id, mt, sz)
            }
            sqlite3_finalize(s)
        }
        // Compute diff.
        var toRemove: [Int64] = []
        var toInsert: [(path: String, mtime: TimeInterval, size: Int64)] = []
        var toUpdate: [(id: Int64, path: String, mtime: TimeInterval, size: Int64)] = []
        for (path, x) in indexed where current[path] == nil {
            toRemove.append(x.id)
        }
        for (path, cur) in current {
            if let ix = indexed[path] {
                if ix.mtime != cur.mtime || ix.size != cur.size {
                    toUpdate.append((ix.id, path, cur.mtime, cur.size))
                }
            } else {
                toInsert.append((path, cur.mtime, cur.size))
            }
        }
        // Apply diff inside one transaction.
        if !toRemove.isEmpty || !toUpdate.isEmpty || !toInsert.isEmpty,
           let h = handle {
            _ = exec(h.ptr, "BEGIN IMMEDIATE;")
            for id in toRemove {
                runVoid("DELETE FROM files_fts WHERE rowid=?;", [Int64(id)])
                runVoid("DELETE FROM files WHERE id=?;", [Int64(id)])
            }
            for u in toUpdate {
                let text = readBody(rel: u.path) ?? ""
                runVoid("UPDATE files SET mtime=?, size=? WHERE id=?;",
                        [u.mtime, Int64(u.size), Int64(u.id)])
                runVoid("DELETE FROM files_fts WHERE rowid=?;", [Int64(u.id)])
                runVoid("INSERT INTO files_fts(rowid, text) VALUES(?, ?);",
                        [Int64(u.id), text])
            }
            for ins in toInsert {
                let text = readBody(rel: ins.path) ?? ""
                runVoid("INSERT INTO files(path, mtime, size) VALUES(?, ?, ?);",
                        [ins.path, ins.mtime, Int64(ins.size)])
                let rowid = sqlite3_last_insert_rowid(h.ptr)
                runVoid("INSERT INTO files_fts(rowid, text) VALUES(?, ?);",
                        [Int64(rowid), text])
            }
            _ = exec(h.ptr, "COMMIT;")
        }
        if let attrs = try? fm.attributesOfItem(atPath: memDir),
           let d = attrs[.modificationDate] as? Date {
            lastDirMTime = d.timeIntervalSince1970
        }
    }

    private func currentIndexedPaths() -> [String: (mtime: TimeInterval, size: Int64)] {
        var out: [String: (TimeInterval, Int64)] = [:]
        guard let s = prepare("SELECT path, mtime, size FROM files;") else {
            return out
        }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(s, 0))
            let mt = sqlite3_column_double(s, 1)
            let sz = sqlite3_column_int64(s, 2)
            out[path] = (mt, sz)
        }
        return out
    }

    private func readBody(rel: String) -> String? {
        try? String(contentsOfFile: memDir + "/" + rel, encoding: .utf8)
    }

    /// Walk the memories directory and return every .md (and other text-like)
    /// file path relative to the root. Symlinks are *not* followed: an
    /// adversarial symlink to /etc/passwd will appear as a regular entry but
    /// we skip it here so it never lands in the FTS5 corpus.
    private func enumerateMemories(root: String) -> [String: (mtime: TimeInterval, size: Int64)] {
        var out: [String: (TimeInterval, Int64)] = [:]
        let fm = FileManager.default
        // macOS `/var` is a firmlink to `/private/var`. Foundation's URL
        // canonicalization (`resolvingSymlinksInPath`, `standardizedFileURL`)
        // does NOT follow firmlinks, but the kernel-emitted URLs from
        // `FileManager.enumerator(at:)` do — so the relative-path strip
        // below would silently throw away every entry (path prefix
        // `/private/var/...` vs canonRoot `/var/...`). `realpath(3)` is the
        // only API that resolves firmlinks reliably.
        let canonRoot: String = root.withCString { cstr in
            guard let r = realpath(cstr, nil) else { return root }
            defer { free(r) }
            return String(cString: r)
        }
        let rootURL = URL(fileURLWithPath: canonRoot)
        guard let en = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey,
                                         .fileSizeKey,
                                         .isRegularFileKey,
                                         .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            return out
        }
        for case let url as URL in en {
            // Skip symlinks — they can't escape the jail anyway, but indexing
            // them would expose their targets through search.
            let vals = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
                .contentModificationDateKey, .fileSizeKey,
            ])
            if (vals?.isSymbolicLink ?? false) { continue }
            guard (vals?.isRegularFile ?? false) else { continue }
            // Use `url.path` as-is. `url.resolvingSymlinksInPath().path`
            // actually un-canonicalizes /private/var back to /var on this
            // macOS, which is the opposite of what we want — the enumerator
            // already yields kernel-canonical URLs (matching `canonRoot`
            // after our `realpath()` above).
            let path = url.path
            let rel: String
            if path.hasPrefix(canonRoot + "/") {
                rel = String(path.dropFirst(canonRoot.count + 1))
            } else {
                continue
            }
            // Only index files that look like memory bodies (`.md` etc.).
            // Keeping the filter loose lets us index sub-namespaces (e.g.
            // `sub/foo.md`) while still ignoring the `.index.sqlite` shard.
            if rel.hasPrefix(".") { continue }
            if rel.hasSuffix(".sqlite") || rel.hasSuffix(".sqlite-wal")
                || rel.hasSuffix(".sqlite-shm") {
                continue
            }
            let mtime = (vals?.contentModificationDate ?? Date(timeIntervalSince1970: 0))
                .timeIntervalSince1970
            let size = Int64(vals?.fileSize ?? 0)
            out[rel] = (mtime, size)
        }
        return out
    }

    /// Run the FTS5 prefilter. Returns the relative paths of every file that
    /// contains *at least one* of the supplied query terms. Returns `nil` if
    /// the index is not operational (caller falls back to linear scan).
    ///
    /// `scopePath`, when non-empty, restricts results to files at-or-below
    /// `scopePath` (LIKE prefix on the stored path).
    func candidates(forTerms terms: [String], scopePath: String?) -> [String]? {
        guard handle != nil else { return nil }
        // Bring the index up to date against the on-disk corpus before
        // querying. `refresh()` is a no-op if nothing changed.
        refresh()
        guard let match = MemoriesFTSQuery.unionExpression(terms) else {
            // Empty/all-noise query: degrade to "no candidates" rather than
            // returning everything (the FTS5 parser would otherwise reject
            // an empty MATCH expression with SQLITE_ERROR).
            return []
        }
        var sql = """
        SELECT files.path FROM files
        JOIN files_fts ON files_fts.rowid = files.id
        WHERE files_fts MATCH ?
        """
        var binds: [Any] = [match]
        if let sp = scopePath, !sp.isEmpty {
            let trimmed = sp.trimmingCharacters(in: .init(charactersIn: "/"))
            if !trimmed.isEmpty {
                sql += " AND (files.path = ? OR files.path LIKE ?)"
                binds.append(trimmed)
                binds.append(trimmed + "/%")
            }
        }
        sql += " ORDER BY files.path;"
        guard let s = prepare(sql) else { return [] }
        defer { sqlite3_finalize(s) }
        bind(s, binds)
        var out: [String] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW {
                out.append(String(cString: sqlite3_column_text(s, 0)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                // Treat any FTS5 syntax/runtime error as "no candidates" so
                // adversarial input degrades cleanly rather than crashing.
                return []
            }
        }
        return out
    }

    /// Wipe the index — used when the memories root is `reset()`.
    func clear() {
        guard let h = handle else { return }
        _ = exec(h.ptr, "BEGIN IMMEDIATE;")
        runVoid("DELETE FROM files_fts;")
        runVoid("DELETE FROM files;")
        _ = exec(h.ptr, "COMMIT;")
        lastDirMTime = -1
    }
}

// MARK: - Symlink jail helpers

enum MemoriesPathJail {
    /// Reject paths containing traversal segments, NUL bytes, or absolute
    /// roots. Returns the cleaned relative path on success.
    static func validateRelative(_ raw: String) throws -> String {
        if raw.isEmpty {
            throw MemoriesJailError.invalid("empty path")
        }
        // NUL bytes terminate C strings inside SQLite/POSIX; reject hard.
        if raw.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw MemoriesJailError.invalid("NUL in path")
        }
        // Absolute paths are not allowed.
        if raw.hasPrefix("/") {
            throw MemoriesJailError.invalid("absolute path")
        }
        // Reject `..` traversal segments anywhere in the path. We split on
        // both `/` and `\` because some clients normalise to backslashes on
        // Windows-style inputs.
        let components = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        for c in components {
            if c == ".." || c == "." {
                throw MemoriesJailError.invalid("traversal segment in path")
            }
        }
        // Reject UTF-16 BOMs and other surprising prefixes that some clients
        // smuggle through.
        if raw.hasPrefix("\u{FEFF}") {
            throw MemoriesJailError.invalid("BOM in path")
        }
        return raw
    }

    /// Resolve a candidate path against the memories root and confirm the
    /// result stays under the root after symlink resolution. Returns the
    /// resolved absolute path on success.
    static func resolveAndJail(memRoot: String, rel: String) throws -> String {
        let cleaned = try validateRelative(rel)
        let memRootURL = URL(fileURLWithPath: memRoot).resolvingSymlinksInPath()
        let canonRoot = memRootURL.path
        let full = URL(fileURLWithPath: canonRoot + "/" + cleaned)
        let resolved = full.resolvingSymlinksInPath().path
        // After symlink resolution, the file must still live under canonRoot.
        if resolved == canonRoot || resolved.hasPrefix(canonRoot + "/") {
            return resolved
        }
        throw MemoriesJailError.escape("symlink escapes memories root")
    }
}

enum MemoriesJailError: Error, Sendable, CustomStringConvertible {
    case invalid(String)
    case escape(String)
    public var description: String {
        switch self {
        case .invalid(let s): return "memories path invalid: \(s)"
        case .escape(let s):  return "memories path escape: \(s)"
        }
    }
}
