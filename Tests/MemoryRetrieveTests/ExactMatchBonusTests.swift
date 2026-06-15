import XCTest
import Foundation
import InfraPrimitives
@testable import MemoryRetrieve
@testable import MemoryStore
@testable import MemoryInfer

/// Wave 2.18: the entity-intent exact-title bonus is now CONSUMED by the ranker
/// (it was populated per-intent but dropped at the base-score sum). Pure-predicate
/// guards + an end-to-end proof that an exact-title document outranks an equal-content
/// rival on an entity query, and that non-entity intents are unaffected.
final class ExactMatchBonusTests: XCTestCase {
    private typealias R = MemoryRetriever

    func testExactMatchKeysAndStrictPredicate() {
        XCTAssertTrue(R.titleExactlyMatches("Andrej Karpathy", keys: R.exactMatchKeys("Andrej Karpathy")))
        XCTAssertTrue(R.titleExactlyMatches("Hall of Light", keys: R.exactMatchKeys("\"Hall of Light\"")), "quoted span")
        XCTAssertTrue(R.titleExactlyMatches("sama", keys: R.exactMatchKeys("@sama")), "@handle")
        XCTAssertTrue(R.titleExactlyMatches("Andrej   Karpathy", keys: R.exactMatchKeys("andrej karpathy")), "whitespace-collapse + case")
        // STRICT: a substring/partial title must NOT match (the bonus is for exact lookups).
        XCTAssertFalse(R.titleExactlyMatches("Andrej Karpathy on RL", keys: R.exactMatchKeys("Andrej Karpathy")))
        XCTAssertFalse(R.titleExactlyMatches("", keys: R.exactMatchKeys("Andrej Karpathy")), "empty title never matches")
        XCTAssertTrue(R.exactMatchKeys("   ").isEmpty)
    }

    func testBonusGatedToEntityIntent() {
        XCTAssertEqual(QueryIntentClassifier.resolve("Andrej Karpathy").weights.exactMatchBonus, 0.15, accuracy: 1e-9,
                       "entity intent carries the bonus")
        XCTAssertEqual(QueryIntentClassifier.resolve("latest updates on RL").weights.exactMatchBonus, 0.0,
                       "temporal/general carry NO bonus → other intents are byte-for-byte unchanged")
    }

    private struct FixedProvider: LocalInferenceProvider {
        var embeddingDimension: Int { 16 }
        func extract(_ batch: ChunkBatch, schema: ExtractionSchema, deadline: Deadline) async throws -> ExtractionResult {
            ExtractionResult(perChunk: [], tokensInput: 0, tokensOutput: 0)
        }
        func contextualize(_ chunk: Chunk, in document: DocumentDigest, deadline: Deadline) async throws -> String { "" }
        func embed(_ texts: [String], deadline: Deadline) async throws -> [MemoryInfer.Embedding] {
            texts.map { _ in var v = [Float](repeating: 0, count: 16); v[0] = 1.0; return MemoryInfer.Embedding(v) }
        }
        func rerank(_ query: String, candidates: [String], deadline: Deadline) async throws -> [Float] {
            [Float](repeating: 0, count: candidates.count)
        }
        func logprob(_ text: String, given: String?, deadline: Deadline) async throws -> Double { 1.0 }
    }

    /// Two documents with IDENTICAL chunk content (→ equal bm25/vec/rerank) differing
    /// ONLY in title. On an entity query equal to docA's title, docA must rank first —
    /// it is the +0.15 exact-title bonus that breaks the tie. Before the fix the bonus
    /// was dropped and the order was undetermined.
    func testExactTitleRanksFirstForEntityQuery() async throws {
        let path = NSTemporaryDirectory() + "emb-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 16))
        let text = "andrej karpathy works on neural networks"
        func add(title: String) async throws -> Int64 {
            let id = try await store.upsertDocument(DocumentRow(
                source: .manual, sourceURI: "memo:\(title)", title: title,
                bodyPath: "rollout:\(title)", fetchedAt: 0, contentSHA: Data(count: 32), rawBytes: 1))
            var v = [Float](repeating: 0, count: 16); v[0] = 1.0
            _ = try await store.insertChunk(
                ChunkRow(documentId: id, idx: 0, text: text, rawText: text, tokenCount: 6, createdAt: 0),
                embeddingValues: v)
            return id
        }
        let docA = try await add(title: "Andrej Karpathy")   // exact title match
        _        = try await add(title: "Yann LeCun")         // equal content, different title
        let retriever = MemoryRetriever(store: store, inference: FixedProvider())

        let hits = try await retriever.search("Andrej Karpathy", k: 5)   // capitalized → entity intent
        XCTAssertGreaterThanOrEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.documentId, docA, "the exact-title doc wins on the entity exact-match bonus")
        // The winner's score exceeds the runner-up by ~the bonus (content is otherwise equal).
        if hits.count >= 2 {
            XCTAssertGreaterThan(hits[0].score - hits[1].score, 0.1, "the +0.15 bonus separates them")
        }
    }
}
