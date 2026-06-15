import Foundation

/// Zero-LLM, deterministic query-intent classification (gbrain.md Wave 2.16).
/// Drives per-intent ranking weights so a name lookup leans on keyword/exact
/// match while a "latest …" query leans on recency. Misclassification degrades
/// gracefully — the full hybrid stack still runs; only the blend shifts.
public enum QueryIntent: String, Sendable, Equatable {
    case entity      // proper-noun / quoted / @handle lookups → keyword + exact bonus
    case temporal    // "latest", "recent", "in 2026" → recency on
    case event       // "launched", "Series A", "announced" → keyword boost
    case general     // everything else → the standard hybrid blend
}

/// Final-score weights for one intent. `.general` reproduces the retriever's
/// historical `0.7·rerank + 0.2·vec + 0.1·bm25` blend exactly, so classification
/// can never regress a non-special query.
public struct IntentWeights: Sendable, Equatable {
    public var bm25: Double
    public var vec: Double
    public var rerank: Double
    /// Additive bonus applied when the query exactly matches a candidate's title
    /// (applied by callers that thread the title — see Wave 2.18).
    public var exactMatchBonus: Double
    /// Whether per-source recency decay should be applied (see Wave 2.17).
    public var recencyOn: Bool
    public init(bm25: Double, vec: Double, rerank: Double,
                exactMatchBonus: Double, recencyOn: Bool) {
        self.bm25 = bm25; self.vec = vec; self.rerank = rerank
        self.exactMatchBonus = exactMatchBonus; self.recencyOn = recencyOn
    }
}

public enum QueryIntentClassifier {
    // Precedence: temporal → event → entity → general. "latest llama paper" is
    // temporal (recency dominates); "OpenAI Series A" is event (exact-phrase win).
    private static let temporalPattern =
        #"(?i)\b(latest|recent|recently|newest|today|yesterday|this (week|month|year)|last (week|month|year)|currently|nowadays|as of|in 20\d{2}|20\d{2})\b"#
    private static let eventPattern =
        #"(?i)\b(launch(ed|es|ing)?|announc\w*|releas\w*|shipp\w*|unveil\w*|acqui\w*|merger|rais(ed|ing)|funding|series [a-e]|ipo|debut\w*)\b"#
    // A quoted span, an @handle, or a run of ≥2 capitalized words (a proper noun).
    private static let entityPattern =
        #""[^"]{2,}"|@\w{2,}|\b[A-Z][\w'’.\-]+(?: [A-Z][\w'’.\-]+)+\b"#

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func classify(_ query: String) -> QueryIntent {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .general }
        if matches(temporalPattern, q) { return .temporal }
        if matches(eventPattern, q) { return .event }
        if matches(entityPattern, q) { return .entity }
        // A single Capitalized token that IS the whole query (e.g. "Mingtang").
        if !q.contains(" "), let first = q.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(first) { return .entity }
        return .general
    }

    public static func weights(for intent: QueryIntent) -> IntentWeights {
        switch intent {
        case .general:
            return IntentWeights(bm25: 0.1, vec: 0.2, rerank: 0.7, exactMatchBonus: 0.0, recencyOn: false)
        case .entity:
            return IntentWeights(bm25: 0.2, vec: 0.15, rerank: 0.65, exactMatchBonus: 0.15, recencyOn: false)
        case .temporal:
            return IntentWeights(bm25: 0.15, vec: 0.2, rerank: 0.65, exactMatchBonus: 0.0, recencyOn: true)
        case .event:
            return IntentWeights(bm25: 0.2, vec: 0.2, rerank: 0.6, exactMatchBonus: 0.0, recencyOn: false)
        }
    }

    public static func resolve(_ query: String) -> (intent: QueryIntent, weights: IntentWeights) {
        let i = classify(query)
        return (i, weights(for: i))
    }
}
