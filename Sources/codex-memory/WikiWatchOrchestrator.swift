import Foundation
import MemoryStore
import WikiIngest

// Scheduled freshness round (§14.5/§14.6): select the watch sources whose cadence is due
// (WatchScheduler), poll each (fetch → change-gate → ingest the genuinely-new items),
// then advance the scheduler (success resets the error backoff; failure backs off and
// honors Retry-After). No model in the round itself — change-detection is the content-SHA
// gate that WikiIngestWriter already enforces (re-seeing an unchanged item is a skip).

/// The verdict of polling one source, for the scheduler + the round tally.
struct WatchPollResult: Sendable, Equatable {
    var outcome: PollOutcome
    var itemsIngested: Int          // non-skipped writes (new revisions: CREATE + UPDATE)
    var itemsUpdated: Int           // subset of itemsIngested that superseded a prior revision
    init(outcome: PollOutcome, itemsIngested: Int = 0, itemsUpdated: Int = 0) {
        self.outcome = outcome; self.itemsIngested = itemsIngested; self.itemsUpdated = itemsUpdated
    }
}

/// Poll port — `LiveWatchPoller` in prod (adapter + fetch + ingest), a mock in tests.
protocol WatchPoller: Sendable {
    func poll(_ source: WatchSource) async -> WatchPollResult
}

enum WikiWatchOrchestrator {
    struct RoundResult: Sendable, Equatable {
        var polled = 0, changed = 0, unchanged = 0, failed = 0, itemsIngested = 0, itemsUpdated = 0
    }

    /// One round: due sources → poll → advance. Bounded by `limit`. Each source's
    /// scheduler state is advanced regardless of outcome, so a failing source backs off
    /// (and eventually flips to `error`) without blocking the rest.
    static func runRound(store: MemoryStore, poller: any WatchPoller, now: Int64, limit: Int = 100) async -> RoundResult {
        let due = (try? await store.dueWatchSources(now: now)) ?? []
        var r = RoundResult()
        for s in due.prefix(max(0, limit)) {
            let res = await poller.poll(s)
            try? await store.advanceWatch(id: s.id, outcome: res.outcome, now: now)
            r.polled += 1
            switch res.outcome {
            case .changed: r.changed += 1; r.itemsIngested += res.itemsIngested; r.itemsUpdated += res.itemsUpdated
            case .unchanged: r.unchanged += 1
            case .failed: r.failed += 1
            }
        }
        return r
    }
}

/// Live poller: resolve the source's adapter (M5 `WikiAdapterRegistry`), enumerate the
/// current items, and ingest the NEW ones via `WikiIngestWriter`. The writer's content-SHA
/// dedupe IS the change gate — an unchanged upstream re-enumerates to skipped writes, so
/// `>0` non-skipped writes ⇒ `.changed`; an adapter/fetch throw ⇒ `.failed` (backoff).
struct LiveWatchPoller: WatchPoller {
    let registry: WikiAdapterRegistry
    let writer: WikiIngestWriter
    let fetchedAt: Int64
    let maxPerSource: Int

    func poll(_ source: WatchSource) async -> WatchPollResult {
        let kind = WikiSourceKind(rawValue: source.kind)
        let adapter = registry.resolve(source.id, forced: kind)
        let req = IngestRequest(input: source.id, adapter: kind, limit: maxPerSource, fetchedAt: fetchedAt)
        var ingested = 0
        var updated = 0
        do {
            for try await cand in adapter.enumerate(req) {
                if ingested >= maxPerSource { break }
                if let r = try? await writer.write(cand, extract: false), !r.skipped {
                    ingested += 1
                    if r.revisionOf != nil { updated += 1 }   // superseded a prior revision → an UPDATE
                }
            }
        } catch {
            return WatchPollResult(outcome: .failed(retryAfterSeconds: nil))
        }
        return WatchPollResult(outcome: ingested > 0 ? .changed : .unchanged, itemsIngested: ingested, itemsUpdated: updated)
    }
}
