import XCTest
@testable import MemoryStore

/// Severe coverage for the calibration scorer (gbrain.md Wave 3.26): Brier math,
/// weighted-vs-scalar conviction weighting, cold-start floor, coverage, and the
/// [0,1] Brier invariant.
final class CalibrationScorerTests: XCTestCase {
    private func items(_ pairs: [(Double, Double?)], domain: String = "d") -> [ResolvedItem] {
        pairs.map { ResolvedItem(domain: domain, confidence: $0.0, outcome: $0.1) }
    }

    func testPerfectCalibrationBrierZero() {
        let s = CalibrationScorer.score(items(Array(repeating: (1.0, 1.0), count: 5)))
        XCTAssertEqual(s.brier, 0, accuracy: 1e-9)
        XCTAssertEqual(s.accuracy, 1.0, accuracy: 1e-9)
        XCTAssertFalse(s.coldStart)
        XCTAssertEqual(s.n, 5)
    }

    func testWorstCaseBrierIsOne() {
        let s = CalibrationScorer.score(items(Array(repeating: (1.0, 0.0), count: 5)))
        XCTAssertEqual(s.brier, 1.0, accuracy: 1e-9, "confident-and-wrong → Brier 1")
        XCTAssertEqual(s.accuracy, 0.0, accuracy: 1e-9)
    }

    func testHalfConfidenceBrierQuarter() {
        let s = CalibrationScorer.score(items(Array(repeating: (0.5, 0.0), count: 6)))
        XCTAssertEqual(s.brier, 0.25, accuracy: 1e-9)
    }

    func testColdStartBelowMinN() {
        let s = CalibrationScorer.score(items([(1.0, 1.0), (1.0, 1.0)]))  // n=2 < 5
        XCTAssertTrue(s.coldStart)
        XCTAssertEqual(s.n, 2)
    }

    func testCoverageExcludesUnresolvable() {
        // 5 resolved + 5 unresolvable → coverage 0.5, n 5.
        var pairs: [(Double, Double?)] = Array(repeating: (0.8, 1.0), count: 5)
        pairs += Array(repeating: (0.8, nil), count: 5)
        let s = CalibrationScorer.score(items(pairs))
        XCTAssertEqual(s.n, 5)
        XCTAssertEqual(s.coverage, 0.5, accuracy: 1e-9)
        XCTAssertFalse(s.coldStart)
    }

    func testWeightedBrierUpweightsHighConvictionMiss() {
        // One high-conviction miss (0.95→0) + four well-calibrated hits (0.5→0.5).
        var pairs: [(Double, Double?)] = [(0.95, 0.0)]
        pairs += Array(repeating: (0.5, 0.5), count: 4)
        let scalar = CalibrationScorer.score(items(pairs), aggregator: .scalarBrier)
        let weighted = CalibrationScorer.score(items(pairs), aggregator: .weightedBrier)
        // The 0.5→0.5 hits have zero conviction, so weighted Brier is dominated by
        // the single high-conviction miss → strictly worse (higher) than scalar.
        XCTAssertGreaterThan(weighted.brier, scalar.brier)
    }

    func testPartialOutcomesCountHalf() {
        let s = CalibrationScorer.score(items(Array(repeating: (0.5, 0.5), count: 5)))
        XCTAssertEqual(s.partialRate, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.accuracy, 0.5, accuracy: 1e-9, "all-partial → accuracy 0.5")
        XCTAssertEqual(s.brier, 0, accuracy: 1e-9, "0.5 confidence on a 0.5 outcome is perfectly calibrated")
    }

    func testScoreByDomainGroupsAndSortsDeterministically() {
        let mixed = items([(1.0, 1.0)], domain: "zeta") + items([(0.0, 1.0)], domain: "alpha")
        let cards = CalibrationScorer.scoreByDomain(mixed)
        XCTAssertEqual(cards.map(\.domain), ["alpha", "zeta"], "domains sorted")
    }

    func testBrierAlwaysInUnitInterval() {
        // Property: across random-ish confidences/outcomes, Brier ∈ [0,1].
        for seed in 0..<20 {
            let conf = Double((seed * 37) % 101) / 100.0
            let out: Double = (seed % 3 == 0) ? 1.0 : (seed % 3 == 1 ? 0.0 : 0.5)
            let s = CalibrationScorer.score(items(Array(repeating: (conf, out), count: 5)))
            XCTAssertGreaterThanOrEqual(s.brier, 0)
            XCTAssertLessThanOrEqual(s.brier, 1)
        }
    }
}
