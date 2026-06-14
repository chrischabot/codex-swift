import Foundation

/// Gap scoring (§ "Gap Scoring (Plan Reflection)"). Composite = Impact ×
/// Feasibility × Specificity (each 1-5, range 1-125); the next round drills the
/// top 3 by composite. Pure arithmetic — the gap *discovery* is the frontier
/// reflection agent's job; the multiply/sort/top-3 is local.
public enum GapScorer {

    /// Top-N gaps by composite score (default 3), highest first. Ties broken by
    /// impact then description for determinism.
    public static func topGaps(_ gaps: [Gap], n: Int = 3) -> [Gap] {
        let ranked = gaps.sorted {
            if $0.composite != $1.composite { return $0.composite > $1.composite }
            if $0.impact != $1.impact { return $0.impact > $1.impact }
            return $0.description < $1.description
        }
        return Array(ranked.prefix(max(0, n)))
    }

    public static func anyHighImpact(_ gaps: [Gap]) -> Bool { gaps.contains { $0.isHighImpact } }
}
