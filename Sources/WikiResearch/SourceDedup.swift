import Foundation

/// Source dedupe + selection (§ "Phase 2b": dedupe exact URL, then >80% cosine
/// overlap keep higher-credibility; rank by credibility×agent-quality; select
/// top-N). Pure: the cosine metric is built in but the embeddings are carried on
/// the sources, so this is fully deterministic and testable.
public enum SourceDedup {

    /// Canonicalize a URL for exact-dup detection: lowercase host, drop scheme,
    /// a trailing slash, a leading `www.`, and the fragment.
    public static func canonicalURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") { s = String(s[s.startIndex..<hash]) }
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if s.lowercased().hasPrefix("www.") { s = String(s.dropFirst(4)) }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        // lowercase the host portion only (path can be case-sensitive)
        if let slash = s.firstIndex(of: "/") {
            return s[s.startIndex..<slash].lowercased() + s[slash...]
        }
        return s.lowercased()
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count { dot += Double(a[i] * b[i]); na += Double(a[i] * a[i]); nb += Double(b[i] * b[i]) }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Dedupe and rank. Survivors are ordered by rankScore (credibility×agent-quality)
    /// descending; `keep` (default all) bounds the final selection.
    public static func dedupe(_ sources: [RankedSource], threshold: Double = 0.8,
                              keep: Int? = nil) -> [RankedSource] {
        // 1. Exact-URL dedupe: among same canonical URL, keep highest credibility.
        var byURL: [String: RankedSource] = [:]
        for s in sources {
            let key = canonicalURL(s.url)
            if let existing = byURL[key] {
                if s.credibility > existing.credibility { byURL[key] = s }
            } else {
                byURL[key] = s
            }
        }
        // Process in a stable, credibility-first order so the higher-credibility
        // member of a near-duplicate pair is the one retained.
        let urlUnique = byURL.values.sorted {
            $0.rankScore != $1.rankScore ? $0.rankScore > $1.rankScore : $0.url < $1.url
        }
        // 2. Cosine-overlap dedupe (>threshold): keep the already-accepted (higher
        // rank) source, drop the new near-duplicate.
        var survivors: [RankedSource] = []
        for s in urlUnique {
            if let emb = s.embedding,
               survivors.contains(where: { $0.embedding.map { cosine($0, emb) > threshold } ?? false }) {
                continue
            }
            survivors.append(s)
        }
        if let keep, keep < survivors.count { return Array(survivors.prefix(keep)) }
        return survivors
    }
}
