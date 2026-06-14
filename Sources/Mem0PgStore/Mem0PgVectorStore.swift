import Foundation
import Logging
import Mem0Core
import EmbeddedPG
import NIOCore
import NIOPosix
import PostgresNIO

/// A pgvector-backed Mem0 store that conforms to BOTH `Mem0VectorStore` and
/// `Mem0HistoryStore` — a drop-in alongside `Mem0SQLiteStore`. Pass one instance
/// as both `vectorStore` and `historyStore` to `Mem0Engine` (the engine holds
/// `any Mem0VectorStore` / `any Mem0HistoryStore`, so it needs ZERO changes).
///
/// Architecture (pglite.md, Architecture B):
///   • Talks to a supervised native postmaster over a UNIX socket via PostgresNIO.
///   • Vectors live in `memories.vector` (a real `vector`/`halfvec` column) with
///     an HNSW index → `search` is one `ORDER BY vector <=> $1 LIMIT k`, replacing
///     the SQLite lane's brute-force Swift cosine over an in-RAM cache.
///   • v1 concurrency: a SINGLE connection owned by this actor, and every public
///     op holds a FIFO gate, so all queries are fully serialized — preserving
///     today's non-atomic engine read-modify-write semantics exactly. (A
///     pooled-reads / serialized-write split is a v2; see pglite.md §5.)
///   • Security: the data plane connects as a NON-superuser role (`codex_app`)
///     with only DML grants; the one-time bootstrap (extension/schema/role) runs
///     as the superuser. The postmaster never opens a TCP port.
public actor Mem0PgVectorStore: Mem0VectorStore, Mem0HistoryStore {
    public let paths: PGPaths
    private let dims: Int
    /// `"vector"` (≤2000 dims, HNSW) | `"halfvec"` (2001–4000, HNSW) |
    /// `"vector"` with no HNSW (>4000 → brute-force seq scan).
    private let vectorType: String
    private let opclass: String
    private let hasHNSW: Bool
    private let appUsername = "codex_app"
    private let logger: Logger
    private let eventLoop: any EventLoop
    private var conn: PostgresConnection?

    // Serialization gate. Swift actors are REENTRANT: when a method suspends at an
    // `await conn.query(...)` inside a BEGIN/COMMIT, the actor is free to run
    // another method, whose queries would interleave into the open transaction on
    // the shared connection (a real corruption bug — the SQLite store dodges it
    // because its BEGIN..COMMIT bodies are synchronous). So every PUBLIC op holds
    // this FIFO gate for its whole duration, giving the same fully-serialized
    // single-connection semantics as `Mem0SQLiteStore`.
    private var gateLocked = false
    private var gateWaiters: [(id: UInt64, cont: CheckedContinuation<Void, any Error>)] = []
    private var gateSeq: UInt64 = 0

    /// Acquire the gate. Cancellation-aware: a task cancelled WHILE waiting is
    /// removed from the queue and throws `CancellationError` instead of later
    /// waking up and running a DB op anyway. Pair with `defer { release() }` —
    /// placed AFTER `try await acquire()` so a throwing acquire does NOT release
    /// a lock it never held.
    private func acquire() async throws {
        if !gateLocked { gateLocked = true; return }
        let id = gateSeq; gateSeq &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                gateWaiters.append((id, cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UInt64) {
        if let i = gateWaiters.firstIndex(where: { $0.id == id }) {
            let w = gateWaiters.remove(at: i)
            w.cont.resume(throwing: CancellationError())
        }
    }
    private func release() {
        if gateWaiters.isEmpty { gateLocked = false }
        else { gateWaiters.removeFirst().cont.resume() }
    }

    // MARK: - construction

    private init(paths: PGPaths, dims: Int, logLabel: String) {
        self.paths = paths
        self.dims = dims
        if dims <= 2000 {
            self.vectorType = "vector"; self.opclass = "vector_cosine_ops"; self.hasHNSW = true
        } else if dims <= 4000 {
            self.vectorType = "halfvec"; self.opclass = "halfvec_cosine_ops"; self.hasHNSW = true
        } else {
            // pgvector HNSW caps at 2000 (vector) / 4000 (halfvec) dims — above
            // that we store the full vector but fall back to an exact seq scan.
            self.vectorType = "vector"; self.opclass = "vector_cosine_ops"; self.hasHNSW = false
        }
        self.logger = Logger(label: logLabel)
        self.eventLoop = MultiThreadedEventLoopGroup.singleton.any()
        self.conn = nil
    }

    /// Bring up the cluster (optional), provision schema/role, and open the
    /// data-plane connection.
    public static func open(paths: PGPaths, dims: Int,
                            lifecycle: PostgresLifecycle? = nil,
                            logLabel: String = "codex.mem0.pg") async throws -> Mem0PgVectorStore {
        let store = Mem0PgVectorStore(paths: paths, dims: dims, logLabel: logLabel)
        try await store.start(lifecycle: lifecycle)
        return store
    }

    /// One-call convenience for "just give me an embedded Postgres store": resolve
    /// the default cluster layout under `$CODEX_HOME/mem0/pg` from the environment,
    /// spawn/provision it, and open the store. Lets any target adopt the embedded
    /// store without hand-wiring `PGPaths`/`PostgresLifecycle`.
    public static func openDefault(dims: Int,
                                   env: [String: String] = ProcessInfo.processInfo.environment,
                                   logLabel: String = "codex.mem0.pg") async throws -> Mem0PgVectorStore {
        guard let paths = PGPaths.resolveDefault(env: env) else {
            throw Mem0Error.configuration(
                "embedded Postgres unavailable: no postgres server binary found (install postgresql@NN + pgvector)")
        }
        return try await open(paths: paths, dims: dims,
                              lifecycle: PostgresLifecycle(paths: paths), logLabel: logLabel)
    }

    private func start(lifecycle: PostgresLifecycle?) async throws {
        if let lifecycle { try await lifecycle.ensureStarted() }
        try await bootstrap()
        self.conn = try await openConnection(username: appUsername)
    }

    /// Close the data-plane connection. Call on shutdown; the postmaster keeps
    /// running (stop it via `PostgresLifecycle.stop()` if desired).
    public func shutdown() async {
        // non-throwing: if cancelled while waiting, bail BEFORE registering the
        // defer so we never release a gate we didn't hold.
        do { try await acquire() } catch { return }
        defer { release() }
        if let c = conn { try? await c.close(); conn = nil }
    }

    // MARK: - connection helpers (private; callers already hold the gate)

    private func openConnection(username: String) async throws -> PostgresConnection {
        let config = PostgresConnection.Configuration(
            unixSocketPath: paths.unixSocketPath,
            username: username, password: nil, database: paths.database)
        do {
            return try await PostgresConnection.connect(
                on: eventLoop, configuration: config, id: 1, logger: logger).get()
        } catch {
            throw Mem0PgErrorMap.wrap(error, "connect(\(username))")
        }
    }

    private func connection() throws -> PostgresConnection {
        guard let conn else { throw Mem0Error.database("postgres store is closed") }
        return conn
    }

    private func execOn(_ conn: PostgresConnection, _ sql: String) async throws {
        _ = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: logger)
    }

    private func vectorLiteral(_ v: [Float]) -> String {
        "[" + v.map { String($0) }.joined(separator: ",") + "]"
    }

    /// pgvector rejects NaN/Inf at the cast (clean rollback); validate up-front so
    /// callers get a clear `validation` error instead of a buried `database` one,
    /// and so a bad embedding never reaches a transaction.
    private func validateFinite(_ v: [Float]) throws {
        if !v.allSatisfy(\.isFinite) {
            throw Mem0Error.validation("vector contains non-finite values (NaN/Inf)")
        }
    }

    // MARK: - bootstrap (superuser; one-time, idempotent; pre-gate, single-threaded)

    private func bootstrap() async throws {
        let su = try await openConnection(username: paths.username)
        do {
            try await execOn(su, "CREATE EXTENSION IF NOT EXISTS vector")
            try await execOn(su, "CREATE TABLE IF NOT EXISTS memories (id text PRIMARY KEY, vector \(vectorType)(\(dims)), payload jsonb NOT NULL)")
            if hasHNSW {
                try await execOn(su, "CREATE INDEX IF NOT EXISTS memories_vec_hnsw ON memories USING hnsw (vector \(opclass))")
            }
            try await execOn(su, "CREATE INDEX IF NOT EXISTS memories_fts ON memories USING gin (to_tsvector('simple', coalesce(payload ->> 'text_lemmatized', '')))")
            try await execOn(su, """
            CREATE TABLE IF NOT EXISTS history (
                id text PRIMARY KEY, memory_id text, old_memory text, new_memory text,
                event text, created_at text, updated_at text, is_deleted integer,
                actor_id text, role text, user_id text, agent_id text, run_id text)
            """)
            try await execOn(su, "CREATE INDEX IF NOT EXISTS history_scope ON history (memory_id, user_id, agent_id, run_id)")
            try await execOn(su, """
            CREATE TABLE IF NOT EXISTS messages (
                id text PRIMARY KEY, session_scope text, role text, content text,
                name text, created_at text)
            """)
            try await execOn(su, "CREATE INDEX IF NOT EXISTS messages_scope ON messages (session_scope, created_at)")
            // Non-superuser data-plane role + least-privilege DML grants.
            // `appUsername` is a fixed internal constant; quote it as an
            // identifier anyway (defence-in-depth) and pass it as a string literal
            // in the existence check.
            try await execOn(su, """
            DO $$ BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '\(appUsername)') THEN
                CREATE ROLE "\(appUsername)" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
              END IF;
            END $$;
            """)
            try await execOn(su, "GRANT CONNECT ON DATABASE \"\(paths.database)\" TO \"\(appUsername)\"")
            try await execOn(su, "GRANT USAGE ON SCHEMA public TO \"\(appUsername)\"")
            try await execOn(su, "GRANT SELECT, INSERT, UPDATE, DELETE ON memories, history, messages TO \"\(appUsername)\"")
            try await su.close()
        } catch {
            try? await su.close()
            throw Mem0PgErrorMap.wrap(error, "bootstrap")
        }
    }

    // MARK: - Mem0VectorStore

    public func insert(_ records: [VectorRecord]) async throws {
        try await acquire(); defer { release() }
        for r in records { try validateFinite(r.vector) }
        let conn = try connection()
        do {
            try await execOn(conn, "BEGIN")
            for r in records {
                var b = PGQueryBuilder()
                b.raw("INSERT INTO memories (id, vector, payload) VALUES (")
                try b.param(r.id); b.raw(", ")
                try b.param(vectorLiteral(r.vector)); b.raw("::\(vectorType), ")
                try b.param(JSONValue.object(r.payload).jsonString()); b.raw("::jsonb) ")
                b.raw("ON CONFLICT (id) DO UPDATE SET vector = EXCLUDED.vector, payload = EXCLUDED.payload")
                _ = try await conn.query(b.build(), logger: logger)
            }
            try await execOn(conn, "COMMIT")
        } catch {
            try? await execOn(conn, "ROLLBACK")
            throw Mem0PgErrorMap.wrap(error, "insert")
        }
    }

    public func search(_ query: String, _ vector: [Float], topK: Int, filters: JSONObject) async throws -> [SearchHit] {
        try await acquire(); defer { release() }
        try validateFinite(vector)
        var b = PGQueryBuilder()
        b.raw("SELECT id, payload::text, (vector <=> ")
        try b.param(vectorLiteral(vector))           // $1 — reused in ORDER BY
        b.raw("::\(vectorType)) AS dist FROM memories")
        if PGFilterTranslator.willEmit(filters) {
            b.raw(" WHERE ")
            try PGFilterTranslator.appendPredicate(filters, into: &b)
        }
        // Reuse $1 in ORDER BY so the planner keeps the HNSW index ordering.
        b.raw(" ORDER BY vector <=> $1::\(vectorType) LIMIT ")
        try b.param(topK)
        do {
            let rows = try await connection().query(b.build(), logger: logger)
            var hits: [SearchHit] = []
            for try await (id, payloadText, dist) in rows.decode((String, String, Double).self) {
                // A zero-norm stored vector makes cosine distance NaN; clamp to 0
                // (matching Mem0SQLiteStore's zero-norm guard) so a NaN score never
                // reaches the engine's threshold/sort, where it would misbehave.
                let score = dist.isNaN ? 0 : max(1 - dist, 0)
                hits.append(SearchHit(id: id, score: score,
                                      payload: JSONValue.parse(payloadText)?.objectValue ?? [:]))
            }
            return hits
        } catch {
            throw Mem0PgErrorMap.wrap(error, "search")
        }
    }

    public func get(_ id: String) async throws -> SearchHit? {
        try await acquire(); defer { release() }
        var b = PGQueryBuilder()
        b.raw("SELECT payload::text FROM memories WHERE id = "); try b.param(id)
        do {
            let rows = try await connection().query(b.build(), logger: logger)
            for try await payloadText in rows.decode(String.self) {
                return SearchHit(id: id, score: 0, payload: JSONValue.parse(payloadText)?.objectValue ?? [:])
            }
            return nil
        } catch {
            throw Mem0PgErrorMap.wrap(error, "get")
        }
    }

    public func update(_ id: String, vector: [Float]?, payload: JSONObject?) async throws {
        try await acquire(); defer { release() }
        if let vector { try validateFinite(vector) }
        var b = PGQueryBuilder()
        b.raw("UPDATE memories SET vector = COALESCE(")
        try b.paramOptional(vector.map(vectorLiteral)); b.raw("::\(vectorType), vector), payload = COALESCE(")
        try b.paramOptional(payload.map { JSONValue.object($0).jsonString() }); b.raw("::jsonb, payload) WHERE id = ")
        try b.param(id)
        do {
            _ = try await connection().query(b.build(), logger: logger)
        } catch {
            throw Mem0PgErrorMap.wrap(error, "update")
        }
    }

    public func delete(_ id: String) async throws {
        try await acquire(); defer { release() }
        var b = PGQueryBuilder()
        b.raw("DELETE FROM memories WHERE id = "); try b.param(id)
        do { _ = try await connection().query(b.build(), logger: logger) }
        catch { throw Mem0PgErrorMap.wrap(error, "delete") }
    }

    public func list(_ filters: JSONObject, limit: Int?) async throws -> [SearchHit] {
        try await acquire(); defer { release() }
        var b = PGQueryBuilder()
        b.raw("SELECT id, payload::text FROM memories")
        if PGFilterTranslator.willEmit(filters) {
            b.raw(" WHERE "); try PGFilterTranslator.appendPredicate(filters, into: &b)
        }
        b.raw(" ORDER BY (payload ->> 'created_at') DESC NULLS LAST")
        if let n = limit { b.raw(" LIMIT "); try b.param(n) }
        do {
            let rows = try await connection().query(b.build(), logger: logger)
            var out: [SearchHit] = []
            for try await (id, payloadText) in rows.decode((String, String).self) {
                out.append(SearchHit(id: id, score: 0, payload: JSONValue.parse(payloadText)?.objectValue ?? [:]))
            }
            return out
        } catch {
            throw Mem0PgErrorMap.wrap(error, "list")
        }
    }

    public func deleteCol() async throws {
        try await acquire(); defer { release() }
        do { try await execOn(connection(), "DELETE FROM memories") }
        catch { throw Mem0PgErrorMap.wrap(error, "deleteCol") }
    }

    public func keywordSearch(_ query: String, topK: Int, filters: JSONObject) async throws -> [SearchHit]? {
        try await acquire(); defer { release() }
        var b = PGQueryBuilder()
        b.raw("SELECT id, payload::text, ts_rank(to_tsvector('simple', coalesce(payload ->> 'text_lemmatized', '')), plainto_tsquery('simple', ")
        try b.param(query)
        b.raw(")) AS rank FROM memories WHERE to_tsvector('simple', coalesce(payload ->> 'text_lemmatized', '')) @@ plainto_tsquery('simple', ")
        try b.param(query)
        b.raw(")")
        if PGFilterTranslator.willEmit(filters) {
            b.raw(" AND "); try PGFilterTranslator.appendPredicate(filters, into: &b)
        }
        b.raw(" ORDER BY rank DESC LIMIT ")
        try b.param(topK)
        do {
            let rows = try await connection().query(b.build(), logger: logger)
            var out: [SearchHit] = []
            for try await (id, payloadText, rank) in rows.decode((String, String, Float).self) {
                out.append(SearchHit(id: id, score: Double(rank),
                                     payload: JSONValue.parse(payloadText)?.objectValue ?? [:]))
            }
            return out
        } catch {
            throw Mem0PgErrorMap.wrap(error, "keywordSearch")
        }
    }

    // MARK: - Mem0HistoryStore

    public func addHistory(memoryID: String, oldMemory: String?, newMemory: String?, event: String,
                           createdAt: String?, updatedAt: String?, isDeleted: Int,
                           actorID: String?, role: String?, userID: String?,
                           agentID: String?, runID: String?) async throws {
        try await acquire(); defer { release() }
        do {
            try await insertHistory(try connection(),
                                    memoryID: memoryID, oldMemory: oldMemory, newMemory: newMemory,
                                    event: event, createdAt: createdAt, updatedAt: updatedAt,
                                    isDeleted: isDeleted, actorID: actorID, role: role,
                                    userID: userID, agentID: agentID, runID: runID)
        } catch { throw Mem0PgErrorMap.wrap(error, "addHistory") }
    }

    public func batchAddHistory(_ records: [NewHistory]) async throws {
        try await acquire(); defer { release() }
        let conn = try connection()
        do {
            try await execOn(conn, "BEGIN")
            for r in records {
                try await insertHistory(conn, memoryID: r.memoryID, oldMemory: r.oldMemory,
                                        newMemory: r.newMemory, event: r.event, createdAt: r.createdAt,
                                        updatedAt: r.updatedAt, isDeleted: r.isDeleted, actorID: r.actorID,
                                        role: r.role, userID: r.userID, agentID: r.agentID, runID: r.runID)
            }
            try await execOn(conn, "COMMIT")
        } catch {
            try? await execOn(conn, "ROLLBACK")
            throw Mem0PgErrorMap.wrap(error, "batchAddHistory")
        }
    }

    private func insertHistory(_ conn: PostgresConnection, memoryID: String, oldMemory: String?,
                               newMemory: String?, event: String, createdAt: String?, updatedAt: String?,
                               isDeleted: Int, actorID: String?, role: String?, userID: String?,
                               agentID: String?, runID: String?) async throws {
        var b = PGQueryBuilder()
        b.raw("""
        INSERT INTO history (id, memory_id, old_memory, new_memory, event, created_at,
                             updated_at, is_deleted, actor_id, role, user_id, agent_id, run_id) VALUES (
        """)
        try b.param(UUID().uuidString); b.raw(", ")
        try b.param(memoryID); b.raw(", ")
        try b.paramOptional(oldMemory); b.raw(", ")
        try b.paramOptional(newMemory); b.raw(", ")
        try b.param(event); b.raw(", ")
        try b.paramOptional(createdAt); b.raw(", ")
        try b.paramOptional(updatedAt); b.raw(", ")
        try b.param(isDeleted); b.raw(", ")
        try b.paramOptional(actorID); b.raw(", ")
        try b.paramOptional(role); b.raw(", ")
        try b.paramOptional(userID); b.raw(", ")
        try b.paramOptional(agentID); b.raw(", ")
        try b.paramOptional(runID); b.raw(")")
        _ = try await conn.query(b.build(), logger: logger)
    }

    public func getHistory(_ memoryID: String) async throws -> [HistoryRecord] {
        try await acquire(); defer { release() }
        var b = PGQueryBuilder()
        b.raw("""
        SELECT id, memory_id, old_memory, new_memory, event, created_at, updated_at,
               is_deleted, actor_id, role, user_id, agent_id, run_id
        FROM history WHERE memory_id =
        """)
        b.raw(" "); try b.param(memoryID)
        b.raw(" ORDER BY created_at ASC, updated_at ASC")
        do {
            let rows = try await connection().query(b.build(), logger: logger)
            var out: [HistoryRecord] = []
            for try await row in rows.decode(
                (String, String?, String?, String?, String, String?, String?, Int, String?, String?, String?, String?, String?).self) {
                out.append(HistoryRecord(
                    id: row.0, memoryID: row.1 ?? "", oldMemory: row.2, newMemory: row.3,
                    event: row.4, createdAt: row.5, updatedAt: row.6, isDeleted: row.7 != 0,
                    actorID: row.8, role: row.9, userID: row.10, agentID: row.11, runID: row.12))
            }
            return out
        } catch {
            throw Mem0PgErrorMap.wrap(error, "getHistory")
        }
    }

    public func saveMessages(_ messages: [Message], scope: String) async throws {
        try await acquire(); defer { release() }
        if messages.isEmpty { return }
        let conn = try connection()
        let now = nowUTCRFC3339()
        do {
            try await execOn(conn, "BEGIN")
            for m in messages {
                var b = PGQueryBuilder()
                b.raw("INSERT INTO messages (id, session_scope, role, content, name, created_at) VALUES (")
                try b.param(UUID().uuidString); b.raw(", ")
                try b.param(scope); b.raw(", ")
                try b.param(m.role); b.raw(", ")
                try b.param(m.content); b.raw(", ")
                try b.paramOptional(m.name); b.raw(", ")
                try b.param(now); b.raw(")")
                _ = try await conn.query(b.build(), logger: logger)
            }
            // Evict all but the most recent 10 for this scope.
            var e = PGQueryBuilder()
            e.raw("DELETE FROM messages WHERE session_scope = "); try e.param(scope)
            e.raw(" AND id NOT IN (SELECT id FROM messages WHERE session_scope = "); try e.param(scope)
            e.raw(" ORDER BY created_at DESC LIMIT 10)")
            _ = try await conn.query(e.build(), logger: logger)
            try await execOn(conn, "COMMIT")
        } catch {
            try? await execOn(conn, "ROLLBACK")
            throw Mem0PgErrorMap.wrap(error, "saveMessages")
        }
    }

    public func getLastMessages(_ scope: String, limit: Int) async throws -> [StoredMessage] {
        try await acquire(); defer { release() }
        var b = PGQueryBuilder()
        b.raw("SELECT role, content, name, created_at FROM (SELECT role, content, name, created_at FROM messages WHERE session_scope = ")
        try b.param(scope)
        b.raw(" ORDER BY created_at DESC LIMIT ")
        try b.param(limit)
        b.raw(") sub ORDER BY created_at ASC")
        do {
            let rows = try await connection().query(b.build(), logger: logger)
            var out: [StoredMessage] = []
            for try await (role, content, name, createdAt) in rows.decode((String?, String?, String?, String?).self) {
                out.append(StoredMessage(role: role, content: content, name: name, createdAt: createdAt))
            }
            return out
        } catch {
            throw Mem0PgErrorMap.wrap(error, "getLastMessages")
        }
    }

    /// Full reset — satisfies both protocols' `reset()`.
    public func reset() async throws {
        try await acquire(); defer { release() }
        let conn = try connection()
        do {
            try await execOn(conn, "BEGIN")
            try await execOn(conn, "DELETE FROM memories")
            try await execOn(conn, "DELETE FROM history")
            try await execOn(conn, "DELETE FROM messages")
            try await execOn(conn, "COMMIT")
        } catch {
            try? await execOn(conn, "ROLLBACK")
            throw Mem0PgErrorMap.wrap(error, "reset")
        }
    }

    // MARK: - snapshots (macOS APFS clone)

    /// Best-effort online snapshot: `CHECKPOINT` then an APFS copy-on-write clone
    /// of `PGDATA`. The clone includes `pg_wal`, so a crash-style recovery on
    /// re-open reaches a consistent state. For the STRONGEST guarantee, take a
    /// cold snapshot (stop the postmaster, clone, restart) — see pglite.md.
    /// `destination` must not already exist.
    public func snapshot(to destination: String) async throws {
        try await acquire(); defer { release() }
        do {
            try await execOn(connection(), "CHECKPOINT")
            try PGSnapshot.cloneQuiesced(from: paths.dataDir, to: destination)
        } catch let e as Mem0Error {
            throw e
        } catch {
            throw Mem0PgErrorMap.wrap(error, "snapshot")
        }
    }
}
