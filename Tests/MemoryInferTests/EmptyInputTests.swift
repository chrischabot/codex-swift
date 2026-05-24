import XCTest
@testable import MemoryInfer
import InfraPrimitives

/// Polish round: every provider must handle empty inputs without burning a
/// model call, hanging, or returning surprising shapes. We assert via the
/// `crash on call` discipline — the test closures throw a sentinel error if
/// they're invoked, so a passing test proves the call was short-circuited.
final class EmptyInputTests: XCTestCase {
    struct UnexpectedCall: Error {}

    func testRemoteEmbedShortCircuitsOnEmptyInput() async throws {
        let provider = RemoteOpenAICompatibleProvider(
            embeddingDimension: 8,
            textCall: { _, _ in throw UnexpectedCall() },
            embeddingCall: { _, _ in throw UnexpectedCall() },
            logprobCall: { _, _, _ in throw UnexpectedCall() })
        let out = try await provider.embed([], deadline: .fromNow(.seconds(1)))
        XCTAssertEqual(out, [])
    }

    func testRemoteExtractShortCircuitsOnEmptyBatch() async throws {
        let provider = RemoteOpenAICompatibleProvider(
            embeddingDimension: 8,
            textCall: { _, _ in throw UnexpectedCall() },
            embeddingCall: { _, _ in throw UnexpectedCall() },
            logprobCall: { _, _, _ in throw UnexpectedCall() })
        let batch = ChunkBatch(documentTitle: nil, documentURI: "u", chunks: [])
        let r = try await provider.extract(batch, schema: .default,
                                            deadline: .fromNow(.seconds(1)))
        XCTAssertEqual(r.perChunk.count, 0)
    }

    func testMockExtractShortCircuitsOnEmptyBatch() async throws {
        let mock = MockInferenceProvider(embeddingDimension: 8)
        let batch = ChunkBatch(documentTitle: nil, documentURI: "u", chunks: [])
        let r = try await mock.extract(batch, schema: .default,
                                        deadline: .fromNow(.seconds(1)))
        XCTAssertEqual(r.perChunk.count, 0)
    }

    func testRemoteRerankShortCircuitsOnEmptyCandidates() async throws {
        let provider = RemoteOpenAICompatibleProvider(
            embeddingDimension: 8,
            textCall: { _, _ in throw UnexpectedCall() },
            embeddingCall: { _, _ in throw UnexpectedCall() },
            logprobCall: { _, _, _ in throw UnexpectedCall() })
        let r = try await provider.rerank("q", candidates: [],
                                          deadline: .fromNow(.seconds(1)))
        XCTAssertEqual(r, [])
    }
}
