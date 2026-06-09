import XCTest
import Foundation
@testable import WikiQueryKit
import MemoryStore
import WireProtocol
import Config

/// Severe coverage for the `wiki/*` JSON shapers (the read path the browser hits)
/// against a REAL MemoryStore on a temp DB. CLAIM: each shaper maps store rows to
/// the documented wire shape, degrades safely on missing data, and never traps on
/// adversarial ids. ORACLE: a hand-seeded fixture with known structure.
final class WikiJSONTests: XCTestCase {
    // Fixture handles captured by setUp for per-test assertions.
    private var store: MemoryStore!
    private var dir: String!
    private var doc1: Int64 = 0   // "Alpha", real body, 2 chunks, tag+concept entities
    private var doc2: Int64 = 0   // "Beta", body file DELETED, 1 chunk
    private var doc3: Int64 = 0   // title nil → sourceURI, 0 chunks
    private var tagAI: Int64 = 0  // kind .tag
    private var concML: Int64 = 0 // kind .concept

    override func setUp() async throws {
        dir = NSTemporaryDirectory() + "wikijson-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Small embedding dim so the fixture stays light (FTS search is dim-independent).
        store = try MemoryStore(MemoryStoreConfig(path: dir + "/m.db", embeddingDimension: 8))
        let now: Int64 = 1_700_000_000

        let body1 = dir + "/body1.md"
        try "Hello **world**, this is the alpha page about machine learning.".write(
            toFile: body1, atomically: true, encoding: .utf8)
        doc1 = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "wiki://alpha", title: "Alpha", bodyPath: body1,
            fetchedAt: now, contentSHA: Data([1]), rawBytes: 64))
        doc2 = try await store.upsertDocument(DocumentRow(
            source: .web, sourceURI: "wiki://beta", title: "Beta",
            bodyPath: dir + "/MISSING-body.md", fetchedAt: now + 10, contentSHA: Data([2]), rawBytes: 32))
        doc3 = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "wiki://gamma", title: nil,
            bodyPath: dir + "/body3.md", fetchedAt: now + 20, contentSHA: Data([3]), rawBytes: 0))

        let c1 = try await store.insertChunk(ChunkRow(
            documentId: doc1, idx: 0, text: "Hello world machine learning alpha", rawText: "Hello world",
            tokenCount: 6, createdAt: now), embeddingValues: Array(repeating: 0, count: 8))
        _ = try await store.insertChunk(ChunkRow(
            documentId: doc1, idx: 1, text: "second alpha chunk", rawText: "second", tokenCount: 3,
            createdAt: now), embeddingValues: Array(repeating: 0, count: 8))
        _ = try await store.insertChunk(ChunkRow(
            documentId: doc2, idx: 0, text: "beta page body", rawText: "beta", tokenCount: 3,
            createdAt: now), embeddingValues: Array(repeating: 0, count: 8))

        tagAI = try await store.upsertEntity(EntityRow(
            kind: .tag, canonical: "ai", firstSeen: now, lastSeen: now, degree: 5))
        concML = try await store.upsertEntity(EntityRow(
            kind: .concept, canonical: "machine-learning", firstSeen: now, lastSeen: now, degree: 2))
        // An EXTERNAL entity (not mentioned by the page) connected to a page
        // entity — gives a deterministic "connection" regardless of Set order.
        let deepL = try await store.upsertEntity(EntityRow(
            kind: .concept, canonical: "deep-learning", firstSeen: now, lastSeen: now))
        // Edge ai → machine-learning, a self-loop on the tag (degree edge case),
        // and machine-learning → deep-learning (the external neighbor).
        _ = try await store.upsertEdge(EdgeRow(src: tagAI, dst: concML, relation: "related",
                                               firstSeen: now, lastSeen: now, weight: 0.9))
        _ = try await store.upsertEdge(EdgeRow(src: tagAI, dst: tagAI, relation: "self",
                                               firstSeen: now, lastSeen: now, weight: 0.1))
        _ = try await store.upsertEdge(EdgeRow(src: concML, dst: deepL, relation: "subfield",
                                               firstSeen: now, lastSeen: now, weight: 0.5))
        // chunk1 mentions both entities.
        try await store.insertMention(MentionRow(chunkId: c1, entityId: tagAI))
        try await store.insertMention(MentionRow(chunkId: c1, entityId: concML))
    }

    override func tearDown() async throws {
        store = nil
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    // MARK: - list

    func testListReturnsAllDocsWithFields() async throws {
        let r = try await WikiJSON.list(store, limit: 100)
        let items = r.obj?["data"]?.arr
        XCTAssertEqual(items?.count, 3, "all three docs listed (incl. the zero-chunk one)")
        let byTitle = Dictionary(uniqueKeysWithValues: (items ?? []).map { ($0.obj?["title"]?.str ?? "", $0) })
        XCTAssertNotNil(byTitle["Alpha"])
        // doc3 has nil title → falls back to sourceURI.
        XCTAssertNotNil(byTitle["wiki://gamma"], "nil title falls back to sourceURI")
        XCTAssertEqual(byTitle["wiki://gamma"]?.obj?["chunkCount"]?.int, 0)
        XCTAssertEqual(byTitle["Alpha"]?.obj?["chunkCount"]?.int, 2)
        // updatedAt is epoch MILLIS (seconds * 1000).
        XCTAssertEqual(byTitle["Alpha"]?.obj?["updatedAt"]?.int, 1_700_000_000 * 1000)
    }

    /// CLAIM: "recent pages" are ordered NEWEST-first by fetched_at, before the
    /// limit — not by source_uri. (Fixes the codex-review P2 where the sidebar
    /// showed an alphabetic, truncated list.) Fixture: doc1<doc2<doc3 by time.
    func testListIsRecencyOrdered() async throws {
        let r = try await WikiJSON.list(store, limit: 100)
        let titles = (r.obj?["data"]?.arr ?? []).map { $0.obj?["title"]?.str ?? "" }
        // doc3 (now+20, title nil→gamma URI), doc2 (now+10, Beta), doc1 (now, Alpha).
        XCTAssertEqual(titles.first, "wiki://gamma", "newest page first")
        XCTAssertEqual(titles, ["wiki://gamma", "Beta", "Alpha"], "strict newest→oldest order")
        // The limit must select the NEWEST, not the alphabetically-first.
        let top1 = try await WikiJSON.list(store, limit: 1)
        XCTAssertEqual(top1.obj?["data"]?.arr?.first?.obj?["title"]?.str, "wiki://gamma")
    }

    // MARK: - pageGet

    func testPageGetFull() async throws {
        let page = try await WikiJSON.pageGet(store, id: doc1)
        let o = try XCTUnwrap(page?.obj)
        XCTAssertEqual(o["title"]?.str, "Alpha")
        XCTAssertTrue((o["content"]?.str ?? "").contains("Hello **world**"), "body markdown read from disk")
        let tags = (o["tags"]?.arr ?? []).compactMap { $0.str }
        XCTAssertEqual(tags, ["ai"], "only the .tag entity surfaces as a tag; concept does not")
        let conns = o["connections"]?.arr ?? []
        XCTAssertFalse(conns.isEmpty, "edges surface as connections")
        // The external neighbor (deep-learning, reachable only via the page's
        // machine-learning entity) must surface — deterministic, order-independent.
        let connNames = conns.compactMap { $0.obj?["canonical"]?.str }
        XCTAssertTrue(connNames.contains("deep-learning"), "external connection surfaced; got \(connNames)")
    }

    func testPageGetMissingBodyDegradesToEmpty() async throws {
        let page = try await WikiJSON.pageGet(store, id: doc2)
        // bodyPath points at a deleted file → content "" (degrade, not throw).
        XCTAssertEqual(page?.obj?["content"]?.str, "")
        XCTAssertEqual(page?.obj?["title"]?.str, "Beta")
    }

    func testPageGetNotFoundReturnsNil() async throws {
        let missing = try await WikiJSON.pageGet(store, id: 9_999_999)
        XCTAssertNil(missing, "unknown id → nil (router maps to invalidRequest)")
        // Adversarial ids must not trap.
        let neg = try await WikiJSON.pageGet(store, id: -1)
        let big = try await WikiJSON.pageGet(store, id: Int64.max)
        XCTAssertNil(neg)
        XCTAssertNil(big)
    }

    // MARK: - search

    func testSearchGroupsByDocumentAndExcerpts() async throws {
        let r = try await WikiJSON.search(store, query: "world", k: 10)
        let items = try XCTUnwrap(r.obj?["data"]?.arr)
        XCTAssertGreaterThanOrEqual(items.count, 1)
        // doc1's two chunks must collapse to ONE document entry (grouped).
        let ids = items.compactMap { $0.obj?["id"]?.int }
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate document entries")
        XCTAssertTrue(ids.contains(doc1))
        let alpha = items.first { $0.obj?["id"]?.int == doc1 }
        XCTAssertFalse((alpha?.obj?["excerpt"]?.str ?? "").isEmpty, "excerpt present")
    }

    func testSearchEmptyQueryShortCircuits() async throws {
        let r = try await WikiJSON.search(store, query: "   ", k: 10)
        XCTAssertEqual(r.obj?["data"]?.arr?.count, 0)
    }

    // MARK: - graph

    func testGraphWholeGraph() async throws {
        let r = try await WikiJSON.graph(store, seed: nil, depth: 2)
        let nodes = try XCTUnwrap(r.obj?["nodes"]?.arr)
        let edges = try XCTUnwrap(r.obj?["edges"]?.arr)
        XCTAssertGreaterThanOrEqual(nodes.count, 2, "ai + machine-learning present")
        // node weight mirrors the store-maintained degree (upsertEdge recomputes it).
        let liveDegree = try await store.entity(id: tagAI)?.degree
        let ai = nodes.first { $0.obj?["title"]?.str == "ai" }
        XCTAssertEqual(ai?.obj?["weight"]?.int, liveDegree.map(Int64.init))
        XCTAssertGreaterThanOrEqual(edges.count, 1)
    }

    func testGraphSeededWalk() async throws {
        let r = try await WikiJSON.graph(store, seed: tagAI, depth: 2)
        let nodes = (r.obj?["nodes"]?.arr ?? []).compactMap { $0.obj?["title"]?.str }
        XCTAssertTrue(nodes.contains("ai"), "seed node present")
        // A seed that doesn't exist yields an empty-ish graph, not a crash.
        let empty = try await WikiJSON.graph(store, seed: 9_999_999, depth: 2)
        XCTAssertNotNil(empty.obj?["nodes"]?.arr)
    }

    // MARK: - tags

    func testTagsOnlyTagKind() async throws {
        let r = try await WikiJSON.tags(store)
        let tags = (r.obj?["data"]?.arr ?? []).compactMap { $0.obj?["tag"]?.str }
        XCTAssertEqual(tags, ["ai"], "only .tag entities; the concept must not leak")
        // count mirrors the store-maintained degree.
        let liveDegree = try await store.entity(id: tagAI)?.degree
        let count = r.obj?["data"]?.arr?.first?.obj?["count"]?.int
        XCTAssertEqual(count, liveDegree.map(Int64.init))
    }

    // MARK: - upsert (write path)

    /// CLAIM: upsert creates a page (body written, doc + lexical chunks inserted),
    /// it's then listable/gettable/searchable, and a second upsert with the id
    /// OVERWRITES the body + re-chunks (no stale chunks). SEVERITY: severe — this
    /// is the edit environment's write path against a real store.
    func testUpsertCreatesThenOverwrites() async throws {
        let root = dir + "/bodies"
        // Create a new page.
        let created = try await WikiJSON.upsert(store, bodyRoot: root, id: nil, title: "My Note",
                                                body: "First body about penguins and pelicans.")
        let newId = created.obj?["id"]?.int
        XCTAssertNotNil(newId)
        // page/get returns the body + title.
        let page = try await WikiJSON.pageGet(store, id: newId!)
        XCTAssertEqual(page?.obj?["title"]?.str, "My Note")
        XCTAssertTrue((page?.obj?["content"]?.str ?? "").contains("penguins"))
        // It is lexically searchable (zero-embedding chunks still index in FTS).
        let hits = try await WikiJSON.search(store, query: "penguins", k: 10)
        let hitIds = (hits.obj?["data"]?.arr ?? []).compactMap { $0.obj?["id"]?.int }
        XCTAssertTrue(hitIds.contains(newId!), "the new page is found by full-text search")

        // Overwrite the SAME page by id — body replaced, old chunks gone.
        let updated = try await WikiJSON.upsert(store, bodyRoot: root, id: newId, title: "My Note v2",
                                                body: "Second body about wardrobes entirely.")
        XCTAssertEqual(updated.obj?["id"]?.int, newId, "overwrite keeps the same document id")
        let page2 = try await WikiJSON.pageGet(store, id: newId!)
        XCTAssertEqual(page2?.obj?["title"]?.str, "My Note v2")
        XCTAssertTrue((page2?.obj?["content"]?.str ?? "").contains("wardrobes"))
        // The OLD term no longer matches this page (stale chunks were purged).
        let staleHits = try await WikiJSON.search(store, query: "penguins", k: 10)
        let staleIds = (staleHits.obj?["data"]?.arr ?? []).compactMap { $0.obj?["id"]?.int }
        XCTAssertFalse(staleIds.contains(newId!), "old chunks purged — no stale search hit")
    }

    /// CLAIM: wiki/page/delete removes the page AND its derived chunks/FTS rows,
    /// so a deleted page is no longer fetchable or searchable; deleting a missing
    /// id is idempotent ({deleted:false}, no throw). SEVERITY: severe — this is
    /// destructive and the index must stay consistent.
    func testDeletePurgesPageAndSearchIndex() async throws {
        let root = dir + "/bodies"
        let created = try await WikiJSON.upsert(store, bodyRoot: root, id: nil, title: "Doomed",
                                                body: "A page about quokkas and capybaras.")
        let id = created.obj?["id"]?.int
        XCTAssertNotNil(id)
        // Precondition: it's fetchable and searchable.
        let prePage = try await WikiJSON.pageGet(store, id: id!)
        XCTAssertNotNil(prePage)
        let preHits = try await WikiJSON.search(store, query: "quokkas", k: 10)
        XCTAssertTrue((preHits.obj?["data"]?.arr ?? []).compactMap { $0.obj?["id"]?.int }.contains(id!))

        // Delete it.
        let del = try await WikiJSON.delete(store, id: id!)
        XCTAssertEqual(del.obj?["deleted"]?.bool, true, "a present page reports deleted:true")
        XCTAssertEqual(del.obj?["id"]?.int, id!)

        // Postcondition: not fetchable, and the FTS index no longer surfaces it
        // (a raw delete that orphaned chunk_fts rows would still return a hit).
        let postPage = try await WikiJSON.pageGet(store, id: id!)
        XCTAssertNil(postPage, "deleted page is gone")
        let postHits = try await WikiJSON.search(store, query: "quokkas", k: 10)
        XCTAssertFalse((postHits.obj?["data"]?.arr ?? []).compactMap { $0.obj?["id"]?.int }.contains(id!),
                       "deleted page's chunks were purged from the search index")

        // Idempotent: deleting the now-gone id does not throw and reports false.
        let again = try await WikiJSON.delete(store, id: id!)
        XCTAssertEqual(again.obj?["deleted"]?.bool, false, "re-deleting a missing id is a no-op")
    }

    // MARK: - brief (enrich)

    /// CLAIM: wiki/brief produces a structured payload (object) from lexical
    /// evidence without throwing, even when evidence is thin. SEVERITY: strong.
    func testBriefReturnsStructuredPayload() async throws {
        let r = try await WikiJSON.brief(store, topic: "penguins machine learning", k: 8)
        // Must be a JSON object with at least a topic/summary/status field.
        XCTAssertNotNil(r.obj, "brief returns a JSON object, got \(r)")
        let keys = Set(r.obj?.keys ?? [:].keys)
        XCTAssertTrue(keys.contains("summary") || keys.contains("topic") || keys.contains("status"),
                      "payload carries brief fields; got keys \(keys)")
    }

    // MARK: - deny-default

    func testMakeDenyDefaultWithoutEnvFlag() {
        // No CODEXKIT_MEMORY=1 → the handle is nil regardless of config (wiki off).
        let cfg = Config(layers: [])
        XCTAssertNil(WikiQueryWiring.make(config: cfg, env: [:]),
                     "wiki handle must be nil unless CODEXKIT_MEMORY=1")
        XCTAssertNil(WikiQueryWiring.make(config: cfg, env: ["CODEXKIT_MEMORY": "0"]))
    }

    /// CLAIM: make() opens a store whose stamped embedding dimension differs from
    /// the configured default — the wiki READ path doesn't use vectors, so the
    /// candidate-dim fallback must still open it. (Reproduces the live failure: a
    /// 768-dim Nomic DB vs the 1536 OpenAI default.) SEVERITY: strong — without
    /// this the wiki silently disables itself on any real on-device DB.
    func testMakeOpensDespiteDimensionMismatch() async throws {
        let d = NSTemporaryDirectory() + "wikidim-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: d) }
        let dbPath = d + "/m.db"
        // Build a 768-dim store (NOT the 1536 default) and seed one page.
        let seed = try MemoryStore(MemoryStoreConfig(path: dbPath, embeddingDimension: 768))
        _ = try await seed.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "wiki://x", title: "X", bodyPath: d + "/b.md",
            fetchedAt: 1, contentSHA: Data([1]), rawBytes: 1))
        // fromConfig resolves embeddingDimension to the 1536 default (no override),
        // which MISMATCHES the 768 store — the fallback must still open it.
        let cfg = Config(layers: [ConfigLayer(
            name: "test", values: ["memory": .object(["db_path": .string(dbPath)])])])
        let handle = WikiQueryWiring.make(config: cfg, env: ["CODEXKIT_MEMORY": "1"])
        let h = try XCTUnwrap(handle, "wiki handle must open despite the default-dim mismatch")
        let listed = try await h.list(100)
        XCTAssertEqual(listed.obj?["data"]?.arr?.count, 1, "the seeded page is listable")
    }
}

// Minimal JSONValue accessors for assertions.
private extension JSONValue {
    var obj: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var arr: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var str: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int64? { if case .int(let i) = self { return i }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
}
