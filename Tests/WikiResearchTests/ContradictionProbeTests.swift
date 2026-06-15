import XCTest
@testable import WikiResearch
@testable import MemoryStore

/// Severe coverage for the contradiction probe-runner (gbrain.md Wave 3): the
/// prefilter, bounded judge calls (the adversarial O(n²) guard), deterministic
/// order, and opt-in auto-apply.
final class ContradictionProbeTests: XCTestCase {
    private func claim(_ id: Int64, _ text: String, firstSeen: Int64 = 100) -> ClaimRow {
        ClaimRow(id: id, text: text, firstSeen: firstSeen, updatedAt: firstSeen)
    }

    // MARK: - prefilter

    func testPrefilterSubjectOverlap() {
        let a = claim(1, "Acme raised a Series A funding round")
        let b = claim(2, "Acme did not raise any funding")
        XCTAssertTrue(ContradictionPrefilter.shouldJudge(a, b), "shared subject tokens → candidate")
    }

    func testPrefilterRejectsUnrelated() {
        let a = claim(1, "Acme raised funding")
        let b = claim(2, "The weather in Tokyo is rainy")
        XCTAssertFalse(ContradictionPrefilter.shouldJudge(a, b))
    }

    func testPrefilterRejectsSelfAndDup() {
        let a = claim(1, "Acme raised funding rapidly")
        XCTAssertFalse(ContradictionPrefilter.shouldJudge(a, a), "same id")
        let dup = ClaimRow(id: 2, text: "Acme raised funding rapidly", firstSeen: 1, updatedAt: 1)
        XCTAssertFalse(ContradictionPrefilter.shouldJudge(a, dup), "byte-dup is dedup, not contradiction")
    }

    func testSignificantTokensDropStopwordsAndShort() {
        let toks = ContradictionPrefilter.significantTokens("The Acme CEO has not left")
        XCTAssertTrue(toks.contains("acme"))
        XCTAssertTrue(toks.contains("ceo"))
        XCTAssertTrue(toks.contains("left"))
        XCTAssertFalse(toks.contains("the"), "stopword dropped")
        XCTAssertFalse(toks.contains("has"), "stopword dropped")
    }

    // MARK: - bounded judge calls (adversarial)

    func testUnrelatedCorpusProducesZeroJudgeCalls() async {
        // 60 mutually-unrelated claims with fully DISJOINT vocabulary (each token
        // unique to one claim) → prefilter rejects all pairs → 0 judge calls.
        let claims = (1...60).map { claim(Int64($0), "alpha\($0) beta\($0) gamma\($0)") }
        let probe = ContradictionProbe(judge: CountingJudge(verdict: .contradiction, confidence: 0.9))
        let report = await probe.run(claims: claims, now: 1)
        XCTAssertEqual(report.pairsJudged, 0, "no overlap → nothing judged (O(n²) prefilter, O(0) judge)")
    }

    func testMaxJudgeCallsBudgetTruncates() async {
        // Many related claims; cap judge calls at 3.
        let claims = (1...20).map { claim(Int64($0), "Acme funding round number \($0)") }
        let probe = ContradictionProbe(judge: CountingJudge(verdict: .noContradiction, confidence: 0.0),
                                       maxPairsPerClaim: 100, maxJudgeCalls: 3)
        let report = await probe.run(claims: claims, now: 1)
        XCTAssertEqual(report.pairsJudged, 3)
        XCTAssertTrue(report.truncated)
    }

    func testDeterministicAcrossRuns() async {
        let claims = (1...8).map { claim(Int64($0), "Acme CEO change event \($0)") }
        let p = ContradictionProbe(judge: CountingJudge(verdict: .noContradiction, confidence: 0.0))
        let r1 = await p.run(claims: claims, now: 1)
        let r2 = await p.run(claims: claims.reversed(), now: 1)
        XCTAssertEqual(r1.pairsJudged, r2.pairsJudged, "pair order is id-sorted, run-independent")
    }

    // MARK: - report-only vs apply

    func testReportOnlyDoesNotMutate() async throws {
        let store = try makeStore()
        let c1 = try await store.upsertClaim(ClaimRow(text: "Acme CEO is Alice", status: .active, firstSeen: 100, updatedAt: 100))
        let c2 = try await store.upsertClaim(ClaimRow(text: "Acme CEO Alice stepped down", status: .active, firstSeen: 200, updatedAt: 200))
        let a = try await store.claim(id: c1)!
        let b = try await store.claim(id: c2)!
        let probe = ContradictionProbe(judge: CountingJudge(verdict: .temporalSupersession, confidence: 0.95))
        let report = await probe.run(claims: [a, b], now: 300, apply: false, store: store)
        XCTAssertEqual(report.applied, 0, "report-only mode applies nothing")
        XCTAssertFalse(report.reviewQueue.isEmpty, "the supersession is queued, not applied")
        let after = try await store.claim(id: c1)
        XCTAssertEqual(after?.status, .active, "no mutation in report-only mode")
    }

    func testApplyModeArchivesOlder() async throws {
        let store = try makeStore()
        let older = try await store.upsertClaim(ClaimRow(text: "Acme CEO is Alice", status: .active, firstSeen: 100, updatedAt: 100))
        let newer = try await store.upsertClaim(ClaimRow(text: "Acme CEO Alice stepped down", status: .active, firstSeen: 200, updatedAt: 200))
        let a = try await store.claim(id: older)!
        let b = try await store.claim(id: newer)!
        let probe = ContradictionProbe(judge: CountingJudge(verdict: .temporalSupersession, confidence: 0.95))
        let report = await probe.run(claims: [a, b], now: 300, apply: true, store: store)
        XCTAssertEqual(report.applied, 1)
        let archived = try await store.claim(id: older)
        let kept = try await store.claim(id: newer)
        XCTAssertEqual(archived?.status, .archived)
        XCTAssertEqual(kept?.status, .active)
    }

    private func makeStore() throws -> MemoryStore {
        let db = NSTemporaryDirectory() + "contradiction-probe-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: db, embeddingDimension: 8))
    }
}

/// A judge backend that returns a fixed verdict and counts its invocations.
private final class CountingJudge: ContradictionJudgeBackend, @unchecked Sendable {
    let verdict: ContradictionVerdict
    let confidence: Double
    init(verdict: ContradictionVerdict, confidence: Double) { self.verdict = verdict; self.confidence = confidence }
    func judge(_ a: ClaimRow, _ b: ClaimRow, context: JudgeContext) async -> JudgedPair {
        JudgedPair(verdict: ContradictionJudge.normalize(verdict, confidence: confidence),
                   confidence: confidence, reasoning: "counting")
    }
}
