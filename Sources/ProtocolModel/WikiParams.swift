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

public struct WikiBriefParams: Decodable, Sendable, Equatable {
    /// Topic/query to synthesize a cited brief for.
    public var topic: String
    /// Evidence count; router clamps 1...20 (default 8).
    public var k: Int?
    public init(topic: String, k: Int? = nil) { self.topic = topic; self.k = k }
}

public struct WikiPageUpsertParams: Decodable, Sendable, Equatable {
    /// Existing page (DocumentRow) id to overwrite; nil → create a new page.
    public var id: Int64?
    public var title: String?
    /// The markdown body to persist.
    public var body: String
    public init(id: Int64? = nil, title: String? = nil, body: String) {
        self.id = id; self.title = title; self.body = body
    }
}

public struct WikiPageDeleteParams: Decodable, Sendable, Equatable {
    /// DocumentRow.id of the page to delete (with its derived chunks/index rows).
    public var id: Int64
    public init(id: Int64) { self.id = id }
}

public struct WikiPageRenameParams: Decodable, Sendable, Equatable {
    /// DocumentRow.id of the page to rename.
    public var id: Int64
    /// The new title.
    public var title: String
    public init(id: Int64, title: String) { self.id = id; self.title = title }
}
