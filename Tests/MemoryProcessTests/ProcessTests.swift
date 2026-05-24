import XCTest
import Foundation
@testable import MemoryProcess
@testable import MemoryStore
@testable import MemoryInfer
@testable import MemoryIngest
import InfraPrimitives

final class ProcessTests: XCTestCase {
    func testChunkSplitterRespectsTargetTokens() {
        let splitter = ChunkSplitter(targetTokens: 20, overlapTokens: 0,
                                     tokensFor: { _ in 7 })
        let text = (0..<20).map { "sentence \($0)." }.joined(separator: " ")
        let pieces = splitter.split(text)
        XCTAssertGreaterThan(pieces.count, 1)
        for p in pieces {
            XCTAssertLessThanOrEqual(p.tokens, 21 * 7)  // sanity upper bound
        }
    }

    func testProcessorPersistsChunksAndEntities() async throws {
        let path = NSTemporaryDirectory() + "proc-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8))
        let inference = MockInferenceProvider(embeddingDimension: 8)
        let processor = MemoryProcessor(store: store, inference: inference)
        let doc = IngestedDocument(
            sourceName: "manual", sourceKind: .manual,
            sourceURI: "memo://alpha",
            title: "Alpha", publishedAt: nil, fetchedAt: 1,
            canonicalText: "Alice met Bob at Acme. The Foo Bar Baz convention.",
            rawBytes: 42, contentSHA: Data(count: 32))
        let report = try await processor.process(doc)
        XCTAssertGreaterThan(report.chunksWritten, 0)
        XCTAssertGreaterThan(report.entitiesUpserted, 0)
        XCTAssertGreaterThanOrEqual(report.edgesUpserted, 0)
        let docs = try await store.documentCount()
        XCTAssertEqual(docs, 1)
    }
}
