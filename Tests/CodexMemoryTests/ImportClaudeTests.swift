import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore
@testable import MemoryProcess
@testable import MemoryInfer

/// #4 regression guard at the REAL import path: drives
/// `CodexMemoryClaudeImport.importDocuments` (the per-document `--extract` loop)
/// twice on the same source_uri and asserts it does not duplicate chunks. This
/// is the guard the prior contract-only test could not provide — it exercises
/// the actual decode → delete-first → process pipeline the CLI runs.
final class ImportClaudeTests: XCTestCase {
    private func line(uri: String) -> String {
        "{\"source_uri\":\"\(uri)\",\"title\":\"T\"," +
        "\"canonical_text\":\"Alice met Bob at Acme. The Foo Bar Baz convention.\"}"
    }

    func testExtractImportTwiceDoesNotDuplicateChunks() async throws {
        let path = NSTemporaryDirectory() + "import-claude-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8))
        let processor = MemoryProcessor(
            store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let text = line(uri: "claude://conv/1") + "\n"

        let out1 = await CodexMemoryClaudeImport.importDocuments(
            text: text, extractMode: true, store: store, processor: processor)
        let afterFirst = try await store.chunkCount()
        XCTAssertGreaterThan(afterFirst, 0)
        XCTAssertTrue(out1.contains("imported=1"), "first import should report one document")

        // Re-run the SAME source through the real loop — must NOT duplicate.
        let out2 = await CodexMemoryClaudeImport.importDocuments(
            text: text, extractMode: true, store: store, processor: processor)
        let afterSecond = try await store.chunkCount()
        XCTAssertTrue(out2.contains("imported=1"))
        let docCount = try await store.documentCount()
        XCTAssertEqual(afterSecond, afterFirst,
                       "re-running --extract on the same source_uri must not duplicate chunks")
        XCTAssertEqual(docCount, 1)
    }

    /// The cheap (default, non-extract) loop must also be idempotent and must
    /// produce no graph entities — the importCanonical behavior, now via the one
    /// unified pipeline.
    func testDefaultImportIsIdempotentAndHasNoEntities() async throws {
        let path = NSTemporaryDirectory() + "import-claude-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8))
        let processor = MemoryProcessor(
            store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let text = line(uri: "claude://conv/2") + "\n"

        _ = await CodexMemoryClaudeImport.importDocuments(
            text: text, extractMode: false, store: store, processor: processor)
        let afterFirst = try await store.chunkCount()
        _ = await CodexMemoryClaudeImport.importDocuments(
            text: text, extractMode: false, store: store, processor: processor)
        let afterSecond = try await store.chunkCount()

        let entityCount = try await store.entityCount()
        XCTAssertGreaterThan(afterFirst, 0)
        XCTAssertEqual(afterSecond, afterFirst, "default re-import must not duplicate chunks")
        XCTAssertEqual(entityCount, 0, "cheap path creates no graph entities")
    }
}
