import Foundation

/// Progress scoring + termination logic (§ "Progress Scoring (0-100)"). The score
/// is the decision signal that lets multi-round research terminate on principle
/// rather than on the clock. All local arithmetic.
public enum ProgressScorer {

    /// The four weighted components, each capped, summed, clamped to 0...100.
    ///   sources    : count × 3, max 30
    ///   articles   : count × 5, max 30
    ///   cross-refs : count × 2, max max(20, existingArticles × 2)   (scales with maturity)
    ///   credibility: avg   × 4, max 20
    public static func score(_ r: RoundSignals) -> Int {
        let sources = min(r.sourcesIngested * 3, 30)
        let articles = min(r.articlesCreatedOrUpdated * 5, 30)
        let crossCap = max(20, r.existingArticles * 2)
        let crossRefs = min(r.crossRefsAdded * 2, crossCap)
        let credibility = min(max(0, Int((r.avgCredibility * 4).rounded())), 20)
        return min(100, max(0, sources + articles + crossRefs + credibility))
    }

    public static func band(_ score: Int) -> ProgressBand {
        switch score {
        case ...40:   return .minimal
        case 41...70: return .moderate
        case 71...90: return .strong
        default:      return .comprehensive
        }
    }

    /// Assess the latest round against the decision tree + trajectory triggers.
    /// `history` is the per-round scores oldest→newest (latest last).
    /// `crossRefDensity` is 0...1 (the share of articles that are cross-linked).
    public static func assess(history: [Int], anyHighImpactGaps: Bool,
                              crossRefDensity: Double, newHighImpactGaps: Bool) -> ProgressAssessment {
        let latest = history.last ?? 0

        // Decision tree.
        let decision: TerminationDecision
        if latest >= 80 {
            if anyHighImpactGaps {
                decision = .continueHighQuality
            } else if crossRefDensity > 0.60 {
                decision = .earlyCompletion
            } else {
                decision = .oneMoreRoundConnections
            }
        } else if latest < 40 {
            decision = .lowYieldWarning
        } else {
            decision = .continueNormally
        }

        // Trajectory triggers (in addition to the per-round decision).
        var flags: [TrajectoryFlag] = []
        if latest < 20 { flags.append(.stalled) }
        if isDeclining(history) { flags.append(.declining) }
        if history.count >= 2 {
            let prev = history[history.count - 2]
            if abs(latest - prev) <= 5 && !newHighImpactGaps { flags.append(.plateau) }
            if latest < 40 && prev < 40 { flags.append(.lowYieldTwoRounds) }
        }

        return ProgressAssessment(score: latest, band: band(latest), decision: decision, flags: flags)
    }

    /// 3 consecutive declines (a trailing strictly-decreasing run of ≥4 scores)
    /// whose total drop is ≥ 30 (e.g. 98→95→68→58 = -40).
    static func isDeclining(_ history: [Int]) -> Bool {
        guard history.count >= 4 else { return false }
        var i = history.count - 1
        while i - 1 >= 0 && history[i - 1] > history[i] { i -= 1 }
        let run = Array(history[i...])
        return run.count >= 4 && (run.first! - run.last!) >= 30
    }
}
