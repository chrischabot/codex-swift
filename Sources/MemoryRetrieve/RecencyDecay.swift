import Foundation
import MemoryStore

/// Per-source recency boost (gbrain.md Wave 2.17). A hyperbolic multiplier ≥ 1
/// that lifts fresh documents — strongest at age 0, decaying toward 1.0 (no
/// demote) as a document ages. Applied only on temporal-intent queries (so a
/// name lookup of an old-but-canonical page is never demoted) and only above the
/// floor-ratio gate (so a weak-but-fresh page can't leapfrog a strong hit).
public enum RecencyDecay {
    /// Per-source half-life in days: short for fast-moving feeds, long/evergreen
    /// for papers + repos + curated manual entries.
    public static func halfLifeDays(_ source: MemorySource) -> Double {
        switch source {
        case .x, .rss, .newsletter:     return 14
        case .web, .claude:             return 90
        case .github, .arxiv, .manual:  return 365
        }
    }

    /// Boost strength at age 0 (the maximum extra multiplier a brand-new doc gets).
    public static func coefficient(_ source: MemorySource) -> Double {
        switch source {
        case .x, .rss, .newsletter:     return 0.5   // recency matters most here
        case .web, .claude:             return 0.3
        case .github, .arxiv, .manual:  return 0.15  // evergreen — gentle
        }
    }

    /// `1 + coeff · hl / (hl + ageDays)` — ∈ [1, 1+coeff]. Age 0 → 1+coeff;
    /// age → ∞ → 1. Never demotes (multiplier ≥ 1).
    public static func factor(source: MemorySource, ageDays: Double) -> Double {
        let age = max(0, ageDays)
        let hl = halfLifeDays(source)
        return 1.0 + coefficient(source) * hl / (hl + age)
    }

    /// Convenience: derive age from `publishedAt ?? fetchedAt` vs `now` (epoch s).
    public static func factor(source: MemorySource, publishedAt: Int64?,
                              fetchedAt: Int64, now: Int64) -> Double {
        let ref = publishedAt ?? fetchedAt
        let ageDays = Double(max(0, now - ref)) / 86_400.0
        return factor(source: source, ageDays: ageDays)
    }
}
