import XCTest
import Mem0Core
import EmbeddedPG
@testable import Mem0PgStore

/// Integration smoke tests for the pgvector-backed store. Gated behind
/// `CODEX_MEM0_PG_TEST=1` (like the OPENAI_API_KEY-gated LiveTests) — they spawn a
/// real local postmaster and are skipped by default.
///
/// Run with:  `CODEX_MEM0_PG_TEST=1 swift test --filter Mem0PgStoreTests`
final class Mem0PgStoreTests: XCTestCase {
    func testSmokeInsertSearch() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, _, _ in
            try await store.insert([
                VectorRecord(id: "a", vector: [1, 0, 0, 0], payload: ["user_id": .string("u1"), "data": .string("alpha")]),
                VectorRecord(id: "b", vector: [0, 1, 0, 0], payload: ["user_id": .string("u1"), "data": .string("beta")]),
            ])
            let hits = try await store.search("", [1, 0, 0, 0], topK: 2, filters: ["user_id": .string("u1")])
            XCTAssertEqual(hits.first?.id, "a", "nearest vector should rank first")
            XCTAssertEqual(hits.count, 2)
            XCTAssertGreaterThan(hits[0].score, hits[1].score, "score must be a descending similarity")
        }
    }

    func testGetUpdateDelete() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, _, _ in
            try await store.insert([VectorRecord(id: "x", vector: [1, 0, 0, 0], payload: ["user_id": .string("u1")])])
            let got = try await store.get("x")
            XCTAssertEqual(got?.id, "x")
            try await store.update("x", vector: nil, payload: ["user_id": .string("u1"), "k": .string("v")])
            let after = try await store.get("x")
            XCTAssertEqual(after?.payload["k"]?.stringValue, "v")
            // update of an absent id is a no-op (parity with the SQLite store)
            try await store.update("nope", vector: [0, 0, 0, 1], payload: ["a": .string("b")])
            let absent = try await store.get("nope")
            XCTAssertNil(absent)
            try await store.delete("x")
            let deleted = try await store.get("x")
            XCTAssertNil(deleted)
        }
    }
}
