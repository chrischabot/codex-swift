import XCTest
import Foundation
@testable import Cron

/// Severe tests for the ADDONS #6 scheduler: next-fire for at/every/UTC-cron, the
/// dom/dow OR semantics, and the grace-window catch-up vs fast-forward decision.
final class CronTests: XCTestCase {

    /// Epoch for a UTC wall-clock instant.
    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Int64 {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return Int64(cal.date(from: c)!.timeIntervalSince1970)
    }

    // MARK: at / every

    func testAtFiresOnceInFuture() {
        let t = utc(2026, 6, 1, 12, 0)
        XCTAssertEqual(Schedule.at(t + 100).next(after: t), t + 100)
        XCTAssertNil(Schedule.at(t - 100).next(after: t), "a past one-shot never fires")
    }

    func testEveryAnchorsOnPrior() {
        let t = utc(2026, 6, 1, 12, 0)
        XCTAssertEqual(Schedule.every(300).next(after: t), t + 300)
        XCTAssertNil(Schedule.every(0).next(after: t))
    }

    // MARK: cron (UTC)

    func testCronEveryFiveMinutes() {
        let t = utc(2026, 6, 1, 12, 2)
        XCTAssertEqual(Schedule.cron("*/5 * * * *").next(after: t), utc(2026, 6, 1, 12, 5))
    }

    func testCronDailyAtNineUTC() {
        let t = utc(2026, 6, 1, 12, 0)   // past 9am today
        XCTAssertEqual(Schedule.cron("0 9 * * *").next(after: t), utc(2026, 6, 2, 9, 0))
    }

    func testCronFirstOfMonth() {
        let t = utc(2026, 6, 15, 0, 0)
        XCTAssertEqual(Schedule.cron("0 0 1 * *").next(after: t), utc(2026, 7, 1, 0, 0))
    }

    func testCronWeekday() {
        // "0 0 * * 1" → next Monday 00:00. 2026-06-01 is a Monday.
        let sun = utc(2026, 5, 31, 12, 0)   // a Sunday afternoon
        XCTAssertEqual(Schedule.cron("0 0 * * 1").next(after: sun), utc(2026, 6, 1, 0, 0))
        // dow 7 == 0 == Sunday.
        let sat = utc(2026, 6, 6, 12, 0)
        XCTAssertEqual(Schedule.cron("0 0 * * 7").next(after: sat), utc(2026, 6, 7, 0, 0))
    }

    func testCronRangeAndList() {
        let t = utc(2026, 6, 1, 8, 0)
        // at minute 0, hours 9 and 17.
        XCTAssertEqual(Schedule.cron("0 9,17 * * *").next(after: t), utc(2026, 6, 1, 9, 0))
        let t2 = utc(2026, 6, 1, 10, 0)
        XCTAssertEqual(Schedule.cron("0 9,17 * * *").next(after: t2), utc(2026, 6, 1, 17, 0))
    }

    func testCronInvalidRejected() {
        XCTAssertNil(Schedule.cron("nope").next(after: 0))
        XCTAssertNil(Schedule.cron("60 * * * *").next(after: 0), "minute 60 out of range")
        XCTAssertNil(Schedule.cron("* * *").next(after: 0), "wrong field count")
    }

    // MARK: scheduler — due / catch-up / fast-forward

    func testDueFiresAndAdvancesLastRun() async {
        let now = utc(2026, 6, 1, 12, 5)
        let store = MemoryCronStore()
        let fired = FireRecorder()
        let sched = CronScheduler(store: store, graceSeconds: 600, run: fired.run)
        await sched.upsert(CronJob(id: "j", schedule: .cron("*/5 * * * *"),
                                   prompt: "report", lastRunAt: utc(2026, 6, 1, 12, 0),
                                   createdAt: utc(2026, 6, 1, 0, 0)))
        let ran = await sched.tick(now: now)
        XCTAssertEqual(ran, ["j"], "the 12:05 fire is due")
        let count = await fired.count()
        XCTAssertEqual(count, 1)
        let job = await sched.list().first
        XCTAssertEqual(job?.lastRunAt, now, "lastRunAt advanced")
    }

    func testStaleMissedFireIsFastForwardedNotRun() async {
        // Daemon was down for a day; a "every 5 min" job's missed fires are stale.
        let now = utc(2026, 6, 2, 12, 0)
        let store = MemoryCronStore()
        let fired = FireRecorder()
        let sched = CronScheduler(store: store, graceSeconds: 3600, run: fired.run)
        await sched.upsert(CronJob(id: "j", schedule: .cron("*/5 * * * *"),
                                   prompt: "x", lastRunAt: utc(2026, 6, 1, 12, 0),   // 24h ago
                                   createdAt: utc(2026, 6, 1, 0, 0)))
        let ran = await sched.tick(now: now)
        XCTAssertEqual(ran, [], "a stale missed fire is NOT run (fast-forwarded)")
        let count = await fired.count()
        XCTAssertEqual(count, 0)
        let job = await sched.list().first
        XCTAssertEqual(job?.lastRunAt, now, "fast-forwarded past the stale fires")
    }

    func testCaughtUpWithinGraceWindowRuns() async {
        // A fire missed 5 minutes ago, grace 1h → caught up.
        let lastRun = utc(2026, 6, 1, 11, 55)
        let now = utc(2026, 6, 1, 12, 5)   // next fire was 12:00, 5 min ago
        let store = MemoryCronStore()
        let fired = FireRecorder()
        let sched = CronScheduler(store: store, graceSeconds: 3600, run: fired.run)
        await sched.upsert(CronJob(id: "j", schedule: .cron("0 12 * * *"),
                                   prompt: "x", lastRunAt: lastRun, createdAt: utc(2026, 6, 1, 0, 0)))
        let ran = await sched.tick(now: now)
        XCTAssertEqual(ran, ["j"], "a fire missed within the grace window is caught up")
    }

    func testOneShotAtDisablesAfterFiring() async {
        let now = utc(2026, 6, 1, 12, 0)
        let store = MemoryCronStore()
        let fired = FireRecorder()
        let sched = CronScheduler(store: store, graceSeconds: 600, run: fired.run)
        await sched.upsert(CronJob(id: "once", schedule: .at(utc(2026, 6, 1, 11, 59)),
                                   prompt: "x", createdAt: utc(2026, 6, 1, 11, 0)))
        _ = await sched.tick(now: now)
        let job = await sched.list().first
        XCTAssertEqual(job?.enabled, false, "a one-shot .at disables after firing")
        // A second tick does not re-run it.
        _ = await sched.tick(now: now + 60)
        let count = await fired.count()
        XCTAssertEqual(count, 1)
    }

    func testSkipMemoryDefaultsTrue() {
        let job = CronJob(id: "j", schedule: .every(60), prompt: "x", createdAt: 0)
        XCTAssertTrue(job.skipMemory, "unattended runs skip memory by default")
    }

    func testJobAccessor() async {
        let sched = CronScheduler(store: MemoryCronStore(), run: FireRecorder().run)
        await sched.upsert(CronJob(id: "j", schedule: .every(60), prompt: "x", createdAt: 0))
        let got = await sched.job("j")
        XCTAssertEqual(got?.id, "j")
        let missing = await sched.job("nope")
        XCTAssertNil(missing)
    }

    // MARK: self-driving tick loop

    func testStartDrivesTickAndStopHalts() async {
        let store = MemoryCronStore()
        let fired = FireRecorder()
        let sched = CronScheduler(store: store, graceSeconds: 3600, run: fired.run)
        // A one-shot `.at` 50s in the (relative) past, within the grace window of
        // now=100, so the tick fires it once then disables it.
        await sched.upsert(CronJob(id: "j", schedule: .at(50), prompt: "x", createdAt: 0))
        await sched.start(tickSeconds: 0, now: { 100 })
        var fires = 0
        for _ in 0..<200 {
            fires = await fired.count()
            if fires >= 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(fires, 1, "the tick loop fired the due job")
        await sched.stop()
        let running = await sched.isRunning
        XCTAssertFalse(running, "stop() halts the loop")
        let afterStop = await fired.count()
        try? await Task.sleep(for: .milliseconds(30))
        let later = await fired.count()
        XCTAssertEqual(afterStop, later, "no ticks after stop()")
    }

    func testStartIsIdempotent() async {
        let sched = CronScheduler(store: MemoryCronStore(), run: FireRecorder().run)
        await sched.start(tickSeconds: 3600)
        await sched.start(tickSeconds: 3600)   // a second call is a no-op
        let running = await sched.isRunning
        XCTAssertTrue(running)
        await sched.stop()
    }

    // MARK: persist-on-change (the `|| true` → `changed` fix)

    func testNoOpTickDoesNotPersistButFastForwardDoes() async {
        // CLAIM: a tick with nothing due must NOT persist; a fast-forward tick
        // MUST persist (else stale fires resurrect on restart).
        let counting = CountingCronStore()
        let sched = CronScheduler(store: counting, graceSeconds: 600, run: FireRecorder().run)
        await sched.upsert(CronJob(id: "future", schedule: .every(3600),
                                   prompt: "x", lastRunAt: 1000, createdAt: 0))
        let baseline = await counting.saves()
        _ = await sched.tick(now: 1500)          // next fire is 4600 → nothing due
        let afterNoop = await counting.saves()
        XCTAssertEqual(afterNoop, baseline, "a no-op tick does NOT persist")

        await sched.upsert(CronJob(id: "stale", schedule: .every(60),
                                   prompt: "x", lastRunAt: 0, createdAt: 0))
        let before = await counting.saves()
        _ = await sched.tick(now: 1_000_000)     // way past grace → fast-forward
        let after = await counting.saves()
        XCTAssertGreaterThan(after, before, "a fast-forward tick persists (no stale-fire resurrection)")
    }
}

actor FireRecorder {
    private var fired: [String] = []
    nonisolated var run: CronScheduler.Runner { { [self] job in await self.record(job.id); return true } }
    private func record(_ id: String) { fired.append(id) }
    func count() -> Int { fired.count }
}

/// A CronStore that counts save() calls (to assert persist-on-change).
actor CountingCronStore: CronStore {
    private var jobs: [CronJob] = []
    private var saveCount = 0
    func load() -> [CronJob] { jobs }
    func save(_ j: [CronJob]) { jobs = j; saveCount += 1 }
    func saves() -> Int { saveCount }
}
