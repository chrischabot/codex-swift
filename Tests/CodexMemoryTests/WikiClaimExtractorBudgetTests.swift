import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore
import MemoryScore

/// Severe coverage for the SpendGate-gated claim extractor (gbrain.md Wave 0.1).
/// The safety property under test: when the monthly USD ceiling is reached, the
/// extractor returns no claims and records NO spend, WITHOUT issuing any network
/// call (the gate short-circuits before the URLSession request). All tests are
/// hermetic — the rate-limited path never touches the network, so the dummy API
/// key is never used.
final class WikiClaimExtractorBudgetTests: XCTestCase {
    private func makeStore(dim: Int = 8) throws -> MemoryStore {
        let db = NSTemporaryDirectory() + "wiki-claim-budget-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: db, embeddingDimension: dim))
    }

    func testZeroCeilingRateLimitsBeforeAnyNetworkCall() async throws {
        let store = try makeStore()
        let gate = SpendGate(store: store,
                             config: .init(monthlyCeilingUSD: 0, bucket: "wiki-research"))
        let extractor = WikiClaimExtractor(
            apiKey: "unused-because-rate-limited", model: "gpt-4o-mini", spendGate: gate)

        let claims = await extractor.extract(
            text: "Some sufficiently long factual passage that would otherwise be extracted.",
            maxClaims: 5)

        XCTAssertEqual(claims, [], "ceiling=0 must rate-limit before the network call")
        let spent = try await gate.monthlySpentUSD()
        XCTAssertEqual(spent, 0, accuracy: 1e-9, "a rate-limited call must record no spend")
    }

    func testPriorSpendOverCeilingRateLimits() async throws {
        let store = try makeStore()
        let now = Int64(Date().timeIntervalSince1970)
        // Pre-load this month's bucket past a $1 ceiling.
        try await store.recordSpend(SpendRow(
            ts: now, bucket: "wiki-research", units: 1_000_000,
            unitKind: "tokens", costUSD: 5.0))
        let gate = SpendGate(store: store,
                             config: .init(monthlyCeilingUSD: 1.0, bucket: "wiki-research"))
        let extractor = WikiClaimExtractor(apiKey: "unused", model: "gpt-4o-mini", spendGate: gate)

        let claims = await extractor.extract(
            text: "Another sufficiently long passage of factual text here.", maxClaims: 5)
        XCTAssertEqual(claims, [], "month-to-date spend over the ceiling must rate-limit")
    }

    func testParseClaimsTrimsAndDropsShort() {
        let json = #"{"claims": ["  A sufficiently long factual claim about X.  ", "short", "Another valid factual claim here."]}"#
        let claims = WikiClaimExtractor.parseClaims(json)
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims.first, "A sufficiently long factual claim about X.")
        XCTAssertFalse(claims.contains("short"), "<=12-char claims are dropped")
    }

    func testParseClaimsRejectsMalformed() {
        XCTAssertEqual(WikiClaimExtractor.parseClaims("not json at all"), [])
        XCTAssertEqual(WikiClaimExtractor.parseClaims(#"{"notclaims": []}"#), [])
        XCTAssertEqual(WikiClaimExtractor.parseClaims(""), [])
    }
}
