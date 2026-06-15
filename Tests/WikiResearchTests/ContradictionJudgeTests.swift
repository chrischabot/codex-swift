import XCTest
@testable import WikiResearch
import MemoryStore

/// Severe coverage for the 6-verdict temporal contradiction judge (gbrain.md
/// Wave 3.22): the C1 confidence floor, robust parsing, and the temporal-vs-
/// genuine-conflict distinction.
final class ContradictionJudgeTests: XCTestCase {
    private func claim(_ text: String, firstSeen: Int64 = 1_700_000_000) -> ClaimRow {
        ClaimRow(text: text, firstSeen: firstSeen, updatedAt: firstSeen)
    }

    // MARK: - C1 confidence floor

    func testLowConfidenceContradictionDowngraded() {
        XCTAssertEqual(ContradictionJudge.normalize(.contradiction, confidence: 0.69), .noContradiction)
        XCTAssertEqual(ContradictionJudge.normalize(.contradiction, confidence: 0.7), .contradiction,
                       "0.7 is the inclusive floor")
        XCTAssertEqual(ContradictionJudge.normalize(.contradiction, confidence: 0.95), .contradiction)
    }

    func testFloorOnlyAffectsContradiction() {
        // A low-confidence supersession is NOT downgraded — only `contradiction` is gated.
        XCTAssertEqual(ContradictionJudge.normalize(.temporalSupersession, confidence: 0.3), .temporalSupersession)
        XCTAssertEqual(ContradictionJudge.normalize(.negationArtifact, confidence: 0.1), .negationArtifact)
    }

    // MARK: - parsing

    func testParseStrictJSON() {
        let raw = #"{"verdict": "temporalSupersession", "confidence": 0.9, "reasoning": "role changed", "resolution_hint": "B"}"#
        let p = ContradictionJudge.parse(raw)
        XCTAssertEqual(p.verdict, .temporalSupersession)
        XCTAssertEqual(p.confidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(p.resolutionHint, "B")
    }

    func testParseJSONWithPreambleAndFence() {
        let raw = "Here is my answer:\n```json\n{\"verdict\":\"contradiction\",\"confidence\":0.85,\"reasoning\":\"x\"}\n```"
        let p = ContradictionJudge.parse(raw)
        XCTAssertEqual(p.verdict, .contradiction)
        XCTAssertEqual(p.confidence, 0.85, accuracy: 1e-9)
    }

    func testParseAppliesFloorOnContradiction() {
        let raw = #"{"verdict":"contradiction","confidence":0.4,"reasoning":"weak"}"#
        XCTAssertEqual(ContradictionJudge.parse(raw).verdict, .noContradiction,
                       "a 0.4 contradiction must be floored to noContradiction")
    }

    func testParseKeywordFallback() {
        XCTAssertEqual(ContradictionJudge.parse("I think this is a temporal supersession.").verdict, .temporalSupersession)
        XCTAssertEqual(ContradictionJudge.parse("these are a negation artifact").verdict, .negationArtifact)
    }

    func testParseUnparseableFailsSafe() {
        let p = ContradictionJudge.parse("?????")
        XCTAssertEqual(p.verdict, .noContradiction, "never invent a conflict from garbage")
        XCTAssertEqual(p.confidence, 0, accuracy: 1e-9)
    }

    // MARK: - prompt

    func testPromptIncludesBothClaimsDatesAndAllVerdicts() {
        let a = claim("X is the CEO", firstSeen: 1_700_000_000)
        let b = claim("X stepped down as CEO", firstSeen: 1_710_000_000)
        let prompt = ContradictionJudge.buildPrompt(a, b, context: JudgeContext(aTrust: "high", bTrust: "high"))
        XCTAssertTrue(prompt.contains("X is the CEO"))
        XCTAssertTrue(prompt.contains("X stepped down as CEO"))
        for v in ContradictionVerdict.allCases { XCTAssertTrue(prompt.contains(v.rawValue), "missing \(v)") }
        XCTAssertTrue(prompt.contains("UNTRUSTED DATA"))
    }

    func testDateTagPrefersExplicitElseEpoch() {
        XCTAssertEqual(ContradictionJudge.dateTag("2026-01-15", fallbackEpoch: 0), "2026-01-15")
        // epoch 1_700_000_000 = 2023-11-14 UTC
        XCTAssertEqual(ContradictionJudge.dateTag(nil, fallbackEpoch: 1_700_000_000), "2023-11-14")
    }

    // MARK: - mock backend end-to-end

    func testMockBackendRoundTripsAndFloors() async {
        let a = claim("A"); let b = claim("B")
        let strong = MockContradictionJudgeBackend(verdict: .contradiction, confidence: 0.9)
        let weak = MockContradictionJudgeBackend(verdict: .contradiction, confidence: 0.5)
        let r1 = await strong.judge(a, b, context: JudgeContext())
        let r2 = await weak.judge(a, b, context: JudgeContext())
        XCTAssertEqual(r1.verdict, .contradiction)
        XCTAssertEqual(r2.verdict, .noContradiction, "mock applies the C1 floor too")
    }

    func testPromptVersionIsStable() {
        XCTAssertEqual(ContradictionJudge.promptVersion, "1")
    }
}
