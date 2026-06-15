import XCTest
@testable import MemoryStore

/// Severe coverage for the M8 curation CRUD (Inventory / Datasets / Collect) against a
/// real MemoryStore. Properties: round-trip fidelity, upsert-by-natural-key (slug /
/// dataset_id) updates in place, list filters + archived exclusion, dataset note
/// round-trip, and collect-item idempotent dedupe (by sha256, then canonical_url)
/// even though SQLite treats NULLs as distinct in the unique index.
final class CurationStoreTests: XCTestCase {
    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "curation-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private let now: Int64 = 1_000_000_000

    func testInventoryRoundTripUpsertAndFilters() async throws {
        let store = try makeStore()
        let id1 = try await store.upsertInventoryRecord(InventoryRecordRow(
            slug: "rag", kind: "item", status: "active", priority: "p1", title: "RAG",
            summary: "retrieval-augmented generation", tags: "ml,rag", createdAt: now, updatedAt: now))
        XCTAssertGreaterThan(id1, 0)
        // upsert by slug updates in place (same id), not a duplicate.
        let id2 = try await store.upsertInventoryRecord(InventoryRecordRow(
            slug: "rag", kind: "item", status: "blocked", priority: "p0", title: "RAG (revised)",
            createdAt: now, updatedAt: now + 10))
        XCTAssertEqual(id1, id2, "upsert by slug updates the same row")
        let got = try await store.inventoryRecord(slug: "rag")
        XCTAssertEqual(got?.title, "RAG (revised)")
        XCTAssertEqual(got?.status, "blocked")
        XCTAssertEqual(got?.priority, "p0")

        _ = try await store.upsertInventoryRecord(InventoryRecordRow(
            slug: "q1", kind: "question", status: "proposed", priority: "p2", title: "open Q",
            createdAt: now, updatedAt: now))
        _ = try await store.upsertInventoryRecord(InventoryRecordRow(
            slug: "old", kind: "item", status: "archived", priority: "p4", title: "archived item",
            createdAt: now, updatedAt: now, lifecycleStatus: "archived"))

        let items = try await store.inventoryRecords(kind: "item")
        XCTAssertEqual(Set(items.map(\.slug)), ["rag"], "kind filter + active-only excludes the archived item + the question")
        let questions = try await store.inventoryRecords(kind: "question")
        XCTAssertEqual(questions.map(\.slug), ["q1"])
        let all = try await store.inventoryRecords()
        XCTAssertEqual(Set(all.map(\.slug)), ["rag", "q1"], "archived excluded by default")
        let withArchived = try await store.inventoryRecords(includeArchived: true)
        XCTAssertTrue(withArchived.contains { $0.slug == "old" }, "includeArchived surfaces it")
    }

    func testInventoryViewRoundTrip() async throws {
        let store = try makeStore()
        _ = try await store.upsertInventoryView(InventoryViewRow(
            slug: "p0-items", title: "P0 items", filters: #"{"kind":"item","priority":"p0"}"#, updatedAt: now))
        let views = try await store.inventoryViews()
        XCTAssertEqual(views.count, 1)
        XCTAssertEqual(views.first?.title, "P0 items")
        XCTAssertTrue(views.first?.filters?.contains("\"p0\"") ?? false)
    }

    func testDatasetManifestAndNotes() async throws {
        let store = try makeStore()
        let mid = try await store.upsertDatasetManifest(DatasetManifestRow(
            datasetID: "imagenet", title: "ImageNet", status: "external", storage: "remote",
            recordCount: 1_281_167, createdAt: now, updatedAt: now))
        XCTAssertGreaterThan(mid, 0)
        // upsert by dataset_id updates in place.
        let mid2 = try await store.upsertDatasetManifest(DatasetManifestRow(
            datasetID: "imagenet", title: "ImageNet (v2)", status: "active", storage: "hybrid",
            createdAt: now, updatedAt: now + 5))
        XCTAssertEqual(mid, mid2)
        let updated = try await store.datasetManifest(datasetID: "imagenet")
        XCTAssertEqual(updated?.title, "ImageNet (v2)")

        _ = try await store.addDatasetNote(DatasetNoteRow(manifestID: mid, noteKind: "sample",
                                                          title: "first 20 rows", bodyMd: "| a | b |", createdAt: now))
        _ = try await store.addDatasetNote(DatasetNoteRow(manifestID: mid, noteKind: "profile",
                                                          title: "column stats", bodyMd: "...", createdAt: now + 1))
        let notes = try await store.datasetNotes(manifestID: mid)
        XCTAssertEqual(notes.map(\.noteKind), ["sample", "profile"], "notes returned in creation order")

        let manifests = try await store.datasetManifests(status: "active")
        XCTAssertEqual(manifests.map(\.datasetID), ["imagenet"])
    }

    func testCollectItemDedupeBySHAThenURL() async throws {
        let store = try makeStore()
        func item(_ row: Int64, sha: String? = nil, url: String? = nil, title: String = "x") -> CollectItemRow {
            CollectItemRow(catalogSlug: "memes", rowNumber: row, title: title, canonicalURL: url, sha256: sha, createdAt: now)
        }
        // distinct content → distinct rows.
        let a = try await store.upsertCollectItem(item(1, sha: "aaa", url: "https://ex.com/a"))
        let b = try await store.upsertCollectItem(item(2, sha: "bbb", url: "https://ex.com/b"))
        XCTAssertNotEqual(a, b)
        // same sha (even with a different URL) → dedup to the first.
        let a2 = try await store.upsertCollectItem(item(3, sha: "aaa", url: "https://ex.com/MIRROR"))
        XCTAssertEqual(a, a2, "dedupe by content sha256 within the catalog")
        // no sha but same canonical_url → dedup by URL.
        let b2 = try await store.upsertCollectItem(item(4, url: "https://ex.com/b"))
        XCTAssertEqual(b, b2, "dedupe by canonical_url when sha absent")
        // a different catalog with the same sha is INDEPENDENT.
        let other = try await store.upsertCollectItem(
            CollectItemRow(catalogSlug: "tools", rowNumber: 1, title: "t", sha256: "aaa", createdAt: now))
        XCTAssertNotEqual(a, other, "dedupe is scoped per catalog")

        let memes = try await store.collectItems(catalogSlug: "memes")
        XCTAssertEqual(memes.count, 2, "only the two distinct items survive in 'memes'")
        let catalogs = try await store.collectCatalogs()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: catalogs.map { ($0.slug, $0.count) }), ["memes": 2, "tools": 1])
    }

    func testCollectItemEmptyStringKeysDoNotThrow() async throws {
        let store = try makeStore()
        // empty-string sha + url must be treated as ABSENT (normalized to NULL), not bound
        // as distinct-but-equal "" values that trip the UNIQUE index.
        let a = try await store.upsertCollectItem(CollectItemRow(
            catalogSlug: "c", rowNumber: 1, title: "one", canonicalURL: "", sha256: "", createdAt: now))
        let b = try await store.upsertCollectItem(CollectItemRow(
            catalogSlug: "c", rowNumber: 2, title: "two", canonicalURL: "", sha256: "", createdAt: now))
        XCTAssertNotEqual(a, b, "empty-string keys → keyless → appended, no UNIQUE throw")
        let items = try await store.collectItems(catalogSlug: "c")
        XCTAssertEqual(items.count, 2)
    }

    func testCollectItemKeylessAppendsAndSourceURLDedup() async throws {
        let store = try makeStore()
        // keyless items have no identity → each call appends (documented contract).
        let k1 = try await store.upsertCollectItem(CollectItemRow(catalogSlug: "k", rowNumber: 1, title: "x", createdAt: now))
        let k2 = try await store.upsertCollectItem(CollectItemRow(catalogSlug: "k", rowNumber: 2, title: "x", createdAt: now))
        XCTAssertNotEqual(k1, k2, "keyless → appended, not deduped")
        // source_url is the third-priority dedupe key (when sha + canonical absent).
        let s1 = try await store.upsertCollectItem(CollectItemRow(
            catalogSlug: "k", rowNumber: 3, title: "s", sourceURL: "https://ex.com/s", createdAt: now))
        let s2 = try await store.upsertCollectItem(CollectItemRow(
            catalogSlug: "k", rowNumber: 4, title: "s-again", sourceURL: "https://ex.com/s", createdAt: now))
        XCTAssertEqual(s1, s2, "dedupe by source_url when sha + canonical absent")
    }

    func testUpsertPreservesCreatedAtRefreshesUpdatedAt() async throws {
        let store = try makeStore()
        _ = try await store.upsertInventoryRecord(InventoryRecordRow(
            slug: "x", kind: "item", status: "active", priority: "p1", title: "v1", createdAt: now, updatedAt: now))
        _ = try await store.upsertInventoryRecord(InventoryRecordRow(
            slug: "x", kind: "item", status: "active", priority: "p1", title: "v2",
            createdAt: now + 999, updatedAt: now + 50))   // a re-upsert tries a new created_at
        let got = try await store.inventoryRecord(slug: "x")
        XCTAssertEqual(got?.createdAt, now, "created_at is preserved across upsert (not clobbered)")
        XCTAssertEqual(got?.updatedAt, now + 50, "updated_at is refreshed")
        XCTAssertEqual(got?.title, "v2")
    }

    func testInventoryListIsPriorityOrdered() async throws {
        let store = try makeStore()
        for (slug, prio) in [("c", "p3"), ("a", "p0"), ("b", "p1")] {
            _ = try await store.upsertInventoryRecord(InventoryRecordRow(
                slug: slug, kind: "item", status: "active", priority: prio, title: slug, createdAt: now, updatedAt: now))
        }
        let items = try await store.inventoryRecords()
        XCTAssertEqual(items.map(\.priority), ["p0", "p1", "p3"], "ordered by priority ascending")
    }

    func testCollectItemFullFieldRoundTrip() async throws {
        let store = try makeStore()
        let id = try await store.upsertCollectItem(CollectItemRow(
            catalogSlug: "art", rowNumber: 1, title: "Mona Lisa", aliases: "La Gioconda", collectKind: "artwork",
            canonicalURL: "https://ex.com/ml", creator: "da Vinci",
            foundInContext: #"[{"url":"https://ex.com/blog"}]"#, provenanceConfidence: "high",
            mediaFormat: "image/jpeg", localMediaPath: "output/assets/collect-art/ml.jpg", mediaBytes: 12345,
            sha256: "deadbeef", downloadStatus: "downloaded", downloadedAt: now, createdAt: now))
        let items = try await store.collectItems(catalogSlug: "art")
        let got = try XCTUnwrap(items.first)
        XCTAssertEqual(got.id, id)
        XCTAssertEqual(got.title, "Mona Lisa")
        XCTAssertEqual(got.creator, "da Vinci")
        XCTAssertEqual(got.mediaBytes, 12345)
        XCTAssertEqual(got.downloadStatus, "downloaded")
        XCTAssertEqual(got.foundInContext, #"[{"url":"https://ex.com/blog"}]"#)
    }
}
