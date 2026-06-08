import Foundation

/// Deterministic hash-based embedder: similar text → similar vectors. Port of
/// `MockEmbedder` (FNV-1a bucketed, L2-normalized) — bit-compatible with the
/// Rust/Python parity harness.
public struct MockEmbedder: Mem0Embedder {
    public let dims: Int
    public init(dims: Int = 32) { self.dims = max(1, dims) }

    public func embed(_ text: String, _ action: MemoryAction) async throws -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var h: UInt64 = 0xcbf29ce484222325
            for b in raw.utf8 {
                h ^= UInt64(b)
                h = h &* 0x100000001b3
            }
            let idx = Int(h % UInt64(dims))
            v[idx] += 1.0
        }
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        if norm > 0 { for i in v.indices { v[i] /= norm } }
        return v
    }
}

/// Synchronous critical section over an `NSLock` (Swift 6 forbids calling
/// `lock()`/`unlock()` directly from an async context; wrapping them in a
/// non-async function is the supported workaround). The body must not suspend.
@inline(__always)
private func locked<T>(_ lock: NSLock, _ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
}

/// Mock LLM returning queued responses (or a default when the queue empties).
/// Port of `MockLlm`.
public final class MockLLM: Mem0LLM, @unchecked Sendable {
    private var responses: [String]
    private let fallback: String
    private let lock = NSLock()

    public init(_ fallback: String = #"{"memory": []}"#) {
        self.responses = []
        self.fallback = fallback
    }

    public init(responses: [String]) {
        self.responses = responses
        self.fallback = #"{"memory": []}"#
    }

    public func generate(_ messages: [Message], _ options: GenerateOptions) async throws -> String {
        locked(lock) {
            if responses.isEmpty { return fallback }
            return responses.removeFirst()
        }
    }
}

private func cosine(_ a: [Float], _ b: [Float]) -> Float {
    if a.count != b.count { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    if na == 0 || nb == 0 { return 0 }
    return dot / (sqrt(na) * sqrt(nb))
}

/// In-memory vector store with cosine search and BM25 keyword search over the
/// `text_lemmatized` payload field. Port of `InMemoryVectorStore`.
///
/// A lock-guarded `final class` (not an `actor`): the store does only short,
/// non-suspending work, so guarding a dictionary with an `NSLock` avoids the
/// per-call executor hop an actor would impose on the add/search hot paths.
public final class InMemoryVectorStore: Mem0VectorStore, @unchecked Sendable {
    private var inner: [String: VectorRecord] = [:]
    private let lock = NSLock()
    public init() {}

    public func insert(_ records: [VectorRecord]) async throws {
        locked(lock) { for r in records { inner[r.id] = r } }
    }

    public func search(_ query: String, _ vector: [Float], topK: Int, filters: JSONObject) async throws -> [SearchHit] {
        locked(lock) {
            var idScores: [(String, Double)] = inner.values
                .filter { Mem0Filters.matchesFilters($0.payload, filters) }
                .map { ($0.id, Double(max(cosine(vector, $0.vector), 0))) }
            idScores.sort { $0.1 > $1.1 }
            if idScores.count > topK { idScores = Array(idScores.prefix(topK)) }
            return idScores.compactMap { (id, score) in
                inner[id].map { SearchHit(id: id, score: score, payload: $0.payload) }
            }
        }
    }

    public func get(_ id: String) async throws -> SearchHit? {
        guard let r = locked(lock, { inner[id] }) else { return nil }
        return SearchHit(id: r.id, score: 0, payload: r.payload)
    }

    public func update(_ id: String, vector: [Float]?, payload: JSONObject?) async throws {
        locked(lock) {
            if var r = inner[id] {
                if let v = vector { r.vector = v }
                if let p = payload { r.payload = p }
                inner[id] = r
            }
        }
    }

    public func delete(_ id: String) async throws {
        locked(lock) { inner[id] = nil }
    }

    public func list(_ filters: JSONObject, limit: Int?) async throws -> [SearchHit] {
        let recs: [(String, VectorRecord)] = locked(lock) {
            inner.values
                .filter { Mem0Filters.matchesFilters($0.payload, filters) }
                .map { ($0.payload["created_at"]?.stringValue ?? "", $0) }
        }
        var sorted = recs.sorted { $0.0 > $1.0 }
        if let n = limit { sorted = Array(sorted.prefix(n)) }
        return sorted.map { SearchHit(id: $0.1.id, score: 0, payload: $0.1.payload) }
    }

    public func deleteCol() async throws { locked(lock) { inner.removeAll() } }
    public func reset() async throws { locked(lock) { inner.removeAll() } }

    public func keywordSearch(_ query: String, topK: Int, filters: JSONObject) async throws -> [SearchHit]? {
        locked(lock) { () -> [SearchHit]? in
            let corpus: [(String, String)] = inner.values
                .filter { Mem0Filters.matchesFilters($0.payload, filters) }
                .map { ($0.id, $0.payload["text_lemmatized"]?.stringValue ?? "") }
            let scores = Mem0Scoring.bm25Scores(query, corpus: corpus)
            if scores.isEmpty { return [] }
            var idScores = scores.map { ($0.key, $0.value) }
            idScores.sort { $0.1 > $1.1 }
            if idScores.count > topK { idScores = Array(idScores.prefix(topK)) }
            return idScores.compactMap { (id, score) in
                inner[id].map { SearchHit(id: id, score: score, payload: $0.payload) }
            }
        }
    }
}

/// In-memory history + recent-message store. Port of the in-memory side of the
/// rusqlite history manager, for tests and the `:memory:` default. Lock-guarded
/// `final class` (not an `actor`) to avoid an executor hop on the add hot path.
public final class InMemoryHistoryStore: Mem0HistoryStore, @unchecked Sendable {
    private var rows: [HistoryRecord] = []
    private var messages: [String: [StoredMessage]] = [:]
    private let lock = NSLock()
    public init() {}

    public func addHistory(memoryID: String, oldMemory: String?, newMemory: String?, event: String,
                           createdAt: String?, updatedAt: String?, isDeleted: Int,
                           actorID: String?, role: String?, userID: String?,
                           agentID: String?, runID: String?) async throws {
        locked(lock) {
            rows.append(HistoryRecord(id: UUID().uuidString, memoryID: memoryID,
                                      oldMemory: oldMemory, newMemory: newMemory, event: event,
                                      createdAt: createdAt, updatedAt: updatedAt,
                                      isDeleted: isDeleted != 0, actorID: actorID, role: role,
                                      userID: userID, agentID: agentID, runID: runID))
        }
    }

    public func batchAddHistory(_ records: [NewHistory]) async throws {
        locked(lock) {
            for r in records {
                rows.append(HistoryRecord(id: UUID().uuidString, memoryID: r.memoryID,
                                          oldMemory: r.oldMemory, newMemory: r.newMemory, event: r.event,
                                          createdAt: r.createdAt, updatedAt: r.updatedAt,
                                          isDeleted: r.isDeleted != 0, actorID: r.actorID, role: r.role,
                                          userID: r.userID, agentID: r.agentID, runID: r.runID))
            }
        }
    }

    public func getHistory(_ memoryID: String) async throws -> [HistoryRecord] {
        let out = locked(lock) { rows.filter { $0.memoryID == memoryID } }
        return out.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
    }

    public func saveMessages(_ messages: [Message], scope: String) async throws {
        let now = nowUTCRFC3339()
        locked(lock) {
            var bucket = self.messages[scope] ?? []
            for m in messages {
                bucket.append(StoredMessage(role: m.role, content: m.content, name: m.name, createdAt: now))
            }
            if bucket.count > 10 { bucket = Array(bucket.suffix(10)) }
            self.messages[scope] = bucket
        }
    }

    public func getLastMessages(_ scope: String, limit: Int) async throws -> [StoredMessage] {
        let bucket = locked(lock) { messages[scope] ?? [] }
        return Array(bucket.suffix(limit))
    }

    public func reset() async throws {
        locked(lock) {
            rows.removeAll()
            messages.removeAll()
        }
    }
}
