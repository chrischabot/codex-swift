import XCTest
@testable import WikiResearch
import MemoryStore

/// Wave 3.26: the contradiction→supersession→calibration loop now closes —
/// CalibrationProbe maps a judged pair + its resolved action to a graded ResolvedItem
/// (confidence-IN-CONFLICT), which CalibrationScorer aggregates per domain. Pure mapper
/// semantics + the probe-emits-items integration.
final class CalibrationProbeTests: XCTestCase {
    private func claim(_ text: String, category: String?, firstSeen: Int64) -> ClaimRow {
        ClaimRow(text: text, category: category, firstSeen: firstSeen, updatedAt: firstSeen)
    }
    private func judged(_ v: ContradictionVerdict, _ c: Double) -> JudgedPair {
        JudgedPair(verdict: v, confidence: c, reasoning: "r")
    }

    func testMutatingActionScoresConfidenceInConflict() {
        let a = claim("old", category: "ai-safety", firstSeen: 100)   // older → domain source
        let b = claim("new", category: "other", firstSeen: 200)
        let item = CalibrationProbe.resolvedItem(for: judged(.temporalSupersession, 0.9), a: a, b: b,
                                                 action: .archiveOlder(keep: 2, archive: 1))
        XCTAssertEqual(item.domain, "ai-safety")
        XCTAssertEqual(item.confidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(item.outcome, 1.0, "the judge committed to a real conflict")
    }

    func testNoContradictionComplementsConfidence() {
        let a = claim("a", category: "x", firstSeen: 100)
        let b = claim("b", category: "y", firstSeen: 200)
        let item = CalibrationProbe.resolvedItem(for: judged(.noContradiction, 0.8), a: a, b: b, action: .skip)
        XCTAssertEqual(item.confidence, 0.2, accuracy: 1e-9, "confidence-in-conflict = 1 − confidence-in-no-conflict")
        XCTAssertEqual(item.outcome, 0.0)
    }

    func testFlagForReviewIsUnresolvable() {
        let a = claim("a", category: "x", firstSeen: 100)
        let b = claim("b", category: "y", firstSeen: 200)
        let item = CalibrationProbe.resolvedItem(for: judged(.temporalRegression, 0.95), a: a, b: b,
                                                 action: .flagForReview(1, 2, reason: "regression"))
        XCTAssertNil(item.outcome, "unresolvable → counted in coverage, excluded from Brier")
    }

    func testDomainFallsBackToUncategorizedOnOlderClaim() {
        let a = claim("a", category: nil, firstSeen: 300)   // newer
        let b = claim("b", category: nil, firstSeen: 100)   // OLDER, no category → fallback
        let item = CalibrationProbe.resolvedItem(for: judged(.noContradiction, 0.5), a: a, b: b, action: .skip)
        XCTAssertEqual(item.domain, "uncategorized")
    }

    func testScoreByDomainAggregatesEmittedItems() {
        let items = [
            CalibrationProbe.resolvedItem(for: judged(.temporalSupersession, 0.9),
                                          a: claim("o", category: "d", firstSeen: 1), b: claim("n", category: "d", firstSeen: 2),
                                          action: .markBothContradicted(1, 2)),
            CalibrationProbe.resolvedItem(for: judged(.noContradiction, 0.7),
                                          a: claim("o", category: "d", firstSeen: 1), b: claim("n", category: "d", firstSeen: 2),
                                          action: .skip),
            CalibrationProbe.resolvedItem(for: judged(.temporalEvolution, 0.6),
                                          a: claim("o", category: "d", firstSeen: 1), b: claim("n", category: "d", firstSeen: 2),
                                          action: .flagForReview(1, 2, reason: "evolution")),
        ]
        let cards = CalibrationScorer.scoreByDomain(items)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.domain, "d")
        XCTAssertEqual(cards.first?.n, 2, "two resolved (non-nil) outcomes; the flagged one is coverage-only")
        XCTAssertEqual(cards.first?.coverage ?? 0, 2.0 / 3.0, accuracy: 1e-9)
    }
}
