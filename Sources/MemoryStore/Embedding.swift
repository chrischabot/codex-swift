import Foundation

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
        var sum: Float = 0
        for v in values { sum += v * v }
        let n = sum.squareRoot()
        guard n > 0 else { return }
        for i in 0..<values.count { values[i] /= n }
    }

    public func normalised() -> Embedding {
        var copy = self
        copy.normalise()
        return copy
    }

    /// Cosine distance in [0, 2]; assumes neither side is empty.
    public func cosineDistance(to other: Embedding) -> Double {
        precondition(values.count == other.values.count,
                     "embedding dim mismatch: \(values.count) vs \(other.values.count)")
        var dot: Double = 0, a: Double = 0, b: Double = 0
        for i in 0..<values.count {
            let x = Double(values[i]); let y = Double(other.values[i])
            dot += x * y; a += x * x; b += y * y
        }
        let denom = (a.squareRoot()) * (b.squareRoot())
        if denom == 0 { return 1 }
        return 1 - (dot / denom)
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
