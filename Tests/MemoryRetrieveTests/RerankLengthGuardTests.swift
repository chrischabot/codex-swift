import XCTest
import Foundation
import InfraPrimitives
@testable import MemoryRetrieve
@testable import MemoryStore
@testable import MemoryInfer

/// Regression: a reranker that returns FEWER scores than candidates must not crash
/// the retriever with an index-out-of-range (it used to: `rerankScores[i]` was
/// indexed up to `hydrated.count` while the provider's short result was adopted
/// wholesale). Found live via `wiki-query` against a real 4983-doc store.
final class RerankLengthGuardTests: XCTestCase {

    /// A provider whose rerank deliberately returns a too-short array.
    actor ShortRerankProvider: LocalInferenceProvider {
        nonisolated let embeddingDimension: Int = 16
        func extract(_ batch: ChunkBatch, schema: ExtractionSchema, deadline: Deadline) async throws -> ExtractionResult {
            ExtractionResult(perChunk: [], tokensInput: 0, tokensOutput: 0)
        }
        func contextualize(_ chunk: Chunk, in document: DocumentDigest, deadline: Deadline) async throws -> String { "" }
        func embed(_ texts: [String], deadline: Deadline) async throws -> [MemoryInfer.Embedding] {
            texts.map { t in
                var v = [Float](repeating: 0, count: 16); v[abs(t.hashValue) % 16] = 1.0
                return MemoryInfer.Embedding(v)
            }
        }
        func rerank(_ query: String, candidates: [String], deadline: Deadline) async throws -> [Float] {
            // Pathological: one fewer score than candidates (some providers truncate).
            Array([Float](repeating: 0.5, count: candidates.count).dropLast())
        }
        func logprob(_ text: String, given: String?, deadline: Deadline) async throws -> Double { 1.0 }
    }

    func testShortRerankResultDoesNotCrash() async throws {
        let path = NSTemporaryDirectory() + "rerank-guard-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 16))
        let provider = ShortRerankProvider()
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "doc:rerank", bodyPath: "r:1", fetchedAt: 0,
            contentSHA: Data(count: 32), rawBytes: 1))
        // Several chunks so the fused/hydrated window has > 1 candidate. Embeddings
        // built inline (hash-based, dim 16) — no need to call the provider.
        for (i, text) in ["alpha memory note", "beta memory note", "gamma memory note",
                          "delta memory note", "epsilon memory note"].enumerated() {
            var v = [Float](repeating: 0, count: 16); v[abs(text.hashValue) % 16] = 1.0
            _ = try await store.insertChunk(
                ChunkRow(documentId: docId, idx: i, text: text, rawText: text, tokenCount: 3, createdAt: 0),
                embeddingValues: v)
        }
        let retriever = MemoryRetriever(store: store, inference: provider)
        // Before the fix this trapped with "Index out of range". Now it must return
        // hits, with rerank simply contributing nothing (the short result is rejected).
        let hits = try await retriever.search("memory note", k: 5, rerank: true)
        XCTAssertFalse(hits.isEmpty)
        for h in hits { XCTAssertEqual(h.why.rerank, 0) }   // short result was NOT adopted
    }
}
