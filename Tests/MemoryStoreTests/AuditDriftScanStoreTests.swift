import XCTest
@testable import MemoryStore

final class AuditDriftScanStoreTests: XCTestCase {

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "auditscan-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }

    func testAuditDriftScanOverStore() async throws {
        let store = try makeStore()
        // A report generated at t=100, compiled from one claim last updated at t=50.
        let sid = try await store.upsertSynthesis(SynthesisRow(
            slug: "p", category: "report", title: "p", bodyPath: "p.md",
            createdAt: 100, updatedAt: 100, generatedAt: 100))
        let c1 = try await store.upsertClaim(ClaimRow(text: "old fact", firstSeen: 50, updatedAt: 50))
        try await store.linkSynthesisClaim(synthesis: sid, claim: c1)

        let before = try await store.auditDriftScan()
        XCTAssertEqual(before.first(where: { $0.id == sid })?.status, .current)

        // A claim updated AFTER the page was generated → the page is now drifted.
        let c2 = try await store.upsertClaim(ClaimRow(text: "new fact", firstSeen: 200, updatedAt: 200))
        try await store.linkSynthesisClaim(synthesis: sid, claim: c2)

        let after = try await store.auditDriftScan()
        XCTAssertEqual(after.first(where: { $0.id == sid })?.status, .drifted)
        XCTAssertEqual(after.first?.id, sid)   // drifted pages sort first
    }

    func testEmptyStoreAuditIsEmpty() async throws {
        let store = try makeStore()
        let scan = try await store.auditDriftScan()
        XCTAssertTrue(scan.isEmpty)
    }
}
