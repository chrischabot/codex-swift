import Foundation

/// Scoring utilities for hybrid retrieval, ported exactly from
/// `mem0-rs/crates/mem0-core/src/scoring.rs` (which itself mirrors mem0's
/// `utils/scoring.py`). Pure arithmetic — bit-for-bit faithful.
public enum Mem0Scoring {
    /// Entity-boost weight in the additive combine.
    public static let entityBoostWeight: Double = 0.5

    /// Query-length-adaptive BM25 sigmoid parameters `(midpoint, steepness)`.
    /// Port of `get_bm25_params`.
    public static func bm25Params(_ query: String, lemmatized: String? = nil) -> (Double, Double) {
        let lem = lemmatized ?? Mem0NLP.lemmatizeForBM25(query)
        let numTerms = lem.isEmpty ? 1 : lem.split(separator: " ").count
        switch numTerms {
        case ..<4: return (5.0, 0.7)
        case ..<7: return (7.0, 0.6)
        case ..<10: return (9.0, 0.5)
        case ..<16: return (10.0, 0.5)
        default: return (12.0, 0.5)
        }
    }

    /// Logistic-sigmoid normalization of a raw BM25 score to [0, 1]. Port of
    /// `normalize_bm25`.
    public static func normalizeBM25(_ raw: Double, midpoint: Double, steepness: Double) -> Double {
        1.0 / (1.0 + exp(-steepness * (raw - midpoint)))
    }

    /// Score candidates additively and return the top-k. Port of
    /// `score_and_rank`: the threshold gates the SEMANTIC score before
    /// combining; the divisor adapts to which signals are present
    /// (semantic 1.0; +1.0 if BM25; +0.5 if entity boosts).
    public static func scoreAndRank(_ semantic: [SearchHit],
                                    bm25: [String: Double],
                                    entityBoosts: [String: Double],
                                    threshold: Double,
                                    topK: Int) -> [SearchHit] {
        let hasBM25 = !bm25.isEmpty
        let hasEntity = !entityBoosts.isEmpty
        var maxPossible = 1.0
        if hasBM25 { maxPossible += 1.0 }
        if hasEntity { maxPossible += entityBoostWeight }

        var scored: [SearchHit] = []
        for result in semantic {
            let semanticScore = result.score
            if semanticScore < threshold { continue }
            let b = bm25[result.id] ?? 0.0
            let e = entityBoosts[result.id] ?? 0.0
            let combined = min((semanticScore + b + e) / maxPossible, 1.0)
            scored.append(SearchHit(id: result.id, score: combined, payload: result.payload))
        }
        scored.sort { $0.score > $1.score }
        if scored.count > topK { scored = Array(scored.prefix(topK)) }
        return scored
    }

    /// BM25 (k1=1.5, b=0.75) over a corpus of `(id, lemmatizedText)`. `query`
    /// must already be lemmatized. Returns id → score for docs scoring > 0.
    /// Mirrors the Rust `bm25_scores` corpus scorer (and the project's
    /// ToolRouter BM25-lite).
    public static func bm25Scores(_ query: String, corpus: [(String, String)]) -> [String: Double] {
        let k1 = 1.5
        let b = 0.75
        let n = corpus.count
        if n == 0 { return [:] }
        let qList = Array(Set(query.split(separator: " ")))
        let q = qList.count
        if q == 0 { return [:] }
        var qIndex = [Substring: Int](minimumCapacity: q)
        for (i, t) in qList.enumerated() { qIndex[t] = i }

        var docData: [(id: String, dl: Int, counts: [Int])] = []
        docData.reserveCapacity(n)
        var df = [Int](repeating: 0, count: q)
        var totalLen = 0
        for (id, text) in corpus {
            var counts = [Int](repeating: 0, count: q)
            var dl = 0
            for tok in text.split(separator: " ") {
                dl += 1
                if let qi = qIndex[tok] { counts[qi] += 1 }
            }
            for qi in 0..<q where counts[qi] > 0 { df[qi] += 1 }
            totalLen += dl
            docData.append((id, dl, counts))
        }
        let avgdl = Double(totalLen) / Double(n)

        var idf = [Double](repeating: 0, count: q)
        for qi in 0..<q {
            let dft = df[qi]
            idf[qi] = dft == 0 ? 0 : log((Double(n) - Double(dft) + 0.5) / (Double(dft) + 0.5) + 1.0)
        }

        var out: [String: Double] = [:]
        for d in docData {
            var score = 0.0
            let dl = Double(d.dl)
            for qi in 0..<q {
                let count = d.counts[qi]
                if count == 0 { continue }
                let tf = Double(count)
                let denom = tf + k1 * (1 - b + b * (dl / avgdl))
                score += idf[qi] * (tf * (k1 + 1)) / denom
            }
            if score > 0 { out[d.id] = score }
        }
        return out
    }
}