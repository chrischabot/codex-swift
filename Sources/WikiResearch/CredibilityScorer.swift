import Foundation

/// Independent credibility arithmetic (§ "Credibility Scoring (Phase 2b)"). The
/// point math is LOCAL over the signals the agent surfaced; the agent's own
/// self-rating never enters here (independence is structural — no fox guarding the
/// henhouse).
public enum CredibilityScorer {

    /// Sum the signal points with the non-stacking bias rule, then assign a tier.
    public static func score(_ s: CredibilitySignals) -> CredibilityResult {
        var p = 0
        if s.peerReviewed { p += 2 }
        if s.recent { p += 1 }
        if s.veryOld { p -= 1 }
        if s.knownAuthor { p += 1 }
        // Non-stacking rule: bias and vendor-primary are refinements of the SAME
        // concern (promotional framing). If both fire, apply only -1, not -2.
        if s.biasDetected || s.vendorPrimary { p -= 1 }
        p += max(0, min(s.corroboratingAgents, 2))   // +1 per agent, capped at +2
        return CredibilityResult(points: p, tier: tier(points: p))
    }

    /// High 4-6 / Medium 2-3 / Low 0-1 / Reject <0.
    public static func tier(points: Int) -> TrustTier {
        switch points {
        case 4...:    return .high
        case 2...3:   return .medium
        case 0...1:   return .low
        default:      return .reject
        }
    }
}
