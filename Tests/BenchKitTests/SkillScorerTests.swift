import XCTest
@testable import BenchKit

/// Severe coverage for the held-out skill-scoring harness (gbrain.md Wave 5, §9.6 #1):
/// the three judge kinds (rule/llm/qrels), the weighted blend, SHA-8 receipt
/// determinism, and the regression gate (mean drop, per-case regression, eval drift,
/// set mismatch). The harness is pure (outputs fed in), so all of this is deterministic.
final class SkillScorerTests: XCTestCase {

    /// Assert an OPTIONAL sub-score equals a value (the `accuracy:` overload needs a
    /// non-optional, so unwrap first; nil is a failure, never silently skipped).
    private func assertEq(_ a: Double?, _ b: Double, _ msg: String = "",
                          file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("expected \(b), got nil. \(msg)", file: file, line: line) }
        XCTAssertEqual(a, b, accuracy: 1e-9, msg, file: file, line: line)
    }

    // MARK: - rule judge dimension

    func testRuleOnlyAggregateEqualsRuleScore() async {
        let c = SkillCase(id: "a", input: "q", output: "Hello [Source: x] world",
                          rules: [.contains("hello"), .minCitations(1), .notContains("forbidden")])
        let r = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: [c])
        XCTAssertEqual(r.caseScores.count, 1)
        assertEq(r.caseScores[0].ruleScore, 1.0, "all 3 rules pass")
        XCTAssertEqual(r.caseScores[0].aggregate, 1.0, accuracy: 1e-9)
        XCTAssertNil(r.caseScores[0].llmScore)
        XCTAssertNil(r.caseScores[0].qrelsScore)
        XCTAssertEqual(r.caseScores[0].ruleResults.count, 3, "per-rule detail recorded for debugging")
    }

    func testPartialRuleFailLowersScore() async {
        let c = SkillCase(id: "a", input: "q", output: "Hello world",
                          rules: [.contains("hello"), .minCitations(1)])   // citation rule fails
        let r = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: [c])
        assertEq(r.caseScores[0].ruleScore, 0.5)
    }

    // MARK: - qrels (nDCG) judge dimension

    func testQrelsPerfectRankingScoresOne() {
        let q = Qrels(relevant: ["d1": 3, "d2": 2, "d3": 1])
        XCTAssertEqual(SkillScorer.ndcg(retrieved: ["d1", "d2", "d3"], qrels: q), 1.0, accuracy: 1e-9)
    }

    func testQrelsWorseRankingScoresLower() {
        let q = Qrels(relevant: ["d1": 3, "d2": 2, "d3": 1])
        let good = SkillScorer.ndcg(retrieved: ["d1", "d2", "d3"], qrels: q)
        let bad = SkillScorer.ndcg(retrieved: ["d3", "d2", "d1"], qrels: q)
        XCTAssertGreaterThan(good, bad, "reversing the ideal order must lower nDCG")
        XCTAssertGreaterThan(bad, 0, "some relevant items were still retrieved")
    }

    func testQrelsNothingRelevantRetrievedScoresZero() {
        let q = Qrels(relevant: ["d1": 3])
        XCTAssertEqual(SkillScorer.ndcg(retrieved: ["x", "y", "z"], qrels: q), 0.0, accuracy: 1e-9)
    }

    func testQrelsNoRelevantLabelsIsVacuousOne() {
        XCTAssertEqual(SkillScorer.ndcg(retrieved: [], qrels: Qrels(relevant: [:])), 1.0, accuracy: 1e-9)
        XCTAssertEqual(SkillScorer.ndcg(retrieved: ["x"], qrels: Qrels(relevant: ["d": 0])), 1.0, accuracy: 1e-9,
                       "a grade-0 label is not relevant → vacuous")
    }

    // MARK: - llm rubric judge dimension (decoupled, injected)

    func testRubricJudgeContributesAndClampsToUnit() async {
        let judge = ClosureRubricJudge { _, output, _ in output.contains("good") ? 5.0 : -2.0 }  // out of range
        let good = SkillCase(id: "g", input: "q", output: "this is good", rubric: "is it good?")
        let bad = SkillCase(id: "b", input: "q", output: "this is bad", rubric: "is it good?")
        let r = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: [good, bad], rubricJudge: judge)
        assertEq(r.caseScores[0].llmScore, 1.0, "5.0 clamps to 1.0")
        assertEq(r.caseScores[1].llmScore, 0.0, "-2.0 clamps to 0.0")
    }

    func testRubricSetButNoJudgeExcludesLLMDimension() async {
        // A rubric with NO judge wired must not silently score 0 — the dimension is absent.
        let c = SkillCase(id: "a", input: "q", output: "x", rules: [.contains("x")], rubric: "rate it")
        let r = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: [c], rubricJudge: nil)
        XCTAssertNil(r.caseScores[0].llmScore, "no judge ⇒ llm dimension excluded, not zero")
        XCTAssertEqual(r.caseScores[0].aggregate, 1.0, accuracy: 1e-9, "aggregate is just the rule score")
    }

    func testJudgeReturningNilExcludesLLMDimension() async {
        let judge = ClosureRubricJudge { _, _, _ in nil }   // judge unavailable
        let c = SkillCase(id: "a", input: "q", output: "x", rules: [.contains("x")], rubric: "rate it")
        let r = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: [c], rubricJudge: judge)
        XCTAssertNil(r.caseScores[0].llmScore)
        XCTAssertEqual(r.caseScores[0].aggregate, 1.0, accuracy: 1e-9)
    }

    // MARK: - blended weighting

    func testWeightedBlendAcrossThreeJudges() async {
        // rule=1.0, llm=0.0, qrels=1.0 ; weights rule=1, llm=3, qrels=1 ⇒ (1+0+1)/(1+3+1)=0.4
        let judge = ClosureRubricJudge { _, _, _ in 0.0 }
        let c = SkillCase(id: "a", input: "q", output: "hello d1",
                          rules: [.contains("hello")], rubric: "r", qrels: Qrels(relevant: ["d1": 1]),
                          retrieved: ["d1"])
        let r = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: [c], rubricJudge: judge,
                                        weights: SkillJudgeWeights(rule: 1, llm: 3, qrels: 1))
        assertEq(r.caseScores[0].ruleScore, 1.0)
        assertEq(r.caseScores[0].qrelsScore, 1.0)
        XCTAssertEqual(r.caseScores[0].aggregate, 0.4, accuracy: 1e-9, "weighted blend (1+0+1)/(1+3+1)")
    }

    func testNoJudgeCaseIsVacuouslyOne() async {
        let c = SkillCase(id: "a", input: "q", output: "anything")   // no rules/rubric/qrels
        let r = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: [c])
        XCTAssertEqual(r.caseScores[0].aggregate, 1.0, accuracy: 1e-9)
    }

    // MARK: - SHA-8 receipt determinism

    func testReceiptHashesAreDeterministicAndOrderIndependent() async {
        let mk: (String) -> [SkillCase] = { out in
            [SkillCase(id: "a", input: "qa", output: out, rules: [.contains("x")]),
             SkillCase(id: "b", input: "qb", output: "y", rules: [.contains("y")])]
        }
        let r1 = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: mk("x"))
        let r2 = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: mk("x").reversed())
        XCTAssertEqual(r1.caseSetSha8, r2.caseSetSha8, "case-set hash is order-independent")
        XCTAssertEqual(r1.sha8, r2.sha8, "identical scores ⇒ identical run hash regardless of order")
        XCTAssertEqual(r1.sha8.count, 8, "SHA-8")
    }

    func testCaseSetHashStableAcrossVersionAndOutputButRunHashDiffers() async {
        let base: (String, String) -> [SkillCase] = { out, _ in
            [SkillCase(id: "a", input: "qa", output: out, rules: [.contains("hello")])]
        }
        let v1 = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: base("hello there", ""))
        let v2 = await SkillScorer.score(skillId: "s", promptVersion: "v2", cases: base("nope", ""))
        XCTAssertEqual(v1.caseSetSha8, v2.caseSetSha8, "same eval definition ⇒ same set hash (version/output excluded)")
        XCTAssertNotEqual(v1.sha8, v2.sha8, "different version + scores ⇒ different run hash")
        assertEq(v1.caseScores[0].ruleScore, 1.0)
        assertEq(v2.caseScores[0].ruleScore, 0.0)
    }

    func testCaseFileRoundTripsThroughJSONIncludingAllRuleKinds() throws {
        let cases = [
            SkillCase(id: "a", input: "in", output: "out", rules: [
                .contains("x"), .notContains("y"), .regex("^o"), .sectionPresent("H"),
                .maxChars(99), .minChars(1), .minCitations(2), .toolCalled("grep")]),
            SkillCase(id: "b", input: "q", output: "", qrels: Qrels(relevant: ["d1": 3]), retrieved: ["d1"]),
        ]
        let data = try JSONEncoder().encode(cases)
        let back = try JSONDecoder().decode([SkillCase].self, from: data)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].rules.map(\.label), cases[0].rules.map(\.label), "all 8 rule kinds round-trip")
        XCTAssertEqual(back[1].qrels?.relevant, ["d1": 3])
        XCTAssertEqual(back[1].retrieved, ["d1"])
    }

    func testCaseFileToleratesOmittedOptionalFields() throws {
        // A minimal case file: only id + input + a single rule.
        let json = #"[{"id":"c1","input":"hi","rules":[{"kind":"contains","value":"hi"}]}]"#
        let cases = try JSONDecoder().decode([SkillCase].self, from: Data(json.utf8))
        XCTAssertEqual(cases.count, 1)
        XCTAssertEqual(cases[0].output, "", "omitted output defaults to empty")
        XCTAssertTrue(cases[0].retrieved.isEmpty)
        XCTAssertNil(cases[0].rubric)
    }

    func testReceiptRoundTripsThroughJSON() async throws {
        let c = SkillCase(id: "a", input: "q", output: "hello [Source: x]",
                          rules: [.contains("hello"), .minCitations(1)])
        let r = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: [c])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(SkillReceipt.self, from: data)
        XCTAssertEqual(r, back, "a baseline receipt persists + reloads losslessly")
    }

    // MARK: - regression gate

    func testRegressionGatePassesOnEqualOrImproved() async throws {
        let cs = [SkillCase(id: "a", input: "q", output: "hello", rules: [.contains("hello")])]
        let base = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: cs)
        let cand = await SkillScorer.score(skillId: "s", promptVersion: "v2", cases: cs)
        let v = try SkillScorer.regressionGate(baseline: base, candidate: cand)
        XCTAssertTrue(v.passed)
        XCTAssertEqual(v.delta, 0, accuracy: 1e-9)
        XCTAssertTrue(v.regressedCases.isEmpty)
    }

    func testRegressionGateFailsOnMeanDrop() async throws {
        let cs: (String) -> [SkillCase] = { out in
            [SkillCase(id: "a", input: "q", output: out, rules: [.contains("hello")])]
        }
        let base = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: cs("hello"))   // 1.0
        let cand = await SkillScorer.score(skillId: "s", promptVersion: "v2", cases: cs("bye"))      // 0.0
        let v = try SkillScorer.regressionGate(baseline: base, candidate: cand)
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.candidateAggregate, 0.0, accuracy: 1e-9)
        XCTAssertEqual(v.regressedCases, ["a"])
        XCTAssertLessThan(v.delta, 0)
    }

    func testRegressionGateTolersWithinTolerance() async throws {
        // base aggregate 1.0 (two cases pass), candidate 0.5 (one regresses) → delta -0.5
        let pass2: [SkillCase] = [
            SkillCase(id: "a", input: "q", output: "hello", rules: [.contains("hello")]),
            SkillCase(id: "b", input: "q", output: "world", rules: [.contains("world")]),
        ]
        let oneFails: [SkillCase] = [
            SkillCase(id: "a", input: "q", output: "hello", rules: [.contains("hello")]),
            SkillCase(id: "b", input: "q", output: "nope", rules: [.contains("world")]),
        ]
        let base = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: pass2)
        let cand = await SkillScorer.score(skillId: "s", promptVersion: "v2", cases: oneFails)
        // mean drop is 0.5; even with a generous mean tolerance the PER-CASE regression still fails it.
        let v = try SkillScorer.regressionGate(baseline: base, candidate: cand, tolerance: 0.6)
        XCTAssertFalse(v.passed, "a single case regressing past tolerance fails even if the mean is within tolerance")
        XCTAssertEqual(v.regressedCases, ["b"])
    }

    func testRegressionGateThrowsOnCaseSetMismatch() async {
        let a = await SkillScorer.score(skillId: "s", promptVersion: "v1",
                                        cases: [SkillCase(id: "a", input: "q", output: "x", rules: [.contains("x")])])
        let b = await SkillScorer.score(skillId: "DIFFERENT", promptVersion: "v1",
                                        cases: [SkillCase(id: "a", input: "q", output: "x", rules: [.contains("x")])])
        XCTAssertThrowsError(try SkillScorer.regressionGate(baseline: a, candidate: b)) { err in
            guard case SkillScorerError.caseSetMismatch = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    func testRegressionGateFlagsEvalDriftSameSetHashImpossibleButMissingCaseGuard() async throws {
        // Same skillId + identical rule/input specs ⇒ same caseSetSha8, but a candidate
        // that scored a strict SUBSET of cases is eval drift → fail with missingCases.
        let two: [SkillCase] = [
            SkillCase(id: "a", input: "q", output: "hello", rules: [.contains("hello")]),
            SkillCase(id: "b", input: "q", output: "world", rules: [.contains("world")]),
        ]
        let base = await SkillScorer.score(skillId: "s", promptVersion: "v1", cases: two)
        // Hand-craft a candidate receipt with the SAME set hash but one case dropped.
        var cand = base
        cand.caseScores = Array(base.caseScores.prefix(1))
        let v = try SkillScorer.regressionGate(baseline: base, candidate: cand)
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.missingCases, ["b"])
    }
}
