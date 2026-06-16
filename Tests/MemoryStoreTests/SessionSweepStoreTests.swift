import XCTest
import Foundation
@testable import MemoryStore

/// Boot-time orphan sweep: a crash leaves ingest jobs `running` (and research sessions
/// `in_progress`), which show as perpetual ghosts + invite a re-spend. The sweep reaps
/// stale ones to `failed`, gated on age, idempotently.
final class SessionSweepStoreTests: XCTestCase {
    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "sweep-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private let now: Int64 = 1_800_000_000
    private let hour: Int64 = 3600

    func testReapsStaleRunningIngestJobsByThreshold() async throws {
        let store = try makeStore()
        try await store.ingestBegin(jobID: "old", input: "x", adapter: nil, rawType: nil, corpus: nil, startedAt: now - 7 * hour)
        try await store.ingestBegin(jobID: "fresh", input: "y", adapter: nil, rawType: nil, corpus: nil, startedAt: now - 1 * hour)
        let r = try await store.sweepStaleRunningSessions(now: now, olderThanSeconds: 6 * hour)
        XCTAssertEqual(r.ingestJobs, 1, "only the >6h job is reaped")
        let old = try await store.ingestJob("old")
        let fresh = try await store.ingestJob("fresh")
        XCTAssertEqual(old?.status, "failed")
        XCTAssertNotNil(old?.error, "a reaped job is stamped with a reason for the UI")
        XCTAssertEqual(fresh?.status, "running", "a job within the threshold (this boot's work) is untouched")
    }

    func testSweepIsIdempotentAndDoesNotReStamp() async throws {
        let store = try makeStore()
        try await store.ingestBegin(jobID: "old", input: "x", adapter: nil, rawType: nil, corpus: nil, startedAt: now - 7 * hour)
        _ = try await store.sweepStaleRunningSessions(now: now)
        let firstFinished = try await store.ingestJob("old")?.finishedAt
        let second = try await store.sweepStaleRunningSessions(now: now + hour)
        XCTAssertEqual(second.ingestJobs, 0, "an already-failed row is never re-reaped")
        let stillFinished = try await store.ingestJob("old")?.finishedAt
        XCTAssertEqual(firstFinished, stillFinished, "finished_at must not be re-stamped on a second sweep")
    }

    func testReapsStaleResearchSession() async throws {
        let store = try makeStore()
        try await store.upsertResearchSession(ResearchSessionRow(
            sessionID: "s", startTime: now - 7 * hour, status: "in_progress"))
        let r = try await store.sweepStaleRunningSessions(now: now)
        XCTAssertEqual(r.researchSessions, 1)
        let s = try await store.researchSession(id: "s")
        XCTAssertEqual(s?.status, "failed")
    }

    func testFreshResearchSessionUntouched() async throws {
        let store = try makeStore()
        try await store.upsertResearchSession(ResearchSessionRow(
            sessionID: "s", startTime: now - 1 * hour, status: "in_progress"))
        let r = try await store.sweepStaleRunningSessions(now: now)
        XCTAssertEqual(r.researchSessions, 0)
        let s = try await store.researchSession(id: "s")
        XCTAssertEqual(s?.status, "in_progress", "an in-flight session from this boot is preserved")
    }

    // start_time is NULLABLE; COALESCE(start_time, 0) treats a NULL stamp as epoch 0 so a
    // prior-run orphan running session with no start stamp is reaped at boot, not left a ghost.
    func testReapsNullStartTimeResearchSession() async throws {
        let store = try makeStore()
        try await store.upsertResearchSession(ResearchSessionRow(
            sessionID: "ghost", startTime: nil, status: "running"))
        let r = try await store.sweepStaleRunningSessions(now: now)
        XCTAssertEqual(r.researchSessions, 1, "a NULL-start_time running session must be reaped, not left a ghost")
        let s = try await store.researchSession(id: "ghost")
        XCTAssertEqual(s?.status, "failed")
    }
}
