import Foundation
import WireProtocol

/// Deny-default read-only handle into the Memory Wiki store, injected by the
/// composition root (codexd). All closures return wire-ready `JSONValue` so the
/// `Supervisor` module never imports `MemoryStore`/`MemoryRetrieve` (whose
/// `MemoryStore` type name collides with `HarnessCore.MemoryStore`). A `nil`
/// handle means the wiki is not enabled → every `wiki/*` RPC is refused.
///
/// The closures capture the `MemoryStore`/`MemoryRetriever` actors, so the
/// struct is trivially `Sendable` and safe to share across per-tab routers.
public struct WikiQueryHandle: Sendable {
    /// Recent/all pages (documents). `limit` is pre-clamped by the router.
    public var list: @Sendable (_ limit: Int) async throws -> JSONValue
    /// One page by document id; `nil` → not found (router maps to invalidRequest).
    public var pageGet: @Sendable (_ id: Int64) async throws -> JSONValue?
    /// Hybrid search, grouped by document. `k` is pre-clamped.
    public var search: @Sendable (_ query: String, _ k: Int) async throws -> JSONValue
    /// Entity/edge graph: seeded 2-hop walk, or capped whole-graph when `seed == nil`.
    public var graph: @Sendable (_ seed: Int64?, _ depth: Int) async throws -> JSONValue
    /// In/out edges for an entity.
    public var backlinks: @Sendable (_ entityId: Int64) async throws -> JSONValue
    /// Pages that MENTION an entity (entity→page backlinks).
    public var entityBacklinks: @Sendable (_ entityId: Int64) async throws -> JSONValue
    /// Tag entities with counts.
    public var tags: @Sendable () async throws -> JSONValue
    /// Vault link + property index: per-page outgoing `[[wikilinks]]` + parsed
    /// frontmatter props. Powers backlinks / unlinked-mentions / property-catalog
    /// and rename link-rewrite (M26/M28/M30) from a single read.
    public var index: @Sendable () async throws -> JSONValue
    /// Insert/overwrite a page (id nil → create). Returns `{id}`. The wiki UI is
    /// the edit environment, so this WRITE lives on the same deny-default handle.
    public var upsert: @Sendable (_ id: Int64?, _ title: String?, _ body: String) async throws -> JSONValue
    /// Delete a page (manual document) + its derived chunks/index rows. Returns
    /// `{deleted, id}`; idempotent on a missing id. Lives on the same
    /// deny-default handle as upsert — the wiki UI is the edit environment.
    public var delete: @Sendable (_ id: Int64) async throws -> JSONValue
    /// Rename a page (title only — preserves source/body/index). `{renamed, id}`.
    public var rename: @Sendable (_ id: Int64, _ title: String) async throws -> JSONValue
    /// Lexical, zero-spend cited synthesis brief on a topic (the "enrich" surface).
    public var brief: @Sendable (_ topic: String, _ k: Int) async throws -> JSONValue
    /// Depth-tiered retrieval: depth 1=quick (lexical/index only), 2=standard,
    /// 3=deep (hybrid BM25∥cosine→RRF→rerank when an embedder matching the store's
    /// stamp is available; otherwise lexical, with the response noting the mode).
    /// `k` pre-clamped by the router.
    public var query: @Sendable (_ query: String, _ depth: Int, _ k: Int) async throws -> JSONValue
    /// Dashboard: raw doc / wiki-page counts, flagged-stale count, recent ingest log.
    public var status: @Sendable () async throws -> JSONValue
    /// Watched sources + their cadence / due status (the Watch tab).
    public var watchList: @Sendable () async throws -> JSONValue
    /// Librarian Tier-1 staleness report (pure date arithmetic, no spend/egress): the
    /// stalest pages + which are flagged for a Tier-2 model review. A Tier-A read.
    public var librarianReport: @Sendable () async throws -> JSONValue
    /// Audit Pass-2 output-drift report (pure timestamps, no spend/egress): which
    /// compiled pages were built from a since-changed claim. A Tier-A read.
    public var auditReport: @Sendable () async throws -> JSONValue
    /// Inventory records (compact-table projection). Tier-A read.
    public var inventoryList: @Sendable () async throws -> JSONValue
    /// Dataset manifests. Tier-A read.
    public var datasetList: @Sendable () async throws -> JSONValue
    /// Collect catalogs with item counts. Tier-A read.
    public var collectList: @Sendable () async throws -> JSONValue
    /// Research-session history (topic/mode/status/rounds/score). Tier-A read.
    public var sessionsList: @Sendable () async throws -> JSONValue

    public init(
        list: @escaping @Sendable (Int) async throws -> JSONValue,
        pageGet: @escaping @Sendable (Int64) async throws -> JSONValue?,
        search: @escaping @Sendable (String, Int) async throws -> JSONValue,
        graph: @escaping @Sendable (Int64?, Int) async throws -> JSONValue,
        backlinks: @escaping @Sendable (Int64) async throws -> JSONValue,
        entityBacklinks: @escaping @Sendable (Int64) async throws -> JSONValue,
        tags: @escaping @Sendable () async throws -> JSONValue,
        index: @escaping @Sendable () async throws -> JSONValue,
        upsert: @escaping @Sendable (Int64?, String?, String) async throws -> JSONValue,
        delete: @escaping @Sendable (Int64) async throws -> JSONValue,
        rename: @escaping @Sendable (Int64, String) async throws -> JSONValue,
        brief: @escaping @Sendable (String, Int) async throws -> JSONValue,
        query: @escaping @Sendable (String, Int, Int) async throws -> JSONValue,
        status: @escaping @Sendable () async throws -> JSONValue,
        watchList: @escaping @Sendable () async throws -> JSONValue,
        librarianReport: @escaping @Sendable () async throws -> JSONValue,
        auditReport: @escaping @Sendable () async throws -> JSONValue,
        inventoryList: @escaping @Sendable () async throws -> JSONValue,
        datasetList: @escaping @Sendable () async throws -> JSONValue,
        collectList: @escaping @Sendable () async throws -> JSONValue,
        sessionsList: @escaping @Sendable () async throws -> JSONValue
    ) {
        self.list = list
        self.pageGet = pageGet
        self.search = search
        self.graph = graph
        self.backlinks = backlinks
        self.entityBacklinks = entityBacklinks
        self.tags = tags
        self.index = index
        self.upsert = upsert
        self.delete = delete
        self.rename = rename
        self.brief = brief
        self.query = query
        self.status = status
        self.watchList = watchList
        self.librarianReport = librarianReport
        self.auditReport = auditReport
        self.inventoryList = inventoryList
        self.datasetList = datasetList
        self.collectList = collectList
        self.sessionsList = sessionsList
    }
}
