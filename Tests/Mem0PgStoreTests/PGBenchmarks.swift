import XCTest
import Foundation
import Mem0Core
import Mem0Store
import EmbeddedPG
@testable import Mem0PgStore

/// Benchmarks for the embedded Postgres lane — insert throughput, HNSW build +
/// search latency, and the headline head-to-head vs the sqlite-vec brute-force
/// store. Double-gated: needs CODEX_MEM0_PG_TEST=1 AND CODEX_MEM0_PG_BENCH=1
/// (they're slow + print a report rather than assert hard).
///
///   CODEX_MEM0_PG_TEST=1 CODEX_MEM0_PG_BENCH=1 swift test --filter PGBenchmarks
///
/// Scale is `CODEX_MEM0_PG_BENCH_N` rows (default 5000) × 384 dims.
final class PGBenchmarks: XCTestCase {
    private var benchEnabled: Bool {
        ProcessInfo.processInfo.environment["CODEX_MEM0_PG_TEST"] == "1" &&
        ProcessInfo.processInfo.environment["CODEX_MEM0_PG_BENCH"] == "1"
    }
    private var N: Int { Int(ProcessInfo.processInfo.environment["CODEX_MEM0_PG_BENCH_N"] ?? "") ?? 5000 }
    private let dims = 384

    // deterministic pseudo-random vectors (LCG — no Math.random / Date dependency)
    private func vectors(_ n: Int, _ d: Int, seed: UInt64) -> [[Float]] {
        var s = seed
        func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 23) - 1 }
        return (0..<n).map { _ in (0..<d).map { _ in next() } }
    }
    private func literal(_ v: [Float]) -> String { "[" + v.map { String($0) }.joined(separator: ",") + "]" }
    private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    private func pct(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); return s[min(s.count - 1, Int(p * Double(s.count)))]
    }
    private func report(_ s: String) { print("📊 BENCH | \(s)") }

    // MARK: insert throughput (single-row vs batched)

    func testBenchInsertThroughput() async throws {
        try XCTSkipUnless(benchEnabled, "set CODEX_MEM0_PG_TEST=1 CODEX_MEM0_PG_BENCH=1")
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("CREATE EXTENSION IF NOT EXISTS vector")
            try await db.exec("CREATE TABLE bt (id int, v vector(\(self.dims)))")
            let data = self.vectors(self.N, self.dims, seed: 1)
            let clock = ContinuousClock()

            // single-row inserts (first 1000 only — slow)
            let singleCount = min(1000, self.N)
            let t1 = clock.now
            for i in 0..<singleCount {
                try await db.exec("INSERT INTO bt VALUES (\(i), '\(self.literal(data[i]))')")
            }
            let single = self.ms(clock.now - t1)
            self.report(String(format: "single-row insert: %d rows in %.0f ms = %.0f rows/s",
                               singleCount, single, Double(singleCount) / (single / 1000)))

            // batched multi-row inserts (chunks of 500)
            try await db.exec("TRUNCATE bt")
            let t2 = clock.now
            var i = 0
            while i < self.N {
                let chunk = Array(i..<min(i + 500, self.N))
                let values = chunk.map { "(\($0), '\(self.literal(data[$0]))')" }.joined(separator: ",")
                try await db.exec("INSERT INTO bt VALUES \(values)")
                i += 500
            }
            let batched = self.ms(clock.now - t2)
            self.report(String(format: "batched insert:    %d rows in %.0f ms = %.0f rows/s (%.1f× single)",
                               self.N, batched, Double(self.N) / (batched / 1000),
                               (Double(self.N) / batched) / (Double(singleCount) / single)))
            let total = try await db.int("SELECT count(*)::int FROM bt")
            XCTAssertEqual(total, self.N)
        }
    }

    // MARK: HNSW build + search latency (HNSW vs seq-scan)

    func testBenchHnswBuildAndSearch() async throws {
        try XCTSkipUnless(benchEnabled, "set CODEX_MEM0_PG_TEST=1 CODEX_MEM0_PG_BENCH=1")
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("CREATE EXTENSION IF NOT EXISTS vector")
            try await db.exec("CREATE TABLE bv (id int, v vector(\(self.dims)))")
            let data = self.vectors(self.N, self.dims, seed: 2)
            var i = 0
            while i < self.N {
                let chunk = Array(i..<min(i + 500, self.N))
                try await db.exec("INSERT INTO bv VALUES " + chunk.map { "(\($0), '\(self.literal(data[$0]))')" }.joined(separator: ","))
                i += 500
            }
            let clock = ContinuousClock()
            try await db.exec("SET maintenance_work_mem='512MB'")
            let tb = clock.now
            try await db.exec("CREATE INDEX bv_hnsw ON bv USING hnsw (v vector_l2_ops)")
            self.report(String(format: "HNSW build: %d×%d in %.0f ms", self.N, self.dims, self.ms(clock.now - tb)))
            try await db.exec("ANALYZE bv")

            let queries = self.vectors(100, self.dims, seed: 99)
            // HNSW search latency
            try await db.exec("SET enable_seqscan=on")
            var hnsw: [Double] = []
            for q in queries {
                let t = clock.now
                _ = try await db.int("SELECT id FROM bv ORDER BY v <-> '\(self.literal(q))' LIMIT 10")
                hnsw.append(self.ms(clock.now - t))
            }
            self.report(String(format: "HNSW search (k=10):     p50=%.2f ms  p99=%.2f ms", self.pct(hnsw, 0.50), self.pct(hnsw, 0.99)))
            // seq-scan (exact) latency for comparison
            try await db.exec("SET enable_indexscan=off"); try await db.exec("SET enable_seqscan=on")
            var seq: [Double] = []
            for q in queries.prefix(20) {
                let t = clock.now
                _ = try await db.int("SELECT id FROM bv ORDER BY v <-> '\(self.literal(q))' LIMIT 10")
                seq.append(self.ms(clock.now - t))
            }
            self.report(String(format: "seq-scan search (k=10): p50=%.2f ms  → HNSW is %.1f× faster",
                               self.pct(seq, 0.50), self.pct(seq, 0.50) / max(self.pct(hnsw, 0.50), 0.001)))
        }
    }

    // MARK: headline — embedded-PG HNSW vs sqlite-vec brute-force (same dataset)

    func testBenchPgHnswVsSqliteVecBruteForce() async throws {
        try XCTSkipUnless(benchEnabled, "set CODEX_MEM0_PG_TEST=1 CODEX_MEM0_PG_BENCH=1")
        let data = vectors(N, dims, seed: 7)
        let records = data.enumerated().map { (i, v) in
            VectorRecord(id: "r\(i)", vector: v, payload: ["user_id": .string("u")])
        }
        let queries = vectors(50, dims, seed: 77)
        let clock = ContinuousClock()

        // sqlite-vec brute-force
        let sqlite = try Mem0SQLiteStore(path: ":memory:")
        try await sqlite.insert(records)
        var sq: [Double] = []
        for q in queries {
            let t = clock.now
            _ = try await sqlite.search("", q, topK: 10, filters: ["user_id": .string("u")])
            sq.append(ms(clock.now - t))
        }
        report(String(format: "sqlite-vec brute-force search (n=%d, k=10): p50=%.2f ms  p99=%.2f ms", N, pct(sq, 0.50), pct(sq, 0.99)))

        // embedded-PG HNSW
        try await PGTestHarness.withCluster(dims: dims) { pg, _, _ in
            try await pg.insert(records)
            var pgL: [Double] = []
            for q in queries {
                let t = clock.now
                _ = try await pg.search("", q, topK: 10, filters: ["user_id": .string("u")])
                pgL.append(self.ms(clock.now - t))
            }
            self.report(String(format: "embedded-PG HNSW search       (n=%d, k=10): p50=%.2f ms  p99=%.2f ms", self.N, self.pct(pgL, 0.50), self.pct(pgL, 0.99)))
            self.report(String(format: "→ embedded-PG HNSW is %.0f× FASTER than sqlite-vec brute-force at n=%d (gap widens with n)",
                               self.pct(sq, 0.50) / max(self.pct(pgL, 0.50), 0.001), self.N))
        }
    }

    // MARK: cluster cold-spawn latency

    func testBenchClusterSpawnLatency() async throws {
        try XCTSkipUnless(benchEnabled, "set CODEX_MEM0_PG_TEST=1 CODEX_MEM0_PG_BENCH=1")
        let clock = ContinuousClock()
        let t = clock.now
        try await PGTestHarness.withRawConnection { db, _ in
            self.report(String(format: "cold spawn (initdb + postmaster + provision + connect): %.0f ms", self.ms(clock.now - t)))
            _ = try await db.int("SELECT 1")
        }
    }
}
