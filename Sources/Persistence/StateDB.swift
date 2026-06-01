import Foundation
import CSQLite
import ProtocolModel

public enum StateDBError: Error, Sendable, CustomStringConvertible {
    case open(String), exec(String), prepare(String), step(String)
    public var description: String {
        switch self {
        case .open(let s): return "sqlite open: \(s)"
        case .exec(let s): return "sqlite exec: \(s)"
        case .prepare(let s): return "sqlite prepare: \(s)"
        case .step(let s): return "sqlite step: \(s)"
        }
    }
}

public struct ThreadRow: Sendable, Equatable {
    public var id: String
    public var cwd: String
    public var model: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var archived: Bool
    public var ephemeral: Bool
    public var rolloutPath: String
    public var lastCommittedSeq: Int
    public var name: String?
    public var memoryMode: String
    public var gitSha: String?
    public var gitBranch: String?
    public var gitOriginURL: String?
    /// Whether the user pinned this thread to the top of the sidebar.
    public var pinned: Bool
    /// Unix-seconds timestamp recorded when the thread is archived (upstream
    /// `mark_archived` writes `archived_at = now`; `mark_unarchived` clears it
    /// to NULL). Distinct from the `archived` boolean so a listing can surface
    /// both the flag and the moment of archival (archive_thread.rs asserts
    /// `archived_at == updated_at`). `nil` when the thread is active.
    public var archivedAt: Int64?

    public init(id: String, cwd: String, model: String, createdAt: Int64,
                updatedAt: Int64, archived: Bool, ephemeral: Bool,
                rolloutPath: String, lastCommittedSeq: Int, name: String?,
                memoryMode: String, gitSha: String?, gitBranch: String?,
                gitOriginURL: String?, archivedAt: Int64? = nil, pinned: Bool = false) {
        self.id = id; self.cwd = cwd; self.model = model
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.archived = archived; self.ephemeral = ephemeral
        self.rolloutPath = rolloutPath; self.lastCommittedSeq = lastCommittedSeq
        self.name = name; self.memoryMode = memoryMode
        self.gitSha = gitSha; self.gitBranch = gitBranch
        self.gitOriginURL = gitOriginURL; self.archivedAt = archivedAt
        self.pinned = pinned
    }
}

public struct GoalRow: Sendable, Equatable {
    public var threadId: String
    public var objective: String
    public var status: String
    public var tokenBudget: Int64?
    public var tokensUsed: Int64
    public var timeUsedSeconds: Int64
    public var createdAt: Int64
    public var updatedAt: Int64
}

/// Owns the raw `sqlite3*` and closes it on its own deinit. `@unchecked
/// Sendable`: the enclosing `StateDB` actor serializes every access, and
/// sqlite is opened with `SQLITE_OPEN_FULLMUTEX`. If `StateDB.init` throws
/// after this is constructed, releasing it closes the database (no leak).
final class SQLiteHandle: @unchecked Sendable {
    let ptr: OpaquePointer
    init(_ p: OpaquePointer) { ptr = p }
    deinit { sqlite3_close_v2(ptr) }
}

/// Per-session SQLite index. WAL mode, `synchronous=NORMAL`, busy-timeout
/// (hardening §7). The worker is the sole writer; the actor serializes all
/// access to the raw `sqlite3*` handle so the C pointer never races. Schema
/// setup runs in `init` via static helpers over the local handle (no `self`)
/// so it does not violate actor-init isolation.
public actor StateDB {
    private let handle: SQLiteHandle
    private var db: OpaquePointer { handle.ptr }
    // SQLITE_TRANSIENT: tell sqlite to copy bound text/blob.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &raw, flags, nil)
        guard rc == SQLITE_OK, let h = raw else {
            if let r = raw { sqlite3_close_v2(r) }
            throw StateDBError.open("rc=\(rc) path=\(path)")
        }
        // Assigned before schema setup: if setup throws, releasing `handle`
        // runs SQLiteHandle.deinit which closes the database.
        self.handle = SQLiteHandle(h)
        try Self.execRaw(h, "PRAGMA journal_mode=WAL;")
        try Self.execRaw(h, "PRAGMA synchronous=NORMAL;")
        try Self.execRaw(h, "PRAGMA busy_timeout=5000;")
        try Self.execRaw(h, """
        CREATE TABLE IF NOT EXISTS threads(
          id TEXT PRIMARY KEY,
          cwd TEXT NOT NULL,
          model TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          archived INTEGER NOT NULL DEFAULT 0,
          ephemeral INTEGER NOT NULL DEFAULT 0,
          pinned INTEGER NOT NULL DEFAULT 0,
          rollout_path TEXT NOT NULL,
          last_committed_seq INTEGER NOT NULL DEFAULT 0,
          name TEXT,
          memory_mode TEXT NOT NULL DEFAULT 'enabled',
          git_sha TEXT,
          git_branch TEXT,
          git_origin_url TEXT,
          archived_at INTEGER
        );
        """)
        // Best-effort migrations for indexes created by an older schema.
        try? Self.execRaw(h, "ALTER TABLE threads ADD COLUMN name TEXT;")
        try? Self.execRaw(h, "ALTER TABLE threads ADD COLUMN memory_mode TEXT NOT NULL DEFAULT 'enabled';")
        try? Self.execRaw(h, "ALTER TABLE threads ADD COLUMN git_sha TEXT;")
        try? Self.execRaw(h, "ALTER TABLE threads ADD COLUMN git_branch TEXT;")
        try? Self.execRaw(h, "ALTER TABLE threads ADD COLUMN git_origin_url TEXT;")
        try? Self.execRaw(h, "ALTER TABLE threads ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;")
        try? Self.execRaw(h, "ALTER TABLE threads ADD COLUMN archived_at INTEGER;")
        try Self.execRaw(h, """
        CREATE TABLE IF NOT EXISTS goals(
          thread_id TEXT PRIMARY KEY,
          objective TEXT NOT NULL,
          status TEXT NOT NULL,
          token_budget INTEGER,
          tokens_used INTEGER NOT NULL DEFAULT 0,
          time_used_seconds INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        """)
    }

    // MARK: handle-scoped helpers (no `self`; safe from a nonisolated init)

    private static func errMsg(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func execRaw(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? errMsg(db)
            sqlite3_free(err)
            throw StateDBError.exec("\(m) [\(sql.prefix(60))]")
        }
    }

    // MARK: actor-isolated operations

    private func errMsg() -> String { Self.errMsg(db) }
    private func execRaw(_ sql: String) throws { try Self.execRaw(db, sql) }

    private enum Bind { case text(String), int(Int64), null }

    @discardableResult
    private func run(_ sql: String, _ binds: [Bind] = []) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw StateDBError.prepare(errMsg())
        }
        defer { sqlite3_finalize(s) }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch b {
            case .text(let t): rc = sqlite3_bind_text(s, idx, t, -1, StateDB.transient)
            case .int(let v): rc = sqlite3_bind_int64(s, idx, v)
            case .null: rc = sqlite3_bind_null(s, idx)
            }
            if rc != SQLITE_OK { throw StateDBError.prepare("bind \(idx): \(errMsg())") }
        }
        var rows: [[String: Any]] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw StateDBError.step(errMsg()) }
            var row: [String: Any] = [:]
            for col in 0..<sqlite3_column_count(s) {
                let name = String(cString: sqlite3_column_name(s, col))
                switch sqlite3_column_type(s, col) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(s, col)
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(s, col) { row[name] = String(cString: c) }
                default: row[name] = nil
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func upsertThread(_ r: ThreadRow) throws {
        try run("""
        INSERT INTO threads(id,cwd,model,created_at,updated_at,archived,ephemeral,rollout_path,last_committed_seq,name,memory_mode,git_sha,git_branch,git_origin_url,archived_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          cwd=excluded.cwd, model=excluded.model, updated_at=excluded.updated_at,
          archived=excluded.archived, ephemeral=excluded.ephemeral,
          rollout_path=excluded.rollout_path,
          last_committed_seq=MAX(threads.last_committed_seq, excluded.last_committed_seq),
          name=excluded.name, memory_mode=excluded.memory_mode,
          git_sha=excluded.git_sha, git_branch=excluded.git_branch,
          git_origin_url=excluded.git_origin_url, archived_at=excluded.archived_at;
        """, [
            .text(r.id), .text(r.cwd), .text(r.model),
            .int(r.createdAt), .int(r.updatedAt),
            .int(r.archived ? 1 : 0), .int(r.ephemeral ? 1 : 0),
            .text(r.rolloutPath), .int(Int64(r.lastCommittedSeq)),
            r.name.map(Bind.text) ?? .null, .text(r.memoryMode),
            r.gitSha.map(Bind.text) ?? .null,
            r.gitBranch.map(Bind.text) ?? .null,
            r.gitOriginURL.map(Bind.text) ?? .null,
            r.archivedAt.map(Bind.int) ?? .null,
        ])
    }

    /// Set the committed-seq pointer to an exact value (used after a rollback
    /// rewrites the rollout to fewer records than the index recorded).
    public func setCommittedSeq(_ id: String, to seq: Int, updatedAt: Int64) throws {
        try run("UPDATE threads SET last_committed_seq=?, updated_at=? WHERE id=?;",
                [.int(Int64(seq)), .int(updatedAt), .text(id)])
    }

    public func getThread(_ id: String) throws -> ThreadRow? {
        let rows = try run("SELECT * FROM threads WHERE id=?;", [.text(id)])
        return rows.first.map(Self.rowToThread)
    }

    public func getThreadByRolloutPath(_ rolloutPath: String) throws -> ThreadRow? {
        let rows = try run("SELECT * FROM threads WHERE rollout_path=?;",
                           [.text(rolloutPath)])
        return rows.first.map(Self.rowToThread)
    }

    public func listThreads(archived: Bool, limit: Int) throws -> [ThreadRow] {
        try run("SELECT * FROM threads WHERE archived=? ORDER BY created_at DESC LIMIT ?;",
                [.int(archived ? 1 : 0), .int(Int64(limit))]).map(Self.rowToThread)
    }

    public func setArchived(_ id: String, _ archived: Bool, updatedAt: Int64) throws {
        try run("UPDATE threads SET archived=?, updated_at=? WHERE id=?;",
                [.int(archived ? 1 : 0), .int(updatedAt), .text(id)])
    }

    /// Mirror upstream `mark_archived` (archive_thread.rs:55-58): flip the
    /// archived flag, repoint `rollout_path` to the archived location, and
    /// record `archived_at = now` (asserted equal to `updated_at` upstream).
    public func markArchived(_ id: String, rolloutPath: String, archivedAt: Int64) throws {
        try run("""
        UPDATE threads SET archived=1, rollout_path=?, archived_at=?, updated_at=?
        WHERE id=?;
        """, [.text(rolloutPath), .int(archivedAt), .int(archivedAt), .text(id)])
    }

    /// Mirror upstream `mark_unarchived` (unarchive_thread.rs:78-80): clear the
    /// archived flag, repoint `rollout_path` back into the active sessions tree,
    /// and reset `archived_at` to NULL.
    public func markUnarchived(_ id: String, rolloutPath: String, updatedAt: Int64) throws {
        try run("""
        UPDATE threads SET archived=0, rollout_path=?, archived_at=NULL, updated_at=?
        WHERE id=?;
        """, [.text(rolloutPath), .int(updatedAt), .text(id)])
    }

    /// Advance the committed sequence pointer. Called only **after** the
    /// rollout fsync (crash-consistent ordering, rework §8.1).
    public func advanceCommittedSeq(_ id: String, to seq: Int, updatedAt: Int64) throws {
        try run("""
        UPDATE threads SET last_committed_seq=MAX(last_committed_seq,?), updated_at=?
        WHERE id=?;
        """, [.int(Int64(seq)), .int(updatedAt), .text(id)])
    }

    public func checkpoint() throws { try execRaw("PRAGMA wal_checkpoint(TRUNCATE);") }

    public func setName(_ id: String, _ name: String?, updatedAt: Int64) throws {
        try run("UPDATE threads SET name=?, updated_at=? WHERE id=?;",
                [name.map(Bind.text) ?? .null, .int(updatedAt), .text(id)])
    }

    public func setPinned(_ id: String, _ pinned: Bool, updatedAt: Int64) throws {
        try run("UPDATE threads SET pinned=?, updated_at=? WHERE id=?;",
                [.int(pinned ? 1 : 0), .int(updatedAt), .text(id)])
    }

    public func setMemoryMode(_ id: String, _ mode: String, updatedAt: Int64) throws {
        try run("UPDATE threads SET memory_mode=?, updated_at=? WHERE id=?;",
                [.text(mode), .int(updatedAt), .text(id)])
    }

    public func setGitInfo(_ id: String, sha: String?, branch: String?,
                           originURL: String?, updatedAt: Int64) throws {
        try run("""
        UPDATE threads SET git_sha=?, git_branch=?, git_origin_url=?, updated_at=?
        WHERE id=?;
        """, [
            sha.map(Bind.text) ?? .null,
            branch.map(Bind.text) ?? .null,
            originURL.map(Bind.text) ?? .null,
            .int(updatedAt), .text(id),
        ])
    }

    public func getGoal(_ threadId: String) throws -> GoalRow? {
        try run("SELECT * FROM goals WHERE thread_id=?;", [.text(threadId)]).first.map(Self.rowToGoal)
    }

    public func upsertGoal(_ g: GoalRow) throws {
        try run("""
        INSERT INTO goals(thread_id,objective,status,token_budget,tokens_used,time_used_seconds,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(thread_id) DO UPDATE SET
          objective=excluded.objective, status=excluded.status,
          token_budget=excluded.token_budget, tokens_used=excluded.tokens_used,
          time_used_seconds=excluded.time_used_seconds, updated_at=excluded.updated_at;
        """, [
            .text(g.threadId), .text(g.objective), .text(g.status),
            g.tokenBudget.map(Bind.int) ?? .null,
            .int(g.tokensUsed), .int(g.timeUsedSeconds),
            .int(g.createdAt), .int(g.updatedAt),
        ])
    }

    public func clearGoal(_ threadId: String) throws -> Bool {
        let existed = try getGoal(threadId) != nil
        try run("DELETE FROM goals WHERE thread_id=?;", [.text(threadId)])
        return existed
    }

    /// Atomically accumulate goal usage in a single UPDATE.
    public func addGoalUsage(_ threadId: String, tokens: Int64,
                             seconds: Int64, updatedAt: Int64) throws {
        try run("""
        UPDATE goals SET
          tokens_used = tokens_used + ?,
          time_used_seconds = time_used_seconds + ?,
          status = CASE WHEN token_budget IS NOT NULL
                         AND (tokens_used + ?) >= token_budget
                         AND status = 'active'
                    THEN 'budgetLimited' ELSE status END,
          updated_at = ?
        WHERE thread_id = ?;
        """, [.int(tokens), .int(seconds), .int(tokens),
              .int(updatedAt), .text(threadId)])
    }

    private static func rowToGoal(_ r: [String: Any]) -> GoalRow {
        func s(_ k: String) -> String { (r[k] as? String) ?? "" }
        func i(_ k: String) -> Int64 { (r[k] as? Int64) ?? 0 }
        return GoalRow(
            threadId: s("thread_id"), objective: s("objective"), status: s("status"),
            tokenBudget: r["token_budget"] as? Int64,
            tokensUsed: i("tokens_used"), timeUsedSeconds: i("time_used_seconds"),
            createdAt: i("created_at"), updatedAt: i("updated_at"))
    }

    private static func rowToThread(_ r: [String: Any]) -> ThreadRow {
        func s(_ k: String) -> String { (r[k] as? String) ?? "" }
        func i(_ k: String) -> Int64 { (r[k] as? Int64) ?? 0 }
        return ThreadRow(
            id: s("id"), cwd: s("cwd"), model: s("model"),
            createdAt: i("created_at"), updatedAt: i("updated_at"),
            archived: i("archived") != 0, ephemeral: i("ephemeral") != 0,
            rolloutPath: s("rollout_path"),
            lastCommittedSeq: Int(i("last_committed_seq")),
            name: r["name"] as? String,
            memoryMode: (r["memory_mode"] as? String) ?? "enabled",
            gitSha: r["git_sha"] as? String,
            gitBranch: r["git_branch"] as? String,
            gitOriginURL: r["git_origin_url"] as? String,
            archivedAt: r["archived_at"] as? Int64,
            pinned: i("pinned") != 0)
    }
}
