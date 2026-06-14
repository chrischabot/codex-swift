import XCTest
import Foundation
@testable import WikiQueryKit
import MemoryStore
import MemoryRetrieve
import MemoryInfer
import WireProtocol

/// Coverage for the depth-tiered `wiki/query` shaper: the quick (lexical) tier,
/// honest degradation when no matching embedder is available (the design's
/// never-mix-embedding-spaces rule), and the hybrid shaping via a mock retriever.
final class WikiQueryTests: XCTestCase {
    private var store: MemoryStore!
    private var doc1: Int64 = 0
    private var doc2: Int64 = 0

    override func setUp() async throws {
        let dir = NSTemporaryDirectory() + "wikiquery-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        store = try MemoryStore(MemoryStoreConfig(path: dir + "/m.db", embeddingDimension: 8))
        let sha = Data(repeating: 0x01, count: 32)
        doc1 = try await store.upsertDocument(DocumentRow(source: .web, sourceURI: "u1", title: "Alpha",
            bodyPath: "b1", fetchedAt: 100, contentSHA: sha, rawBytes: 1))
        doc2 = try await store.upsertDocument(DocumentRow(source: .web, sourceURI: "u2", title: "Beta",
            bodyPath: "b2", fetchedAt: 200, contentSHA: sha, rawBytes: 1))
        _ = try await store.insertChunk(ChunkRow(documentId: doc1, idx: 0, text: "hello world alpha",
            rawText: "hello world alpha", tokenCount: 3, createdAt: 100),
            embeddingValues: [0.9, 0.1, 0, 0, 0, 0, 0, 0])
        _ = try await store.insertChunk(ChunkRow(documentId: doc2, idx: 0, text: "world beta context",
            rawText: "world beta context", tokenCount: 3, createdAt: 200),
            embeddingValues: [0.1, 0.9, 0, 0, 0, 0, 0, 0])
    }

    private func obj(_ v: JSONValue?) -> [String: JSONValue]? { if case .object(let o)? = v { return o }; return nil }
    private func str(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s }; return nil }
    private func arr(_ v: JSONValue?) -> [JSONValue]? { if case .array(let a)? = v { return a }; return nil }

    func testEmptyQueryIsNone() async throws {
        let r = try await WikiJSON.query(store, retriever: nil, query: "   ", depth: 2, k: 10)
        let o = obj(r)
        XCTAssertEqual(str(o?["retrieval"]), "none")
        XCTAssertEqual(arr(o?["data"])?.count, 0)
    }

    func testQuickTierIsLexical() async throws {
        let r = try await WikiJSON.query(store, retriever: nil, query: "world", depth: 1, k: 10)
        let o = obj(r)
        XCTAssertEqual(str(o?["retrieval"]), "lexical")   // depth 1 → lexical, NOT degraded
        XCTAssertEqual(arr(o?["data"])?.count, 2)         // both docs mention "world"
    }

    func testStandardWithoutEmbedderDegradesHonestly() async throws {
        // depth >= 2 but no matching embedder → lexical-degraded (never silently
        // embeds with a mismatched model).
        let r2 = try await WikiJSON.query(store, retriever: nil, query: "world", depth: 2, k: 10)
        XCTAssertEqual(str(obj(r2)?["retrieval"]), "lexical-degraded")
        let r3 = try await WikiJSON.query(store, retriever: nil, query: "world", depth: 3, k: 10)
        XCTAssertEqual(str(obj(r3)?["retrieval"]), "lexical-degraded")
        XCTAssertEqual(arr(obj(r2)?["data"])?.count, 2)   // still returns lexical results
    }

    func testHybridShapingWithRetriever() async throws {
        // A real MemoryRetriever over a mock embedder — exercises the hybrid
        // grouping + the per-result `why` (bm25/vec/rerank) shaping.
        let retriever = MemoryRetriever(store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let r = try await WikiJSON.query(store, retriever: retriever, query: "world", depth: 3, k: 10)
        let o = obj(r)
        XCTAssertEqual(str(o?["retrieval"]), "hybrid")
        let data = arr(o?["data"]) ?? []
        XCTAssertGreaterThan(data.count, 0)
        // each item carries id/title/score + the score breakdown
        if case .object(let first)? = data.first {
            XCTAssertNotNil(first["id"]); XCTAssertNotNil(first["title"]); XCTAssertNotNil(first["score"])
            XCTAssertNotNil(obj(first["why"])?["bm25"])
            XCTAssertNotNil(obj(first["why"])?["vec"])
        } else { XCTFail("expected object items") }
    }
}
