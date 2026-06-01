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
        // context-compaction finding 1: compactPrompt must be byte-identical to
        // upstream core/templates/compact/prompt.md (426 bytes, ends with a
        // trailing newline). The Swift literal previously dropped the trailing
        // \n (425 bytes). Verify both the count and the trailing byte.
        XCTAssertEqual(Templates.compactPrompt.utf8.count, 426)
        XCTAssertTrue(Templates.compactPrompt.hasSuffix("seamlessly continue the work.\n"))
        XCTAssertTrue(Templates.compactSummaryPrefix.hasPrefix(
            "Another language model started to solve this problem"))
        // summary_prefix.md is 399 bytes with NO trailing newline upstream.
        XCTAssertEqual(Templates.compactSummaryPrefix.utf8.count, 399)
        XCTAssertFalse(Templates.compactSummaryPrefix.hasSuffix("\n"))
        XCTAssertTrue(Templates.goalContinuation.contains("<objective>\n{{ objective }}\n</objective>"))
        XCTAssertTrue(Templates.goalBudgetLimit.contains("reached its token budget"))
        XCTAssertTrue(Templates.goalObjectiveUpdated.contains("<untrusted_objective>"))
        XCTAssertTrue(Templates.collabExperimentalPrompt.hasPrefix("## Multi agents"))
        XCTAssertTrue(Templates.reviewExitSuccess.contains("{{results}}"))
        XCTAssertTrue(Templates.reviewExitInterrupted.contains("None."))
        // persistence-rollout finding 4: upstream review/exit_interrupted.xml is
        // 264 bytes and ends with `</user_action>\n\n` (TWO trailing newlines).
        // The Swift multiline literal drops the trailing newlines, so the engine
        // re-appends `\n\n` at the recorded use site; the byte-faithful recorded
        // form is therefore the constant + "\n\n".
        XCTAssertFalse(Templates.reviewExitInterrupted.hasSuffix("\n"),
                       "the literal itself carries no trailing newline")
        let recorded = Templates.reviewExitInterrupted + "\n\n"
        XCTAssertEqual(recorded.utf8.count, 264,
                       "recorded exit-interrupted text matches upstream byte count")
        XCTAssertTrue(recorded.hasSuffix("</user_action>\n\n"),
                      "recorded text ends with two trailing newlines (byte-faithful)")
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
        XCTAssertEqual(Personality(fromOptional: "pragmatic"), .pragmatic)
        XCTAssertEqual(Personality(fromOptional: nil), .pragmatic)
        XCTAssertEqual(Personality(fromOptional: "bogus"), .pragmatic)
        // Documented protocol value `none` (docs/protocol_v1.md): an explicit
        // "none" must map to the new `.none` variant, NOT be coerced to the
        // pragmatic default. Case-insensitive, matching `rename_all=lowercase`.
        XCTAssertEqual(Personality(fromOptional: "none"), Personality.none)
        XCTAssertEqual(Personality(fromOptional: "NONE"), Personality.none)
        // prompts finding 2: feature-flag resolution (config/mod.rs:3097-3104).
        // An explicit personality always wins, regardless of the feature flag.
        XCTAssertEqual(
            Personality.resolve(fromOptional: "friendly", personalityFeatureEnabled: false),
            .friendly)
        // Unset + feature ON → pragmatic (the shipped default).
        XCTAssertEqual(
            Personality.resolve(fromOptional: nil, personalityFeatureEnabled: true),
            .pragmatic)
        // Unset + feature DISABLED → upstream leaves personality None, and
        // get_personality_message(None) returns the empty `personality_default`
        // fragment. `.none` reproduces that empty-fragment outcome.
        XCTAssertEqual(
            Personality.resolve(fromOptional: nil, personalityFeatureEnabled: false),
            Personality.none)
        XCTAssertEqual(
            Personality.resolve(fromOptional: nil, personalityFeatureEnabled: false).templateText,
            "")
        XCTAssertEqual(Personality.none.catalogKey, "none")
        // Upstream `get_personality_message`: `Personality::None => String::new()`.
        XCTAssertEqual(Personality.none.templateText, "")
        // `templateText` sources the personality fragment from the bundled
        // ModelsCatalog (single source of truth), so it equals the default
        // model's `personality_friendly` fragment — not a duplicated constant.
        let catalogFriendly = ModelsCatalog.entry(for: "gpt-5.5")?
            .instructionsVariables["personality_friendly"]
        XCTAssertEqual(Personality.friendly.templateText, catalogFriendly)
        XCTAssertTrue(Personality.friendly.templateText.contains("# Personality"))
        XCTAssertNotEqual(Personality.friendly.templateText, Personality.pragmatic.templateText)
    }

    func testInstructionsPersonalityNoneResolvesToEmptyFragment() {
        // models.json ships no `personality_none` key, and upstream produces the
        // empty string in code (`Personality::None => String::new()`). The
        // catalog must therefore substitute an empty `{{ personality }}` slot
        // for "none" instead of falling back to `personality_default`.
        guard let entry = ModelsCatalog.entry(for: "gpt-5.5") else {
            return XCTFail("expected gpt-5.5 catalog entry")
        }
        let none = entry.instructions(personality: "none")
        let pragmatic = entry.instructions(personality: "pragmatic")
        XCTAssertFalse(none.contains("{{ personality }}"),
                       "personality slot must be filled (with empty string)")
        XCTAssertNotEqual(none, pragmatic,
                          "`none` must NOT fall back to the pragmatic prose")
        // The only difference between the `none` and a personality-default
        // render is the substituted fragment; with an empty fragment the
        // `none` render must equal the template with the slot stripped.
        if let template = entry.instructionsTemplate {
            let expected = template.replacingOccurrences(of: "{{ personality }}", with: "")
            XCTAssertEqual(none, expected)
        }
    }

    func testModelsCatalogParsesShellType() {
        // Upstream `spec_plan.rs` gates the shell-tool family on each model's
        // `shell_type` (`ConfigShellToolType`). The bundled `models.json`
        // declares `shell_type: shell_command` for every shipped model, so the
        // catalog must surface that string for `DefaultTools.register(shellType:)`.
        let entry = ModelsCatalog.entry(for: "gpt-5.5")
        XCTAssertEqual(entry?.shellType, "shell_command",
                       "models.json declares shell_type=shell_command for gpt-5.5")
        for (slug, e) in ModelsCatalog.entries {
            XCTAssertEqual(e.shellType, "shell_command",
                           "every shipped model declares shell_type=shell_command (\(slug))")
        }
    }

    func testModelsCatalogParsesReasoningAndVerbosityCapabilities() {
        // Upstream `ModelInfo` carries supports_reasoning_summaries,
        // default_reasoning_level, default_reasoning_summary, support_verbosity.
        // The bundled models.json declares these for the gpt-5 family.
        let entry = ModelsCatalog.entry(for: "gpt-5.5")
        XCTAssertEqual(entry?.supportsReasoningSummaries, true)
        XCTAssertEqual(entry?.defaultReasoningLevel, "medium")
        XCTAssertEqual(entry?.defaultReasoningSummary, "none")
        XCTAssertEqual(entry?.supportVerbosity, true)
    }

    func testComposerDeveloperMessageSubstitutesPersonality() {
        // Personality substitution is MODEL-AWARE: assert it against a catalog
        // model (gpt-5.5) whose entry ships an `instructions_template`.
        let c = PromptComposer(personality: .friendly,
                               developerInstructions: "Use tabs.",
                               multiAgentEnabled: true,
                               model: "gpt-5.5")
        let dev = c.developerMessage()
        let friendlyFrag = ModelsCatalog.entry(for: "gpt-5.5")!
            .instructionsVariables["personality_friendly"]!
        XCTAssertFalse(dev.contains("{{ personality }}"), "personality slot must be filled")
        XCTAssertTrue(dev.contains(friendlyFrag), "friendly personality fragment injected verbatim")
        XCTAssertTrue(dev.contains("## Multi agents"), "collab hint injected when enabled")
        XCTAssertTrue(dev.contains("# Developer instructions"))
        XCTAssertTrue(dev.contains("Use tabs."))
    }

    func testComposerEnvironmentAndGoal() {
        let c = PromptComposer()
        // environmentMessage now delegates to the faithful Fragments
        // EnvironmentContext (environment_context.rs:276-322): only cwd/shell
        // (plus optional network/date/timezone/subagents), wrapped in the
        // <environment_context> markers. The obsolete <model>/<sandbox_mode>/
        // <approval_policy>/<network_access>/<writable_roots> tags are gone.
        let env = c.environmentMessage(.init(cwd: "/w", model: "gpt-5.1-codex",
            sandboxMode: "workspace-write", approvalPolicy: "on-request",
            networkAccess: false, writableRoots: ["/w"], shell: "/bin/zsh"))
        XCTAssertTrue(env.hasPrefix("<environment_context>\n"))
        XCTAssertTrue(env.hasSuffix("\n</environment_context>"))
        XCTAssertTrue(env.contains("  <cwd>/w</cwd>"))
        XCTAssertTrue(env.contains("  <shell>/bin/zsh</shell>"))
        XCTAssertFalse(env.contains("<model>"), "obsolete <model> tag must not be emitted")
        XCTAssertFalse(env.contains("<sandbox_mode>"))
        XCTAssertFalse(env.contains("<approval_policy>"))
        XCTAssertFalse(env.contains("<network_access>"))
        XCTAssertFalse(env.contains("<writable_roots>"))
        XCTAssertFalse(env.contains("<network"), "network omitted when networkAccess=false")

        // With network access enabled, the faithful <network> block appears.
        let netEnv = c.environmentMessage(.init(cwd: "/w", model: "m",
            sandboxMode: "workspace-write", approvalPolicy: "on-request",
            networkAccess: true, shell: "/bin/zsh",
            allowedDomains: ["a.com"], deniedDomains: ["b.com"]))
        XCTAssertTrue(netEnv.contains("<network enabled=\"true\"><allowed>a.com</allowed><denied>b.com</denied></network>"))

        // persistence-rollout findings 5 & 6: the goal/skills assertions that
        // exercised the now-removed `PromptComposer.goalMessage` /
        // `skillsMessage` formatters were deleted. The faithful per-turn goal
        // wire format is covered by `GoalPromptsTests` (none/unbounded budget),
        // and the skills fragment by the `SkillInstructions` fragment tests.
    }
}