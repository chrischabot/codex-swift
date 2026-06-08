import Foundation

/// Utilities for adapting a provider's native vector width to the store width.
///
/// This is intentionally conservative: padding a 768-dim Nomic vector to a
/// 1536-dim store preserves cosine similarity among Nomic vectors, while
/// truncation is only used for embedding models with Matryoshka-style prefixes.
/// A store-level provider id still prevents mixing different vector spaces.
public enum EmbeddingDimensions {
    public static func adapt(_ values: [Float], to dimension: Int) -> [Float] {
        guard dimension > 0 else { return values }
        var out: [Float]
        if values.count == dimension {
            out = values
        } else if values.count < dimension {
            out = values + [Float](repeating: 0, count: dimension - values.count)
        } else {
            out = Array(values.prefix(dimension))
        }
        normalise(&out)
        return out
    }

    public static func normalise(_ values: inout [Float]) {
        var sum: Float = 0
        for value in values { sum += value * value }
        let norm = sum.squareRoot()
        guard norm > 0, norm.isFinite else { return }
        for index in values.indices { values[index] /= norm }
    }
}
