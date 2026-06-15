import XCTest
@testable import MemoryRetrieve
import MemoryStore

/// Severe coverage for per-source recency decay (gbrain.md Wave 2.17).
final class RecencyDecayTests: XCTestCase {

    func testFreshDocGetsMaxBoostOldDecaysTowardOne() {
        let fresh = RecencyDecay.factor(source: .rss, ageDays: 0)
        let old = RecencyDecay.factor(source: .rss, ageDays: 100_000)
        XCTAssertEqual(fresh, 1.0 + RecencyDecay.coefficient(.rss), accuracy: 1e-9,
                       "age 0 → 1 + coefficient")
        XCTAssertEqual(old, 1.0, accuracy: 1e-3, "very old → ~1.0 (no demote)")
        XCTAssertGreaterThan(fresh, old)
    }

    func testMonotonicNonIncreasingInAge() {
        var prev = Double.greatestFiniteMagnitude
        for age in stride(from: 0.0, through: 800, by: 25) {
            let f = RecencyDecay.factor(source: .web, ageDays: age)
            XCTAssertLessThanOrEqual(f, prev + 1e-12, "factor must not increase with age")
            prev = f
        }
    }

    func testFactorNeverDemotes() {
        for source in MemorySource.allCases {
            for age in [0.0, 1, 30, 365, 5000] {
                XCTAssertGreaterThanOrEqual(RecencyDecay.factor(source: source, ageDays: age), 1.0,
                                            "\(source)@\(age) must be ≥ 1 (boost-only)")
            }
        }
    }

    func testFastSourcesDecayFasterThanEvergreen() {
        // At 30 days, an RSS feed (hl 14) should have decayed more toward 1 than
        // an arXiv paper (hl 365) relative to its own coefficient.
        let rssDrop = RecencyDecay.factor(source: .rss, ageDays: 0) - RecencyDecay.factor(source: .rss, ageDays: 30)
        let arxivDrop = RecencyDecay.factor(source: .arxiv, ageDays: 0) - RecencyDecay.factor(source: .arxiv, ageDays: 30)
        XCTAssertGreaterThan(rssDrop, arxivDrop, "short half-life decays faster")
    }

    func testNegativeAgeClampedToOne() {
        // A publishedAt in the future (clock skew) must not over-boost beyond age 0.
        let skew = RecencyDecay.factor(source: .x, ageDays: -50)
        XCTAssertEqual(skew, RecencyDecay.factor(source: .x, ageDays: 0), accuracy: 1e-9)
    }

    func testEpochConvenienceUsesPublishedOverFetched() {
        let now: Int64 = 1_800_000_000
        let dayAgo = now - 86_400
        let yearAgo = now - 365 * 86_400
        // publishedAt (recent) wins over fetchedAt (old).
        let f = RecencyDecay.factor(source: .web, publishedAt: dayAgo, fetchedAt: yearAgo, now: now)
        let expected = RecencyDecay.factor(source: .web, ageDays: 1)
        XCTAssertEqual(f, expected, accuracy: 1e-9)
        // nil publishedAt falls back to fetchedAt.
        let f2 = RecencyDecay.factor(source: .web, publishedAt: nil, fetchedAt: dayAgo, now: now)
        XCTAssertEqual(f2, expected, accuracy: 1e-9)
    }
}
