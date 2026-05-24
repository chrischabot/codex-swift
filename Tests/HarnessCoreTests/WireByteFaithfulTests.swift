import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import Prompts

/// Project a prompt's input back to text exactly as the wire client would
/// serialize the role bodies (user/developer/assistant/tool).
private func projectedBlob(_ items: [PromptInput]) -> String {
    items.map { i in
        switch i {
        case .userText(let t), .developerText(let t), .assistantText(let t): return t
        case .toolOutput(_, let o): return o
        }
    }.joined(separator: "\n")
}

private func wbCollect(_ engine: SessionEngine,
                       untilCompletions n: Int,
                       timeout: Duration = .seconds(30)) async -> [ServerNotification] {
    let stream = await engine.events()
    let collector = Task { () -> [ServerNotification] in
        var out: [ServerNotification] = []
        var c = 0
        for await ev in stream {
            out.append(ev)
            if case .turnCompleted = ev { c += 1; if c == n { break } }
        }
        return out
    }
    let timer = Task { try? await Task.sleep(for: timeout); collector.cancel() }
    let r = await collector.value
    timer.cancel()
    return r
}

/// P2.1 / C3: terminal-event collector — counts both `turnCompleted` and
/// `turnAborted` toward the target. An interrupted turn now emits the latter
/// (not the former) so callers driving an interrupt flow must wait on either.
private func wbCollect(_ engine: SessionEngine,
                       untilTerminals n: Int,
                       timeout: Duration = .seconds(30)) async -> [ServerNotification] {
    let stream = await engine.events()
    let collector = Task { () -> [ServerNotification] in
        var out: [ServerNotification] = []
        var c = 0
        for await ev in stream {
            out.append(ev)
            switch ev {
            case .turnCompleted, .turnAborted:
                c += 1
                if c == n { return out }
            default: continue
            }
        }
        return out
    }
    let timer = Task { try? await Task.sleep(for: timeout); collector.cancel() }
    let r = await collector.value
    timer.cancel()
    return r
}

final class WireByteFaithfulTests: XCTestCase {

    private func makeStore() throws -> (ThreadStore, String) {
        let home = NSTemporaryDirectory() + "wbf-" + UUID().uuidString
        return (try ThreadStore(codexHome: home, limits: Limits()), home)
    }

    // MARK: Compaction constants are byte-identical to the vendored templates.

    func testCompactionConstantsByteFaithful() {
        XCTAssertEqual(Compaction.summaryPrefix, Templates.compactSummaryPrefix)
        XCTAssertEqual(Compaction.compactionPrompt, Templates.compactPrompt)
        XCTAssertEqual(Compaction.summaryPrefix,
            "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:")
        XCTAssertTrue(Compaction.compactionPrompt.hasPrefix(
            "You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task."))
        XCTAssertEqual(Compaction.headsUpWarning,
            "Heads up: Long threads and multiple compactions can cause the model to be less accurate. Start a new thread when possible to keep threads small and targeted.")
        // is_summary_message requires the prefix to be followed by a newline.
        XCTAssertTrue(Compaction.isSummaryMessage(Compaction.summaryPrefix + "\nx"))
        XCTAssertFalse(Compaction.isSummaryMessage(Compaction.summaryPrefix))
    }

    // MARK: Interrupted turn appends the exact TurnAborted guidance, and the
    // next turn's wire prompt carries it byte-for-byte.

    func testInterruptedTurnAbortedGuidanceIsByteFaithfulInNextPrompt() async throws {
        // P2.1 / C3: the interrupted turn now ends with a `turn/aborted`
        // notification (not `turn/completed`). The next turn's prompt must
        // still carry the byte-exact `<turn_aborted>` guidance (parity with
        // Codex `INTERRUPTED_GUIDANCE`).
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let model = RecordingModelClient(MockModelClient([
            MockScenario([.created, .slowMillis(400),
                          .agentDone(itemId: "m1", "unreached"),
                          .completeEndTurn(responseId: "r", tokens: 1)]),
            .hello("second"),
        ]))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let collector = Task { await wbCollect(engine, untilTerminals: 2) }
        await engine.submit(.startTurn(input: [TurnInput(text: "long task")], model: nil))
        try await Task.sleep(for: .milliseconds(80))
        await engine.submit(.interrupt(turnId: TurnId("x")))
        try await Task.sleep(for: .milliseconds(120))
        await engine.submit(.startTurn(input: [TurnInput(text: "next")], model: nil))
        let evs = await collector.value

        // The first terminal event for the interrupted turn must be
        // `turnAborted`, NOT `turnCompleted`.
        let firstTerminal = evs.first { ev in
            if case .turnCompleted = ev { return true }
            if case .turnAborted = ev { return true }
            return false
        }
        guard case .turnAborted(_, _, let reason, _, _, _)? = firstTerminal else {
            return XCTFail("first terminal event must be turnAborted, got: \(String(describing: firstTerminal))")
        }
        XCTAssertEqual(reason, "interrupted",
                       "user-initiated interrupt maps to canonical reason `interrupted`")

        let expectedFragment = TurnAborted(TurnAborted.interruptedGuidance).render()
        XCTAssertEqual(expectedFragment,
            "<turn_aborted>\nThe user interrupted the previous turn on purpose. Any running unified exec processes may still be running in the background. If any tools/commands were aborted, they may have partially executed.\n</turn_aborted>",
            "TurnAborted render is byte-exact to Codex INTERRUPTED_GUIDANCE")

        let caps = await model.capturedRequests()
        let lastBlob = projectedBlob(caps.last?.prompt.input ?? [])
        XCTAssertTrue(lastBlob.contains(expectedFragment),
                      "next turn's wire prompt carries the byte-exact turn_aborted guidance")
    }

    // MARK: Per-turn goal injection is the exact <goal_context> wrapper.

    func testGoalContextWrapperIsByteFaithfulInPrompt() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        _ = try await store.goalSet(tid, objective: "Ship the <FALCON> feature & stop",
                                    status: .active, tokenBudget: .some(100_000))
        let model = RecordingModelClient(MockModelClient([.hello("ok")]))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let collector = Task { await wbCollect(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil))
        let evs = await collector.value

        let expected = GoalPrompts.goalContextItem(
            kind: .continuation, objective: "Ship the <FALCON> feature & stop",
            tokensUsed: 0, tokenBudget: 100_000, timeUsedSeconds: 0).text
        XCTAssertTrue(expected.hasPrefix("<goal_context>\n"))
        XCTAssertTrue(expected.hasSuffix("\n</goal_context>"))
        XCTAssertTrue(expected.contains("Ship the &lt;FALCON&gt; feature &amp; stop"),
                      "objective is XML-escaped (&,<,> order) inside the wrapper")

        let caps = await model.capturedRequests()
        let blob = projectedBlob(caps.first?.prompt.input ?? [])
        XCTAssertTrue(blob.contains(expected),
                      "the per-turn goal injection is the byte-exact GoalPrompts wrapper")

        let g = try await store.goalGet(tid)
        XCTAssertEqual(g?.tokensUsed, 12)
        XCTAssertTrue(evs.contains {
            if case .threadGoalUpdated(_, _, let gg) = $0 { return gg.tokensUsed == 12 }
            return false
        })
    }

    // MARK: Initial-context bundle is byte-faithful on the wire.

    func testInitialContextFragmentsAreByteFaithfulInPrompt() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = NSTemporaryDirectory() + "wbf-work-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: work + "/.git",
                                                 withIntermediateDirectories: true)
        try "ALWAYS_SAY_HELLO_BYTE".write(toFile: work + "/AGENTS.md",
                                          atomically: true, encoding: .utf8)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work))
        let model = RecordingModelClient(MockModelClient([.hello("ok")]))
        let skills = [PromptComposer.SkillInjection(
            name: "byteskill", description: "byte test skill", path: work + "/s/byteskill")]
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: work),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits(),
                                   skills: skills)
        await engine.start()
        let collector = Task { await wbCollect(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "hi")], model: nil))
        _ = await collector.value

        let caps = await model.capturedRequests()
        let blob = projectedBlob(caps.first?.prompt.input ?? [])

        let perms = PermissionsInstructions(
            sandboxMode: .workspaceWrite, networkAccess: .restricted,
            approvalPolicy: .onRequest, approvalsReviewer: .user,
            writableRoots: [work]).render()
        XCTAssertTrue(perms.hasPrefix("<permissions instructions>"))
        XCTAssertTrue(blob.contains(perms),
                      "permissions fragment present byte-for-byte in the wire prompt")
        let ui = UserInstructions(directory: work, text: "ALWAYS_SAY_HELLO_BYTE").render()
        XCTAssertEqual(ui,
            "# AGENTS.md instructions for \(work)\n\n<INSTRUCTIONS>\nALWAYS_SAY_HELLO_BYTE\n</INSTRUCTIONS>")
        XCTAssertTrue(blob.contains(ui),
                      "AGENTS.md UserInstructions fragment present byte-for-byte")
        XCTAssertTrue(blob.contains("<skills_instructions>")
                      && blob.contains("byteskill")
                      && blob.contains("</skills_instructions>"),
                      "available-skills fragment present with its markers")
    }

    // MARK: Steered input is drained into a same-turn subsequent sampling prompt.

    func testSteeredInputReachesSubsequentTurnPrompt() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let model = RecordingModelClient(MockModelClient([
            MockScenario([.created, .slowMillis(250),
                          .agentDone(itemId: "m1", "first done"),
                          .completeEndTurn(responseId: "r1", tokens: 2)]),
            .hello("second"),
        ]))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let collector = Task { await wbCollect(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "please do X")], model: nil))
        try await Task.sleep(for: .milliseconds(80))
        await engine.submit(.steer(input: [TurnInput(text: "STEER_EXTRA_42")],
                                   expectedTurnId: TurnId("t")))
        _ = await collector.value

        let caps = await model.capturedRequests()
        let anyHasSteer = caps.contains {
            projectedBlob($0.prompt.input).contains("STEER_EXTRA_42")
        }
        XCTAssertTrue(anyHasSteer,
                      "steered input is drained into a same-turn subsequent sampling prompt")
        // And it persisted as a user message in the durable rollout.
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .userMessage(_, let c) = $0 {
                return c.contains { ($0.text ?? "").contains("STEER_EXTRA_42") }
            }
            return false
        }, "steered input is recorded as a durable user message")
    }

    // MARK: Model-backed behavioral replay: prompt/tool/compaction/memory/durability.

    func testModelBackedToolCompactionMemoryPersistenceReplay() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = NSTemporaryDirectory() + "wbf-replay-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work,
                                                 model: "gpt-4o-mini"))
        try await store.setMemoryMode(tid, .enabled)
        let memory = MemoryStore(codexHome: home)
        let model = RecordingModelClient(MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "replay_tool", name: "echo",
                                    argumentsJSON: #"{"text":"TOOL_REPLAY_OK"}"#),
                          .completeContinue(responseId: "resp_tool", tokens: 300_000)]),
            MockScenario([.created,
                          .agentDone(itemId: "replay_summary",
                                     "MODEL_REPLAY_SUMMARY includes TOOL_REPLAY_OK"),
                          .completeEndTurn(responseId: "resp_compact", tokens: 7)]),
            MockScenario([.created,
                          .agentDone(itemId: "replay_final",
                                     "FINAL_REPLAY_OK after compaction"),
                          .completeEndTurn(responseId: "resp_final", tokens: 11)]),
            .hello("SECOND_TURN_OK"),
        ]))
        let router = ToolRouter(limits: Limits())
        await router.register(EchoToolHC())
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: work,
                                                         model: "gpt-4o-mini"),
                                   model: model, store: store, router: router,
                                   limits: Limits(), autoCompactTokens: 24_000,
                                   memoryStore: memory)
        await engine.start()

        let first = Task { await wbCollect(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "Build with TOOL_REPLAY_MARKER")],
                                       model: nil))
        let firstEvents = await first.value

        XCTAssertTrue(firstEvents.contains {
            if case .itemCompleted(_, _, let item) = $0,
               case .commandExecution(let id, _, _, let status, let output, _) = item {
                return id.raw == "replay_tool"
                    && status == .completed
                    && (output ?? "").contains("TOOL_REPLAY_OK")
            }
            return false
        }, "tool execution event is completed with model-requested output")
        XCTAssertTrue(firstEvents.contains {
            if case .raw(let method, _) = $0 { return method == "thread/compacted" }
            return false
        }, "high-token tool follow-up triggers model-backed compaction")
        XCTAssertTrue(firstEvents.contains {
            if case .raw(let method, let params) = $0 {
                return method == "warning"
                    && params["message"]?.stringValue == Compaction.headsUpWarning
            }
            return false
        }, "compaction emits the byte-exact warning event")
        XCTAssertTrue(firstEvents.contains {
            if case .itemCompleted(_, _, let item) = $0,
               case .agentMessage(_, let text) = item {
                return text == "FINAL_REPLAY_OK after compaction"
            }
            return false
        }, "final assistant item is emitted after compaction continuation")

        let afterFirstCaps = await model.capturedRequests()
        XCTAssertEqual(afterFirstCaps.count, 3,
                       "tool call, compaction, and post-compaction continuation are distinct model requests")
        let firstPrompt = projectedBlob(afterFirstCaps[0].prompt.input)
        XCTAssertTrue(firstPrompt.contains("Build with TOOL_REPLAY_MARKER"))
        XCTAssertTrue(afterFirstCaps[0].prompt.tools.contains { $0.name == "echo" },
                      "model-visible tool inventory is present on the first request")
        XCTAssertNil(afterFirstCaps[0].settings.previousResponseId)
        XCTAssertEqual(afterFirstCaps[0].settings.turnState, "ts-\(tid.raw)-g0")

        let compactPrompt = projectedBlob(afterFirstCaps[1].prompt.input)
        XCTAssertTrue(compactPrompt.contains(Compaction.compactionPrompt),
                      "compaction request carries the byte-exact compaction prompt")
        XCTAssertTrue(compactPrompt.contains("TOOL_REPLAY_OK"),
                      "compaction sees the completed tool output as transcript data")

        let continuationPrompt = projectedBlob(afterFirstCaps[2].prompt.input)
        XCTAssertTrue(continuationPrompt.contains(Compaction.summaryPrefix))
        XCTAssertTrue(continuationPrompt.contains("MODEL_REPLAY_SUMMARY includes TOOL_REPLAY_OK"))
        XCTAssertTrue(continuationPrompt.contains("Build with TOOL_REPLAY_MARKER"))
        XCTAssertEqual(afterFirstCaps[2].settings.previousResponseId, "resp_tool",
                       "post-tool continuation keeps previous_response_id within the turn")
        XCTAssertEqual(afterFirstCaps[2].settings.turnState, "ts-\(tid.raw)-g1",
                       "post-compaction continuation advances the window generation")

        let noteName = "\(tid.raw).md"
        let note = await memory.read(noteName) ?? ""
        XCTAssertTrue(note.contains("Build with TOOL_REPLAY_MARKER"))
        XCTAssertTrue(note.contains("FINAL_REPLAY_OK after compaction"),
                      "memory consolidation receives the completed compacted transcript")

        let rebuilt = try await store.reconstruct(tid)
        XCTAssertEqual(rebuilt.lastTurnStatus, .completed)
        XCTAssertTrue(rebuilt.items.contains {
            if case .agentMessage(_, let text) = $0 {
                return text.hasPrefix(Compaction.summaryPrefix)
                    && text.contains("MODEL_REPLAY_SUMMARY includes TOOL_REPLAY_OK")
            }
            return false
        }, "durable rollout reconstructs the model-produced compaction summary")
        XCTAssertTrue(rebuilt.items.contains {
            if case .agentMessage(_, let text) = $0 {
                return text == "FINAL_REPLAY_OK after compaction"
            }
            return false
        }, "durable rollout reconstructs the post-compaction final answer")

        let second = Task { await wbCollect(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "Continue after replay")],
                                       model: nil))
        _ = await second.value
        let allCaps = await model.capturedRequests()
        XCTAssertEqual(allCaps.count, 4)
        let secondPrompt = projectedBlob(allCaps[3].prompt.input)
        XCTAssertTrue(secondPrompt.contains("MODEL_REPLAY_SUMMARY includes TOOL_REPLAY_OK"))
        XCTAssertTrue(secondPrompt.contains("FINAL_REPLAY_OK after compaction"))
        XCTAssertTrue(secondPrompt.contains("Continue after replay"))
        XCTAssertNil(allCaps[3].settings.previousResponseId,
                     "previous_response_id is turn-scoped and resets on the next user turn")
    }
}
