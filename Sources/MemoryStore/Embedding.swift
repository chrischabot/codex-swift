import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

/// Dense vector representation used end-to-end in MemoryStore. Stored in
/// SQLite either via sqlite-vec's `vec0` virtual table (preferred — brute-force
/// O(N·d) inner loop in C) or as a raw little-endian Float32 blob alongside
/// the chunk row when sqlite-vec is unavailable. Either way the on-disk byte
/// representation is identical, so a future upgrade is purely additive.
public struct Embedding: Sendable, Equatable {
    public var values: [Float]
    public init(_ values: [Float]) { self.values = values }

    public var dimension: Int { values.count }

    /// L2-normalise in place. Callers — including the LocalInferenceProvider
    /// embed path — are expected to ship normalised vectors so cosine collapses
    /// to a dot product.
    public mutating func normalise() {
        #if canImport(Accelerate)
        var sumSq: Float = 0
        vDSP_svesq(values, 1, &sumSq, vDSP_Length(values.count))
        let n = sumSq.squareRoot()
        guard n > 0, n.isFinite else { return }
        var inv = 1 / n
        vDSP_vsmul(values, 1, &inv, &values, 1, vDSP_Length(values.count))
        #else
        var sum: Float = 0
        for v in values { sum += v * v }
        let n = sum.squareRoot()
        guard n > 0 else { return }
        for i in 0..<values.count { values[i] /= n }
        #endif
    }

    public func normalised() -> Embedding {
        var copy = self
        copy.normalise()
        return copy
    }

    /// Cosine distance in [0, 2]. Uses Accelerate vDSP on Apple platforms
    /// (a single vDSP_dotpr + two vDSP_svesq calls) for an order-of-magnitude
    /// speedup over the scalar Swift loop. NaN propagation is preserved
    /// (documented behaviour); +/- Inf inputs collapse to the safe 1.0
    /// "fully dissimilar" sentinel rather than producing NaN.
    public func cosineDistance(to other: Embedding) -> Double {
        precondition(values.count == other.values.count,
                     "embedding dim mismatch: \(values.count) vs \(other.values.count)")
        if values.isEmpty { return 1.0 }
        #if canImport(Accelerate)
        return Embedding.cosineDistanceAccelerate(values, other.values)
        #else
        return Embedding.cosineDistanceSIMD(values, other.values)
        #endif
    }

    /// Reference SIMD-on-Float implementation. Exposed for tests so we can
    /// hold the Accelerate path against a from-scratch SIMD oracle (the
    /// production path always uses Accelerate when available; this is the
    /// fallback for non-Darwin and a useful second reference for the test
    /// suite to detect drift between vDSP and a hand-rolled SIMD loop).
    public static func cosineDistanceSIMD(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count)
        if a.isEmpty { return 1.0 }
        // Process in stripes of SIMD16 lanes to hide load-use latency. Tail
        // is handled scalar.
        let n = a.count
        var dot: Double = 0
        var ass: Double = 0
        var bss: Double = 0
        var i = 0
        let lane = 16
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                while i + lane <= n {
                    let av = SIMD16<Float>(
                        ap[i], ap[i+1], ap[i+2], ap[i+3],
                        ap[i+4], ap[i+5], ap[i+6], ap[i+7],
                        ap[i+8], ap[i+9], ap[i+10], ap[i+11],
                        ap[i+12], ap[i+13], ap[i+14], ap[i+15])
                    let bv = SIMD16<Float>(
                        bp[i], bp[i+1], bp[i+2], bp[i+3],
                        bp[i+4], bp[i+5], bp[i+6], bp[i+7],
                        bp[i+8], bp[i+9], bp[i+10], bp[i+11],
                        bp[i+12], bp[i+13], bp[i+14], bp[i+15])
                    dot += Double((av * bv).sum())
                    ass += Double((av * av).sum())
                    bss += Double((bv * bv).sum())
                    i += lane
                }
                while i < n {
                    let x = Double(ap[i]); let y = Double(bp[i])
                    dot += x * y; ass += x * x; bss += y * y
                    i += 1
                }
            }
        }
        return finalize(dot: dot, ass: ass, bss: bss)
    }

    #if canImport(Accelerate)
    /// vDSP-backed cosine distance. Three Accelerate calls instead of a
    /// 3000-iteration Swift loop for a 1024-dim vector. We pull the partial
    /// sums into `Double` after the SIMD reduce so the final ratio doesn't
    /// inherit the Float-summed rounding error on large dims.
    static func cosineDistanceAccelerate(_ a: [Float], _ b: [Float]) -> Double {
        let n = vDSP_Length(a.count)
        var dot: Float = 0, ass: Float = 0, bss: Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                vDSP_dotpr(ap.baseAddress!, 1, bp.baseAddress!, 1, &dot, n)
                vDSP_svesq(ap.baseAddress!, 1, &ass, n)
                vDSP_svesq(bp.baseAddress!, 1, &bss, n)
            }
        }
        return finalize(dot: Double(dot), ass: Double(ass), bss: Double(bss))
    }
    #endif

    /// Final ratio + edge-case handling shared by the Accelerate and SIMD
    /// paths. Invariants:
    ///   * empty / zero / subnormal input → 1.0 (NOT NaN)
    ///   * +/- Inf in input → 1.0 (the dot/sums become non-finite; we choose
    ///     a safe sentinel)
    ///   * NaN in input → NaN (documented: callers must filter)
    @inline(__always)
    private static func finalize(dot: Double, ass: Double, bss: Double) -> Double {
        // NaN must propagate — the production embed path should not ship
        // NaN-bearing vectors, and surfacing NaN here helps catch upstream
        // bugs rather than silently masking them.
        if dot.isNaN || ass.isNaN || bss.isNaN { return .nan }
        // Non-finite-but-not-NaN means +/- Inf slipped in. Collapse to the
        // "fully dissimilar" sentinel — that's a safer default than feeding
        // an Inf into the ranking math.
        if !dot.isFinite || !ass.isFinite || !bss.isFinite { return 1.0 }
        let denom = ass.squareRoot() * bss.squareRoot()
        if denom == 0 || !denom.isFinite { return 1.0 }
        return 1.0 - dot / denom
    }

    public func toBlob() -> Data {
        values.withUnsafeBytes { raw in Data(raw) }
    }

    /// Bridge constructor for callers that already have a `[Float]` from a
    /// MemoryInfer provider — avoids the module-name vs. type-name shadowing
    /// when both `MemoryStore` (module) and `MemoryStore` (actor) are in scope.
    public static func from(_ values: [Float]) -> Embedding { Embedding(values) }

    public init?(blob: Data) {
        guard blob.count % MemoryLayout<Float>.size == 0 else { return nil }
        let n = blob.count / MemoryLayout<Float>.size
        var out = [Float](repeating: 0, count: n)
        out.withUnsafeMutableBytes { dst in
            _ = blob.copyBytes(to: dst)
        }
        self.values = out
    }
}
