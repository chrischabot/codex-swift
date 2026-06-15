import XCTest
@testable import BenchKit

/// Deterministic coverage for the gradient-free prompt optimizer (gbrain.md §9.6 #5).
/// The runner echoes the prompt (so a rule like `.contains("good")` is satisfied iff
/// the prompt contains it), making the train/held-out dynamics exact and model-free.
final class SkilloptTests: XCTestCase {

    /// Output is just the prompt — so rules on the output test the prompt text.
    private let echoRunner = ClosureSkillRunner { prompt, _ in SkillRunOutput(output: prompt) }

    func testAdoptsImprovementWhenHeldoutDoesNotRegress() async {
        let train = [SkillCase(id: "t1", input: "x", rules: [.contains("good")])]
        let heldout = [SkillCase(id: "h1", input: "y", rules: [.contains("good")])]
        // Proposer always offers the fixed improved prompt.
        let proposer = ClosurePromptProposer { _, _, _ in ["hello good"] }
        let r = await SkillOptimizer.optimize(basePrompt: "hello", train: train, heldout: heldout,
                                              runner: echoRunner, proposer: proposer)
        XCTAssertTrue(r.adoptedOverBase, "train improved (0→1) and held-out did not regress (0→1)")
        XCTAssertEqual(r.bestPrompt, "hello good")
        XCTAssertEqual(r.baseTrainScore, 0, accuracy: 1e-9)
        XCTAssertEqual(r.bestTrainScore, 1, accuracy: 1e-9)
        XCTAssertEqual(r.bestHeldoutScore, 1, accuracy: 1e-9)
        XCTAssertEqual(r.bestPromptSha8.count, 8)
    }

    func testRejectsOverfitThatRegressesHeldout() async {
        // TRAIN wants the word present; HELD-OUT wants it ABSENT. A variant that adds
        // the word improves train but regresses held-out → the gate must ship the base.
        let train = [SkillCase(id: "t1", input: "x", rules: [.contains("trainword")])]
        let heldout = [SkillCase(id: "h1", input: "y", rules: [.notContains("trainword")])]
        let proposer = ClosurePromptProposer { _, _, _ in ["base trainword"] }
        let r = await SkillOptimizer.optimize(basePrompt: "base", train: train, heldout: heldout,
                                              runner: echoRunner, proposer: proposer)
        XCTAssertFalse(r.adoptedOverBase, "held-out regressed (1→0) → reject the overfit")
        XCTAssertEqual(r.bestPrompt, "base", "ships the BASE prompt, not the overfit winner")
        XCTAssertEqual(r.bestTrainScore, 1, accuracy: 1e-9, "the optimizer DID find a train improvement…")
        XCTAssertEqual(r.baseHeldoutScore, 1, accuracy: 1e-9)
        XCTAssertEqual(r.bestHeldoutScore, 0, accuracy: 1e-9, "…but it regressed held-out, so it's rejected")
    }

    func testNoImprovementShipsBase() async {
        let train = [SkillCase(id: "t1", input: "x", rules: [.contains("hello")])]   // base already passes
        let heldout = [SkillCase(id: "h1", input: "y", rules: [.contains("hello")])]
        let proposer = ClosurePromptProposer { _, _, _ in ["worse"] }   // never beats base
        let r = await SkillOptimizer.optimize(basePrompt: "hello", train: train, heldout: heldout,
                                              runner: echoRunner, proposer: proposer,
                                              config: SkillOptConfig(rounds: 2, variantsPerRound: 1))
        XCTAssertFalse(r.adoptedOverBase)
        XCTAssertEqual(r.bestPrompt, "hello")
        XCTAssertEqual(r.bestTrainScore, 1, accuracy: 1e-9)
        XCTAssertEqual(r.rounds.count, 2)
        XCTAssertFalse(r.rounds.contains { $0.adopted }, "no round adopted a variant")
    }

    func testEmptyProposalsAreSafe() async {
        let cases = [SkillCase(id: "t1", input: "x", rules: [.contains("z")])]
        let proposer = ClosurePromptProposer { _, _, _ in [] }
        let r = await SkillOptimizer.optimize(basePrompt: "base", train: cases, heldout: cases,
                                              runner: echoRunner, proposer: proposer)
        XCTAssertFalse(r.adoptedOverBase)
        XCTAssertEqual(r.bestPrompt, "base")
    }

    func testFailureFeedbackNamesFailingRules() async {
        let cases = [SkillCase(id: "c1", input: "x", output: "nope", rules: [.contains("missing"), .minCitations(1)])]
        let receipt = await SkillScorer.score(skillId: "s", promptVersion: "v", cases: cases)
        let fb = SkillOptimizer.failureFeedback(receipt)
        XCTAssertTrue(fb.contains("c1"), "feedback names the failing case")
        XCTAssertTrue(fb.contains("contains(missing)"), "feedback names the failing rule so the proposer can target it")
    }

    func testResultRoundTripsThroughJSON() async throws {
        let cases = [SkillCase(id: "t1", input: "x", rules: [.contains("good")])]
        let proposer = ClosurePromptProposer { _, _, _ in ["x good"] }
        let r = await SkillOptimizer.optimize(basePrompt: "x", train: cases, heldout: cases,
                                              runner: echoRunner, proposer: proposer)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(SkillOptResult.self, from: data)
        XCTAssertEqual(r, back)
    }
}
