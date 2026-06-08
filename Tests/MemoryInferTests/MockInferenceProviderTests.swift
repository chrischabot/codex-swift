import XCTest
@testable import MemoryInfer
import InfraPrimitives

final class MockInferenceProviderTests: XCTestCase {
    func testDeterministicEmbeddingsAreStableAndNormalised() async throws {
        let p = MockInferenceProvider(embeddingDimension: 32)
        let e1 = try await p.embed(["hello world"], deadline: .fromNow(.seconds(1)))
        let e2 = try await p.embed(["hello world"], deadline: .fromNow(.seconds(1)))
        XCTAssertEqual(e1, e2)
        let mag = e1.first!.values.map { $0 * $0 }.reduce(0, +).squareRoot()
        XCTAssertEqual(mag, 1, accuracy: 1e-4)
    }

    func testExtractionPicksCapitalisedNouns() async throws {
        let p = MockInferenceProvider()
        let batch = ChunkBatch(
            documentTitle: "test",
            documentURI: "test://x",
            chunks: [Chunk(localId: "c0", rawText: "Alice met Bob at Acme", idx: 0)])
        let result = try await p.extract(batch, schema: .default,
                                          deadline: .fromNow(.seconds(1)))
        let names = result.perChunk.first?.entities.map(\.canonical) ?? []
        XCTAssertTrue(names.contains("Alice"))
        XCTAssertTrue(names.contains("Bob"))
        XCTAssertTrue(names.contains("Acme"))
    }

    func testContextualiseUsesTitle() async throws {
        let p = MockInferenceProvider()
        let chunk = Chunk(localId: "x", rawText: "body", idx: 7)
        let digest = DocumentDigest(title: "Spec", uri: "spec://", summary: "")
        let ctx = try await p.contextualize(chunk, in: digest,
                                            deadline: .fromNow(.seconds(1)))
        XCTAssertTrue(ctx.contains("Spec"))
        XCTAssertTrue(ctx.contains("7"))
    }

    func testRerankIsMonotoneToSemanticMatch() async throws {
        let p = MockInferenceProvider(embeddingDimension: 32)
        let scores = try await p.rerank("hello world",
                                         candidates: ["hello world", "goodbye sky"],
                                         deadline: .fromNow(.seconds(1)))
        XCTAssertEqual(scores.count, 2)
        XCTAssertGreaterThan(scores[0], scores[1])
    }

    func testBoundedWrapperPassesThroughResults() async throws {
        let inner = MockInferenceProvider(embeddingDimension: 8)
        let wrapped = BoundedInferenceProvider(
            inner, config: MemoryInferConfig(embeddingDimension: 8))
        let e = try await wrapped.embed(["x"], deadline: .fromNow(.seconds(1)))
        XCTAssertEqual(e.first?.dimension, 8)
    }

    func testMLXLocalProviderDefaultsToBGERerankerWithFallback() {
        let config = MLXLocalProvider.Config()
        XCTAssertEqual(config.rerankerModelID, "BAAI/bge-reranker-v2-m3")
        XCTAssertEqual(config.rerankerMaxTokens, 8192)
        XCTAssertTrue(config.allowCosineRerankFallback)
    }

    func testMLXAvailabilityHonorsRuntimeDisableEnv() {
        XCTAssertFalse(MLXLocalProvider.isAvailable(env: ["CODEXKIT_MOCK": "1"]))
        XCTAssertFalse(MLXLocalProvider.isAvailable(env: ["CODEXKIT_MLX": "0"]))
        XCTAssertFalse(MLXLocalProvider.isAvailable(env: ["CODEXKIT_MLX_RUNTIME": "0"]))
    }
}
