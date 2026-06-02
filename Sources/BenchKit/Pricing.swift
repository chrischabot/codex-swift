import Foundation

/// Approximate model pricing (USD per 1M tokens) for the report's cost column.
/// `cached` is the discounted price for prompt-cache hits (OpenAI bills cached
/// input at ~10% of fresh input) — accounting for it matters a LOT: in agent
/// runs 97–98% of input tokens are cache hits, so billing them at the full
/// input rate overstates cost by ~7×. Unknown models cost 0.
public enum Pricing {
    struct Rate { let inp: Double; let cached: Double; let out: Double }
    static let table: [(prefix: String, rate: Rate)] = [
        ("gpt-5.5",      Rate(inp: 1.25, cached: 0.125, out: 10.0)),
        ("gpt-5.4-mini", Rate(inp: 0.25, cached: 0.025, out: 2.0)),
        ("gpt-5.4",      Rate(inp: 1.25, cached: 0.125, out: 10.0)),
        ("gpt-5",        Rate(inp: 1.25, cached: 0.125, out: 10.0)),
        ("gpt-4o-mini",  Rate(inp: 0.15, cached: 0.075, out: 0.60)),
        ("gpt-4o",       Rate(inp: 2.50, cached: 1.25,  out: 10.0)),
        ("o3",           Rate(inp: 2.0,  cached: 0.50,  out: 8.0)),
        ("o4-mini",      Rate(inp: 1.10, cached: 0.275, out: 4.40)),
        // Realtime voice models — TEXT-token rates only. The bench cost column
        // does not model audio tokens (in $32 / cached $0.40 / out $64 per 1M)
        // or image input ($5 per 1M). `gpt-realtime-2` must precede the shorter
        // `gpt-realtime` prefix so the first-match lookup resolves it.
        ("gpt-realtime-2", Rate(inp: 4.0, cached: 0.40, out: 24.0)),
        ("gpt-realtime",   Rate(inp: 4.0, cached: 0.40, out: 24.0)),
    ]

    /// Cost given total input (incl. cached), cached subset, and output tokens.
    /// Cached tokens are billed at the cache rate; the rest of input at the
    /// fresh rate.
    public static func cost(model: String, inputTokens: Int, cachedInputTokens: Int = 0,
                            outputTokens: Int) -> Double {
        let m = model.lowercased()
        guard let r = table.first(where: { m.hasPrefix($0.prefix) })?.rate else { return 0 }
        let cached = min(cachedInputTokens, inputTokens)
        let fresh = inputTokens - cached
        return Double(fresh) / 1_000_000 * r.inp
            + Double(cached) / 1_000_000 * r.cached
            + Double(outputTokens) / 1_000_000 * r.out
    }
}
