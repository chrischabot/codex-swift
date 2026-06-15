import Foundation

// Watch scheduling & efficiency (§14.6). PURE cadence/backoff arithmetic — the
// change-detection gate and the "which sources are due" decision use NO model, so
// the frontier only ever sees genuinely-new content. Cadence maps to volatility:
// hot → daily, warm → ~every 3 days, cold → weekly; the scheduler buckets sources
// by next_due_at and applies exponential backoff to erroring sources.

public enum WatchStatus: String, Sendable, Equatable, Codable {
    case active, paused, error, disabled
}

/// The outcome of polling a watched source (the change-detection gate's verdict).
public enum PollOutcome: Sendable, Equatable {
    case unchanged
    case changed
    case failed(retryAfterSeconds: Int64?)   // honor Retry-After / X-RateLimit-Reset
}

public struct WatchSource: Sendable, Equatable {
    public var id: String
    public var volatility: Volatility
    /// Adapter kind (github-owner|feed|arxiv|url) — selects how the round polls this source.
    public var kind: String
    public var lastPolledAt: Int64
    public var errorCount: Int
    public var nextDueAt: Int64
    public var status: WatchStatus
    public init(id: String, volatility: Volatility, kind: String = "url", lastPolledAt: Int64 = 0,
                errorCount: Int = 0, nextDueAt: Int64 = 0, status: WatchStatus = .active) {
        self.id = id; self.volatility = volatility; self.kind = kind; self.lastPolledAt = lastPolledAt
        self.errorCount = errorCount; self.nextDueAt = nextDueAt; self.status = status
    }
}

public enum WatchScheduler {
    /// Base poll interval in days per cadence tier (§14.6).
    public static func intervalDays(_ v: Volatility) -> Double {
        switch v {
        case .hot:  return 1     // daily
        case .warm: return 3     // every 2-3 days
        case .cold: return 7     // weekly
        }
    }
    public static func intervalSeconds(_ v: Volatility) -> Int64 { Int64(intervalDays(v) * 86_400) }

    /// Exponential backoff multiplier from consecutive errors: 0 → 1×, 1 → 2×,
    /// 2 → 4×, … capped at 2^cap.
    public static func backoffMultiplier(errorCount: Int, cap: Int = 6) -> Int64 {
        1 << min(max(0, errorCount), cap)
    }

    /// The next poll time: base cadence × backoff, never sooner than an explicit
    /// Retry-After.
    public static func nextDue(volatility: Volatility, lastPolledAt: Int64, errorCount: Int,
                               retryAfterSeconds: Int64? = nil) -> Int64 {
        let base = intervalSeconds(volatility) * backoffMultiplier(errorCount: errorCount)
        var due = lastPolledAt + base
        if let ra = retryAfterSeconds { due = max(due, lastPolledAt + ra) }
        return due
    }

    /// A source is due when it's active and its next_due_at has passed. Paused /
    /// disabled / hard-errored sources are never due.
    public static func isDue(_ s: WatchSource, now: Int64) -> Bool {
        s.status == .active && s.nextDueAt <= now
    }

    /// The round's work list: due sources, soonest-due first.
    public static func dueSources(_ sources: [WatchSource], now: Int64) -> [WatchSource] {
        sources.filter { isDue($0, now: now) }.sorted { $0.nextDueAt < $1.nextDueAt }
    }

    /// Advance a source's state after a poll. Success (changed/unchanged) clears the
    /// error streak and schedules the normal cadence; a failure increments the streak,
    /// backs off, and flips to `error` once it crosses `errorThreshold`.
    public static func advance(_ s: WatchSource, outcome: PollOutcome, now: Int64,
                               errorThreshold: Int = 5) -> WatchSource {
        var n = s
        n.lastPolledAt = now
        switch outcome {
        case .unchanged, .changed:
            n.errorCount = 0
            if n.status == .error { n.status = .active }   // recovered
            n.nextDueAt = nextDue(volatility: s.volatility, lastPolledAt: now, errorCount: 0)
        case .failed(let retryAfter):
            n.errorCount = s.errorCount + 1
            n.status = n.errorCount >= errorThreshold ? .error : .active
            n.nextDueAt = nextDue(volatility: s.volatility, lastPolledAt: now,
                                  errorCount: n.errorCount, retryAfterSeconds: retryAfter)
        }
        return n
    }

    /// Change-detection gate (no model): genuinely-new content only when the fetched
    /// content-SHA differs from what's stored. A nil stored SHA (first sight) = changed.
    public static func changed(storedSHA: String?, fetchedSHA: String) -> Bool {
        storedSHA != fetchedSHA
    }
}
