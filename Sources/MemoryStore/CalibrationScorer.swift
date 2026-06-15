import Foundation

/// Aggregates graded predictions into per-domain calibration scorecards
/// (gbrain.md Wave 3.26) — "claims we tag at 0.8 in the AI-safety domain actually
/// resolve true 0.55 of the time." Pure (no I/O, no model); the foundation the
/// thesis/claim grading loop feeds. Produces a Brier score (lower = better
/// calibrated), accuracy, partial-rate, n, and coverage.
public enum CalibrationAggregator: Sendable, Equatable {
    case scalarBrier     // mean squared error of confidence vs outcome
    case weightedBrier   // upweight high-conviction misses (conviction = |conf-0.5|·2)
    case countBased      // same MSE; reserved for count-weighted reporting
}

/// One graded prediction. `outcome`: 1.0 correct, 0.0 incorrect, 0.5 partial,
/// nil = unresolvable (excluded from Brier/accuracy, counted in coverage).
public struct ResolvedItem: Sendable, Equatable {
    public var domain: String
    public var confidence: Double
    public var outcome: Double?
    public init(domain: String, confidence: Double, outcome: Double?) {
        self.domain = domain; self.confidence = confidence; self.outcome = outcome
    }
}

public struct DomainScorecard: Sendable, Equatable {
    public var domain: String
    public var brier: Double
    public var accuracy: Double
    public var partialRate: Double
    public var n: Int            // resolved (non-nil outcome) count
    public var coverage: Double  // resolved / total
    public var coldStart: Bool   // n < minimum → no reliable profile yet
    public init(domain: String, brier: Double, accuracy: Double, partialRate: Double,
                n: Int, coverage: Double, coldStart: Bool) {
        self.domain = domain; self.brier = brier; self.accuracy = accuracy
        self.partialRate = partialRate; self.n = n; self.coverage = coverage; self.coldStart = coldStart
    }
}

public enum CalibrationScorer {
    /// Minimum resolved predictions before a profile is considered reliable.
    public static let minN = 5

    public static func score(_ items: [ResolvedItem],
                             aggregator: CalibrationAggregator = .scalarBrier,
                             domain: String = "all") -> DomainScorecard {
        let total = items.count
        let resolved = items.filter { $0.outcome != nil }
        let n = resolved.count
        let coverage = total > 0 ? Double(n) / Double(total) : 0
        guard n >= minN else {
            return DomainScorecard(domain: domain, brier: 0, accuracy: 0, partialRate: 0,
                                   n: n, coverage: coverage, coldStart: true)
        }
        var errSum = 0.0, weightSum = 0.0
        var correct = 0.0, partial = 0
        for it in resolved {
            let o = clamp01(it.outcome!)
            let c = clamp01(it.confidence)
            let err = (c - o) * (c - o)
            switch aggregator {
            case .scalarBrier, .countBased:
                errSum += err; weightSum += 1
            case .weightedBrier:
                let conviction = abs(c - 0.5) * 2     // 0 at 0.5, 1 at 0/1
                errSum += err * conviction; weightSum += conviction
            }
            if o >= 0.999 { correct += 1 }
            else if o > 0.001 { partial += 1 }
        }
        let brier = weightSum > 0 ? errSum / weightSum : 0
        let accuracy = (correct + 0.5 * Double(partial)) / Double(n)
        let partialRate = Double(partial) / Double(n)
        return DomainScorecard(domain: domain, brier: brier, accuracy: accuracy,
                               partialRate: partialRate, n: n, coverage: coverage, coldStart: false)
    }

    /// Group by `domain` and score each (deterministic domain order).
    public static func scoreByDomain(_ items: [ResolvedItem],
                                     aggregator: CalibrationAggregator = .scalarBrier) -> [DomainScorecard] {
        let groups = Dictionary(grouping: items, by: \.domain)
        return groups.keys.sorted().map { score(groups[$0] ?? [], aggregator: aggregator, domain: $0) }
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}
