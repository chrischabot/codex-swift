import XCTest
@testable import BenchKit

/// Severe coverage for the deterministic skill rule-judge (gbrain.md Wave 5.32).
final class SkillRuleJudgeTests: XCTestCase {
    private let sample = """
    # Summary
    Anthropic released Claude. See [docs](https://example.com) and [Source: paper].

    ## Details
    The model uses RLHF. I called wiki_search to verify.
    """

    func testContainsCaseInsensitive() {
        XCTAssertTrue(SkillRuleJudge.check(.contains("claude"), sample))
        XCTAssertTrue(SkillRuleJudge.check(.contains("CLAUDE"), sample))
        XCTAssertFalse(SkillRuleJudge.check(.contains("gpt-5"), sample))
    }

    func testNotContains() {
        XCTAssertTrue(SkillRuleJudge.check(.notContains("forbidden"), sample))
        XCTAssertFalse(SkillRuleJudge.check(.notContains("Claude"), sample))
    }

    func testRegex() {
        XCTAssertTrue(SkillRuleJudge.check(.regex(#"RL\w+"#), sample))
        XCTAssertFalse(SkillRuleJudge.check(.regex(#"^\d{5}$"#), sample))
    }

    func testSectionPresent() {
        XCTAssertTrue(SkillRuleJudge.check(.sectionPresent("Summary"), sample))
        XCTAssertTrue(SkillRuleJudge.check(.sectionPresent("Details"), sample))
        XCTAssertFalse(SkillRuleJudge.check(.sectionPresent("Conclusion"), sample))
        // "Summary" appears as a heading; a body mention alone wouldn't count.
        XCTAssertFalse(SkillRuleJudge.check(.sectionPresent("RLHF"), sample), "RLHF is body text, not a heading")
    }

    func testCharBounds() {
        XCTAssertTrue(SkillRuleJudge.check(.minChars(10), sample))
        XCTAssertFalse(SkillRuleJudge.check(.minChars(100_000), sample))
        XCTAssertTrue(SkillRuleJudge.check(.maxChars(100_000), sample))
        XCTAssertFalse(SkillRuleJudge.check(.maxChars(5), sample))
    }

    func testMinCitations() {
        // sample has one [Source: …] and one ](https://…) → 2 citations.
        XCTAssertTrue(SkillRuleJudge.check(.minCitations(2), sample))
        XCTAssertFalse(SkillRuleJudge.check(.minCitations(3), sample))
    }

    func testToolCalled() {
        XCTAssertTrue(SkillRuleJudge.check(.toolCalled("wiki_search"), sample))
        XCTAssertFalse(SkillRuleJudge.check(.toolCalled("mem0_add"), sample))
    }

    // MARK: - aggregate verdict

    func testVerdictScoreAndAllPassed() {
        let v = SkillRuleJudge.evaluate(output: sample, rules: [
            .contains("Claude"), .sectionPresent("Summary"), .minCitations(2),
        ])
        XCTAssertEqual(v.passed, 3); XCTAssertEqual(v.total, 3)
        XCTAssertEqual(v.score, 1.0, accuracy: 1e-9)
        XCTAssertTrue(v.allPassed)
    }

    func testVerdictPartialScore() {
        let v = SkillRuleJudge.evaluate(output: sample, rules: [
            .contains("Claude"),          // pass
            .sectionPresent("Conclusion"), // fail
        ])
        XCTAssertEqual(v.passed, 1); XCTAssertEqual(v.total, 2)
        XCTAssertEqual(v.score, 0.5, accuracy: 1e-9)
        XCTAssertFalse(v.allPassed)
    }

    func testEmptyRulesVacuouslyPasses() {
        let v = SkillRuleJudge.evaluate(output: sample, rules: [])
        XCTAssertEqual(v.score, 1.0, accuracy: 1e-9)
        XCTAssertTrue(v.allPassed)
    }

    func testDeterministic() {
        let rules: [SkillRule] = [.contains("x"), .regex("y"), .minCitations(1)]
        XCTAssertEqual(SkillRuleJudge.evaluate(output: sample, rules: rules),
                       SkillRuleJudge.evaluate(output: sample, rules: rules))
    }
}
