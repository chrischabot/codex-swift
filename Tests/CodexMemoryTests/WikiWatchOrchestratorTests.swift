import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Coverage for the §14.5/§14.6 scheduled watch round: select due → poll → advance the
/// scheduler. Driven by a scripted mock poller + a real store (no network). Also pins the
/// new WatchSource.kind round-trip (needed so the live poller resolves the right adapter).
final class WikiWatchOrchestratorTests: XCTestCase {
    private final class ScriptedPoller: WatchPoller, @unchecked Sendable {
        let byID: [String: WatchPollResult]
        private let lock = NSLock()
        private(set) var polled: [String] = []
        init(_ byID: [String: WatchPollResult]) { self.byID = byID }
        func poll(_ source: WatchSource) async -> WatchPollResult {
            lock.withLock { polled.append(source.id) }
            return byID[source.id] ?? WatchPollResult(outcome: .unchanged)
        }
    }

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "watchorch-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private let addNow: Int64 = 1_000_000
    private var roundNow: Int64 { addNow + 400 * 86_400 }   // far future → everything is due

    func testRunRoundPollsDueAdvancesAndTallies() async throws {
        let store = try makeStore()
        try await store.addWatch(id: "a", kind: "feed", volatility: .hot, now: addNow)
        try await store.addWatch(id: "b", kind: "url", volatility: .warm, now: addNow)
        try await store.addWatch(id: "c", kind: "github-owner", volatility: .hot, now: addNow)
        let poller = ScriptedPoller([
            "a": WatchPollResult(outcome: .changed, itemsIngested: 2),
            "b": WatchPollResult(outcome: .unchanged),
            "c": WatchPollResult(outcome: .failed(retryAfterSeconds: nil)),
        ])
        let r = await WikiWatchOrchestrator.runRound(store: store, poller: poller, now: roundNow, limit: 100)
        XCTAssertEqual(r, WikiWatchOrchestrator.RoundResult(polled: 3, changed: 1, unchanged: 1, failed: 1, itemsIngested: 2))
        XCTAssertEqual(Set(poller.polled), ["a", "b", "c"])

        // scheduler advanced: a/b reset (errorCount 0, rescheduled into the future); c backed off.
        let byID = Dictionary(uniqueKeysWithValues: (try await store.watchSources()).map { ($0.id, $0) })
        XCTAssertEqual(byID["a"]?.errorCount, 0)
        XCTAssertGreaterThan(byID["a"]?.nextDueAt ?? 0, roundNow, "a rescheduled forward after success")
        XCTAssertEqual(byID["c"]?.errorCount, 1, "c backed off after failure")
        XCTAssertEqual(byID["a"]?.lastPolledAt, roundNow)
    }

    func testRunRoundTalliesUpdatesSeparately() async throws {
        let store = try makeStore()
        try await store.addWatch(id: "a", kind: "url", volatility: .hot, now: addNow)
        try await store.addWatch(id: "b", kind: "url", volatility: .hot, now: addNow)
        let poller = ScriptedPoller([
            // a: 3 new revisions, 2 of which superseded a prior one (updates).
            "a": WatchPollResult(outcome: .changed, itemsIngested: 3, itemsUpdated: 2),
            // b: 1 brand-new item (no update).
            "b": WatchPollResult(outcome: .changed, itemsIngested: 1, itemsUpdated: 0),
        ])
        let r = await WikiWatchOrchestrator.runRound(store: store, poller: poller, now: roundNow, limit: 100)
        XCTAssertEqual(r.itemsIngested, 4)
        XCTAssertEqual(r.itemsUpdated, 2, "updates summed across sources")
        XCTAssertEqual(r.changed, 2)
    }

    func testRunRoundRespectsLimit() async throws {
        let store = try makeStore()
        for id in ["a", "b", "c"] { try await store.addWatch(id: id, kind: "url", volatility: .hot, now: addNow) }
        let poller = ScriptedPoller([:])   // all default → unchanged
        let r = await WikiWatchOrchestrator.runRound(store: store, poller: poller, now: roundNow, limit: 1)
        XCTAssertEqual(r.polled, 1, "limit caps sources polled this round")
        XCTAssertEqual(poller.polled.count, 1)
    }

    func testRunRoundSkipsPausedSources() async throws {
        let store = try makeStore()
        try await store.addWatch(id: "active", kind: "url", volatility: .hot, now: addNow)
        try await store.addWatch(id: "paused", kind: "url", volatility: .hot, now: addNow)
        try await store.setWatchStatus(id: "paused", status: .paused)
        let poller = ScriptedPoller([:])
        let r = await WikiWatchOrchestrator.runRound(store: store, poller: poller, now: roundNow, limit: 100)
        XCTAssertEqual(poller.polled, ["active"], "a paused source is not due → not polled")
        XCTAssertEqual(r.polled, 1)
    }

    func testRunRoundEmpty() async throws {
        let store = try makeStore()
        let r = await WikiWatchOrchestrator.runRound(store: store, poller: ScriptedPoller([:]), now: roundNow, limit: 100)
        XCTAssertEqual(r, WikiWatchOrchestrator.RoundResult())
    }

    // MARK: scheduled rounds (wiki-watch schedule)

    /// Clock that jumps `step` each call so every round re-sees its sources as due
    /// (advanceWatch reschedules forward; without time advancing, only round 1 polls).
    private final class FakeClock: @unchecked Sendable {
        private var t: Int64; private let step: Int64; private let lock = NSLock()
        init(start: Int64, step: Int64) { t = start; self.step = step }
        func now() -> Int64 { lock.withLock { let v = t; t += step; return v } }
    }
    private final class SleepCounter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func sleep(_ s: Int64) async { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock(); private var lines: [String] = []
        func add(_ s: String) { lock.withLock { lines.append(s) } }
        var count: Int { lock.withLock { lines.count } }
    }

    func testScheduleRunsBoundedRoundsAndAccumulates() async throws {
        let store = try makeStore()
        try await store.addWatch(id: "a", kind: "url", volatility: .hot, now: addNow)
        try await store.addWatch(id: "b", kind: "url", volatility: .hot, now: addNow)
        let poller = ScriptedPoller([
            "a": WatchPollResult(outcome: .changed, itemsIngested: 2, itemsUpdated: 1),
            "b": WatchPollResult(outcome: .changed, itemsIngested: 1, itemsUpdated: 0),
        ])
        let clock = FakeClock(start: addNow + 86_400, step: 400 * 86_400)   // each round far in the future → all due
        let sleeper = SleepCounter()
        let lines = LineCollector()
        let tally = await WikiWatchSchedule.run(
            store: store, poller: poller, intervalSeconds: 3600, limit: 100, maxRounds: 3,
            now: { clock.now() }, sleep: { await sleeper.sleep($0) }, emit: { lines.add($0) })
        XCTAssertEqual(tally.rounds, 3)
        XCTAssertEqual(tally.polled, 6, "2 due sources × 3 rounds")
        XCTAssertEqual(tally.itemsIngested, 9, "(2+1) per round × 3")
        XCTAssertEqual(tally.itemsUpdated, 3, "1 update per round × 3")
        XCTAssertEqual(sleeper.count, 2, "sleeps BETWEEN rounds, not after the last")
        XCTAssertEqual(lines.count, 3, "one emit line per round")
    }

    func testScheduleZeroRoundsDoesNothing() async throws {
        let store = try makeStore()
        try await store.addWatch(id: "a", kind: "url", volatility: .hot, now: addNow)
        let poller = ScriptedPoller([:])
        let sleeper = SleepCounter()
        let fixedNow = roundNow
        let tally = await WikiWatchSchedule.run(
            store: store, poller: poller, intervalSeconds: 1, limit: 10, maxRounds: 0,
            now: { fixedNow }, sleep: { await sleeper.sleep($0) })
        XCTAssertEqual(tally, WikiWatchSchedule.Tally())
        XCTAssertEqual(poller.polled.count, 0)
        XCTAssertEqual(sleeper.count, 0)
    }

    func testTierIntervalsAreCadenceOrdered() {
        XCTAssertLessThan(WikiWatchSchedule.tierInterval(.hot), WikiWatchSchedule.tierInterval(.warm))
        XCTAssertLessThan(WikiWatchSchedule.tierInterval(.warm), WikiWatchSchedule.tierInterval(.cold))
        XCTAssertEqual(WikiWatchSchedule.tierInterval(.hot), WikiWatchSchedule.defaultIntervalSeconds)
    }

    func testWatchSourceKindRoundTrips() async throws {
        let store = try makeStore()
        try await store.addWatch(id: "openai", kind: "github-owner", volatility: .hot, now: addNow)
        let s = try await store.watchSources().first { $0.id == "openai" }
        XCTAssertEqual(s?.kind, "github-owner", "the adapter kind round-trips through the store (live poller needs it)")
    }
}
