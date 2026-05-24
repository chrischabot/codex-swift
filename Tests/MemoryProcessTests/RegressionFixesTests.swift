import XCTest
import Foundation
@testable import MemoryProcess
@testable import MemoryStore
@testable import MemoryInfer
@testable import MemoryIngest
import InfraPrimitives

/// Regression coverage for the post-code-review fixes touching MemoryProcess.
final class ProcessRegressionFixesTests: XCTestCase {
    private func tmpDB() -> String {
        NSTemporaryDirectory() + "codex-memory-proc-fix-\(UUID().uuidString).db"
    }

    // Fix #8: when no archive is wired, document.body_path must be a stable,
    // non-placeholder value (and never the literal string "pending").
    func testProcessorWritesStableBodyPathWithoutArchive() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8))
        let inference = MockInferenceProvider(embeddingDimension: 8)
        let processor = MemoryProcessor(store: store, inference: inference,
                                        archive: nil)
        let doc = IngestedDocument(
            sourceName: "x", sourceKind: .manual, sourceURI: "memo:fix",
            title: "Fix", publishedAt: nil, fetchedAt: 1,
            canonicalText: "Alice and Bob.", rawBytes: 14,
            contentSHA: Data(count: 32))
        let report = try await processor.process(doc)
        let row = try await store.document(id: report.documentId)
        XCTAssertNotNil(row)
        XCTAssertNotEqual(row?.bodyPath, "pending")
        XCTAssertTrue(row?.bodyPath.hasPrefix("inline:") == true,
                      "got: \(row?.bodyPath ?? "nil")")
    }

    // Fix #9: cross-chunk edges where dst was first introduced in a later
    // chunk of the same batch must NOT be dropped. We use a custom provider
    // that mimics this exact pattern.
    func testProcessorPreservesCrossChunkEdges() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let inference = CrossChunkEdgeStub()
        let processor = MemoryProcessor(store: store, inference: inference)
        let doc = IngestedDocument(
            sourceName: "x", sourceKind: .manual, sourceURI: "doc:xchunk",
            title: nil, publishedAt: nil, fetchedAt: 0,
            canonicalText: "First chunk. Second chunk.",
            rawBytes: 30, contentSHA: Data(count: 32))
        let report = try await processor.process(doc)
        XCTAssertGreaterThanOrEqual(report.edgesUpserted, 1,
            "the Alice→Bob edge spanning two chunks should survive")
    }
}

/// Mock that mimics a multi-chunk extraction whose chunk-0 edge references
/// an entity that's only entitied by chunk-1.
actor CrossChunkEdgeStub: LocalInferenceProvider {
    nonisolated let embeddingDimension = 4

    func extract(_ batch: ChunkBatch, schema: ExtractionSchema,
                 deadline: Deadline) async throws -> ExtractionResult {
        // Two chunks: chunk-0 surfaces Alice + an edge Alice→Bob; chunk-1
        // surfaces Bob. The old buggy code would drop the edge because Bob
        // wasn't in canonicalToID when chunk-0 was being processed.
        let c0 = ExtractedChunk(
            localId: batch.chunks[0].localId,
            entities: [ExtractedEntity(kind: "concept", canonical: "Alice")],
            edges: [ExtractedEdge(src: "Alice", dst: "Bob", relation: "mentions")])
        let c1 = ExtractedChunk(
            localId: batch.chunks.count > 1 ? batch.chunks[1].localId : "stub",
            entities: [ExtractedEntity(kind: "concept", canonical: "Bob")],
            edges: [])
        return ExtractionResult(perChunk: [c0, c1], tokensInput: 1, tokensOutput: 1)
    }

    func contextualize(_ chunk: Chunk, in document: DocumentDigest,
                       deadline: Deadline) async throws -> String { "" }

    func embed(_ texts: [String], deadline: Deadline) async throws -> [MemoryInfer.Embedding] {
        texts.map { _ -> MemoryInfer.Embedding in
            var e = MemoryInfer.Embedding([1, 0, 0, 0]); e.normalise(); return e
        }
    }

    func rerank(_ query: String, candidates: [String],
                deadline: Deadline) async throws -> [Float] {
        candidates.map { _ in 1.0 }
    }

    func logprob(_ text: String, given: String?,
                 deadline: Deadline) async throws -> Double { 1.0 }
}
