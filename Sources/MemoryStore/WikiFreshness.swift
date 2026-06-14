import Foundation

/// Pure freshness/staleness math over the volatility tiers. Exponential decay:
/// `freshness = 0.5 ^ (ageDays / halfLifeDays)` — so a claim/page is exactly
/// half-fresh at one half-life and the decay is smooth and monotonic. No model,
/// no I/O; the librarian/refresh passes call this to gate which pages to review.
public enum WikiFreshness {
    /// Half-life in days per volatility tier.
    public static func halfLifeDays(_ v: Volatility) -> Double {
        switch v {
        case .hot:  return 30
        case .warm: return 90
        case .cold: return 365
        }
    }

    /// Freshness in `(0, 1]`. `ageDays <= 0` clamps to 1 (just reviewed); the
    /// function is monotonically decreasing in `ageDays` and never reaches 0.
    public static func freshness(ageDays: Double, volatility: Volatility) -> Double {
        let age = max(0, ageDays)
        return pow(0.5, age / halfLifeDays(volatility))
    }

    /// Freshness from epoch-second stamps. A nil `lastReviewed` means never
    /// reviewed → treated as maximally stale (freshness 0).
    public static func freshness(lastReviewed: Int64?, now: Int64, volatility: Volatility) -> Double {
        guard let lr = lastReviewed else { return 0 }
        let ageDays = Double(now - lr) / 86_400.0
        return freshness(ageDays: ageDays, volatility: volatility)
    }

    /// A page/claim is stale when its freshness drops below `threshold`
    /// (default 0.5 = older than one half-life). Never-reviewed is always stale.
    public static func isStale(lastReviewed: Int64?, now: Int64,
                               volatility: Volatility, threshold: Double = 0.5) -> Bool {
        freshness(lastReviewed: lastReviewed, now: now, volatility: volatility) < threshold
    }
}
