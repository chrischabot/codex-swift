import Foundation
import MemoryStore

/// Converts a judged claim pair into a claim-lifecycle ACTION (gbrain.md Wave
/// 3.23). Unlike gbrain (which only prints paste-ready CLI strings for a human),
/// we own a transactional store with an explicit `ClaimStatus` enum, so we can
/// go one step further and actually transition claims — but ONLY above a
/// confidence threshold and behind a caller opt-in. The `resolve` step is pure
/// and exhaustively testable; `apply` performs the existing store transitions.
public enum SupersessionAction: Sendable, Equatable {
    /// Newer claim is the truth; archive the older, link the pair. `keep`/`archive` are claim ids.
    case archiveOlder(keep: Int64, archive: Int64)
    /// Genuine same-period conflict: both → `.contradicted`, link the pair.
    case markBothContradicted(Int64, Int64)
    /// Record the relationship but change no status (regression/evolution/artifact, or mid-confidence).
    case flagForReview(Int64, Int64, reason: String)
    /// Do nothing (no contradiction / floored).
    case skip
}

public enum SupersessionResolver {
    /// Confidence ≥ this auto-applies a mutating action; below → flagForReview.
    public static let autoThreshold = 0.8

    /// Pure mapping of a judged pair + the two claims to an action. The "older"
    /// claim is the one with the smaller `firstSeen`.
    public static func resolve(_ pair: JudgedPair, a: ClaimRow, b: ClaimRow,
                               autoThreshold: Double = autoThreshold) -> SupersessionAction {
        switch pair.verdict {
        case .noContradiction:
            return .skip
        case .temporalSupersession:
            guard pair.confidence >= autoThreshold else {
                return .flagForReview(a.id, b.id, reason: "low-confidence supersession")
            }
            let (older, newer) = a.firstSeen <= b.firstSeen ? (a, b) : (b, a)
            return .archiveOlder(keep: newer.id, archive: older.id)
        case .contradiction:
            guard pair.confidence >= autoThreshold else {
                return .flagForReview(a.id, b.id, reason: "low-confidence contradiction")
            }
            return .markBothContradicted(a.id, b.id)
        case .temporalRegression, .temporalEvolution, .negationArtifact:
            return .flagForReview(a.id, b.id, reason: pair.verdict.rawValue)
        }
    }

    /// Apply an action to the store using the EXISTING (previously-never-called)
    /// lifecycle primitives. The contradiction link is recorded for every
    /// non-skip action so the relationship is queryable even when no status changes.
    /// Returns whether any claim STATUS was mutated (vs. link-only / skip).
    @discardableResult
    public static func apply(_ action: SupersessionAction, to store: MemoryStore,
                             now: Int64) async throws -> Bool {
        switch action {
        case .skip:
            return false
        case .flagForReview(let x, let y, _):
            try await store.markContradiction(claim: x, contradicts: y, at: now)
            return false
        case .archiveOlder(let keep, let archive):
            try await store.setClaimStatus(archive, .archived, updatedAt: now)
            try await store.markClaimReviewed(keep, at: now)
            try await store.markContradiction(claim: keep, contradicts: archive, at: now)
            return true
        case .markBothContradicted(let x, let y):
            try await store.setClaimStatus(x, .contradicted, updatedAt: now)
            try await store.setClaimStatus(y, .contradicted, updatedAt: now)
            try await store.markContradiction(claim: x, contradicts: y, at: now)
            return true
        }
    }
}
