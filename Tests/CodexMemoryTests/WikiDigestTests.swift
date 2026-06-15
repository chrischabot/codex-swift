import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Coverage for the §14.6 digest generator: the pure render (window filter, category
/// grouping, deterministic UTC date) + the --file flow (synthesis row category=digest).
final class WikiDigestTests: XCTestCase {
    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "digest-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private let day: Int64 = 86_400

    private func page(_ slug: String, _ category: String, updatedAt: Int64) -> SynthesisRow {
        SynthesisRow(slug: slug, category: category, title: "Title \(slug)", bodyPath: "inline:\(slug)",
                     createdAt: updatedAt, updatedAt: updatedAt)
    }

    func testRenderWindowFilterAndGrouping() {
        let now: Int64 = 10 * day
        let pages = [
            page("a", "concept", updatedAt: now - 1 * day),       // in window
            page("b", "concept", updatedAt: now - 2 * day),       // in window
            page("c", "report", updatedAt: now - 6 * day),        // in window
            page("old", "concept", updatedAt: now - 30 * day),    // BEFORE window → excluded
            page("future", "concept", updatedAt: now + 1 * day),  // AFTER now → excluded
        ]
        let r = WikiDigest.render(pages: pages, since: now - 7 * day, now: now)
        XCTAssertEqual(r.pageCount, 3, "only the 3 in-window pages")
        XCTAssertTrue(r.markdown.contains("## concept (2)"))
        XCTAssertTrue(r.markdown.contains("## report (1)"))
        XCTAssertTrue(r.markdown.contains("[[a]]"))
        XCTAssertFalse(r.markdown.contains("[[old]]"), "out-of-window excluded")
        XCTAssertFalse(r.markdown.contains("[[future]]"))
        // newest-first within concept: a (now-1d) before b (now-2d)
        XCTAssertLessThan(r.markdown.range(of: "[[a]]")!.lowerBound, r.markdown.range(of: "[[b]]")!.lowerBound)
    }

    func testRenderEmptyWindow() {
        let r = WikiDigest.render(pages: [page("x", "concept", updatedAt: 100)], since: 1000, now: 2000)
        XCTAssertEqual(r.pageCount, 0)
        XCTAssertTrue(r.markdown.contains("0 page(s)"))
    }

    func testIsoDateIsDeterministicUTC() {
        // 1_700_000_000 = 2023-11-14 UTC
        XCTAssertEqual(WikiDigest.isoDate(1_700_000_000), "2023-11-14")
        XCTAssertEqual(WikiDigest.render(pages: [], since: 0, now: 1_700_000_000).slug, "digest-2023-11-14")
    }

    func testRunFilePersistsDigestSynthesis() async throws {
        let store = try makeStore()
        let now: Int64 = 1_700_000_000
        _ = try await store.upsertSynthesis(page("p1", "concept", updatedAt: now - day))
        _ = try await store.upsertSynthesis(page("p2", "report", updatedAt: now - 2 * day))
        // exercise render against the real store rows, then file via the store.
        let pages = try await store.syntheses(limit: 1000)
        let r = WikiDigest.render(pages: pages, since: now - 7 * day, now: now)
        XCTAssertEqual(r.pageCount, 2)
        let id = try await store.upsertSynthesis(SynthesisRow(
            slug: r.slug, category: "digest", title: "Digest", bodyPath: "inline:\(r.slug)",
            createdAt: now, updatedAt: now, generatedAt: now, outputType: "digest"))
        XCTAssertGreaterThan(id, 0)
        let filed = try await store.synthesis(slug: r.slug)
        XCTAssertEqual(filed?.category, "digest")
        XCTAssertEqual(filed?.outputType, "digest")
    }

    func testParseValidation() throws {
        let o = try CodexMemoryWikiDigest.parse(["--days", "3", "--file", "--json"])
        XCTAssertEqual(o.days, 3); XCTAssertTrue(o.file); XCTAssertTrue(o.json)
        XCTAssertThrowsError(try CodexMemoryWikiDigest.parse(["--days", "0"]))
        XCTAssertThrowsError(try CodexMemoryWikiDigest.parse(["--since", "-5"]))
        XCTAssertThrowsError(try CodexMemoryWikiDigest.parse(["--bogus"]))
    }
}
