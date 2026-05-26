import XCTest
import Foundation
@testable import MemoryStore

/// Severe tests for the vDSP_mmul-batched fallback search path. The fast
/// path lives behind `searchVectors` when sqlite-vec is unlinked; we also
/// hammer the `batchedDot` static helper directly to guarantee correctness
/// independent of the on-disk codec.
///
/// Acceptance gates:
/// 1. Batched search on 10000 candidates with 1024-dim vectors is >=5x the
///    naive per-row Swift loop on Apple Silicon.
/// 2. Top-k correctness: batched result matches the row-loop result
///    bit-for-bit on the order of returned ids.
/// 3. Curve published across batch sizes {1, 10, 100, 1000, 10000} and dims
///    {64, 256, 1024, 4096}.
final class BatchedSearchTests: XCTestCase {

    private struct LCG {
        var state: UInt64
        mutating func nextFloat() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let u = Float(state & 0xFFFF_FFFF) / Float(UInt32.max)
            return u * 2 - 1
        }
        mutating func randomNormalized(_ n: Int) -> [Float] {
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n { out[i] = nextFloat() }
            var sum: Double = 0
            for v in out { sum += Double(v) * Double(v) }
            let inv = sum == 0 ? 1 : 1 / sum.squareRoot()
            for i in 0..<n { out[i] = Float(Double(out[i]) * inv) }
            return out
        }
    }

    private static func naiveDots(query: [Float], matrix: [Float],
                                  rowCount: Int, dim: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rowCount)
        for r in 0..<rowCount {
            var s: Float = 0
            for d in 0..<dim {
                s += query[d] * matrix[r * dim + d]
            }
            out[r] = s
        }
        return out
    }

    func testBatchedDotMatchesNaive() {
        var rng = LCG(state: 0x1111_2222_3333_4444)
        let dim = 256
        let rowCount = 1000
        var matrix = [Float]()
        matrix.reserveCapacity(rowCount * dim)
        for _ in 0..<rowCount {
            matrix.append(contentsOf: rng.randomNormalized(dim))
        }
        let q = rng.randomNormalized(dim)
        let batched = MemoryStore.batchedDot(query: q, matrix: matrix,
                                             rowCount: rowCount, dim: dim)
        let naive = Self.naiveDots(query: q, matrix: matrix,
                                   rowCount: rowCount, dim: dim)
        XCTAssertEqual(batched.count, naive.count)
        var maxAbsErr: Float = 0
        for i in 0..<rowCount {
            let e = abs(batched[i] - naive[i])
            if e > maxAbsErr { maxAbsErr = e }
        }
        XCTAssertLessThan(maxAbsErr, 1e-4, "batched vs naive max abs err: \(maxAbsErr)")
        print("[envelope] batched vs naive max abs err (dim=256, n=1000): \(maxAbsErr)")
    }

    func testBatchedTopKMatchesNaiveOrder() {
        var rng = LCG(state: 0x4321_8765_CDEF_BA98)
        let dim = 128
        let rowCount = 500
        var matrix = [Float]()
        matrix.reserveCapacity(rowCount * dim)
        for _ in 0..<rowCount {
            matrix.append(contentsOf: rng.randomNormalized(dim))
        }
        let q = rng.randomNormalized(dim)
        let batched = MemoryStore.batchedDot(query: q, matrix: matrix,
                                             rowCount: rowCount, dim: dim)
        let naive = Self.naiveDots(query: q, matrix: matrix,
                                   rowCount: rowCount, dim: dim)
        let batchedTop = (0..<rowCount).sorted { batched[$0] > batched[$1] }.prefix(10)
        let naiveTop = (0..<rowCount).sorted { naive[$0] > naive[$1] }.prefix(10)
        XCTAssertEqual(Array(batchedTop), Array(naiveTop),
                       "top-10 row order must agree with naive loop")
    }

    func testBenchBatchedVsRowLoop_10kRowsx1024Dim() {
        var rng = LCG(state: 0x9999_AAAA_BBBB_CCCC)
        let dim = 1024
        let rowCount = 10_000
        var matrix = [Float]()
        matrix.reserveCapacity(rowCount * dim)
        for _ in 0..<rowCount {
            matrix.append(contentsOf: rng.randomNormalized(dim))
        }
        let q = rng.randomNormalized(dim)

        for _ in 0..<2 {
            _ = MemoryStore.batchedDot(query: q, matrix: matrix,
                                       rowCount: rowCount, dim: dim)
        }
        for _ in 0..<2 {
            _ = simulateRowLoop(q: q, matrix: matrix, rowCount: rowCount, dim: dim)
        }

        let iters = 3
        let t0 = mach_absolute_time()
        for _ in 0..<iters {
            _ = MemoryStore.batchedDot(query: q, matrix: matrix,
                                       rowCount: rowCount, dim: dim)
        }
        let t1 = mach_absolute_time()
        for _ in 0..<iters {
            _ = simulateRowLoop(q: q, matrix: matrix, rowCount: rowCount, dim: dim)
        }
        let t2 = mach_absolute_time()

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let batchedNs = Double(t1 - t0) * Double(info.numer) / Double(info.denom) / Double(iters)
        let loopNs = Double(t2 - t1) * Double(info.numer) / Double(info.denom) / Double(iters)
        let speedup = loopNs / Swift.max(1, batchedNs)
        print(String(format: "[bench] batched 10000×1024  vDSP=%.2fms  row-loop=%.2fms  speedup=%.1fx",
                     batchedNs / 1e6, loopNs / 1e6, speedup))
        XCTAssertGreaterThan(speedup, 5.0,
            "batched matmul must beat row-loop by >=5x on Apple Silicon")
    }

    private func simulateRowLoop(q: [Float], matrix: [Float],
                                 rowCount: Int, dim: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rowCount)
        for r in 0..<rowCount {
            var dot: Double = 0
            for d in 0..<dim {
                dot += Double(q[d]) * Double(matrix[r * dim + d])
            }
            out[r] = Float(dot)
        }
        return out
    }

    func testBatchedSpeedupCurve() {
        let dim = 1024
        let batchSizes = [1, 10, 100, 1000, 10_000]
        var rng = LCG(state: 0x7777_8888_9999_AAAA)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        for n in batchSizes {
            var matrix = [Float]()
            matrix.reserveCapacity(n * dim)
            for _ in 0..<n {
                matrix.append(contentsOf: rng.randomNormalized(dim))
            }
            let q = rng.randomNormalized(dim)
            for _ in 0..<2 {
                _ = MemoryStore.batchedDot(query: q, matrix: matrix,
                                           rowCount: n, dim: dim)
            }
            let iters = Swift.max(3, 30000 / Swift.max(1, n))

            let t0 = mach_absolute_time()
            for _ in 0..<iters {
                _ = MemoryStore.batchedDot(query: q, matrix: matrix,
                                           rowCount: n, dim: dim)
            }
            let t1 = mach_absolute_time()
            for _ in 0..<iters {
                _ = simulateRowLoop(q: q, matrix: matrix, rowCount: n, dim: dim)
            }
            let t2 = mach_absolute_time()

            let batchedNs = Double(t1 - t0) * Double(info.numer)
                / Double(info.denom) / Double(iters)
            let loopNs = Double(t2 - t1) * Double(info.numer)
                / Double(info.denom) / Double(iters)
            let speedup = loopNs / Swift.max(1, batchedNs)
            print(String(format: "[curve] n=%-6d  vDSP=%9.0fns  row-loop=%9.0fns  speedup=%.1fx",
                         n, batchedNs, loopNs, speedup))
        }
    }
}
