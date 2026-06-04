import XCTest
import Foundation
@testable import MemoryStore

final class MemoryStoreTests: XCTestCase {
    private func tmpDB() -> String {
        NSTemporaryDirectory() + "codex-memory-\(UUID().uuidString).db"
    }

    func testSchemaBringUp() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path))
        let docs = try await store.documentCount()
        let chunks = try await store.chunkCount()
        let entities = try await store.entityCount()
        XCTAssertEqual(docs, 0)
        XCTAssertEqual(chunks, 0)
        XCTAssertEqual(entities, 0)
    }

    func testUpsertAndDedupeDocument() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path))
        let sha = Data(repeating: 0xab, count: 32)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .rss, sourceURI: "https://example.com/x",
            bodyPath: "rollout:x", fetchedAt: 1, contentSHA: sha, rawBytes: 100))
        XCTAssertGreaterThan(docId, 0)
        let again = try await store.upsertDocument(DocumentRow(
            source: .rss, sourceURI: "https://example.com/x",
            bodyPath: "rollout:x", fetchedAt: 2, contentSHA: sha, rawBytes: 100))
        XCTAssertEqual(again, docId)
        let count = try await store.documentCount()
        XCTAssertEqual(count, 1)
    }

    func testInsertChunkAndSearchVectors() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let cfg = MemoryStoreConfig(path: path, embeddingDimension: 8)
        let store = try MemoryStore(cfg)
        let sha = Data(repeating: 0x01, count: 32)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "memo:1",
            bodyPath: "rollout:1", fetchedAt: 1,
            contentSHA: sha, rawBytes: 10))
        let close1: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let close2: [Float] = [0.98, 0.2, 0, 0, 0, 0, 0, 0]
        let far:    [Float] = [0, 1, 0, 0, 0, 0, 0, 0]
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0,
                     text: "alpha", rawText: "alpha",
                     tokenCount: 1, createdAt: 1),
            embeddingValues: close1)
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 1,
                     text: "beta", rawText: "beta",
                     tokenCount: 1, createdAt: 1),
            embeddingValues: close2)
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 2,
                     text: "gamma", rawText: "gamma",
                     tokenCount: 1, createdAt: 1),
            embeddingValues: far)
        let hits = try await store.searchVectorValues(close1, k: 3)
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].distance, 0, accuracy: 1e-4)
        XCTAssertLessThan(hits[1].distance, hits[2].distance)
    }

    func testFTSReturnsMatchingChunk() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let cfg = MemoryStoreConfig(path: path, embeddingDimension: 4)
        let store = try MemoryStore(cfg)
        let sha = Data(count: 32)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "doc:1",
            bodyPath: "rollout:1", fetchedAt: 0,
            contentSHA: sha, rawBytes: 1))
        let emb: [Float] = [1, 0, 0, 0]
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0,
                     text: "the swift language is fast and safe",
                     rawText: "raw", tokenCount: 7, createdAt: 0),
            embeddingValues: emb)
        let hits = try await store.searchLexical("swift safe", k: 5)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits[0].chunkId, 1)
    }

    func testDeleteDocumentCleansChunkReferences() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let cfg = MemoryStoreConfig(path: path, embeddingDimension: 4)
        let store = try MemoryStore(cfg)
        let sha = Data(count: 32)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .claude, sourceURI: "claude://doc/1",
            bodyPath: "rollout:claude", fetchedAt: 0,
            contentSHA: sha, rawBytes: 1))
        let chunkId = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0,
                     text: "chunk", rawText: "chunk",
                     tokenCount: 1, createdAt: 0),
            embeddingValues: [1, 0, 0, 0])
        let alice = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Alice", firstSeen: 0, lastSeen: 0))
        let bob = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Bob", firstSeen: 0, lastSeen: 0))
        try await store.insertMention(MentionRow(chunkId: chunkId, entityId: alice))
        _ = try await store.upsertEdge(EdgeRow(
            src: alice, dst: bob, relation: "mentions",
            firstSeen: 0, lastSeen: 0, evidenceChunkId: chunkId))

        try await store.deleteDocument(id: docId)

        let deletedDoc = try await store.document(byURI: "claude://doc/1")
        let chunkCount = try await store.chunkCount()
        let edges = try await store.edges(fromOrTo: alice)
        XCTAssertNil(deletedDoc)
        XCTAssertEqual(chunkCount, 0)
        XCTAssertEqual(edges.count, 1)
        XCTAssertNil(edges.first?.evidenceChunkId)
    }

    /// deleteDocument must purge the FTS5 + vec0 index rows for the document's
    /// chunks — the chunk FK cascade can't reach those virtual tables, so a
    /// naive delete leaves stale lexical/vector hits and (worse) corrupts the
    /// FTS index when a re-import recycles the rowid. Black-box: search must
    /// return nothing for the deleted text, and a fresh chunk that reuses the
    /// recycled rowid must be findable by its own text and ONLY its own text.
    func testDeleteDocumentPurgesSearchIndexes() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let sha = Data(count: 32)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .claude, sourceURI: "claude://doc/purge",
            bodyPath: "rollout:claude", fetchedAt: 0,
            contentSHA: sha, rawBytes: 1))
        let chunkId = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0,
                     text: "zebraphone unicorn", rawText: "zebraphone unicorn",
                     tokenCount: 2, createdAt: 0),
            embeddingValues: [1, 0, 0, 0])

        // Indexed and findable before delete.
        let lexBefore = try await store.searchLexical("zebraphone", k: 5)
        XCTAssertEqual(lexBefore.map(\.chunkId), [chunkId])
        if store.vecAvailable {
            let vecBefore = try await store.searchVectorValues([1, 0, 0, 0], k: 5)
            XCTAssertEqual(vecBefore.first?.chunkId, chunkId)
        }

        try await store.deleteDocument(id: docId)

        // No orphan hits survive in either index.
        let lexAfter = try await store.searchLexical("zebraphone", k: 5)
        XCTAssertEqual(lexAfter, [], "stale FTS row survived deleteDocument")
        if store.vecAvailable {
            let vecAfter = try await store.searchVectorValues([1, 0, 0, 0], k: 5)
            XCTAssertEqual(vecAfter, [], "stale vec0 row survived deleteDocument")
        }

        // Re-import: the new chunk recycles the freed rowid. The FTS index must
        // not be corrupted — the old term must stay gone, the new term must hit.
        let doc2 = try await store.upsertDocument(DocumentRow(
            source: .claude, sourceURI: "claude://doc/purge2",
            bodyPath: "rollout:claude", fetchedAt: 0,
            contentSHA: sha, rawBytes: 1))
        let chunk2 = try await store.insertChunk(
            ChunkRow(documentId: doc2, idx: 0,
                     text: "octopusneon", rawText: "octopusneon",
                     tokenCount: 1, createdAt: 0),
            embeddingValues: [0, 1, 0, 0])
        XCTAssertEqual(chunk2, chunkId, "expected rowid recycling to exercise desync")
        let staleTerm = try await store.searchLexical("zebraphone", k: 5)
        let freshTerm = try await store.searchLexical("octopusneon", k: 5)
        XCTAssertEqual(staleTerm, [],
                       "deleted term reappeared after rowid recycle (FTS desync)")
        XCTAssertEqual(freshTerm.map(\.chunkId), [chunk2])
    }

    func testEntityEdgeAndTwoHop() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let alice = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Alice", firstSeen: 0, lastSeen: 0))
        let bob = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Bob", firstSeen: 0, lastSeen: 0))
        let cara = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Cara", firstSeen: 0, lastSeen: 0))
        _ = try await store.upsertEdge(EdgeRow(
            src: alice, dst: bob, relation: "mentions",
            firstSeen: 0, lastSeen: 0))
        _ = try await store.upsertEdge(EdgeRow(
            src: bob, dst: cara, relation: "mentions",
            firstSeen: 0, lastSeen: 0))
        let walk = try await store.twoHopNeighbours(seed: alice, depth: 2)
        let ids = walk.map(\.0)
        XCTAssertTrue(ids.contains(alice))
        XCTAssertTrue(ids.contains(bob))
        XCTAssertTrue(ids.contains(cara))
    }

    func testRoundTripScale() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let cfg = MemoryStoreConfig(path: path, embeddingDimension: 16)
        let store = try MemoryStore(cfg)
        let sha = Data(count: 32)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "doc:scale",
            bodyPath: "rollout:scale", fetchedAt: 0,
            contentSHA: sha, rawBytes: 1))
        let N = 500
        for i in 0..<N {
            var emb = [Float](repeating: 0, count: 16)
            emb[i % 16] = 1
            _ = try await store.insertChunk(
                ChunkRow(documentId: docId, idx: i,
                         text: "chunk \(i)", rawText: "raw \(i)",
                         tokenCount: 1, createdAt: Int64(i)),
                embeddingValues: emb)
        }
        let count = try await store.chunkCount()
        XCTAssertEqual(count, N)
        var probe = [Float](repeating: 0, count: 16)
        probe[3] = 1
        let hits = try await store.searchVectorValues(probe, k: 5)
        XCTAssertEqual(hits.count, 5)
        XCTAssertEqual(hits[0].distance, 0, accuracy: 1e-4)
    }
}
