import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore
import MemoryIngest    // Normaliser.contentSHA — match how ingest computed the stored SHA

/// Severe coverage for Refresh (§5.C/§5.D). Properties:
/// 1. Due-selection: only sources past one volatility half-life (or never-verified) refresh.
/// 2. Unchanged (SHA matches) → verified_at bumped to now.
/// 3. Changed (SHA differs) → verified_at NOT bumped (page is now out of date).
/// 4. Unreachable (fetch nil / non-http) → verified_at NOT bumped; fetcher behavior correct.
/// 5. --limit caps the pass.
/// All hermetic — a mock fetcher returns canned markdown; the stored SHA is computed
/// the same way ingest does (Normaliser.contentSHA), so change-detection is meaningful.
final class WikiRefreshTests: XCTestCase {

    private final class MockFetcher: RefreshFetcher, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var fetched: [String] = []
        let byURL: [String: String]   // url → markdown (absent → fetch fails)
        init(_ byURL: [String: String]) { self.byURL = byURL }
        func fetchMarkdown(_ url: URL) async -> String? {
            lock.withLock { fetched.append(url.absoluteString) }
            return byURL[url.absoluteString]
        }
    }

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "refresh-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }

    private let now: Int64 = 1_000_000_000
    private let day: Int64 = 86_400

    /// Insert a document + source_meta whose stored content SHA == Normaliser.contentSHA(markdown).
    @discardableResult
    private func source(_ store: MemoryStore, uri: String, markdown: String,
                        volatility: Volatility, verifiedAt: Int64?, canonicalURL: String? = nil,
                        kind: String = "articles") async throws -> Int64 {
        let sha = Normaliser.contentSHA(markdown)
        let docID = try await store.upsertDocument(DocumentRow(
            source: .web, sourceURI: uri, bodyPath: "inline:\(uri)", fetchedAt: now,
            contentSHA: sha, rawBytes: Int64(markdown.utf8.count)))
        try await store.upsertSourceMeta(SourceMetaRow(
            documentID: docID, sourceKind: kind, volatility: volatility,
            verifiedAt: verifiedAt, ingestedAt: now, canonicalURL: canonicalURL ?? uri))
        return docID
    }

    func testDueSelectionByStaleness() async throws {
        let store = try makeStore()
        let fresh = try await source(store, uri: "https://ex.com/fresh", markdown: "fresh body",
                                     volatility: .hot, verifiedAt: now)                    // freshness 1 → not due
        let stale = try await source(store, uri: "https://ex.com/stale", markdown: "stale body",
                                     volatility: .hot, verifiedAt: now - 100 * day)         // ~0.1 → due
        let never = try await source(store, uri: "https://ex.com/never", markdown: "never body",
                                     volatility: .warm, verifiedAt: nil)                    // never verified → due
        let fetcher = MockFetcher([
            "https://ex.com/fresh": "fresh body", "https://ex.com/stale": "stale body",
            "https://ex.com/never": "never body"])
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 50)
        let ids = Set(results.map(\.documentID))
        XCTAssertEqual(ids, [stale, never], "only stale + never-verified sources are due")
        XCTAssertFalse(ids.contains(fresh), "a freshly-verified source is not re-fetched")
        XCTAssertFalse(fetcher.fetched.contains("https://ex.com/fresh"))
    }

    func testUnchangedBumpsVerifiedAt() async throws {
        let store = try makeStore()
        let id = try await source(store, uri: "https://ex.com/a", markdown: "unchanged body",
                                  volatility: .hot, verifiedAt: now - 100 * day)
        let fetcher = MockFetcher(["https://ex.com/a": "unchanged body"])   // identical → SHA matches
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 50)
        XCTAssertEqual(results.first?.outcome, .unchanged)
        let meta = try await store.sourceMeta(documentID: id)
        XCTAssertEqual(meta?.verifiedAt, now, "an unchanged source is re-verified at now")
    }

    func testChangedDoesNotBumpVerifiedAt() async throws {
        let store = try makeStore()
        let old = now - 100 * day
        let id = try await source(store, uri: "https://ex.com/a", markdown: "original body",
                                  volatility: .hot, verifiedAt: old)
        let fetcher = MockFetcher(["https://ex.com/a": "DIFFERENT body now"])   // SHA differs
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 50)
        XCTAssertEqual(results.first?.outcome, .changed)
        let meta = try await store.sourceMeta(documentID: id)
        XCTAssertEqual(meta?.verifiedAt, old, "a CHANGED source is NOT re-verified (it's now out of date)")
    }

    func testUnreachableDoesNotBump() async throws {
        let store = try makeStore()
        let old = now - 100 * day
        let id = try await source(store, uri: "https://ex.com/a", markdown: "body",
                                  volatility: .hot, verifiedAt: old)
        let fetcher = MockFetcher([:])   // URL present, fetch returns nil
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 50)
        XCTAssertEqual(results.first?.outcome, .unreachable)
        let meta = try await store.sourceMeta(documentID: id)
        XCTAssertEqual(meta?.verifiedAt, old, "an unreachable source is not re-verified")
        XCTAssertEqual(fetcher.fetched, ["https://ex.com/a"], "the fetch was attempted")
    }

    func testNonHttpURLIsUnreachableWithoutFetch() async throws {
        let store = try makeStore()
        _ = try await source(store, uri: "ftp://ex.com/a", markdown: "body",
                             volatility: .hot, verifiedAt: now - 100 * day, canonicalURL: "ftp://ex.com/a")
        let fetcher = MockFetcher([:])
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 50)
        XCTAssertEqual(results.first?.outcome, .unreachable)
        XCTAssertTrue(fetcher.fetched.isEmpty, "a non-http(s) URL is never fetched")
    }

    func testLimitCaps() async throws {
        let store = try makeStore()
        for i in 0..<3 {
            _ = try await source(store, uri: "https://ex.com/\(i)", markdown: "body \(i)",
                                 volatility: .hot, verifiedAt: now - 100 * day)
        }
        let fetcher = MockFetcher([
            "https://ex.com/0": "body 0", "https://ex.com/1": "body 1", "https://ex.com/2": "body 2"])
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 1)
        XCTAssertEqual(results.count, 1, "--limit caps the number of sources refreshed")
    }

    func testNonArticleKindsExcluded() async throws {
        let store = try makeStore()
        let art = try await source(store, uri: "https://ex.com/art", markdown: "a",
                                   volatility: .hot, verifiedAt: now - 100 * day, kind: "articles")
        _ = try await source(store, uri: "https://ex.com/pdf", markdown: "p",
                             volatility: .hot, verifiedAt: now - 100 * day, kind: "papers")   // PDF/arXiv
        _ = try await source(store, uri: "https://ex.com/repo", markdown: "r",
                             volatility: .hot, verifiedAt: now - 100 * day, kind: "repos")     // GitHub
        let fetcher = MockFetcher(["https://ex.com/art": "a", "https://ex.com/pdf": "p", "https://ex.com/repo": "r"])
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 50)
        XCTAssertEqual(results.map(\.documentID), [art], "only readability-comparable 'articles' refresh")
        XCTAssertEqual(fetcher.fetched, ["https://ex.com/art"], "non-article kinds are never re-fetched (would always false-'changed')")
    }

    func testMostStaleFirstUnderLimit() async throws {
        let store = try makeStore()
        _ = try await source(store, uri: "https://ex.com/less", markdown: "l",
                             volatility: .hot, verifiedAt: now - 60 * day)    // freshness ~0.25
        let staler = try await source(store, uri: "https://ex.com/more", markdown: "m",
                                      volatility: .hot, verifiedAt: now - 120 * day)  // freshness ~0.06
        let fetcher = MockFetcher(["https://ex.com/less": "l", "https://ex.com/more": "m"])
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 1)
        XCTAssertEqual(results.map(\.documentID), [staler], "limit keeps the MOST stale, not the lowest id")
    }

    func testColdSourceNotDueAtModerateAge() async throws {
        let store = try makeStore()
        // 100 days on a 365-day half-life → freshness ~0.83 > 0.5 → NOT stale.
        _ = try await source(store, uri: "https://ex.com/cold", markdown: "c",
                             volatility: .cold, verifiedAt: now - 100 * day)
        let fetcher = MockFetcher(["https://ex.com/cold": "c"])
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 50)
        XCTAssertTrue(results.isEmpty, "a cold source 100d old is still fresh (half-life 365d)")
    }

    func testFetchesCanonicalNotRevisionURI() async throws {
        let store = try makeStore()
        // source_uri carries a #rev= fragment; canonical is clean. Refresh must fetch canonical.
        let id = try await source(store, uri: "https://ex.com/page#rev=abc123", markdown: "stable",
                                  volatility: .hot, verifiedAt: now - 100 * day,
                                  canonicalURL: "https://ex.com/page")
        let fetcher = MockFetcher(["https://ex.com/page": "stable"])
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 50)
        XCTAssertEqual(fetcher.fetched, ["https://ex.com/page"], "fetches the clean canonical URL")
        XCTAssertEqual(results.first?.outcome, .unchanged)
        let meta = try await store.sourceMeta(documentID: id)
        XCTAssertEqual(meta?.verifiedAt, now)
    }

    func testEmptyStoreYieldsNoResults() async throws {
        let store = try makeStore()
        let fetcher = MockFetcher([:])
        let results = await WikiRefresh.run(store: store, fetcher: fetcher, now: now, limit: 50)
        XCTAssertTrue(results.isEmpty)
    }
}
