import XCTest
import Foundation
@testable import MemoryStore

/// Regression coverage for the post-code-review fixes touching MemoryStore.
final class RegressionFixesTests: XCTestCase {
    private func tmpDB() -> String {
        NSTemporaryDirectory() + "codex-memory-fix-\(UUID().uuidString).db"
    }

    // Fix #2: twoHopNeighbours should throw on an out-of-range depth instead
    // of tripping the precondition and aborting the daemon.
    func testTwoHopRejectsBadDepth() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let a = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Alice", firstSeen: 0, lastSeen: 0))
        do {
            _ = try await store.twoHopNeighbours(seed: a, depth: 0)
            XCTFail("depth=0 should throw")
        } catch let MemoryStoreError.invalid(msg) {
            XCTAssertTrue(msg.contains("1...4"), msg)
        }
        do {
            _ = try await store.twoHopNeighbours(seed: a, depth: 9)
            XCTFail("depth=9 should throw")
        } catch let MemoryStoreError.invalid(msg) {
            XCTAssertTrue(msg.contains("1...4"), msg)
        }
    }

    // Fix #8 + #16: upsertDocument's ON CONFLICT must refresh body_path so a
    // re-ingest with new content doesn't leave body_path pointing at the
    // previous archive file.
    func testUpsertDocumentRefreshesBodyPath() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let sha1 = Data(repeating: 0xAA, count: 32)
        let sha2 = Data(repeating: 0xBB, count: 32)
        _ = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "memo:1",
            bodyPath: "/archive/v1.txt", fetchedAt: 1,
            contentSHA: sha1, rawBytes: 10))
        let id = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "memo:1",
            bodyPath: "/archive/v2.txt", fetchedAt: 2,
            contentSHA: sha2, rawBytes: 20))
        let row = try await store.document(id: id)
        XCTAssertEqual(row?.bodyPath, "/archive/v2.txt")
        XCTAssertEqual(row?.contentSHA, sha2)
    }

    // Fix #14: recentInteresting must use LEFT JOIN so an insight whose
    // trigger chunk was deleted still appears. Simulate by inserting a
    // doc + chunk + insight, then cascading-delete the document — the
    // insight should still surface as an orphan row.
    func testRecentInterestingKeepsOrphans() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "doc:orphan",
            bodyPath: "/tmp/x.txt", fetchedAt: 0,
            contentSHA: Data(count: 32), rawBytes: 1))
        let chunkId = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0, text: "x", rawText: "x",
                     tokenCount: 1, createdAt: 0),
            embeddingValues: [1, 0, 0, 0])
        _ = try await store.insertInsight(InsightRow(
            triggerChunkId: chunkId, model: "stub",
            inputTokens: 100, outputTokens: 50,
            costUSD: 0.05, score: 0.9, cardMD: "{}", createdAt: 1))
        // Cascade-delete the document → its chunk is removed (FK ON DELETE
        // CASCADE on chunk.document_id) and the insight row is left orphaned
        // because insight has no cascade rule.
        try await store.deleteDocument(id: docId)
        let rows = try await store.recentInteresting(since: 0, minScore: 0.0, limit: 10)
        XCTAssertEqual(rows.count, 1, "LEFT JOIN should preserve the orphan")
        XCTAssertEqual(rows.first?.documentURI, "(orphan)")
    }

    // Fix #15: self-loop edge contributes 2 to the entity's undirected degree.
    func testSelfLoopDegreeCountsTwice() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let alice = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Alice", firstSeen: 0, lastSeen: 0))
        _ = try await store.upsertEdge(EdgeRow(
            src: alice, dst: alice, relation: "loop",
            firstSeen: 0, lastSeen: 0))
        let row = try await store.entity(id: alice)
        XCTAssertEqual(row?.degree, 2, "self-loop should count twice for degree")
    }
}
