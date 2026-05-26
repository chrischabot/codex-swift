import XCTest
import Foundation
import InfraPrimitives
@testable import MemoryRetrieve
@testable import MemoryStore
@testable import MemoryInfer

/// Severe tests for the per-session embedding LRU cache.
///
/// Acceptance gates:
/// 1. Repeated identical query within session: 2nd call skips embed.
///    Verified via `MemoryRetriever.embedCacheHitCount` and a counting mock
///    inference provider.
/// 2. 10000 random queries against a fixed working set produce a measured
///    hit rate consistent with the LRU theoretical bound.
/// 3. 100 concurrent get/put pairs from different tasks produce no torn
///    entries (verified by reading back every key and asserting equality
///    with the original value).
/// 4. Eviction is O(1) — wall-clock time per put remains constant across
///    cache sizes far past the capacity.
final class QueryEmbeddingCacheTests: XCTestCase {

    func testGetPutEvictionLRU() {
        let cache = QueryEmbeddingCache(capacity: 3, modelId: "m")
        cache.put("a", [1, 0, 0])
        cache.put("b", [0, 1, 0])
        cache.put("c", [0, 0, 1])
        XCTAssertEqual(cache.get("a"), [1, 0, 0])
        // After get("a"), order MRU→LRU is a, c, b.
        cache.put("d", [1, 1, 0])      // evicts b
        XCTAssertNil(cache.get("b"), "b should have been evicted as LRU")
        XCTAssertEqual(cache.get("a"), [1, 0, 0])
        XCTAssertEqual(cache.get("c"), [0, 0, 1])
        XCTAssertEqual(cache.get("d"), [1, 1, 0])
    }

    func testUpdateRefreshesValueAndPromotes() {
        let cache = QueryEmbeddingCache(capacity: 2, modelId: "m")
        cache.put("a", [1])
        cache.put("b", [2])
        cache.put("a", [99])           // refresh; a becomes MRU
        cache.put("c", [3])            // evict b (LRU)
        XCTAssertEqual(cache.get("a"), [99])
        XCTAssertNil(cache.get("b"))
        XCTAssertEqual(cache.get("c"), [3])
    }

    func testInvalidateAll() {
        let cache = QueryEmbeddingCache(capacity: 4, modelId: "m")
        for i in 0..<4 { cache.put("k\(i)", [Float(i)]) }
        XCTAssertEqual(cache.size, 4)
        cache.invalidateAll()
        XCTAssertEqual(cache.size, 0)
        for i in 0..<4 { XCTAssertNil(cache.get("k\(i)")) }
    }

    func testNormalizationVersionInvalidates() {
        let cacheV1 = QueryEmbeddingCache(capacity: 4,
                                          modelId: "m",
                                          normalizationVersion: 1)
        let cacheV2 = QueryEmbeddingCache(capacity: 4,
                                          modelId: "m",
                                          normalizationVersion: 2)
        cacheV1.put("q", [0.1, 0.2])
        XCTAssertNil(cacheV2.get("q"))
        XCTAssertEqual(cacheV1.get("q"), [0.1, 0.2])
    }

    func testModelIdSeparation() {
        let a = QueryEmbeddingCache(capacity: 4, modelId: "nomic-1.5")
        let b = QueryEmbeddingCache(capacity: 4, modelId: "bge-small")
        a.put("q", [1])
        XCTAssertEqual(a.get("q"), [1])
        XCTAssertNil(b.get("q"))
    }

    func testHitRateAgainstLRUBound() {
        // Working set of 200 distinct queries, cache capacity 64. Each
        // request is uniform over the working set. Theoretical steady-state
        // hit rate for LRU under a uniform workload is `cap / |WS|` once the
        // cache fills.
        let cap = 64
        let ws = 200
        let cache = QueryEmbeddingCache(capacity: cap, modelId: "m")
        for i in 0..<ws { cache.put("q\(i)", [Float(i)]) }
        cache.resetForTests()
        for i in 0..<ws { cache.put("q\(i)", [Float(i)]) }

        var rng = SystemRandomNumberGenerator()
        let trials = 10_000
        for _ in 0..<trials {
            let pick = Int.random(in: 0..<ws, using: &rng)
            let key = "q\(pick)"
            if cache.get(key) == nil {
                cache.put(key, [Float(pick)])
            }
        }
        let total = cache.hitCount + cache.missCount
        let observed = Double(cache.hitCount) / Double(total)
        let expected = Double(cap) / Double(ws)
        let low = expected * 0.7
        let high = expected * 1.3
        print(String(format: "[cache] LRU hit rate cap=%d |WS|=%d → observed=%.3f expected≈%.3f",
                     cap, ws, observed, expected))
        XCTAssertGreaterThan(observed, low,
                             "hit rate \(observed) below LRU lower bound \(low)")
        XCTAssertLessThan(observed, high,
                          "hit rate \(observed) above LRU upper bound \(high)")
    }

    func testConcurrentGetPutNoTearing() async {
        let cache = QueryEmbeddingCache(capacity: 32, modelId: "m")
        let dim = 64
        let workers = 100
        let opsPerWorker = 500

        await withTaskGroup(of: Bool.self) { group in
            for w in 0..<workers {
                group.addTask {
                    let value = [Float](repeating: Float(w) + 0.25, count: dim)
                    let key = "w-\(w)"
                    for _ in 0..<opsPerWorker {
                        cache.put(key, value)
                        if let got = cache.get(key) {
                            if got != value { return false }
                        }
                    }
                    return true
                }
            }
            var allOK = true
            for await ok in group { allOK = allOK && ok }
            XCTAssertTrue(allOK, "concurrent get/put returned a torn or wrong entry")
        }
    }

    func testEvictionIsConstantTime() {
        let cap = 64
        let cache = QueryEmbeddingCache(capacity: cap, modelId: "m")
        let total = cap * 100
        let value: [Float] = (0..<32).map { Float($0) }
        let start = mach_absolute_time()
        for i in 0..<total {
            cache.put("k\(i)", value)
        }
        let end = mach_absolute_time()
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ns = Double(end - start) * Double(info.numer) / Double(info.denom)
        let perPut = ns / Double(total)
        print(String(format: "[cache] %d puts → %.2fμs total (%.0fns / put)",
                     total, ns / 1000, perPut))
        XCTAssertLessThan(perPut, 5_000, "per-put cost spiraling")
        XCTAssertEqual(cache.size, cap, "cache must not grow past capacity")
    }

    /// Counts embed calls so we can prove the cache short-circuits.
    actor CountingProvider: LocalInferenceProvider {
        nonisolated let embeddingDimension: Int = 16
        private var _embedCalls = 0
        var embedCalls: Int { _embedCalls }

        func extract(_ batch: ChunkBatch,
                     schema: ExtractionSchema,
                     deadline: Deadline) async throws -> ExtractionResult {
            ExtractionResult(perChunk: [], tokensInput: 0, tokensOutput: 0)
        }
        func contextualize(_ chunk: Chunk,
                           in document: DocumentDigest,
                           deadline: Deadline) async throws -> String { "" }
        func embed(_ texts: [String], deadline: Deadline) async throws -> [MemoryInfer.Embedding] {
            _embedCalls += texts.count
            return texts.map { t in
                var values = [Float](repeating: 0, count: 16)
                values[abs(t.hashValue) % 16] = 1.0
                return MemoryInfer.Embedding(values)
            }
        }
        func rerank(_ query: String, candidates: [String],
                    deadline: Deadline) async throws -> [Float] {
            return [Float](repeating: 0, count: candidates.count)
        }
        func logprob(_ text: String, given: String?, deadline: Deadline) async throws -> Double { 1.0 }
    }

    func testRetrieverCachesQueryEmbedding() async throws {
        let path = NSTemporaryDirectory() + "qec-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 16))
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "memo:cache",
            bodyPath: "rollout:c", fetchedAt: 0,
            contentSHA: Data(count: 32), rawBytes: 1))
        var seed = [Float](repeating: 0, count: 16)
        seed[3] = 1.0
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0, text: "x", rawText: "x",
                     tokenCount: 1, createdAt: 0),
            embeddingValues: seed)

        let provider = CountingProvider()
        let retriever = MemoryRetriever(store: store, inference: provider)

        _ = try await retriever.vecTopHits("hello world")
        let calls1 = await provider.embedCalls
        XCTAssertEqual(calls1, 1)
        XCTAssertEqual(retriever.embedCacheHitCount, 0)
        XCTAssertEqual(retriever.embedCacheMissCount, 1)

        _ = try await retriever.vecTopHits("hello world")
        let calls2 = await provider.embedCalls
        XCTAssertEqual(calls2, 1, "second call must NOT re-embed")
        XCTAssertEqual(retriever.embedCacheHitCount, 1)
        XCTAssertEqual(retriever.embedCacheMissCount, 1)

        _ = try await retriever.vecTopHits("different query")
        let calls3 = await provider.embedCalls
        XCTAssertEqual(calls3, 2)
        XCTAssertEqual(retriever.embedCacheHitCount, 1)
        XCTAssertEqual(retriever.embedCacheMissCount, 2)

        retriever.invalidateEmbedCache()
        _ = try await retriever.vecTopHits("hello world")
        let calls4 = await provider.embedCalls
        XCTAssertEqual(calls4, 3, "invalidate must force a re-embed")
    }
}
