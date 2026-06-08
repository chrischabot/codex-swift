import Foundation

/// Embedding action context (`add` | `search` | `update`). Port of `MemoryAction`.
public enum MemoryAction: String, Sendable, Equatable {
    case add, search, update
}

/// Options for an LLM generation call. Port of `GenerateOptions`.
public struct GenerateOptions: Sendable, Equatable {
    public var responseFormatJSON: Bool
    public var temperature: Double?
    public var maxTokens: Int?
    public var topP: Double?
    public init(responseFormatJSON: Bool = false, temperature: Double? = nil,
                maxTokens: Int? = nil, topP: Double? = nil) {
        self.responseFormatJSON = responseFormatJSON
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
    }
}

/// Text → vector embedder. Port of the `Embedder` trait.
public protocol Mem0Embedder: Sendable {
    func embed(_ text: String, _ action: MemoryAction) async throws -> [Float]
    func embedBatch(_ texts: [String], _ action: MemoryAction) async throws -> [[Float]]
    var dims: Int { get }
}

public extension Mem0Embedder {
    /// Default batch embed loops over `embed`.
    func embedBatch(_ texts: [String], _ action: MemoryAction) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for t in texts { out.append(try await embed(t, action)) }
        return out
    }
}

/// Chat-completion LLM. Port of the `Llm` trait.
public protocol Mem0LLM: Sendable {
    func generate(_ messages: [Message], _ options: GenerateOptions) async throws -> String
}

/// Vector store. Port of the `VectorStore` trait.
public protocol Mem0VectorStore: Sendable {
    func insert(_ records: [VectorRecord]) async throws
    func search(_ query: String, _ vector: [Float], topK: Int, filters: JSONObject) async throws -> [SearchHit]
    func get(_ id: String) async throws -> SearchHit?
    func update(_ id: String, vector: [Float]?, payload: JSONObject?) async throws
    func delete(_ id: String) async throws
    func list(_ filters: JSONObject, limit: Int?) async throws -> [SearchHit]
    func deleteCol() async throws
    func reset() async throws
    /// Optional keyword/BM25 search. Returns nil when unsupported.
    func keywordSearch(_ query: String, topK: Int, filters: JSONObject) async throws -> [SearchHit]?
    func searchBatch(_ queries: [String], _ vectors: [[Float]], topK: Int, filters: JSONObject) async throws -> [[SearchHit]]
}

public extension Mem0VectorStore {
    func keywordSearch(_ query: String, topK: Int, filters: JSONObject) async throws -> [SearchHit]? { nil }
    func searchBatch(_ queries: [String], _ vectors: [[Float]], topK: Int, filters: JSONObject) async throws -> [[SearchHit]] {
        var out: [[SearchHit]] = []
        for (q, v) in zip(queries, vectors) {
            out.append(try await search(q, v, topK: topK, filters: filters))
        }
        return out
    }
}

/// SQLite-style history + recent-message store. Port of the rusqlite
/// `SQLiteManager` surface used by the engine.
public protocol Mem0HistoryStore: Sendable {
    func addHistory(memoryID: String, oldMemory: String?, newMemory: String?, event: String,
                    createdAt: String?, updatedAt: String?, isDeleted: Int,
                    actorID: String?, role: String?, userID: String?,
                    agentID: String?, runID: String?) async throws
    func batchAddHistory(_ records: [NewHistory]) async throws
    func getHistory(_ memoryID: String) async throws -> [HistoryRecord]
    func saveMessages(_ messages: [Message], scope: String) async throws
    func getLastMessages(_ scope: String, limit: Int) async throws -> [StoredMessage]
    func reset() async throws
}
