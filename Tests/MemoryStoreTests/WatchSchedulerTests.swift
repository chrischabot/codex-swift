import XCTest
@testable import MemoryStore

final class WatchSchedulerTests: XCTestCase {

    private let day: Int64 = 86_400
    private let now: Int64 = 1_000_000

    func testCadenceIntervals() {
        XCTAssertEqual(WatchScheduler.intervalSeconds(.hot), day)
        XCTAssertEqual(WatchScheduler.intervalSeconds(.warm), 3 * day)
        XCTAssertEqual(WatchScheduler.intervalSeconds(.cold), 7 * day)
    }

    func testNextDueNormalCadence() {
        let due = WatchScheduler.nextDue(volatility: .hot, lastPolledAt: now, errorCount: 0)
        XCTAssertEqual(due, now + day)
    }

    func testExponentialBackoff() {
        XCTAssertEqual(WatchScheduler.backoffMultiplier(errorCount: 0), 1)
        XCTAssertEqual(WatchScheduler.backoffMultiplier(errorCount: 1), 2)
        XCTAssertEqual(WatchScheduler.backoffMultiplier(errorCount: 3), 8)
        XCTAssertEqual(WatchScheduler.backoffMultiplier(errorCount: 100), 64)  // capped at 2^6
        // a hot source with 2 errors backs off to 4 days
        XCTAssertEqual(WatchScheduler.nextDue(volatility: .hot, lastPolledAt: now, errorCount: 2),
                       now + 4 * day)
    }

    func testRetryAfterHonored() {
        // explicit Retry-After (10 days) overrides the shorter normal cadence
        let due = WatchScheduler.nextDue(volatility: .hot, lastPolledAt: now, errorCount: 0,
                                         retryAfterSeconds: 10 * day)
        XCTAssertEqual(due, now + 10 * day)
    }

    func testDueBucketingExcludesPausedAndFuture() {
        let sources = [
            WatchSource(id: "due1", volatility: .hot, nextDueAt: now - 100, status: .active),
            WatchSource(id: "due2", volatility: .warm, nextDueAt: now - 50, status: .active),
            WatchSource(id: "future", volatility: .hot, nextDueAt: now + 100, status: .active),
            WatchSource(id: "paused", volatility: .hot, nextDueAt: now - 100, status: .paused),
        ]
        let due = WatchScheduler.dueSources(sources, now: now)
        XCTAssertEqual(due.map(\.id), ["due1", "due2"])   // soonest-due first, no future/paused
    }

    func testAdvanceOnSuccessClearsErrors() {
        let s = WatchSource(id: "s", volatility: .warm, errorCount: 3, status: .error)
        let n = WatchScheduler.advance(s, outcome: .changed, now: now)
        XCTAssertEqual(n.errorCount, 0)
        XCTAssertEqual(n.status, .active)               // recovered
        XCTAssertEqual(n.nextDueAt, now + 3 * day)      // normal cadence
        XCTAssertEqual(n.lastPolledAt, now)
    }

    func testAdvanceOnFailureBacksOffAndFlipsError() {
        var s = WatchSource(id: "s", volatility: .hot, errorCount: 4, status: .active)
        s = WatchScheduler.advance(s, outcome: .failed(retryAfterSeconds: nil), now: now, errorThreshold: 5)
        XCTAssertEqual(s.errorCount, 5)
        XCTAssertEqual(s.status, .error)                // crossed threshold
        XCTAssertEqual(s.nextDueAt, now + day * 32)     // 2^5 = 32× backoff (cap is 2^6)
    }

    func testChangeDetectionGate() {
        XCTAssertTrue(WatchScheduler.changed(storedSHA: nil, fetchedSHA: "abc"))      // first sight
        XCTAssertTrue(WatchScheduler.changed(storedSHA: "abc", fetchedSHA: "def"))    // changed
        XCTAssertFalse(WatchScheduler.changed(storedSHA: "abc", fetchedSHA: "abc"))   // unchanged → no model
    }
}
