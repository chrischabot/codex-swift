import Foundation
import MemoryStore

/// Cheap, deterministic, zero-model pre-filter that decides whether a claim PAIR
/// is even worth sending to the (expensive) judge (gbrain.md Wave 3 probe). Two
/// claims are candidates only when they plausibly discuss the SAME subject —
/// approximated by significant-token overlap — and are not the exact same claim
/// or a byte-dup (that's dedup, not contradiction).
public enum ContradictionPrefilter {
    static let stopwords: Set<String> = [
        "the", "and", "that", "this", "with", "for", "are", "was", "were", "has",
        "have", "had", "will", "would", "can", "could", "its", "their", "from",
        "into", "than", "then", "they", "them", "out", "not", "but", "all", "any",
    ]

    /// Lowercased alphanumeric tokens ≥3 chars, minus stopwords.
    public static func significantTokens(_ s: String) -> Set<String> {
        var out = Set<String>()
        for raw in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let t = String(raw)
            if t.count >= 3 && !stopwords.contains(t) { out.insert(t) }
        }
        return out
    }

    public static func shouldJudge(_ a: ClaimRow, _ b: ClaimRow, minOverlap: Int = 2) -> Bool {
        guard a.id != b.id, a.canonicalSHA != b.canonicalSHA else { return false }
        let overlap = significantTokens(a.text).intersection(significantTokens(b.text))
        return overlap.count >= minOverlap
    }
}

public struct ContradictionProbeReport: Sendable, Equatable {
    /// Pairs that passed the prefilter (candidate pairs).
    public var pairsConsidered: Int
    /// Pairs actually sent to the judge.
    public var pairsJudged: Int
    /// verdict.rawValue → count.
    public var verdicts: [String: Int]
    /// Status-mutating actions actually applied (apply mode + opt-in).
    public var applied: Int
    /// Human-readable pending/flagged actions for the review queue.
    public var reviewQueue: [String]
    /// True when the maxJudgeCalls budget cut the run short.
    public var truncated: Bool
    /// Graded predictions for the calibration scorer (gbrain.md 3.26). Property-level
    /// default keeps the public init signature unchanged (ABI-safe); populated in run().
    public var resolvedItems: [ResolvedItem] = []
    public init(pairsConsidered: Int = 0, pairsJudged: Int = 0, verdicts: [String: Int] = [:],
                applied: Int = 0, reviewQueue: [String] = [], truncated: Bool = false) {
        self.pairsConsidered = pairsConsidered; self.pairsJudged = pairsJudged
        self.verdicts = verdicts; self.applied = applied
        self.reviewQueue = reviewQueue; self.truncated = truncated
    }
}

/// Enumerates candidate claim pairs, judges only the pre-filter survivors, and
/// (optionally, opt-in) applies the resulting lifecycle transitions via the
/// SupersessionResolver (gbrain.md Wave 3 probe-runner). Deterministic pair
/// order; judge calls bounded by `maxJudgeCalls` + `maxPairsPerClaim` so an
/// adversarial 500-unrelated-claims corpus stays O(claims·cap), not O(claims²),
/// in judge calls (the O(n²) prefilter pass is cheap token-set work).
public struct ContradictionProbe: Sendable {
    public let judge: ContradictionJudgeBackend
    public var minTokenOverlap: Int
    public var maxPairsPerClaim: Int
    public var maxJudgeCalls: Int
    public var autoThreshold: Double

    public init(judge: ContradictionJudgeBackend, minTokenOverlap: Int = 2,
                maxPairsPerClaim: Int = 10, maxJudgeCalls: Int = 500,
                autoThreshold: Double = SupersessionResolver.autoThreshold) {
        self.judge = judge; self.minTokenOverlap = minTokenOverlap
        self.maxPairsPerClaim = maxPairsPerClaim; self.maxJudgeCalls = maxJudgeCalls
        self.autoThreshold = autoThreshold
    }

    public func run(claims: [ClaimRow], now: Int64,
                    apply: Bool = false, store: MemoryStore? = nil) async -> ContradictionProbeReport {
        let sorted = claims.sorted { $0.id < $1.id }
        var report = ContradictionProbeReport()
        var perClaim: [Int64: Int] = [:]

        outer: for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                let a = sorted[i], b = sorted[j]
                guard ContradictionPrefilter.shouldJudge(a, b, minOverlap: minTokenOverlap) else { continue }
                report.pairsConsidered += 1
                if (perClaim[a.id] ?? 0) >= maxPairsPerClaim || (perClaim[b.id] ?? 0) >= maxPairsPerClaim {
                    continue
                }
                if report.pairsJudged >= maxJudgeCalls { report.truncated = true; break outer }
                perClaim[a.id, default: 0] += 1
                perClaim[b.id, default: 0] += 1

                let ctx = JudgeContext(
                    aDateISO: ContradictionJudge.dateTag(nil, fallbackEpoch: a.firstSeen),
                    bDateISO: ContradictionJudge.dateTag(nil, fallbackEpoch: b.firstSeen))
                let verdict = await judge.judge(a, b, context: ctx)
                report.pairsJudged += 1
                report.verdicts[verdict.verdict.rawValue, default: 0] += 1

                let action = SupersessionResolver.resolve(verdict, a: a, b: b, autoThreshold: autoThreshold)
                // Emit a graded prediction for EVERY judged pair (independent of apply
                // mode) so calibration coverage reflects judge quality, not whether the
                // operator opted into mutations.
                report.resolvedItems.append(
                    CalibrationProbe.resolvedItem(for: verdict, a: a, b: b, action: action))
                switch action {
                case .skip:
                    break
                case .flagForReview(_, _, let reason):
                    report.reviewQueue.append("\(a.id)~\(b.id): review (\(reason))")
                case .archiveOlder, .markBothContradicted:
                    if apply, let store {
                        if (try? await SupersessionResolver.apply(action, to: store, now: now)) == true {
                            report.applied += 1
                        }
                    } else {
                        report.reviewQueue.append("\(a.id)~\(b.id): pending \(actionLabel(action))")
                    }
                }
            }
        }
        return report
    }

    private func actionLabel(_ a: SupersessionAction) -> String {
        switch a {
        case .archiveOlder(let keep, let archive): return "supersede (keep \(keep), archive \(archive))"
        case .markBothContradicted(let x, let y): return "contradiction (\(x), \(y))"
        case .flagForReview(_, _, let r): return "review (\(r))"
        case .skip: return "skip"
        }
    }
}
