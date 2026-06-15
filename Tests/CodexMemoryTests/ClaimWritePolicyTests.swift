import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Severe coverage for the three-bucket confidence write policy (gbrain.md Wave
/// 0.3): credibility tier → confidence → {active, draft, skip}, plus the skip/
/// review JSONL logging. Replaces the old hardcoded `confidence: 0.7`.
final class ClaimWritePolicyTests: XCTestCase {

    // MARK: - tier → confidence

    func testConfidenceByCredibilityTier() {
        // CredibilityScorer.tier: high 4+, medium 2-3, low 0-1, reject <0.
        XCTAssertEqual(ClaimWritePolicy.confidence(forCredibilityPoints: 6), 0.85, accuracy: 1e-9)
        XCTAssertEqual(ClaimWritePolicy.confidence(forCredibilityPoints: 4), 0.85, accuracy: 1e-9)
        XCTAssertEqual(ClaimWritePolicy.confidence(forCredibilityPoints: 3), 0.65, accuracy: 1e-9)
        XCTAssertEqual(ClaimWritePolicy.confidence(forCredibilityPoints: 2), 0.65, accuracy: 1e-9)
        XCTAssertEqual(ClaimWritePolicy.confidence(forCredibilityPoints: 1), 0.55, accuracy: 1e-9)
        XCTAssertEqual(ClaimWritePolicy.confidence(forCredibilityPoints: 0), 0.55, accuracy: 1e-9)
        XCTAssertEqual(ClaimWritePolicy.confidence(forCredibilityPoints: -1), 0.30, accuracy: 1e-9)
    }

    // MARK: - confidence → bucket (boundaries)

    func testBucketBoundaries() {
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: 0.85), .active)
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: 0.80), .active, "0.8 boundary is inclusive → active")
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: 0.799), .draft)
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: 0.65), .draft)
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: 0.50), .draft, "0.5 boundary is inclusive → draft")
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: 0.499), .skip)
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: 0.30), .skip)
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: 0.0), .skip)
    }

    // MARK: - end-to-end tier → status

    func testHighSourceWritesActiveLowSourceSkips() {
        // high-trust source → active ground truth
        let highConf = ClaimWritePolicy.confidence(forCredibilityPoints: 5)
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: highConf).claimStatus, .active)
        // medium-trust → draft review queue
        let medConf = ClaimWritePolicy.confidence(forCredibilityPoints: 2)
        XCTAssertEqual(ClaimWritePolicy.bucket(forConfidence: medConf).claimStatus, .draft)
        // reject-tier → skip (no claim written)
        let rejConf = ClaimWritePolicy.confidence(forCredibilityPoints: -2)
        XCTAssertNil(ClaimWritePolicy.bucket(forConfidence: rejConf).claimStatus)
    }

    func testBucketStatusMapping() {
        XCTAssertEqual(ClaimWritePolicy.Bucket.active.claimStatus, .active)
        XCTAssertEqual(ClaimWritePolicy.Bucket.draft.claimStatus, .draft)
        XCTAssertNil(ClaimWritePolicy.Bucket.skip.claimStatus)
    }

    // MARK: - JSONL logging

    func testSkipAndReviewLogsAppendValidJSONL() throws {
        let root = NSTemporaryDirectory() + "claim-policy-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        ClaimWritePolicy.logSkipped(vaultRoot: root, claim: "low claim",
                                    url: "https://blog.test/x", confidence: 0.3, at: 1_800_000_000)
        ClaimWritePolicy.logSkipped(vaultRoot: root, claim: "another low claim",
                                    url: "https://blog.test/y", confidence: 0.3, at: 1_800_000_001)
        ClaimWritePolicy.logReview(vaultRoot: root, claim: "draft claim",
                                   url: "https://news.test/z", confidence: 0.65, at: 1_800_000_002)

        let skipPath = root + "/research/low-confidence-claims.jsonl"
        let reviewPath = root + "/research/draft-claims-review.jsonl"
        let skipLines = try String(contentsOfFile: skipPath, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(skipLines.count, 2, "two skipped claims should append two lines")
        for line in skipLines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertEqual(obj?["disposition"] as? String, "skipped")
            XCTAssertNotNil(obj?["claim"]); XCTAssertNotNil(obj?["url"]); XCTAssertNotNil(obj?["confidence"])
        }
        let reviewLine = try String(contentsOfFile: reviewPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let robj = try JSONSerialization.jsonObject(with: Data(reviewLine.utf8)) as? [String: Any]
        XCTAssertEqual(robj?["disposition"] as? String, "draft")
        XCTAssertEqual(robj?["claim"] as? String, "draft claim")
    }
}
