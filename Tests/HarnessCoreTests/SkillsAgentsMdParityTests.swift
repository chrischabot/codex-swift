import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import Prompts

/// P3.6 parity tests for the three Skills + AGENTS.md gaps:
///   - **C7** AgentsMdManager wiring (configUserInstructions, fallbacks,
///     project-root markers, child-AgentsMd hierarchical message).
///   - **C8** `.agents/skills` Repo scope + `$HOME/.agents/skills` User scope.
///     (See `SkillsTests/SkillsTests.swift` for the discovery-side coverage.)
///   - **C9** Per-turn `$SkillName` body injection into the prompt input.
final class SkillsAgentsMdParityTests: XCTestCase {

    private func makeStore() throws -> (ThreadStore, String) {
        let home = NSTemporaryDirectory() + "p36-" + UUID().uuidString
        return (try ThreadStore(codexHome: home, limits: Limits()), home)
    }
    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "p36-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// C7: a `SessionConfig` whose `agentsMdUserInstructions`/`childEnabled`
    /// are set must reach the AgentsMdManager so they show up in the
    /// `<INSTRUCTIONS>` block. Verified via the recorded prompt (the
    /// AGENTS.md user fragment is part of the initial context bundle that
    /// is replayed every turn).
    func testAgentsMdManagerReceivesConfigValues() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = tmp(); defer { try? FileManager.default.removeItem(atPath: cwd) }
        // Anchor a project root with .git, drop a custom-named project doc
        // so the fallbackFilenames wiring is exercised end-to-end.
        try? FileManager.default.createDirectory(atPath: cwd + "/.git",
                                                  withIntermediateDirectories: true)
        try? "WORKFLOW-DOC-MARKER".write(toFile: cwd + "/WORKFLOW.md",
                                          atomically: true, encoding: .utf8)
        let tid = ThreadId.generate()
        let cfg = SessionConfig(
            threadId: tid, cwd: cwd,
            agentsMdUserInstructions: "CFG-INSTRUCTIONS-MARKER",
            agentsMdFilenames: ["WORKFLOW.md"],
            agentsMdChildEnabled: true)
        _ = try await store.create(cfg)
        let model = RecordingModelClient(MockModelClient([.hello("ok")]))
        let router = ToolRouter(limits: Limits())
        let engine = SessionEngine(config: cfg, model: model, store: store,
                                   router: router, limits: Limits())
        await engine.start()
        let collector = Task {
            await collectHC(engine) {
                if case .turnCompleted = $0 { return true }; return false
            }
        }
        await engine.submit(.startTurn(input: [TurnInput(text: "hi")], model: nil))
        _ = await collector.value

        let caps = await model.capturedRequests()
        XCTAssertFalse(caps.isEmpty, "model must have been called")
        let allInput = caps[0].prompt.input.compactMap { p -> String? in
            switch p {
            case .userText(let s), .developerText(let s), .assistantText(let s): return s
            case .toolOutput(_, let s): return s
            }
        }.joined(separator: "\n")
        // Config user_instructions threaded through:
        XCTAssertTrue(allInput.contains("CFG-INSTRUCTIONS-MARKER"),
                      "configUserInstructions must reach the prompt")
        // Fallback filename (`WORKFLOW.md`) was actually read:
        XCTAssertTrue(allInput.contains("WORKFLOW-DOC-MARKER"),
                      "agentsMdFilenames must reach the AGENTS.md walk")
        // ChildAgentsMd hierarchical message appended when flag is on:
        XCTAssertTrue(allInput.contains(
            "Files called AGENTS.md commonly appear in many places"),
            "agentsMdChildEnabled must append the hierarchical message")
    }

    /// C7 control case: default `SessionConfig` (no agentsMd overrides) must
    /// NOT inject the hierarchical message or any of the new markers.
    func testAgentsMdManagerDefaultsRespected() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: "/w")
        _ = try await store.create(cfg)
        let model = RecordingModelClient(MockModelClient([.hello("ok")]))
        let router = ToolRouter(limits: Limits())
        let engine = SessionEngine(config: cfg, model: model, store: store,
                                   router: router, limits: Limits())
        await engine.start()
        let collector = Task {
            await collectHC(engine) {
                if case .turnCompleted = $0 { return true }; return false
            }
        }
        await engine.submit(.startTurn(input: [TurnInput(text: "hi")], model: nil))
        _ = await collector.value
        let caps = await model.capturedRequests()
        let allInput = caps[0].prompt.input.compactMap { p -> String? in
            switch p {
            case .userText(let s), .developerText(let s), .assistantText(let s): return s
            case .toolOutput(_, let s): return s
            }
        }.joined(separator: "\n")
        XCTAssertFalse(allInput.contains(
            "Files called AGENTS.md commonly appear in many places"),
            "hierarchical message must not appear when childEnabled = false")
    }

    /// C9: when the user input contains `$SkillName`, the engine must read
    /// the matched skill's SKILL.md and prepend a `<skill>` user-role message
    /// to the prompt input.
    func testSkillBodyInjectedOnDollarMention() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let skillRoot = tmp(); defer { try? FileManager.default.removeItem(atPath: skillRoot) }
        let skillDir = skillRoot + "/foo"
        try? FileManager.default.createDirectory(atPath: skillDir,
                                                  withIntermediateDirectories: true)
        let skillBody = "# Foo Skill\nDo the foo thing carefully."
        try? "---\nname: foo\ndescription: foo skill\n---\n\(skillBody)"
            .write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: "/w")
        _ = try await store.create(cfg)
        let model = RecordingModelClient(MockModelClient([.hello("ok")]))
        let router = ToolRouter(limits: Limits())
        let skills = [PromptComposer.SkillInjection(
            name: "foo", description: "foo skill", path: skillDir)]
        let engine = SessionEngine(config: cfg, model: model, store: store,
                                   router: router, limits: Limits(), skills: skills)
        await engine.start()
        let collector = Task {
            await collectHC(engine) {
                if case .turnCompleted = $0 { return true }; return false
            }
        }
        await engine.submit(.startTurn(
            input: [TurnInput(text: "please run $foo on the codebase")], model: nil))
        _ = await collector.value
        let caps = await model.capturedRequests()
        XCTAssertFalse(caps.isEmpty)
        let allInput = caps[0].prompt.input.compactMap { p -> String? in
            switch p {
            case .userText(let s), .developerText(let s), .assistantText(let s): return s
            case .toolOutput(_, let s): return s
            }
        }.joined(separator: "\n")
        XCTAssertTrue(allInput.contains("<skill>"),
                      "must include <skill> wrapper")
        XCTAssertTrue(allInput.contains("<name>foo</name>"),
                      "must include skill name in wrapper")
        XCTAssertTrue(allInput.contains("Do the foo thing carefully."),
                      "must include full SKILL.md body")

        // Parity (REV P3.6 ordering fix): upstream `session/turn.rs:331,356`
        // records the user message FIRST, then appends `<skill>` items —
        // history order is `[user_message, skill_items]`. Assert the user's
        // raw turn text appears BEFORE the `<skill>` wrapper in the request.
        let userMarker = "please run $foo on the codebase"
        let userIdx = allInput.range(of: userMarker)?.lowerBound
        let skillIdx = allInput.range(of: "<skill>")?.lowerBound
        XCTAssertNotNil(userIdx, "user input text must appear in prompt")
        XCTAssertNotNil(skillIdx, "<skill> wrapper must appear in prompt")
        if let u = userIdx, let s = skillIdx {
            XCTAssertLessThan(u, s,
                "user message must precede <skill> injection (upstream parity: turn.rs:331 before 356)")
        }
    }

    /// C9 control: when no `$Name` appears that matches a skill, no
    /// injection occurs (so we don't blow up token usage on every turn).
    func testNoBodyInjectionWhenSkillNotMentioned() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let skillRoot = tmp(); defer { try? FileManager.default.removeItem(atPath: skillRoot) }
        let skillDir = skillRoot + "/foo"
        try? FileManager.default.createDirectory(atPath: skillDir,
                                                  withIntermediateDirectories: true)
        let skillBody = "DETAILED-FOO-BODY-MARKER"
        try? "---\nname: foo\ndescription: foo skill\n---\n\(skillBody)"
            .write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: "/w")
        _ = try await store.create(cfg)
        let model = RecordingModelClient(MockModelClient([.hello("ok")]))
        let router = ToolRouter(limits: Limits())
        let skills = [PromptComposer.SkillInjection(
            name: "foo", description: "foo skill", path: skillDir)]
        let engine = SessionEngine(config: cfg, model: model, store: store,
                                   router: router, limits: Limits(), skills: skills)
        await engine.start()
        let collector = Task {
            await collectHC(engine) {
                if case .turnCompleted = $0 { return true }; return false
            }
        }
        // Note: `$PATH` is a common env var → must NOT trigger any injection
        // even if a skill happened to be called `PATH`.
        await engine.submit(.startTurn(
            input: [TurnInput(text: "please look at $PATH; no real skill")], model: nil))
        _ = await collector.value
        let caps = await model.capturedRequests()
        let allInput = caps[0].prompt.input.compactMap { p -> String? in
            switch p {
            case .userText(let s), .developerText(let s), .assistantText(let s): return s
            case .toolOutput(_, let s): return s
            }
        }.joined(separator: "\n")
        XCTAssertFalse(allInput.contains("DETAILED-FOO-BODY-MARKER"),
                       "skill body must NOT be injected when name not mentioned")
    }

    /// C9 unit-level coverage of the mention extractor: `$Name` is matched
    /// only against known skill names, common env vars are filtered out,
    /// and dedup is by name (no double-injection if mentioned twice).
    func testCollectSkillMentionsFiltering() {
        let names = ["foo", "bar", "baz"]
        let inputs = [
            TurnInput(text: "use $foo and $bar; also $foo again"),
            TurnInput(text: "ignore $PATH and $unknown-skill"),
        ]
        let mentioned = SessionEngine.collectSkillMentions(
            input: inputs, skillNames: names)
        XCTAssertEqual(mentioned, Set(["foo", "bar"]),
                       "must extract only known skills, dedup, exclude env vars")
    }
}
