import XCTest
import Foundation
import Mem0Core
import EmbeddedPG
@testable import Mem0PgStore

/// Remaining severe / edge-case coverage: keyword-search degenerate inputs, NUL
/// bytes (which Postgres text/jsonb cannot hold), batch-insert atomicity on a bad
/// row, and the one-call `openDefault` convenience.
///
/// `CODEX_MEM0_PG_TEST=1 swift test --filter Mem0PgStoreTests`
final class EdgeCaseTests: XCTestCase {

    /// keywordSearch must return a non-nil (possibly empty) result for degenerate
    /// queries (empty / punctuation / stopwords / injection) — never throw a
    /// tsquery syntax error — and the table must survive.
    func testKeywordSearchDegenerateQueries() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, _, _ in
            try await store.insert([
                VectorRecord(id: "k1", vector: [1, 0, 0, 0],
                             payload: ["user_id": .string("u"), "text_lemmatized": .string("hello world foo")]),
                VectorRecord(id: "k2", vector: [0, 1, 0, 0],
                             payload: ["user_id": .string("u"), "text_lemmatized": .string("goodbye world bar")]),
            ])
            // real match
            let hits = try await store.keywordSearch("hello", topK: 5, filters: ["user_id": .string("u")])
            XCTAssertEqual(hits?.first?.id, "k1")
            // degenerate queries → non-nil empty, no throw
            for q in ["", "   ", "...,;!?", "'; DROP TABLE memories;--"] {
                let r = try await store.keywordSearch(q, topK: 5, filters: ["user_id": .string("u")])
                XCTAssertNotNil(r, "keywordSearch(\(q.debugDescription)) must return [] not nil/throw")
                XCTAssertEqual(r?.count, 0, "no matches for \(q.debugDescription)")
            }
            // table intact after the injection-y query
            let still = try await store.list(["user_id": .string("u")], limit: nil)
            XCTAssertEqual(still.count, 2, "DROP TABLE in a keyword query did not execute")
        }
    }

    /// A NUL byte in a payload (illegal in Postgres text/jsonb) is rejected, the
    /// batch rolls back, and the connection survives (not stuck in an aborted txn).
    func testNullByteRejectedConnectionSurvives() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, _, _ in
            try await store.insert([VectorRecord(id: "ok", vector: [1, 0, 0, 0], payload: ["user_id": .string("u")])])
            do {
                try await store.insert([VectorRecord(id: "nul", vector: [0, 1, 0, 0],
                                                     payload: ["user_id": .string("u"), "v": .string("a\u{0000}b")])])
                XCTFail("a NUL byte must be rejected by jsonb")
            } catch { /* expected */ }
            // connection not poisoned: control still readable + a fresh insert works
            let okAfter = try await store.get("ok")
            XCTAssertNotNil(okAfter, "connection survives the rejected insert")
            try await store.insert([VectorRecord(id: "ok2", vector: [0, 0, 1, 0], payload: ["user_id": .string("u")])])
            let ok2 = try await store.get("ok2")
            XCTAssertNotNil(ok2, "fresh insert works after the rejection (txn rolled back)")
        }
    }

    /// A batch insert containing a dimension-mismatched vector rolls back ENTIRELY
    /// (BEGIN/COMMIT atomicity) — the valid row in the same batch is not persisted.
    func testDimensionMismatchBatchRollsBack() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, _, _ in
            do {
                try await store.insert([
                    VectorRecord(id: "okB", vector: [1, 0, 0, 0], payload: ["user_id": .string("u")]),
                    VectorRecord(id: "wrong", vector: [1, 0, 0], payload: ["user_id": .string("u")]),  // 3-dim
                ])
                XCTFail("dimension mismatch must be rejected")
            } catch { /* expected */ }
            let okB = try await store.get("okB")
            XCTAssertNil(okB, "the whole batch rolled back on the bad row")
        }
    }

    /// The one-call `openDefault` convenience spins up a cluster under a custom
    /// CODEX_HOME and serves.
    func testOpenDefaultConvenience() async throws {
        try XCTSkipUnless(PGTestHarness.enabled, "set CODEX_MEM0_PG_TEST=1")
        guard PGPaths.discoverServerBinDir() != nil else { throw XCTSkip("no postgres server binary") }
        let tmpHome = NSTemporaryDirectory() + "codexmem0-home-" + UUID().uuidString.prefix(8)
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = tmpHome
        // AWAIT teardown on every path (a fire-and-forget Task in defer would race
        // the temp-dir removal and leak the postmaster).
        func teardown() async {
            if let paths = PGPaths.resolveDefault(env: env) {
                try? await PostgresLifecycle(paths: paths).stop()
            }
            try? FileManager.default.removeItem(atPath: tmpHome)
        }
        do {
            let store = try await Mem0PgVectorStore.openDefault(dims: 4, env: env)
            try await store.insert([VectorRecord(id: "d", vector: [1, 0, 0, 0], payload: ["user_id": .string("u")])])
            let d = try await store.get("d")
            XCTAssertNotNil(d)
            await store.shutdown()
        } catch {
            await teardown(); throw error
        }
        await teardown()
    }
}
