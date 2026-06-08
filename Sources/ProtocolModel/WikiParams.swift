import Foundation

// Decodable params for the read-only Memory Wiki RPC surface (M0). A wiki
// "page" is a DocumentRow in the SQLite wiki store; ids are the row ids. All
// bounds are RE-clamped router-side (defense in depth) so untrusted browser
// input can never reach an out-of-range store query.

public struct WikiListParams: Decodable, Sendable, Equatable {
    /// Max pages to return; router clamps to 1...500 (default 100).
    public var limit: Int?
    public init(limit: Int? = nil) { self.limit = limit }
}

public struct WikiPageGetParams: Decodable, Sendable, Equatable {
    /// DocumentRow.id of the page to fetch.
    public var id: Int64
    public init(id: Int64) { self.id = id }
}

public struct WikiSearchParams: Decodable, Sendable, Equatable {
    public var query: String
    /// Top-k hits; router clamps to 1...100 (default 10).
    public var k: Int?
    public init(query: String, k: Int? = nil) { self.query = query; self.k = k }
}

public struct WikiGraphParams: Decodable, Sendable, Equatable {
    /// nil → capped whole-graph; non-nil → 2-hop walk seeded at this entity id.
    public var seed: Int64?
    /// Walk depth; router clamps to 1...4 (default 2). Only used when seed != nil.
    public var depth: Int?
    public init(seed: Int64? = nil, depth: Int? = nil) { self.seed = seed; self.depth = depth }
}

public struct WikiBacklinksParams: Decodable, Sendable, Equatable {
    /// Entity id whose in/out edges are returned.
    public var entityId: Int64
    public init(entityId: Int64) { self.entityId = entityId }
}
