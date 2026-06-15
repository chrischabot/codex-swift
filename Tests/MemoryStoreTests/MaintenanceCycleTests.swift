import XCTest
import Foundation
@testable import MemoryStore

/// Severe coverage for the nightly MaintenanceCycle (gbrain.md Wave 1.7): it must
/// turn the read-only scanners into durable transitions, be idempotent, honor
/// dry-run + abort, and NOT flip brand-new (never-reviewed) claims to stale.
final class MaintenanceCycleTests: XCTestCase {
    private let day: Int64 = 86_400

    private func makeStore() throws -> MemoryStore {
        let db = NSTemporaryDirectory() + "maint-cycle-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: db, embeddingDimension: 8))
    }

    @discardableResult
    private func seedClaim(_ store: MemoryStore, text: String, status: ClaimStatus,
                           firstSeen: Int64, lastReviewed: Int64?, updatedAt: Int64,
                           volatility: Volatility = .hot) async throws -> Int64 {
        try await store.upsertClaim(ClaimRow(
            text: text, status: status, confidence: 0.8, volatility: volatility,
            firstSeen: firstSeen, lastReviewed: lastReviewed, updatedAt: updatedAt))
    }

    func testFreshnessFlipsAgedClaimNotFreshOneAndIsIdempotent() async throws {
        let store = try makeStore()
        let now: Int64 = 1_800_000_000
        // Aged, never-reviewed → stale (ref = firstSeen, 400d old, hot half-life 30d).
        try await seedClaim(store, text: "an old factual claim about X", status: .active,
                            firstSeen: now - 400 * day, lastReviewed: nil, updatedAt: now - 400 * day)
        // Brand-new, never-reviewed → must NOT be flagged stale.
        try await seedClaim(store, text: "a brand new factual claim about Y", status: .active,
                            firstSeen: now, lastReviewed: nil, updatedAt: now)

        let cycle = MaintenanceCycle(store: store)
        let report = await cycle.run(now: now)

        let freshness = report.phases.first { $0.name == "freshness" }
        XCTAssertEqual(freshness?.touched, 1, "only the aged claim should be flipped")
        XCTAssertEqual(freshness?.status, .ok)
        let stale = try await store.claimsByStatus(.stale)
        let active = try await store.claimsByStatus(.active)
        XCTAssertEqual(stale.count, 1)
        XCTAssertTrue(stale.first?.text.contains("old") ?? false)
        XCTAssertEqual(active.count, 1, "the fresh claim stays active")

        // Idempotent: second run touches nothing.
        let report2 = await cycle.run(now: now)
        XCTAssertEqual(report2.phases.first { $0.name == "freshness" }?.touched, 0)
    }

    func testDryRunReportsButDoesNotMutate() async throws {
        let store = try makeStore()
        let now: Int64 = 1_800_000_000
        try await seedClaim(store, text: "an old factual claim about X", status: .active,
                            firstSeen: now - 400 * day, lastReviewed: nil, updatedAt: now - 400 * day)
        let report = await MaintenanceCycle(store: store).run(now: now, dryRun: true)
        XCTAssertEqual(report.phases.first { $0.name == "freshness" }?.touched, 1, "dry-run still reports")
        let staleAfter = try await store.claimsByStatus(.stale)
        let activeAfter = try await store.claimsByStatus(.active)
        XCTAssertEqual(staleAfter.count, 0, "dry-run mutates nothing")
        XCTAssertEqual(activeAfter.count, 1)
    }

    func testDriftPhaseMarksChangedSynthesis() async throws {
        let store = try makeStore()
        let now: Int64 = 1_800_000_000
        // A fresh claim (won't be flipped by freshness) whose updated_at is AFTER
        // the synthesis was generated → the page is drifted.
        let cid = try await seedClaim(store, text: "a recently updated claim", status: .active,
                                      firstSeen: now, lastReviewed: now, updatedAt: now)
        let sid = try await store.upsertSynthesis(SynthesisRow(
            slug: "synth-drift", category: "synthesis", title: "Drift", bodyPath: "/tmp/x.md",
            createdAt: now - 1000 * day, updatedAt: now - 1000 * day, generatedAt: now - 1000 * day))
        try await store.linkSynthesisClaim(synthesis: sid, claim: cid)

        let report = await MaintenanceCycle(store: store).run(now: now)
        let drift = report.phases.first { $0.name == "drift" }
        XCTAssertGreaterThanOrEqual(drift?.touched ?? 0, 1, "the changed synthesis should be marked")
        let marker = try await store.metaValue("synthesis_review:\(sid)")
        XCTAssertNotNil(marker, "a durable review marker must be written")
    }

    func testAbortStopsBeforeAnyPhase() async throws {
        let store = try makeStore()
        let now: Int64 = 1_800_000_000
        try await seedClaim(store, text: "an old claim", status: .active,
                            firstSeen: now - 400 * day, lastReviewed: nil, updatedAt: now - 400 * day)
        let report = await MaintenanceCycle(store: store).run(now: now, abort: { true })
        XCTAssertTrue(report.aborted)
        XCTAssertTrue(report.phases.isEmpty, "aborting before phase 1 runs nothing")
        let staleAfter = try await store.claimsByStatus(.stale)
        XCTAssertEqual(staleAfter.count, 0, "no mutation on abort")
    }

    func testReportHasAllThreePhasesWhenNotAborted() async throws {
        let store = try makeStore()
        let now: Int64 = 1_800_000_000
        let report = await MaintenanceCycle(store: store).run(now: now)
        XCTAssertEqual(report.phases.map(\.name), ["freshness", "drift", "librarian"])
        XCTAssertFalse(report.aborted)
    }
}
