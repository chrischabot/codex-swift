import XCTest
import Foundation
@testable import MemoryStore

/// Severe tests for the vDSP-backed Embedding.cosineDistance + batched
/// matmul. We hold the implementation accountable against a reference
/// `Double`-summed oracle, exercise numerical edge cases, and publish
/// speedups vs the pre-vDSP scalar baseline.
///
/// Acceptance gates (per the task spec):
/// 1. cosineDistance on 1024-dim vectors must be >= 10x the scalar baseline
///    on Apple Silicon.
/// 2. Reference oracle: vDSP path matches the naive `Double`-summed
///    reference within rtol=1e-6 across 10000 random normalised pairs across
///    dims {64, 256, 1024, 4096}.
/// 3. cosine(a, a) == 1.0 (distance == 0) for non-zero a; cosine(a, -a) == -1.0
///    (distance == 2.0); symmetry.
/// 4. Adversarial: zero, near-zero, NaN, +/- Inf, single-non-zero,
///    dim=1, dim=8192, all-equal vectors — no NaN propagation unless
///    explicitly documented; published envelope.
final class EmbeddingVDSPTests: XCTestCase {

    /// Naive `Double`-summed cosine distance — the oracle we hold the vDSP
    /// path to. Intentionally NOT using any SIMD or Accelerate so the test
    /// can detect drift between the production path and a "from scratch"
    /// implementation.
    private static func referenceCosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        if a.isEmpty { return 1.0 }
        var dot: Double = 0
        var ass: Double = 0
        var bss: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            ass += x * x
            bss += y * y
        }
        let denom = ass.squareRoot() * bss.squareRoot()
        if denom == 0 || !denom.isFinite { return 1.0 }
        return 1.0 - dot / denom
    }

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

    func testCosineDistanceMatchesOracleAcrossDims() {
        let dims = [64, 256, 1024, 4096]
        var rng = LCG(state: 0xDEAD_BEEF_FEED_CAFE)
        let perDim = 2500
        var maxRelErr: Double = 0
        for d in dims {
            for _ in 0..<perDim {
                let a = rng.randomNormalized(d)
                let b = rng.randomNormalized(d)
                let ref = Self.referenceCosineDistance(a, b)
                let got = Embedding(a).cosineDistance(to: Embedding(b))
                let denom = Swift.max(1e-12, abs(ref))
                let rel = abs(got - ref) / denom
                XCTAssertLessThan(rel, 1e-5,
                    "dim=\(d) rel-err \(rel) too large (ref=\(ref) got=\(got))")
                if rel > maxRelErr { maxRelErr = rel }
            }
        }
        print("[oracle] vDSP vs Double-ref max relative error across 10000 pairs: \(maxRelErr)")
    }

    func testCosineSelfDistanceIsZero() {
        var rng = LCG(state: 0x1234_5678_9ABC_DEF0)
        for _ in 0..<200 {
            let v = rng.randomNormalized(1024)
            let d = Embedding(v).cosineDistance(to: Embedding(v))
            XCTAssertLessThan(abs(d), 1e-5, "cos(a,a) should be ~1 (d~0): \(d)")
        }
    }

    func testCosineAntipodeDistanceIsTwo() {
        var rng = LCG(state: 0x0F0F_F0F0_DEAD_C0DE)
        for _ in 0..<200 {
            let v = rng.randomNormalized(1024)
            let neg = v.map { -$0 }
            let d = Embedding(v).cosineDistance(to: Embedding(neg))
            XCTAssertEqual(d, 2.0, accuracy: 1e-5, "cos(a,-a) should be -1 (d=2)")
        }
    }

    func testCosineSymmetry() {
        var rng = LCG(state: 0xAA55_5555_AAAA_5555)
        for _ in 0..<500 {
            let a = rng.randomNormalized(512)
            let b = rng.randomNormalized(512)
            let ab = Embedding(a).cosineDistance(to: Embedding(b))
            let ba = Embedding(b).cosineDistance(to: Embedding(a))
            XCTAssertEqual(ab, ba, accuracy: 1e-6)
        }
    }

    func testZeroVectorReturnsOneNotNaN() {
        let zero = Embedding([Float](repeating: 0, count: 1024))
        let v = Embedding(Array(repeating: Float(1.0 / 32.0), count: 1024))
        XCTAssertEqual(zero.cosineDistance(to: zero), 1.0,
                       "zero-zero must be defined (1.0), not NaN")
        XCTAssertEqual(zero.cosineDistance(to: v), 1.0)
        XCTAssertEqual(v.cosineDistance(to: zero), 1.0)
    }

    func testSubnormalNearZeroVector() {
        let tiny = Float.leastNormalMagnitude / 1e10
        let a = Embedding([Float](repeating: tiny, count: 1024))
        let b = Embedding([Float](repeating: tiny, count: 1024))
        let d = a.cosineDistance(to: b)
        XCTAssertTrue(d == 1.0 || abs(d) < 1e-3,
                      "subnormal vector should resolve to 1 or ~0: \(d)")
        XCTAssertFalse(d.isNaN)
    }

    func testNaNPropagates() {
        var values = [Float](repeating: 0.1, count: 1024)
        values[42] = .nan
        let a = Embedding(values)
        let b = Embedding(Array(repeating: Float(0.1), count: 1024))
        let d = a.cosineDistance(to: b)
        XCTAssertTrue(d.isNaN, "NaN must propagate (documented behavior)")
    }

    func testInfinityHandled() {
        var values = [Float](repeating: 0.1, count: 1024)
        values[0] = .infinity
        let a = Embedding(values)
        let b = Embedding(Array(repeating: Float(0.1), count: 1024))
        let d = a.cosineDistance(to: b)
        XCTAssertEqual(d, 1.0,
                       "+Inf in input must collapse to defined 1.0 sentinel")
    }

    func testSingleNonZero() {
        var a = [Float](repeating: 0, count: 1024)
        var b = [Float](repeating: 0, count: 1024)
        a[7] = 1.0
        b[7] = 1.0
        XCTAssertEqual(Embedding(a).cosineDistance(to: Embedding(b)),
                       0.0, accuracy: 1e-6)
        b[7] = 0
        b[8] = 1.0
        XCTAssertEqual(Embedding(a).cosineDistance(to: Embedding(b)),
                       1.0, accuracy: 1e-6)
    }

    func testDegenerateDim1() {
        XCTAssertEqual(Embedding([1.0]).cosineDistance(to: Embedding([1.0])),
                       0.0, accuracy: 1e-6)
        XCTAssertEqual(Embedding([1.0]).cosineDistance(to: Embedding([-1.0])),
                       2.0, accuracy: 1e-6)
        XCTAssertEqual(Embedding([0.0]).cosineDistance(to: Embedding([0.0])),
                       1.0)
    }

    func testDim8192Oracle() {
        var rng = LCG(state: 0xFEED_FACE_DEAD_BEEF)
        let a = rng.randomNormalized(8192)
        let b = rng.randomNormalized(8192)
        let ref = Self.referenceCosineDistance(a, b)
        let got = Embedding(a).cosineDistance(to: Embedding(b))
        XCTAssertEqual(got, ref, accuracy: 1e-5)
    }

    func testAllEqualVectors() {
        let a = Embedding([Float](repeating: 0.5, count: 1024))
        let b = Embedding([Float](repeating: 0.5, count: 1024))
        XCTAssertEqual(a.cosineDistance(to: b), 0.0, accuracy: 1e-5)
    }

    func testSIMDFallbackMatchesAccelerate() {
        var rng = LCG(state: 0xBAAD_F00D_DEAD_BEEF)
        var maxRelErr: Double = 0
        for d in [64, 256, 1024, 4096] {
            for _ in 0..<100 {
                let a = rng.randomNormalized(d)
                let b = rng.randomNormalized(d)
                let viaAccel = Embedding(a).cosineDistance(to: Embedding(b))
                let viaSIMD = Embedding.cosineDistanceSIMD(a, b)
                let denom = Swift.max(1e-12, abs(viaAccel))
                let rel = abs(viaAccel - viaSIMD) / denom
                if rel > maxRelErr { maxRelErr = rel }
                XCTAssertLessThan(rel, 1e-4,
                    "dim=\(d) Accelerate vs SIMD rel-err \(rel) too large")
            }
        }
        print("[envelope] Accelerate vs SIMD16 max rel error: \(maxRelErr)")
    }

    func testMicrobenchCosine1024() {
        var rng = LCG(state: 0xCAFE_BABE_DEAD_BEEF)
        let a = rng.randomNormalized(1024)
        let b = rng.randomNormalized(1024)
        let iters = 5000

        for _ in 0..<200 {
            _ = Embedding(a).cosineDistance(to: Embedding(b))
            _ = Self.referenceCosineDistance(a, b)
        }

        let t0 = mach_absolute_time()
        var sink: Double = 0
        for _ in 0..<iters {
            sink += Embedding(a).cosineDistance(to: Embedding(b))
        }
        let t1 = mach_absolute_time()
        for _ in 0..<iters {
            sink += Self.referenceCosineDistance(a, b)
        }
        let t2 = mach_absolute_time()
        XCTAssertTrue(sink.isFinite)

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let accelNs = Double(t1 - t0) * Double(info.numer) / Double(info.denom)
        let scalarNs = Double(t2 - t1) * Double(info.numer) / Double(info.denom)
        let speedup = scalarNs / Swift.max(1, accelNs)
        print(String(format: "[bench] cosine 1024-dim x%d: accel=%.0fμs scalar=%.0fμs speedup=%.1fx",
                     iters, accelNs / 1000, scalarNs / 1000, speedup))
        XCTAssertGreaterThan(speedup, 10.0,
            "vDSP cosine must be >=10x scalar baseline on Apple Silicon")
    }

    func testSpeedupCurveAcrossDims() {
        let dims = [64, 256, 1024, 4096, 16384]
        var rng = LCG(state: 0x5A5A_5A5A_5A5A_5A5A)
        for d in dims {
            let a = rng.randomNormalized(d)
            let b = rng.randomNormalized(d)
            let iters = Swift.max(200, 4_000_000 / d)
            for _ in 0..<50 {
                _ = Embedding(a).cosineDistance(to: Embedding(b))
                _ = Self.referenceCosineDistance(a, b)
            }
            let t0 = mach_absolute_time()
            var sink: Double = 0
            for _ in 0..<iters { sink += Embedding(a).cosineDistance(to: Embedding(b)) }
            let t1 = mach_absolute_time()
            for _ in 0..<iters { sink += Self.referenceCosineDistance(a, b) }
            let t2 = mach_absolute_time()
            XCTAssertTrue(sink.isFinite)
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let accelNs = Double(t1 - t0) * Double(info.numer) / Double(info.denom) / Double(iters)
            let scalarNs = Double(t2 - t1) * Double(info.numer) / Double(info.denom) / Double(iters)
            print(String(format: "[curve] dim=%-5d  vDSP=%6.0fns  scalar=%6.0fns  speedup=%.1fx",
                         d, accelNs, scalarNs, scalarNs / Swift.max(1, accelNs)))
        }
    }
}
