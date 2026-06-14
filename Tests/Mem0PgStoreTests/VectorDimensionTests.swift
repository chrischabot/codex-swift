import XCTest
import Mem0Core
import EmbeddedPG
@testable import Mem0PgStore

/// Vector-path correctness: the right column type + index per dimensionality,
/// proof the HNSW index is actually used, that `<=>` is COSINE (not L2), and that
/// a selective filter still returns the full top-k (HNSW post-filter recall).
///
/// `CODEX_MEM0_PG_TEST=1 swift test --filter Mem0PgStoreTests`
final class VectorDimensionTests: XCTestCase {

    /// `<=>` must be cosine distance: identical-direction vectors tie at the top
    /// regardless of magnitude (L2 would separate them). Score of an exact match
    /// is ~1.0.
    func testCosineOrderingNotL2() async throws {
        try await PGTestHarness.withCluster(dims: 3) { store, _, _ in
            try await store.insert([
                VectorRecord(id: "x1", vector: [1, 0, 0], payload: ["user_id": .string("u")]),
                VectorRecord(id: "x2", vector: [2, 0, 0], payload: ["user_id": .string("u")]),  // same dir, 2× mag
                VectorRecord(id: "diag", vector: [0.707, 0.707, 0], payload: ["user_id": .string("u")]),
                VectorRecord(id: "y", vector: [0, 1, 0], payload: ["user_id": .string("u")]),
            ])
            let hits = try await store.search("", [1, 0, 0], topK: 4, filters: ["user_id": .string("u")])
            XCTAssertEqual(Set(hits.prefix(2).map(\.id)), ["x1", "x2"],
                           "cosine ties the two x-axis vectors at the top; L2 would not")
            XCTAssertEqual(hits.first?.score ?? 0, 1.0, accuracy: 1e-4, "exact-direction match ≈ 1.0")
            XCTAssertEqual(hits.last?.id, "y", "orthogonal vector ranks last")
        }
    }

    /// Default dims → `vector` column + HNSW index, and the index is actually USED
    /// for an ORDER-BY-distance-LIMIT query (proved via EXPLAIN with seqscan off).
    func testVectorTypeAndHnswIndexUsed() async throws {
        try await PGTestHarness.withCluster(dims: 16) { store, _, paths in
            // Insert enough rows that an index plan is meaningful.
            var recs: [VectorRecord] = []
            for i in 0..<200 {
                var v = [Float](repeating: 0, count: 16); v[i % 16] = 1; v[(i + 1) % 16] = 0.5
                recs.append(VectorRecord(id: "r\(i)", vector: v, payload: ["user_id": .string("u")]))
            }
            try await store.insert(recs)

            let typ = try await PGTestHarness.runSQL(paths, user: "codex_app",
                sql: "SELECT pg_typeof(vector)::text FROM memories LIMIT 1")
            XCTAssertEqual(typ.out.trimmingCharacters(in: .whitespacesAndNewlines), "vector")

            let vec = "[" + (0..<16).map { $0 == 0 ? "1" : "0" }.joined(separator: ",") + "]"
            let plan = try await PGTestHarness.runSQL(paths, user: "codex_app",
                sql: "SET enable_seqscan=off; EXPLAIN SELECT id FROM memories ORDER BY vector <=> '\(vec)'::vector LIMIT 5")
            XCTAssertTrue(plan.out.contains("memories_vec_hnsw"),
                          "HNSW index must be used for ORDER BY <=> LIMIT; plan was:\n\(plan.out)")
        }
    }

    /// dims in (2000, 4000] → `halfvec` column (+ halfvec HNSW). Proves the
    /// dimension-guard branch works end-to-end.
    func testHalfvecForLargeDims() async throws {
        try await PGTestHarness.withCluster(dims: 3072) { store, _, paths in
            var v = [Float](repeating: 0, count: 3072); v[0] = 1
            try await store.insert([VectorRecord(id: "h", vector: v, payload: ["user_id": .string("u")])])
            let typ = try await PGTestHarness.runSQL(paths, user: "codex_app",
                sql: "SELECT pg_typeof(vector)::text FROM memories LIMIT 1")
            XCTAssertEqual(typ.out.trimmingCharacters(in: .whitespacesAndNewlines), "halfvec")
            // round-trips through search
            let hits = try await store.search("", v, topK: 1, filters: ["user_id": .string("u")])
            XCTAssertEqual(hits.first?.id, "h")
        }
    }

    /// A selective metadata filter must still return the FULL requested top-k
    /// (the HNSW-post-filter under-recall trap), all matching the filter.
    func testSelectiveFilterReturnsFullTopK() async throws {
        try await PGTestHarness.withCluster(dims: 8) { store, _, _ in
            var recs: [VectorRecord] = []
            for i in 0..<30 {
                recs.append(VectorRecord(id: "u1_\(i)", vector: .oneHot(i % 8, 8),
                                         payload: ["user_id": .string("u1")]))
                recs.append(VectorRecord(id: "u2_\(i)", vector: .oneHot(i % 8, 8),
                                         payload: ["user_id": .string("u2")]))
            }
            try await store.insert(recs)
            let hits = try await store.search("", .oneHot(0, 8), topK: 5, filters: ["user_id": .string("u1")])
            XCTAssertEqual(hits.count, 5, "selective filter must still return the full top-k, not fewer")
            for h in hits {
                XCTAssertEqual(h.payload["user_id"]?.stringValue, "u1", "every hit honors the filter")
            }
        }
    }

    /// Degenerate vectors: a finite all-zero vector is accepted and doesn't crash;
    /// a NaN/Inf vector is rejected up-front with a clear validation error.
    func testDegenerateVectors() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, _, _ in
            // zero vector stores + control still searchable
            try await store.insert([
                VectorRecord(id: "zero", vector: [0, 0, 0, 0], payload: ["user_id": .string("u")]),
                VectorRecord(id: "ctrl", vector: [1, 0, 0, 0], payload: ["user_id": .string("u")]),
            ])
            let hits = try await store.search("", [1, 0, 0, 0], topK: 2, filters: ["user_id": .string("u")])
            XCTAssertEqual(hits.first?.id, "ctrl")
            for h in hits { XCTAssertTrue(h.score.isFinite, "scores must be finite even with a zero vector present") }
            // NaN/Inf rejected up-front
            do {
                try await store.insert([VectorRecord(id: "nan", vector: [.nan, 0, 0, 0], payload: [:])])
                XCTFail("NaN vector should be rejected")
            } catch { /* expected */ }
            do {
                try await store.insert([VectorRecord(id: "inf", vector: [.infinity, 0, 0, 0], payload: [:])])
                XCTFail("Inf vector should be rejected")
            } catch { /* expected */ }
        }
    }
}
