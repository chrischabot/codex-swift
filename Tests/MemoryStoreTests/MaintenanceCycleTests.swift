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

    // MARK: marker queue is now READABLE (the dream-cycle source-of-truth seam)

    func testMetaEntriesPrefixScanAndCount() async throws {
        let store = try makeStore()
        try await store.setMetaValue("librarian_tier2:42", "1")
        try await store.setMetaValue("librarian_tier2:7", "1")
        try await store.setMetaValue("synthesis_review:3", "drifted")
        try await store.setMetaValue("librarian_tier2", "x")       // no colon → different key
        try await store.setMetaValue("librarian_tier2x:9", "x")    // different family
        let lib = try await store.metaEntries(prefix: "librarian_tier2:")
        XCTAssertEqual(lib.map(\.key), ["librarian_tier2:42", "librarian_tier2:7"], "only the exact prefix family, ordered")
        let libCount = try await store.metaCount(prefix: "librarian_tier2:")
        let revCount = try await store.metaCount(prefix: "synthesis_review:")
        XCTAssertEqual(libCount, 2)
        XCTAssertEqual(revCount, 1)
    }

    // RECONCILE: markers must not grow monotonically — the cycle drops markers no longer
    // in the live flagged/drifted set, and a deleted document clears its orphan marker.

    func testCycleReconcilesAwayStaleMarkers() async throws {
        let store = try makeStore()
        // Markers for ids the live scan will NOT flag/drift (here: non-existent ids).
        try await store.setMetaValue("librarian_tier2:9999", "1")
        try await store.setMetaValue("synthesis_review:8888", "drifted")
        let preLib = try await store.metaCount(prefix: "librarian_tier2:")
        let preRev = try await store.metaCount(prefix: "synthesis_review:")
        XCTAssertEqual(preLib, 1); XCTAssertEqual(preRev, 1)

        _ = await MaintenanceCycle(store: store).run(now: 1_800_000_000)

        let postLib = try await store.metaCount(prefix: "librarian_tier2:")
        let postRev = try await store.metaCount(prefix: "synthesis_review:")
        XCTAssertEqual(postLib, 0, "a librarian marker no longer flagged is reconciled away (was monotone-growing)")
        XCTAssertEqual(postRev, 0, "a drift marker no longer drifted is reconciled away")
    }

    func testDryRunDoesNotReconcileMarkers() async throws {
        let store = try makeStore()
        try await store.setMetaValue("librarian_tier2:9999", "1")
        _ = await MaintenanceCycle(store: store).run(now: 1_800_000_000, dryRun: true)
        let n = try await store.metaCount(prefix: "librarian_tier2:")
        XCTAssertEqual(n, 1, "dry-run mutates nothing — neither writes nor reconciles markers")
    }

    // CROSS-AXIS REGRESSION: librarian_tier2 markers are keyed by synthesis.id (librarianScan
    // SELECTs FROM synthesis), NOT document.id — independent id sequences routinely collide.
    // A document delete must therefore NOT touch a synthesis-keyed marker sharing the number,
    // or it would destroy a still-valid synthesis's marker and under-count flaggedStale. The
    // cycle reconcile (not document delete) is the source of truth for orphan markers.
    func testDocumentDeleteDoesNotDestroySynthesisKeyedMarker() async throws {
        let store = try makeStore()
        let docID = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "wiki://x", bodyPath: "inline:x",
            fetchedAt: 1, contentSHA: Data([1]), rawBytes: 10))
        // A marker for the SYNTHESIS that happens to share the document's numeric id.
        try await store.setMetaValue("librarian_tier2:\(docID)", "1")
        try await store.deleteDocument(id: docID)
        let after = try await store.metaValue("librarian_tier2:\(docID)")
        XCTAssertNotNil(after, "document delete must NOT destroy a synthesis-keyed marker sharing the id")
    }

    func testMetaEntriesEscapesLikeWildcards() async throws {
        let store = try makeStore()
        try await store.setMetaValue("50%_off\\promoA", "1")   // literal % _ \ in the key
        try await store.setMetaValue("500XoffYpromoB", "2")    // would match if % _ were wildcards
        let hits = try await store.metaEntries(prefix: "50%_off\\promo")
        XCTAssertEqual(hits.map(\.key), ["50%_off\\promoA"], "LIKE metacharacters in the prefix are escaped, not wildcarded")
    }

    func testCycleMarkerIsReadableAsQueueEntryWithVerdict() async throws {
        let store = try makeStore()
        let now: Int64 = 1_800_000_000
        let cid = try await seedClaim(store, text: "c", status: .active, firstSeen: now, lastReviewed: now, updatedAt: now)
        let sid = try await store.upsertSynthesis(SynthesisRow(
            slug: "s", category: "synthesis", title: "S", bodyPath: "/tmp/x.md",
            createdAt: now - 1000 * day, updatedAt: now - 1000 * day, generatedAt: now - 1000 * day))
        try await store.linkSynthesisClaim(synthesis: sid, claim: cid)
        _ = await MaintenanceCycle(store: store).run(now: now)
        // The marker the cycle committed is now ENUMERABLE (was write-only) and carries the verdict.
        let entries = try await store.metaEntries(prefix: "synthesis_review:")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.key, "synthesis_review:\(sid)")
        XCTAssertEqual(entries.first?.value, "drifted", "the marker carries the DriftStatus the scan produced")
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
