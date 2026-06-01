import XCTest
@testable import MemoryExtension
@testable import MemoryRetrieve
@testable import HarnessCore

/// Phase 1 impl #1 (Wiki) adapter tests. `WikiMemoryProvider`'s only logic is
/// the `RetrievedHit → MemorySnippet` mapping (recall otherwise delegates to the
/// already-tested `MemoryRetriever`), so that mapping is what we lock down.
final class WikiMemoryProviderTests: XCTestCase {

    func testSnippetMappingFromRetrievedHits() {
        let hits = [
            RetrievedHit(chunkId: 1, documentId: 10, documentURI: "wiki://doc/10",
                         snippet: "alpha fact", score: 0.91,
                         why: .init(bm25: 1, vec: 0.8, rerank: 0.9)),
            RetrievedHit(chunkId: 2, documentId: 11, documentURI: "wiki://doc/11",
                         snippet: "beta fact", score: 0.42, why: .init()),
        ]
        let snippets = WikiMemoryProvider.snippets(from: hits)
        XCTAssertEqual(snippets.count, 2)
        XCTAssertEqual(snippets[0].text, "alpha fact")
        XCTAssertEqual(snippets[0].score, 0.91, accuracy: 1e-9)
        XCTAssertEqual(snippets[0].citation, "wiki://doc/10")
        XCTAssertEqual(snippets[1].text, "beta fact")
        XCTAssertEqual(snippets[1].citation, "wiki://doc/11")
    }

    func testEmptyHitsMapToEmpty() {
        XCTAssertTrue(WikiMemoryProvider.snippets(from: []).isEmpty)
    }

    func testProviderIdentity() {
        // The wiki provider's id must match its slot-selection key.
        let dummy = RetrievedHit(chunkId: 0, documentId: 0, documentURI: "x",
                                 snippet: "s", score: 0, why: .init())
        XCTAssertEqual(WikiMemoryProvider.snippets(from: [dummy]).first?.text, "s")
    }
}
