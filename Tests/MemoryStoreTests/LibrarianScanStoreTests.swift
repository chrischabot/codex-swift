import XCTest
@testable import MemoryStore

final class LibrarianScanStoreTests: XCTestCase {

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "librscan-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }

    func testLibrarianScanOverRealStore() async throws {
        let store = try makeStore()
        let now: Int64 = 1_000_000_000
        let day: Int64 = 86_400

        func page(_ slug: String, _ vol: Volatility, stamp: Int64, claims: Int) async throws -> Int64 {
            let sid = try await store.upsertSynthesis(SynthesisRow(
                slug: slug, category: "topic", title: slug, bodyPath: "\(slug).md",
                volatility: vol, verifiedAt: stamp, createdAt: stamp, updatedAt: stamp))
            for i in 0..<claims {
                let cid = try await store.upsertClaim(ClaimRow(text: "\(slug) claim \(i)",
                                                              firstSeen: stamp, updatedAt: stamp))
                try await store.linkSynthesisClaim(synthesis: sid, claim: cid)
            }
            return sid
        }

        let freshID = try await page("fresh", .cold, stamp: now, claims: 5)         // fresh, deep, cold
        let staleID = try await page("stale", .warm, stamp: now - 800 * day, claims: 1) // very old, thin
        let hotID   = try await page("hot", .hot, stamp: now, claims: 3)            // fresh but hot

        let scores = try await store.librarianScan(now: now)
        XCTAssertEqual(scores.count, 3)
        // stalest first
        XCTAssertEqual(scores.first?.documentID, staleID)

        let byID = Dictionary(uniqueKeysWithValues: scores.map { ($0.documentID, $0) })
        XCTAssertFalse(byID[freshID]!.needsTier2)          // fresh + cold + deep → not flagged
        XCTAssertTrue(byID[hotID]!.needsTier2)             // hot always flags
        XCTAssertTrue(byID[staleID]!.needsTier2)           // stale + thin flags
        XCTAssertEqual(byID[freshID]!.quality.sourceCount, 5)
        XCTAssertEqual(byID[freshID]!.quality.depthProxy, 4)   // 5 sources → depth bucket 4
        XCTAssertGreaterThan(byID[freshID]!.staleness.score, byID[staleID]!.staleness.score)
    }

    func testLibrarianScanEmptyStore() async throws {
        let store = try makeStore()
        let scores = try await store.librarianScan(now: 1_000)
        XCTAssertTrue(scores.isEmpty)
    }
}
