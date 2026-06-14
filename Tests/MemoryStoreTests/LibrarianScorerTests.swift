import XCTest
@testable import MemoryStore

final class LibrarianScorerTests: XCTestCase {

    private let day: Int64 = 86_400
    private let now: Int64 = 1_000_000_000

    func testFreshPageScoresFull() {
        // All four stamps = now → each dim 25 → staleness 100.
        let s = LibrarianScorer.PageSignals(
            documentID: 1, volatility: .cold, sourceFetchedAt: now, verifiedAt: now,
            compiledAt: now, sourceChainValidatedAt: now, sourceCount: 5, avgCredibility: 4,
            depthProxy: 4, hasSeeAlso: true)
        let r = LibrarianScorer.score(s, now: now)
        XCTAssertEqual(r.staleness.score, 100, accuracy: 0.001)
        XCTAssertEqual(r.staleness.sourceFreshness, 25, accuracy: 0.001)
        XCTAssertFalse(r.needsTier2)   // fresh, cold, deep, see-also → no escalation
    }

    func testHalfLifeDecay() {
        // A warm page (half-life 90d) whose stamps are exactly 90 days old → each
        // dim = 25 × 0.5 = 12.5 → staleness 50.
        let old = now - 90 * day
        let s = LibrarianScorer.PageSignals(
            documentID: 2, volatility: .warm, sourceFetchedAt: old, verifiedAt: old,
            compiledAt: old, sourceChainValidatedAt: old, depthProxy: 4)
        let r = LibrarianScorer.score(s, now: now)
        XCTAssertEqual(r.staleness.sourceFreshness, 12.5, accuracy: 0.01)
        XCTAssertEqual(r.staleness.score, 50, accuracy: 0.05)
    }

    func testNeverVerifiedDimIsZero() {
        let s = LibrarianScorer.PageSignals(
            documentID: 3, volatility: .cold, sourceFetchedAt: now, verifiedAt: nil,
            compiledAt: now, sourceChainValidatedAt: now, depthProxy: 4)
        let r = LibrarianScorer.score(s, now: now)
        XCTAssertEqual(r.staleness.verification, 0, accuracy: 0.001)   // never verified → 0
        XCTAssertEqual(r.staleness.score, 75, accuracy: 0.001)        // 3 fresh dims
    }

    func testTier2FlagConditions() {
        // (a) low staleness (very old) → flagged
        let oldStamp = now - 800 * day
        let stale = LibrarianScorer.PageSignals(documentID: 4, volatility: .cold,
            sourceFetchedAt: oldStamp, verifiedAt: oldStamp, compiledAt: oldStamp,
            sourceChainValidatedAt: oldStamp, depthProxy: 4)
        XCTAssertTrue(LibrarianScorer.score(stale, now: now).needsTier2)

        // (b) hot volatility ALWAYS flags, even when fresh
        let hot = LibrarianScorer.PageSignals(documentID: 5, volatility: .hot,
            sourceFetchedAt: now, verifiedAt: now, compiledAt: now,
            sourceChainValidatedAt: now, depthProxy: 5)
        XCTAssertTrue(LibrarianScorer.score(hot, now: now).needsTier2)

        // (c) thin depth proxy (1-2) flags even when fresh+cold
        let thin = LibrarianScorer.PageSignals(documentID: 6, volatility: .cold,
            sourceFetchedAt: now, verifiedAt: now, compiledAt: now,
            sourceChainValidatedAt: now, depthProxy: 2)
        XCTAssertTrue(LibrarianScorer.score(thin, now: now).needsTier2)

        // (d) fresh + cold + deep → NOT flagged
        let ok = LibrarianScorer.score(LibrarianScorer.PageSignals(documentID: 7, volatility: .cold,
            sourceFetchedAt: now, verifiedAt: now, compiledAt: now,
            sourceChainValidatedAt: now, depthProxy: 3), now: now)
        XCTAssertFalse(ok.needsTier2)
    }

    func testScanSortsStalestFirst() {
        let fresh = LibrarianScorer.PageSignals(documentID: 10, volatility: .cold,
            sourceFetchedAt: now, verifiedAt: now, compiledAt: now, sourceChainValidatedAt: now, depthProxy: 4)
        let mid = LibrarianScorer.PageSignals(documentID: 11, volatility: .warm,
            sourceFetchedAt: now - 90 * day, verifiedAt: now - 90 * day,
            compiledAt: now - 90 * day, sourceChainValidatedAt: now - 90 * day, depthProxy: 4)
        let stale = LibrarianScorer.PageSignals(documentID: 12, volatility: .hot,
            sourceFetchedAt: now - 300 * day, verifiedAt: nil, compiledAt: now - 300 * day,
            sourceChainValidatedAt: now - 300 * day, depthProxy: 1)
        let scored = LibrarianScorer.scan([fresh, mid, stale], now: now)
        XCTAssertEqual(scored.map(\.documentID), [12, 11, 10])   // stalest → freshest
        XCTAssertTrue(scored[0].staleness.score < scored[2].staleness.score)
    }
}
