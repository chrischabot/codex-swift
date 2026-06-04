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

    /// #15: importCanonical was folded into this one pipeline via `extract:`.
    /// The cheap path (`extract: false`, the canonical import-claude default)
    /// must skip ALL LLM enrichment — no per-chunk contextualise (chunk.text
    /// stays RAW) and no entity/edge extraction — while `extract: true` runs the
    /// full pipeline. Both write the same chunks + embeddings.
    func testProcessExtractFlagGatesLLMEnrichment() async throws {
        let path = NSTemporaryDirectory() + "proc-extract-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8))
        let processor = MemoryProcessor(
            store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let text = "Alice met Bob at Acme. The Foo Bar Baz convention."
        let cheap = IngestedDocument(
            sourceName: "manual", sourceKind: .manual, sourceURI: "memo://cheap",
            title: "Cheap", publishedAt: nil, fetchedAt: 1,
            canonicalText: text, rawBytes: 42, contentSHA: Data(count: 32))
        let full = IngestedDocument(
            sourceName: "manual", sourceKind: .manual, sourceURI: "memo://full",
            title: "Full", publishedAt: nil, fetchedAt: 1,
            canonicalText: text, rawBytes: 42, contentSHA: Data(count: 32))

        let cheapReport = try await processor.process(cheap, extract: false)
        let fullReport = try await processor.process(full, extract: true)

        // Same chunks written either way; only the full path runs extraction.
        XCTAssertGreaterThan(cheapReport.chunksWritten, 0)
        XCTAssertEqual(cheapReport.chunksWritten, fullReport.chunksWritten)
        XCTAssertEqual(cheapReport.entitiesUpserted, 0, "cheap path runs no extraction")
        XCTAssertEqual(cheapReport.edgesUpserted, 0)
        XCTAssertGreaterThan(fullReport.entitiesUpserted, 0, "full path extracts entities")

        // Cheap path stores RAW chunk text; full path stores contextualised text
        // (the Mock contextualiser prefixes 'From "<title>" (chunk N):').
        let cheapChunks = try await store.chunks(forDocument: cheapReport.documentId)
        let fullChunks = try await store.chunks(forDocument: fullReport.documentId)
        XCTAssertFalse(cheapChunks.isEmpty)
        for c in cheapChunks {
            XCTAssertEqual(c.text, c.rawText, "cheap path stores raw, un-contextualised text")
            XCTAssertFalse(c.text.contains("From \""), "no contextualise prefix on the cheap path")
        }
        XCTAssertTrue(fullChunks.contains { $0.text.contains("From \"") },
                      "full path stores contextualised text")
    }
}
