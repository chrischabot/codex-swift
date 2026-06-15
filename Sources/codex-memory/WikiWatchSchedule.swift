import Foundation
import MemoryStore

// Scheduled freshness rounds (§14.5/§14.6 "wiki-watch-round per tier"). The generic
// CronScheduler fires PROMPTS as locked-down LLM turns (.readOnly, no network/shell) —
// which cannot run a deterministic poll-and-ingest. So scheduled watch rounds run as a
// dedicated in-process loop over WikiWatchOrchestrator.runRound. The PER-TIER cadence is
// already enforced by WatchScheduler (each source's volatility → hot/warm/cold due math),
// so a single periodic round polls exactly the sources that are due at that moment — the
// loop interval just sets how often we re-check. Deterministic, no model, no egress beyond
// the adapters' own pinned fetches.
enum WikiWatchSchedule {
    /// Accumulated outcome across the rounds run by `run`.
    struct Tally: Sendable, Equatable {
        var rounds = 0, polled = 0, changed = 0, unchanged = 0, failed = 0, itemsIngested = 0, itemsUpdated = 0

        mutating func add(_ r: WikiWatchOrchestrator.RoundResult) {
            rounds += 1; polled += r.polled; changed += r.changed; unchanged += r.unchanged
            failed += r.failed; itemsIngested += r.itemsIngested; itemsUpdated += r.itemsUpdated
        }
    }

    /// Run scheduled rounds. `maxRounds == nil` loops until cancelled (the operator's
    /// long-running process); a finite cap is for bounded operator runs + tests. `sleep`
    /// and `now` are injected so tests drive many rounds with zero wall-clock. Each round's
    /// failures are contained (advanceWatch backs the source off); the loop never aborts on
    /// one bad source. `emit` receives a one-line summary per round (NDJSON-friendly caller).
    static func run(store: MemoryStore, poller: any WatchPoller,
                    intervalSeconds: Int64, limit: Int, maxRounds: Int?,
                    now: @escaping @Sendable () -> Int64,
                    sleep: @escaping @Sendable (Int64) async -> Void,
                    emit: @Sendable (String) -> Void = { _ in }) async -> Tally {
        var tally = Tally()
        var round = 0
        while !Task.isCancelled {
            if let cap = maxRounds, round >= cap { break }
            let r = await WikiWatchOrchestrator.runRound(store: store, poller: poller, now: now(), limit: limit)
            tally.add(r)
            round += 1
            let newItems = max(0, r.itemsIngested - r.itemsUpdated)
            emit("round \(round): polled \(r.polled) — \(r.changed) changed, \(r.unchanged) unchanged, "
                + "\(r.failed) failed; \(newItems) new, \(r.itemsUpdated) updated")
            // No sleep after the final round (a finite run returns promptly).
            if let cap = maxRounds, round >= cap { break }
            await sleep(intervalSeconds)
        }
        return tally
    }

    /// Per-tier default re-check interval hint (seconds). The loop runs at ONE interval, but
    /// these document the cadence each volatility tier is polled at (the WatchScheduler's own
    /// due math; surfaced for the CLI default + operator guidance).
    static func tierInterval(_ v: Volatility) -> Int64 {
        switch v {
        case .hot:  return 86_400          // daily
        case .warm: return 3 * 86_400      // every 3 days
        case .cold: return 7 * 86_400      // weekly
        }
    }

    /// The default loop interval: the TIGHTEST tier cadence (hot), so hot sources are never
    /// starved. Warmer sources still only poll when their own due time arrives.
    static let defaultIntervalSeconds: Int64 = 86_400
}
