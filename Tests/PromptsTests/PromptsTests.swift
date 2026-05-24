import XCTest
@testable import Prompts

final class PromptsTests: XCTestCase {

    func testTemplatesAreVerbatim() {
        // Spot-check byte-faithful vendoring against Codex source.
        XCTAssertTrue(Templates.modelInstructions.hasPrefix(
            "You are Codex, a coding agent based on GPT-5."))
        XCTAssertTrue(Templates.modelInstructions.contains("{{ personality }}"))
        XCTAssertTrue(Templates.personalityPragmatic.hasPrefix("# Personality"))
        XCTAssertTrue(Templates.personalityFriendly.contains("team morale"))
        XCTAssertTrue(Templates.compactPrompt.contains("CONTEXT CHECKPOINT COMPACTION"))
        XCTAssertTrue(Templates.compactSummaryPrefix.hasPrefix(
            "Another language model started to solve this problem"))
        XCTAssertTrue(Templates.goalContinuation.contains("<objective>\n{{ objective }}\n</objective>"))
        XCTAssertTrue(Templates.goalBudgetLimit.contains("reached its token budget"))
        XCTAssertTrue(Templates.goalObjectiveUpdated.contains("<untrusted_objective>"))
        XCTAssertTrue(Templates.collabExperimentalPrompt.hasPrefix("## Multi agents"))
        XCTAssertTrue(Templates.reviewExitSuccess.contains("{{results}}"))
        XCTAssertTrue(Templates.reviewExitInterrupted.contains("None."))
    }

    func testRendererTrimsKeysAndPreservesUnknown() {
        let r = TemplateRenderer()
        XCTAssertEqual(r.render("a {{ x }} b", ["x": "X"]), "a X b")
        XCTAssertEqual(r.render("a {{x}} b", ["x": "X"]), "a X b")
        XCTAssertEqual(r.render("a {{  x  }} b", ["x": "X"]), "a X b")
        // Unknown placeholder is preserved (Codex Template only fills provided keys).
        XCTAssertEqual(r.render("a {{ y }} b", ["x": "X"]), "a {{ y }} b")
        // Multiple + repeated.
        XCTAssertEqual(r.render("{{a}}-{{b}}-{{a}}", ["a": "1", "b": "2"]), "1-2-1")
        // Unbalanced braces do not trap.
        XCTAssertEqual(r.render("{{ open", ["open": "x"]), "{{ open")
    }

    func testPersonalityDefaultAndText() {
        XCTAssertEqual(Personality.default, .pragmatic)
        XCTAssertEqual(Personality(fromOptional: "friendly"), .friendly)
        XCTAssertEqual(Personality(fromOptional: nil), .pragmatic)
        XCTAssertEqual(Personality(fromOptional: "bogus"), .pragmatic)
        XCTAssertEqual(Personality.friendly.templateText, Templates.personalityFriendly)
    }

    func testComposerDeveloperMessageSubstitutesPersonality() {
        let c = PromptComposer(personality: .friendly,
                               developerInstructions: "Use tabs.",
                               multiAgentEnabled: true)
        let dev = c.developerMessage()
        XCTAssertFalse(dev.contains("{{ personality }}"), "personality slot must be filled")
        XCTAssertTrue(dev.contains("team morale"), "friendly personality injected")
        XCTAssertTrue(dev.contains("## Multi agents"), "collab hint injected when enabled")
        XCTAssertTrue(dev.contains("# Developer instructions"))
        XCTAssertTrue(dev.contains("Use tabs."))
    }

    func testComposerEnvironmentAndGoal() {
        let c = PromptComposer()
        let env = c.environmentMessage(.init(cwd: "/w", model: "gpt-5.1-codex",
            sandboxMode: "workspace-write", approvalPolicy: "on-request",
            networkAccess: false, writableRoots: ["/w"], shell: "/bin/zsh"))
        XCTAssertTrue(env.contains("<cwd>/w</cwd>"))
        XCTAssertTrue(env.contains("<network_access>restricted</network_access>"))
        XCTAssertTrue(env.contains("<root>/w</root>"))

        let goal = c.goalMessage(.init(kind: .continuation, objective: "ship it",
                                       tokensUsed: 100, tokenBudget: 1000, timeUsedSeconds: 30))
        XCTAssertTrue(goal.contains("ship it"))
        XCTAssertTrue(goal.contains("Tokens used: 100"))
        XCTAssertTrue(goal.contains("Token budget: 1000"))
        XCTAssertTrue(goal.contains("Tokens remaining: 900"))
        XCTAssertFalse(goal.contains("{{"), "all goal placeholders filled")

        let skills = c.skillsMessage([.init(name: "fmt", description: "format code", path: "/s/fmt")])
        XCTAssertEqual(skills?.contains("<skill name=\"fmt\" path=\"/s/fmt\">format code</skill>"), true)
    }
}