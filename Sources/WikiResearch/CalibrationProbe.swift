import Foundation
import MemoryStore

/// Closes the contradiction→supersession→calibration loop (gbrain.md Wave 3.26):
/// turns a judged claim pair + its resolved action into a graded `ResolvedItem`, so
/// per-domain Brier / accuracy actually generate (CalibrationScorer had ZERO callers).
/// Pure; exhaustively testable.
///
/// Every prediction is scored on ONE axis — the judge's confidence-IN-CONFLICT — so
/// Brier is comparable across verdicts:
///   • mutating action (archiveOlder / markBothContradicted): the judge committed to a
///     real conflict → outcome 1.0, confidence = judge confidence.
///   • skip (a definitive noContradiction): the judge committed to NO conflict → reframe
///     as confidence-in-conflict = 1 − confidence, outcome 0.0.
///   • flagForReview (mid-confidence OR regression/evolution/negation artifact): genuinely
///     unresolvable → outcome nil (counted in coverage, excluded from Brier).
/// Domain = the OLDER claim's `category` (the claim whose lifecycle the verdict judges),
/// falling back to `defaultDomain` so a card is always produced.
public enum CalibrationProbe {
    public static let defaultDomain = "uncategorized"

    public static func resolvedItem(for verdict: JudgedPair, a: ClaimRow, b: ClaimRow,
                                    action: SupersessionAction) -> ResolvedItem {
        let older = a.firstSeen <= b.firstSeen ? a : b
        let domain = older.category ?? defaultDomain
        let conf = verdict.confidence
        switch action {
        case .archiveOlder, .markBothContradicted:
            return ResolvedItem(domain: domain, confidence: conf, outcome: 1.0)
        case .skip:
            return ResolvedItem(domain: domain, confidence: 1 - conf, outcome: 0.0)
        case .flagForReview:
            return ResolvedItem(domain: domain, confidence: conf, outcome: nil)
        }
    }
}
