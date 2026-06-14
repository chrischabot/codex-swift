import XCTest
@testable import MemoryStore

final class WatchStoreTests: XCTestCase {

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "watch-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }

    func testWatchCRUDAndScheduling() async throws {
        let store = try makeStore()
        let now: Int64 = 1_000
        let day: Int64 = 86_400

        try await store.addWatch(id: "https://github.com/openai", kind: "github-owner", volatility: .hot, now: now)
        try await store.addWatch(id: "https://blog/feed", kind: "feed", volatility: .warm, now: now)

        let list = try await store.watchSources()
        XCTAssertEqual(list.count, 2)

        // both due immediately on first round (next_due = added = now)
        let due0 = try await store.dueWatchSources(now: now)
        XCTAssertEqual(Set(due0.map(\.id)), ["https://github.com/openai", "https://blog/feed"])

        // a 'changed' poll reschedules the hot source to now + 1 day → no longer due
        try await store.advanceWatch(id: "https://github.com/openai", outcome: .changed, now: now)
        let due1 = try await store.dueWatchSources(now: now)
        XCTAssertEqual(due1.map(\.id), ["https://blog/feed"])
        let gh = try await store.watchSources().first { $0.id.contains("openai") }
        XCTAssertEqual(gh?.nextDueAt, now + day)        // hot cadence
        XCTAssertEqual(gh?.errorCount, 0)

        // pausing removes it from the due set
        try await store.setWatchStatus(id: "https://blog/feed", status: .paused)
        let due2 = try await store.dueWatchSources(now: now)
        XCTAssertTrue(due2.isEmpty)

        // a failed poll backs off + increments the error streak
        try await store.setWatchStatus(id: "https://blog/feed", status: .active)
        try await store.advanceWatch(id: "https://blog/feed", outcome: .failed(retryAfterSeconds: nil), now: now)
        let feed = try await store.watchSources().first { $0.id.contains("feed") }
        XCTAssertEqual(feed?.errorCount, 1)
        XCTAssertEqual(feed?.nextDueAt, now + 2 * (3 * day))   // warm 3d × 2× backoff

        // remove
        try await store.removeWatch(id: "https://blog/feed")
        let after = try await store.watchSources()
        XCTAssertEqual(after.map(\.id), ["https://github.com/openai"])
    }

    func testReAddReactivatesAndResetsErrors() async throws {
        let store = try makeStore()
        try await store.addWatch(id: "h", kind: "url", volatility: .cold, now: 0)
        try await store.advanceWatch(id: "h", outcome: .failed(retryAfterSeconds: nil), now: 0, errorThreshold: 1)
        let errored = try await store.watchSources().first
        XCTAssertEqual(errored?.status, .error)        // crossed threshold 1
        // re-adding reactivates + clears the error streak + RE-ARMS the due time
        try await store.addWatch(id: "h", kind: "url", volatility: .hot, now: 10)
        let reArmed = try await store.watchSources().first
        XCTAssertEqual(reArmed?.status, .active)
        XCTAssertEqual(reArmed?.errorCount, 0)
        XCTAssertEqual(reArmed?.volatility, .hot)      // cadence updated
        XCTAssertEqual(reArmed?.nextDueAt, 10)         // re-armed to "now" → due immediately
        let due = try await store.dueWatchSources(now: 10)
        XCTAssertEqual(due.map(\.id), ["h"])           // and actually appears in the due set
    }

    func testReAddReArmsAFutureBackoff() async throws {
        let store = try makeStore()
        // a source backed off far into the future
        try await store.addWatch(id: "g", kind: "url", volatility: .cold, now: 0)
        try await store.advanceWatch(id: "g", outcome: .failed(retryAfterSeconds: 10_000_000), now: 0)
        let future = try await store.watchSources().first
        XCTAssertGreaterThan(future?.nextDueAt ?? 0, 1_000)      // due far in the future
        let dueBefore = try await store.dueWatchSources(now: 1_000)
        XCTAssertTrue(dueBefore.isEmpty)
        // re-adding makes it due NOW (the CLI's "due now" message is honest)
        try await store.addWatch(id: "g", kind: "url", volatility: .hot, now: 1_000)
        let dueAfter = try await store.dueWatchSources(now: 1_000)
        XCTAssertEqual(dueAfter.map(\.id), ["g"])
    }
}
