import Foundation

/// One conversation turn for salience extraction.
public struct SalienceTurn: Sendable, Equatable {
    public var role: String   // "user" | "assistant"
    public var text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}

/// A salient entity surfaced from the rolling conversation window.
public struct SalienceCandidate: Sendable, Equatable {
    public var surface: String       // the entity surface form (proper noun / @handle)
    public var occurrences: Int
    public var lastTurnIndex: Int    // 0-based index of the most recent turn it appears in
    public var userMention: Bool     // appeared in at least one user turn
    public var weight: Double
    public init(surface: String, occurrences: Int, lastTurnIndex: Int, userMention: Bool, weight: Double) {
        self.surface = surface; self.occurrences = occurrences; self.lastTurnIndex = lastTurnIndex
        self.userMention = userMention; self.weight = weight
    }
}

/// Zero-LLM entity-salience extraction over a rolling window (gbrain.md Wave 4.28)
/// — the substrate the push-context volunteer pipeline runs on. Single regex pass
/// per turn; deterministic. The salience weight (gbrain's window formula):
///   weight = (lastTurnIdx+1)/windowSize + min(occurrences,4)·0.1 + (userMention ? 0.15 : 0)
/// so recency dominates, frequency is capped, and a user-said surface beats an
/// assistant-introduced one.
public enum EntitySalience {
    /// @handles and runs of ≥1 capitalized token (a proper noun) or quoted spans.
    private static let candidatePattern =
        #"@\w{2,}|"[^"]{2,}"|\b[A-Z][\w'’.\-]*(?: [A-Z][\w'’.\-]*)*\b"#

    /// Single capitalized words that are too generic to be entities.
    static let suppress: Set<String> = [
        "I", "I'm", "The", "A", "An", "It", "This", "That", "These", "Those", "We",
        "You", "He", "She", "They", "My", "Your", "Our", "Their", "Yes", "No", "Ok",
        "OK", "Hi", "Hello", "Thanks", "Please", "What", "When", "Where", "Who",
        "Why", "How", "Is", "Are", "Was", "Were", "Do", "Does", "Did", "Can", "Could",
    ]

    public static func extract(window: [SalienceTurn], maxCandidates: Int = 12) -> [SalienceCandidate] {
        guard !window.isEmpty, let re = try? NSRegularExpression(pattern: candidatePattern) else { return [] }
        let windowSize = window.count

        struct Agg { var occurrences = 0; var lastTurn = 0; var userMention = false }
        var bySurface: [String: Agg] = [:]

        for (turnIdx, turn) in window.enumerated() {
            let ns = turn.text as NSString
            let isUser = turn.role.lowercased() == "user"
            for m in re.matches(in: turn.text, range: NSRange(location: 0, length: ns.length)) {
                var surface = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                // Normalize a quoted span to its inner text.
                if surface.hasPrefix("\"") && surface.hasSuffix("\"") && surface.count >= 2 {
                    surface = String(surface.dropFirst().dropLast())
                }
                guard !surface.isEmpty, surface.count >= 2, !suppress.contains(surface) else { continue }
                // Drop a single-token capitalized word that is a sentence-start stopword.
                if !surface.contains(" "), !surface.hasPrefix("@"), suppress.contains(surface) { continue }
                var agg = bySurface[surface] ?? Agg()
                agg.occurrences += 1
                agg.lastTurn = max(agg.lastTurn, turnIdx)
                if isUser { agg.userMention = true }
                bySurface[surface] = agg
            }
        }

        let candidates = bySurface.map { (surface, agg) -> SalienceCandidate in
            let recency = Double(agg.lastTurn + 1) / Double(windowSize)
            let freq = Double(min(agg.occurrences, 4)) * 0.1
            let userBonus = agg.userMention ? 0.15 : 0
            return SalienceCandidate(surface: surface, occurrences: agg.occurrences,
                                     lastTurnIndex: agg.lastTurn, userMention: agg.userMention,
                                     weight: recency + freq + userBonus)
        }
        // Highest weight first; tie-break on surface for determinism.
        return candidates
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.surface < $1.surface }
            .prefix(maxCandidates)
            .map { $0 }
    }
}
