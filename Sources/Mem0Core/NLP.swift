import Foundation

/// Dependency-free NLP, ported from `mem0-rs/crates/mem0-core/src/nlp.rs`.
/// mem0's Python uses spaCy but degrades gracefully when it is absent; this
/// preserves the *contract*: a stable lemmatizer used symmetrically at add- and
/// search-time (consistent BM25 matching), plus PROPER/QUOTED entity extraction
/// (the POS/dependency-driven COMPOUND/NOUN cases are intentionally omitted).
public enum Mem0NLP {
    /// A compact English stopword set (subset of spaCy's list), matching the
    /// Rust port.
    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an",
        "and", "any", "are", "aren't", "as", "at", "be", "because", "been",
        "before", "being", "below", "between", "both", "but", "by", "can",
        "cannot", "could", "couldn't", "did", "didn't", "do", "does", "doesn't",
        "doing", "don't", "down", "during", "each", "few", "for", "from",
        "further", "had", "hadn't", "has", "hasn't", "have", "haven't", "having",
        "he", "her", "here", "hers", "herself", "him", "himself", "his", "how",
        "i", "if", "in", "into", "is", "isn't", "it", "its", "itself", "just",
        "me", "more", "most", "my", "myself", "no", "nor", "not", "now", "of",
        "off", "on", "once", "only", "or", "other", "our", "ours", "ourselves",
        "out", "over", "own", "same", "shan't", "she", "should", "shouldn't",
        "so", "some", "such", "than", "that", "the", "their", "theirs", "them",
        "themselves", "then", "there", "these", "they", "this", "those",
        "through", "to", "too", "under", "until", "up", "very", "was", "wasn't",
        "we", "were", "weren't", "what", "when", "where", "which", "while", "who",
        "whom", "why", "will", "with", "won't", "would", "wouldn't", "you",
        "your", "yours", "yourself", "yourselves", "s", "t", "can't", "i'm",
        "i've", "it's",
    ]

    /// Lightweight, deterministic lemmatizer used only for BM25 normalization.
    /// Port of `simple_lemma`.
    static func simpleLemma(_ s: String) -> String {
        guard s.allSatisfy({ $0.isASCII }) else { return s }
        let n = s.count
        if n > 4 && s.hasSuffix("ies") { return String(s.dropLast(3)) + "y" }
        if n > 3 && s.hasSuffix("es") { return String(s.dropLast(2)) }
        if n > 3 && s.hasSuffix("s") && !s.hasSuffix("ss") { return String(s.dropLast(1)) }
        if n > 4 && s.hasSuffix("ing") { return String(s.dropLast(3)) }
        if n > 3 && s.hasSuffix("ed") { return String(s.dropLast(2)) }
        return s
    }

    /// Lemmatize text for BM25 matching. Port of `lemmatize_for_bm25`:
    /// lowercase, drop stopwords + punctuation, light suffix normalization, and
    /// keep the original `-ing` form alongside its lemma. Always returns a value.
    public static func lemmatizeForBM25(_ text: String) -> String {
        let lower = text.lowercased()
        var tokens: [String] = []
        for raw in lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let tok = String(raw)
            if tok.isEmpty || stopwords.contains(tok) { continue }
            let lemma = simpleLemma(tok)
            if !lemma.isEmpty && lemma.allSatisfy({ $0.isLetter || $0.isNumber }) {
                tokens.append(lemma)
            }
            if tok.hasSuffix("ing") && tok != lemma {
                tokens.append(tok)
            }
        }
        return tokens.joined(separator: " ")
    }

    private static let properRE = try! NSRegularExpression(
        pattern: "[A-Z][A-Za-z0-9]+(?:\\s+[A-Z][A-Za-z0-9]+)*")
    private static let quotedDoubleRE = try! NSRegularExpression(pattern: "\"([^\"]+)\"")
    private static let quotedSingleRE = try! NSRegularExpression(pattern: "'([^']+)'")

    private static func allMatches(_ re: NSRegularExpression, _ text: String) -> [[String]] {
        let ns = text as NSString
        let res = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return res.map { m in
            (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    /// Extract `(type, text)` entity pairs: PROPER (capitalized word sequences)
    /// and QUOTED (single/double-quoted spans), deduped case-insensitively
    /// (PROPER preferred over QUOTED). Port of `extract_entities`.
    public static func extractEntities(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var seen: [String: Int] = [:]

        func push(_ type: String, _ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count <= 2 { return }
            let key = t.lowercased()
            let priority = (type == "PROPER") ? 0 : 1
            if let idx = seen[key] {
                let existingPriority = (out[idx].0 == "PROPER") ? 0 : 1
                if priority < existingPriority { out[idx] = (type, t) }
            } else {
                seen[key] = out.count
                out.append((type, t))
            }
        }

        // PROPER: capitalized word sequences.
        for groups in allMatches(properRE, text) {
            if let whole = groups.first { push("PROPER", whole) }
        }
        // QUOTED: double-quoted spans.
        for groups in allMatches(quotedDoubleRE, text) where groups.count >= 2 {
            push("QUOTED", groups[1])
        }
        // QUOTED: single-quoted spans.
        for groups in allMatches(quotedSingleRE, text) where groups.count >= 2 {
            push("QUOTED", groups[1])
        }
        return out
    }

    /// Batch entity extraction. Port of `extract_entities_batch`.
    public static func extractEntitiesBatch(_ texts: [String]) -> [[(String, String)]] {
        texts.map { extractEntities($0) }
    }
}