import XCTest
import Foundation
@testable import MemoryRetrieve
@testable import MemoryStore
@testable import MemoryInfer

final class RetrieveTests: XCTestCase {
    func testReciprocalRankFusionPrefersUniversalTopRanks() {
        // A appears top in both rankings → fused first.
        let fused = ReciprocalRankFusion.fuse([
            [10, 20, 30],
            [10, 30, 20],
        ])
        XCTAssertEqual(fused.first, 10)
    }

    func testHybridSearchReturnsRelevantChunk() async throws {
        let path = NSTemporaryDirectory() + "retr-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 32))
        let inference = MockInferenceProvider(embeddingDimension: 32)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "doc:retrieve",
            bodyPath: "rollout:r", fetchedAt: 0,
            contentSHA: Data(count: 32), rawBytes: 1))
        // Insert several chunks with deterministic mock embeddings, indexed
        // for the same text — the FTS hit and the vec hit point at the same row.
        let target = "the swift programming language"
        let emb = try await inference.embed([target], deadline: .fromNow(.seconds(1)))
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0, text: target, rawText: target,
                     tokenCount: 5, createdAt: 0),
            embeddingValues: emb[0].values)
        let other = "completely unrelated payload about cats"
        let oemb = try await inference.embed([other], deadline: .fromNow(.seconds(1)))
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 1, text: other, rawText: other,
                     tokenCount: 5, createdAt: 0),
            embeddingValues: oemb[0].values)

        let retriever = MemoryRetriever(store: store, inference: inference)
        let hits = try await retriever.search("swift programming", k: 5, rerank: true)
        XCTAssertFalse(hits.isEmpty)
        // The mock embedder is hash-based — we can't predict rerank ties — but
        // BM25 guarantees the matching chunk appears in the top fused window.
        let ids = hits.map(\.chunkId)
        XCTAssertTrue(ids.contains(1),
                      "expected the swift-programming chunk among top hits: \(ids)")
    }

    func testHybridSearchClampsHostileTopKForDirectCallers() async throws {
        let path = NSTemporaryDirectory() + "retr-hostile-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 32))
        let inference = MockInferenceProvider(embeddingDimension: 32)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "doc:hostile",
            bodyPath: "rollout:h", fetchedAt: 0,
            contentSHA: Data(count: 32), rawBytes: 1))
        let text = "agent memory retrieval should not crash on hostile limits"
        let emb = try await inference.embed([text], deadline: .fromNow(.seconds(1)))
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0, text: text, rawText: text,
                     tokenCount: text.split(separator: " ").count, createdAt: 0),
            embeddingValues: emb[0].values)

        let retriever = MemoryRetriever(store: store, inference: inference)
        let negative = try await retriever.search("agent memory", k: -1, rerank: false)
        XCTAssertFalse(negative.isEmpty)
        let huge = try await retriever.search("agent memory", k: Int.max, rerank: false)
        XCTAssertFalse(huge.isEmpty)
    }
}
