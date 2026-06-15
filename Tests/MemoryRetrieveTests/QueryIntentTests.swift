import XCTest
@testable import MemoryRetrieve

/// Severe coverage for the zero-LLM query-intent classifier (gbrain.md Wave 2.16).
/// The load-bearing invariant: `.general` weights MUST equal the historical
/// 0.7/0.2/0.1 blend so an ordinary query never regresses.
final class QueryIntentTests: XCTestCase {

    func testGeneralWeightsMatchHistoricalBlend() {
        let w = QueryIntentClassifier.weights(for: .general)
        XCTAssertEqual(w.rerank, 0.7, accuracy: 1e-9)
        XCTAssertEqual(w.vec, 0.2, accuracy: 1e-9)
        XCTAssertEqual(w.bm25, 0.1, accuracy: 1e-9)
        XCTAssertEqual(w.exactMatchBonus, 0.0, accuracy: 1e-9)
        XCTAssertFalse(w.recencyOn)
    }

    func testTemporalClassification() {
        for q in ["latest llama paper", "what happened recently", "AI news in 2026",
                  "the newest models", "as of this month", "trends last year"] {
            XCTAssertEqual(QueryIntentClassifier.classify(q), .temporal, "\(q) should be temporal")
        }
        XCTAssertTrue(QueryIntentClassifier.weights(for: .temporal).recencyOn)
    }

    func testEventClassification() {
        for q in ["openai launched a model", "acme announced funding",
                  "what did they release", "startup raised a series a", "the IPO"] {
            XCTAssertEqual(QueryIntentClassifier.classify(q), .event, "\(q) should be event")
        }
    }

    func testEntityClassification() {
        XCTAssertEqual(QueryIntentClassifier.classify("Andrej Karpathy"), .entity)
        XCTAssertEqual(QueryIntentClassifier.classify("\"Hall of Light\""), .entity)
        XCTAssertEqual(QueryIntentClassifier.classify("@sama"), .entity)
        XCTAssertEqual(QueryIntentClassifier.classify("Mingtang"), .entity, "single capitalized token")
        let w = QueryIntentClassifier.weights(for: .entity)
        XCTAssertGreaterThan(w.bm25, QueryIntentClassifier.weights(for: .general).bm25,
                             "entity intent must boost keyword weight")
        XCTAssertGreaterThan(w.exactMatchBonus, 0)
    }

    func testGeneralFallback() {
        for q in ["how does retrieval work", "explain embeddings", "what is rrf"] {
            XCTAssertEqual(QueryIntentClassifier.classify(q), .general, "\(q) should be general")
        }
    }

    func testPrecedenceTemporalBeatsEntity() {
        // "latest Karpathy paper" is both temporal and entity → temporal wins.
        XCTAssertEqual(QueryIntentClassifier.classify("latest Karpathy paper"), .temporal)
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(QueryIntentClassifier.classify(""), .general)
        XCTAssertEqual(QueryIntentClassifier.classify("   "), .general)
    }

    func testWeightsAreNormalizedBlends() {
        // Each intent's rerank+vec+bm25 should sum to 1.0 (a proper convex blend).
        for intent in [QueryIntent.general, .entity, .temporal, .event] {
            let w = QueryIntentClassifier.weights(for: intent)
            XCTAssertEqual(w.rerank + w.vec + w.bm25, 1.0, accuracy: 1e-9,
                           "\(intent) weights must sum to 1.0")
        }
    }
}
