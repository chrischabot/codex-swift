import XCTest
import Foundation
@testable import WikiQueryKit
import MemoryStore
import WireProtocol
import Config
import ModelClient

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

    /// CLAIM: wiki/entityBacklinks returns the PAGES that mention an entity
    /// (reverse of the chunk→entity mention index), one row per page with a
    /// snippet; an entity nothing mentions returns empty. SEVERITY: normal —
    /// read-only discovery surface.
    func testEntityBacklinksReturnsMentioningPages() async throws {
        // tagAI is mentioned by chunk c1, which belongs to doc1 "Alpha".
        let r = try await WikiJSON.entityBacklinks(store, entityId: tagAI)
        let pages = r.obj?["data"]?.arr ?? []
        let ids = pages.compactMap { $0.obj?["id"]?.int }
        XCTAssertTrue(ids.contains(doc1), "the page whose chunk mentions the entity is returned")
        let alpha = pages.first { $0.obj?["id"]?.int == doc1 }
        XCTAssertEqual(alpha?.obj?["title"]?.str, "Alpha")
        XCTAssertTrue((alpha?.obj?["excerpt"]?.str ?? "").contains("machine learning"))
        // An entity nothing mentions → empty.
        let none = try await WikiJSON.entityBacklinks(store, entityId: 9_999_999)
        XCTAssertEqual(none.obj?["data"]?.arr?.count, 0)
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

    /// CLAIM: wiki/index extracts a page's outgoing [[wikilinks]] + frontmatter
    /// props, the mtime cache returns identical data on a re-call, and a page
    /// edit (new body file → new mtime) is reflected. SEVERITY: severe — the
    /// cache must never serve stale data nor change the RPC payload.
    func testIndexCachesAndReflectsEdits() async throws {
        let root = dir + "/bodies"
        let cache = WikiIndexCache()
        let created = try await WikiJSON.upsert(
            store, bodyRoot: root, id: nil, title: "Linker",
            body: "---\nstatus: draft\n---\nSee [[Target]] for details.")
        let id = created.obj?["id"]?.int
        XCTAssertNotNil(id)

        // First index: the page appears with its link + prop.
        let r1 = try await WikiJSON.index(store, cache: cache)
        let entries1 = r1.obj?["data"]?.arr ?? []
        let e1 = entries1.first { $0.obj?["id"]?.int == id }
        XCTAssertNotNil(e1, "the linking page is in the index")
        XCTAssertEqual(e1?.obj?["links"]?.arr?.compactMap { $0.str }, ["Target"])
        XCTAssertEqual(e1?.obj?["props"]?.obj?["status"]?.str, "draft")

        // Second call (cache hit) returns the same number of entries.
        let r2 = try await WikiJSON.index(store, cache: cache)
        XCTAssertEqual(r2.obj?["data"]?.arr?.count, entries1.count, "cache hit is output-equivalent")

        // Editing the page (new body → new body file → new mtime) is reflected.
        _ = try await WikiJSON.upsert(
            store, bodyRoot: root, id: id, title: "Linker",
            body: "---\nstatus: done\n---\nNow links to [[Other]].")
        let r3 = try await WikiJSON.index(store, cache: cache)
        let e3 = (r3.obj?["data"]?.arr ?? []).first { $0.obj?["id"]?.int == id }
        XCTAssertEqual(e3?.obj?["links"]?.arr?.compactMap { $0.str }, ["Other"], "index reflects the edit")
        XCTAssertEqual(e3?.obj?["props"]?.obj?["status"]?.str, "done")
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

    /// CLAIM: wiki/page/rename updates ONLY the title (page stays fetchable with
    /// the new title; the body/content is unchanged), and is idempotent on a
    /// missing id ({renamed:false}, no throw). SEVERITY: strong.
    func testRenameUpdatesTitleOnly() async throws {
        let root = dir + "/bodies"
        let created = try await WikiJSON.upsert(store, bodyRoot: root, id: nil, title: "Old Name",
                                                body: "Body about axolotls stays put.")
        let id = created.obj?["id"]?.int
        XCTAssertNotNil(id)

        let renamed = try await WikiJSON.rename(store, id: id!, title: "New Name")
        XCTAssertEqual(renamed.obj?["renamed"]?.bool, true)
        XCTAssertEqual(renamed.obj?["id"]?.int, id!)

        // Title changed; body preserved.
        let page = try await WikiJSON.pageGet(store, id: id!)
        XCTAssertEqual(page?.obj?["title"]?.str, "New Name")
        XCTAssertTrue((page?.obj?["content"]?.str ?? "").contains("axolotls"))

        // Idempotent on a missing id.
        let missing = try await WikiJSON.rename(store, id: 999_999, title: "Nope")
        XCTAssertEqual(missing.obj?["renamed"]?.bool, false)

        // A blank title is rejected (renamed:false) and the title is unchanged.
        let blank = try await WikiJSON.rename(store, id: id!, title: "   ")
        XCTAssertEqual(blank.obj?["renamed"]?.bool, false)
        let still = try await WikiJSON.pageGet(store, id: id!)
        XCTAssertEqual(still?.obj?["title"]?.str, "New Name", "blank rename left the title intact")
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

    func testMakeDenyDefaultWithoutEnvFlag() async {
        // No CODEXKIT_MEMORY=1 → the handle is nil regardless of config (wiki off).
        let cfg = Config(layers: [])
        let mc = MockModelClient([])
        let h1 = await WikiQueryWiring.make(config: cfg, modelClient: mc, env: [:])
        XCTAssertNil(h1, "wiki handle must be nil unless CODEXKIT_MEMORY=1")
        let h2 = await WikiQueryWiring.make(config: cfg, modelClient: mc, env: ["CODEXKIT_MEMORY": "0"])
        XCTAssertNil(h2)
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
        let handle = await WikiQueryWiring.make(config: cfg, modelClient: MockModelClient([]),
                                                env: ["CODEXKIT_MEMORY": "1"])
        let h = try XCTUnwrap(handle, "wiki handle must open despite the default-dim mismatch")
        let listed = try await h.list(100)
        XCTAssertEqual(listed.obj?["data"]?.arr?.count, 1, "the seeded page is listable")
    }

    // MARK: - trust reports (librarian Tier-1 + audit Pass-2) — Tier-A read RPCs

    func testLibrarianReportShapesStalenessScan() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let day: Int64 = 86_400
        // fresh+deep (not flagged) and stale+thin (flagged) synthesis pages.
        _ = try await store.upsertSynthesis(SynthesisRow(
            slug: "fresh", category: "topic", title: "fresh", bodyPath: "inline:fresh",
            volatility: .cold, verifiedAt: now, createdAt: now, updatedAt: now))
        let staleID = try await store.upsertSynthesis(SynthesisRow(
            slug: "stale", category: "topic", title: "stale", bodyPath: "inline:stale",
            volatility: .warm, verifiedAt: now - 800 * day, createdAt: now - 800 * day, updatedAt: now - 800 * day))

        let r = try await WikiJSON.librarianReport(store, limit: 50)
        XCTAssertEqual(r.obj?["pages"]?.int, 2)
        XCTAssertGreaterThanOrEqual(r.obj?["flagged"]?.int ?? 0, 1, "the stale/thin page is flagged")
        let stalest = try XCTUnwrap(r.obj?["stalest"]?.arr)
        // stalest-first → the stale page leads.
        XCTAssertEqual(stalest.first?.obj?["documentID"]?.int, staleID)
        XCTAssertEqual(stalest.first?.obj?["needsTier2"]?.bool, true)
    }

    func testAuditReportShapesDriftScan() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        // A page generated at T, compiled from a claim updated at T+100 → drifted.
        let sid = try await store.upsertSynthesis(SynthesisRow(
            slug: "drifted", category: "synthesis", title: "drifted", bodyPath: "inline:drifted",
            createdAt: now, updatedAt: now, generatedAt: now))
        let cid = try await store.upsertClaim(ClaimRow(text: "a claim that later changed",
                                                       firstSeen: now, updatedAt: now + 100))
        try await store.linkSynthesisClaim(synthesis: sid, claim: cid)

        let r = try await WikiJSON.auditReport(store, limit: 50)
        XCTAssertEqual(r.obj?["pages"]?.int, 1)
        XCTAssertEqual(r.obj?["drifted"]?.int, 1, "the page whose claim changed after generation is drifted")
        let detail = try XCTUnwrap(r.obj?["pagesDetail"]?.arr)
        XCTAssertEqual(detail.first?.obj?["id"]?.int, sid)
        XCTAssertEqual(detail.first?.obj?["status"]?.str, "drifted")
    }

    func testTrustReportsEmptyStore() async throws {
        // setUp seeds documents but NO synthesis rows → both reports are well-formed + empty.
        let lib = try await WikiJSON.librarianReport(store, limit: 50)
        XCTAssertEqual(lib.obj?["pages"]?.int, 0)
        XCTAssertEqual(lib.obj?["stalest"]?.arr?.count, 0)
        let aud = try await WikiJSON.auditReport(store, limit: 50)
        XCTAssertEqual(aud.obj?["pages"]?.int, 0)
        XCTAssertEqual(aud.obj?["drifted"]?.int, 0)
    }

    // MARK: - curation reads (inventory / datasets / collect) — Tier-A read RPCs

    func testInventoryListShaper() async throws {
        _ = try await store.upsertInventoryRecord(InventoryRecordRow(
            slug: "rag", kind: "item", status: "active", priority: "p1", title: "RAG",
            summary: "retrieval", createdAt: 1, updatedAt: 1))
        let r = try await WikiJSON.inventoryList(store, limit: 50)
        XCTAssertEqual(r.obj?["count"]?.int, 1)
        let rec = r.obj?["records"]?.arr?.first
        XCTAssertEqual(rec?.obj?["slug"]?.str, "rag")
        XCTAssertEqual(rec?.obj?["priority"]?.str, "p1")
        XCTAssertEqual(rec?.obj?["summary"]?.str, "retrieval")
    }

    func testDatasetListShaper() async throws {
        _ = try await store.upsertDatasetManifest(DatasetManifestRow(
            datasetID: "d1", title: "D1", status: "active", storage: "local",
            sizeBytes: 99, recordCount: 3, createdAt: 1, updatedAt: 1))
        let r = try await WikiJSON.datasetList(store, limit: 50)
        XCTAssertEqual(r.obj?["count"]?.int, 1)
        let d = r.obj?["datasets"]?.arr?.first
        XCTAssertEqual(d?.obj?["datasetID"]?.str, "d1")
        XCTAssertEqual(d?.obj?["sizeBytes"]?.int, 99)
        XCTAssertEqual(d?.obj?["recordCount"]?.int, 3)
    }

    func testCollectListShaper() async throws {
        _ = try await store.upsertCollectItem(CollectItemRow(catalogSlug: "memes", rowNumber: 1, title: "a", canonicalURL: "https://e/1", createdAt: 1))
        _ = try await store.upsertCollectItem(CollectItemRow(catalogSlug: "memes", rowNumber: 2, title: "b", canonicalURL: "https://e/2", createdAt: 1))
        _ = try await store.upsertCollectItem(CollectItemRow(catalogSlug: "tools", rowNumber: 1, title: "c", canonicalURL: "https://e/3", createdAt: 1))
        let r = try await WikiJSON.collectList(store)
        XCTAssertEqual(r.obj?["count"]?.int, 2, "two catalogs")
        let byCat = Dictionary(uniqueKeysWithValues: (r.obj?["catalogs"]?.arr ?? []).map {
            ($0.obj?["slug"]?.str ?? "", $0.obj?["count"]?.int ?? 0)
        })
        XCTAssertEqual(byCat["memes"], 2); XCTAssertEqual(byCat["tools"], 1)
    }

    func testTier2VerdictsReadBackFromScanResults() throws {
        // The librarian CLI persists Tier-2 verdicts here; the report reads them back
        // (no model re-invocation → stays a Tier-A read).
        let libDir = dir + "/.librarian"
        try FileManager.default.createDirectory(atPath: libDir, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "tier2_scored": 2,
            "tier2": [
                ["documentID": 12, "coherence": 2, "utility": 3, "rationale": "thin"],
                ["documentID": 7, "coherence": 4, "utility": 5, "rationale": "solid"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: libDir + "/scan-results.json"))
        let (map, scored) = WikiJSON.tier2VerdictsByDocID(databasePath: dir + "/m.db")
        XCTAssertEqual(scored, 2)
        XCTAssertEqual(map[12]?.coherence, 2)
        XCTAssertEqual(map[12]?.utility, 3)
        XCTAssertEqual(map[7]?.rationale, "solid")
        XCTAssertNil(map[99], "unscored doc has no verdict")
    }

    func testTier2MissingArtifactYieldsEmpty() {
        let (map, scored) = WikiJSON.tier2VerdictsByDocID(databasePath: "/nonexistent/x.db")
        XCTAssertTrue(map.isEmpty)
        XCTAssertEqual(scored, 0, "a missing artifact → no verdicts (page stays Tier-1-flagged only)")
    }

    func testLibrarianReportExposesTier2ScoredCount() async throws {
        let r = try await WikiJSON.librarianReport(store)
        XCTAssertNotNil(r.obj?["tier2Scored"], "the report exposes the model-scored count distinctly from flagged")
    }

    func testStatusFlaggedCountFromCycleMarkersNotLiveScan() async throws {
        // No cycle has run → flaggedStale falls back to the live scan, source "live".
        let empty = try await WikiJSON.status(store)
        XCTAssertEqual(empty.obj?["flaggedSource"]?.str, "live")
        // The dream cycle commits two librarian_tier2 markers → status now reports THOSE
        // (what was durably decided), not a live recompute.
        try await store.setMetaValue("librarian_tier2:1", "1")
        try await store.setMetaValue("librarian_tier2:2", "1")
        let after = try await WikiJSON.status(store)
        XCTAssertEqual(after.obj?["flaggedSource"]?.str, "cycle")
        XCTAssertEqual(after.obj?["flaggedStale"]?.int, 2, "status reads the marker queue, not the scanner")
    }

    func testCurationReadsEmptyStore() async throws {
        let inv = try await WikiJSON.inventoryList(store)
        let ds = try await WikiJSON.datasetList(store)
        let col = try await WikiJSON.collectList(store)
        let ses = try await WikiJSON.sessionsList(store)
        XCTAssertEqual(inv.obj?["count"]?.int, 0)
        XCTAssertEqual(ds.obj?["count"]?.int, 0)
        XCTAssertEqual(col.obj?["count"]?.int, 0)
        XCTAssertEqual(ses.obj?["count"]?.int, 0)
        XCTAssertEqual(ses.obj?["sessions"]?.arr?.count, 0)
    }

    func testSessionsListShaper() async throws {
        try await store.upsertResearchSession(ResearchSessionRow(
            sessionID: "s1", mode: "standard", topic: "rope memory", startTime: 1_700_000_000,
            currentRound: 3, cumulativeSources: 12, cumulativeArticles: 4, status: "complete",
            lastProgressScore: 0.876_54))
        try await store.upsertResearchSession(ResearchSessionRow(
            sessionID: "s2", topic: "no-score session"))   // sparse: optional fields omitted
        let r = try await WikiJSON.sessionsList(store)
        XCTAssertEqual(r.obj?["count"]?.int, 2)
        let byID = Dictionary(uniqueKeysWithValues: (r.obj?["sessions"]?.arr ?? []).compactMap { v -> (String, JSONValue)? in
            guard let id = v.obj?["sessionID"]?.str else { return nil }
            return (id, v)
        })
        let s1 = byID["s1"]?.obj
        XCTAssertEqual(s1?["topic"]?.str, "rope memory")
        XCTAssertEqual(s1?["mode"]?.str, "standard")
        XCTAssertEqual(s1?["status"]?.str, "complete")
        XCTAssertEqual(s1?["rounds"]?.int, 3)
        XCTAssertEqual(s1?["sources"]?.int, 12)
        XCTAssertEqual(s1?["articles"]?.int, 4)
        XCTAssertEqual(s1?["score"]?.dbl, 0.88, "score rounded to 2dp")
        XCTAssertEqual(s1?["startedAt"]?.int, 1_700_000_000 * 1000, "epoch→ms")
        // Sparse session: only sessionID + topic present; no nulls leaked for absent fields.
        let s2 = byID["s2"]?.obj
        XCTAssertEqual(s2?["topic"]?.str, "no-score session")
        XCTAssertNil(s2?["score"], "absent score is omitted, not null")
        XCTAssertNil(s2?["rounds"], "absent rounds is omitted, not null")
        XCTAssertNil(s2?["startedAt"], "absent startTime is omitted, not null")
    }
}

// Minimal JSONValue accessors for assertions.
private extension JSONValue {
    var obj: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var arr: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var str: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int64? { if case .int(let i) = self { return i }; return nil }
    var dbl: Double? { if case .double(let d) = self { return d }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
}
