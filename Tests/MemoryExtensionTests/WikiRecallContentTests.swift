import XCTest
import Foundation
@testable import MemoryExtension
@testable import MemoryRetrieve
@testable import MemoryStore
@testable import MemoryInfer

/// DEFERRED ITEM 4: prove the wiki provider's *recall returns mapped snippets*
/// (not just the empty/degrade cases) against a seeded SQLite store, using the
/// deterministic `MockInferenceProvider`. This is the end-to-end
/// store → retriever → `WikiMemoryProvider.recall` → `[MemorySnippet]` path that
/// the composition root activates when `[memory].provider == "wiki"`.
///
/// NOTE: this file imports the `MemoryStore` *module* to seed the DB, so it must
/// NOT import `HarnessCore` (which exports a clashing `MemoryStore` type). It
/// builds `WikiMemoryProvider` directly over a `MemoryRetriever` (the same
/// object `makeWikiMemoryProvider` wires) — that is exactly the recall limb.
final class WikiRecallContentTests: XCTestCase {

    func testRecallReturnsMappedSnippetsFromSeededStore() async throws {
        let path = NSTemporaryDirectory() + "wiki-recall-\(UUID().uuidString).db"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }

        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 32))
        let inference = MockInferenceProvider(embeddingDimension: 32)
        let docURI = "wiki://doc/seeded"
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: docURI,
            bodyPath: "rollout:r", fetchedAt: 0,
            contentSHA: Data(count: 32), rawBytes: 1))

        let target = "the swift programming language is memory safe"
        let emb = try await inference.embed([target], deadline: .fromNow(.seconds(1)))
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0, text: target, rawText: target,
                     tokenCount: 7, createdAt: 0),
            embeddingValues: emb[0].values)
        let other = "completely unrelated payload about cats"
        let oemb = try await inference.embed([other], deadline: .fromNow(.seconds(1)))
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 1, text: other, rawText: other,
                     tokenCount: 5, createdAt: 0),
            embeddingValues: oemb[0].values)

        let retriever = MemoryRetriever(store: store, inference: inference)
        let provider = WikiMemoryProvider(retriever: retriever, tools: [])

        let snippets = await provider.recall("swift programming", limit: 5)
        XCTAssertFalse(snippets.isEmpty, "recall should map retriever hits to snippets")
        // The matching chunk must appear, carrying the source document URI as
        // its citation (the `RetrievedHit.documentURI → MemorySnippet.citation`
        // mapping that fences into the prompt).
        XCTAssertTrue(snippets.contains { $0.text.contains("swift programming language") },
                      "expected the swift chunk text in the recalled snippets: \(snippets.map(\.text))")
        XCTAssertTrue(snippets.allSatisfy { $0.citation == docURI },
                      "every snippet must cite the seeded document URI")
    }

    /// `limit` is honoured end-to-end (the provider forwards it as the
    /// retriever's `k`). Seed 3 matching chunks, ask for 2, expect ≤ 2.
    func testRecallHonoursLimit() async throws {
        let path = NSTemporaryDirectory() + "wiki-limit-\(UUID().uuidString).db"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }

        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 16))
        let inference = MockInferenceProvider(embeddingDimension: 16)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "wiki://doc/limit",
            bodyPath: "rollout:r", fetchedAt: 0,
            contentSHA: Data(count: 32), rawBytes: 1))
        for i in 0..<3 {
            let text = "shared keyword token number \(i)"
            let e = try await inference.embed([text], deadline: .fromNow(.seconds(1)))
            _ = try await store.insertChunk(
                ChunkRow(documentId: docId, idx: i, text: text, rawText: text,
                         tokenCount: 5, createdAt: 0),
                embeddingValues: e[0].values)
        }
        let retriever = MemoryRetriever(store: store, inference: inference)
        let provider = WikiMemoryProvider(retriever: retriever, tools: [])
        let snippets = await provider.recall("shared keyword token", limit: 2)
        XCTAssertLessThanOrEqual(snippets.count, 2, "recall must cap at the requested limit")
    }
}
