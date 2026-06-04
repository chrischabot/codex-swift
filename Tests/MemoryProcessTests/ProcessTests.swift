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

    /// Pins the contract the `--extract` import path relies on:
    /// `process()` upserts the document but does NOT clear its prior chunks, so
    /// re-ingesting the same URI through it alone DUPLICATES every chunk. The
    /// caller (ImportClaude's extract branch) must deleteDocument first; once it
    /// does, the re-import is clean. This test fails loudly if `process()` ever
    /// silently gains/loses dedup so the caller-side fix can be re-evaluated.
    func testProcessIsNonIdempotentSoCallerMustDeleteFirst() async throws {
        let path = NSTemporaryDirectory() + "proc-dup-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8))
        let processor = MemoryProcessor(
            store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let doc = IngestedDocument(
            sourceName: "manual", sourceKind: .manual,
            sourceURI: "memo://dup",
            title: "Dup", publishedAt: nil, fetchedAt: 1,
            canonicalText: "Alice met Bob at Acme. The Foo Bar Baz convention.",
            rawBytes: 42, contentSHA: Data(count: 32))

        _ = try await processor.process(doc)
        let single = try await store.chunkCount()
        var docCount = try await store.documentCount()
        XCTAssertGreaterThan(single, 0)
        XCTAssertEqual(docCount, 1)

        // Re-process the SAME URI with no prior delete: chunks duplicate.
        _ = try await processor.process(doc)
        let doubled = try await store.chunkCount()
        docCount = try await store.documentCount()
        XCTAssertEqual(doubled, single * 2,
                       "process() unexpectedly deduped — revisit ImportClaude's delete-first fix")
        XCTAssertEqual(docCount, 1)

        // The fix path: delete the prior document, then re-process → clean copy.
        let existing = try await store.document(byURI: "memo://dup")
        XCTAssertNotNil(existing)
        try await store.deleteDocument(id: existing!.id)
        _ = try await processor.process(doc)
        let afterRefresh = try await store.chunkCount()
        docCount = try await store.documentCount()
        XCTAssertEqual(afterRefresh, single,
                       "delete-then-process should yield exactly one clean copy")
        XCTAssertEqual(docCount, 1)
    }
}
