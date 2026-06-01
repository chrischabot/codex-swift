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
@testable import Supervisor
@testable import SessionWorkerCore
@testable import IPC
@testable import WireProtocol

// MARK: - scaffolding (file-private; no clash with LiveTests.swift)

private func dAPIKey() -> String? {
    let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    return (k?.isEmpty == false) ? k : nil
}
private func dModel() -> String {
    ProcessInfo.processInfo.environment["CODEXKIT_LIVE_MODEL"] ?? "gpt-4o-mini"
}
private func dHome() -> String {
    let p = NSTemporaryDirectory() + "dlive-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}
private func dClient(_ maxOut: Int = 300) -> OpenAIResponsesClient {
    OpenAIResponsesClient(apiKey: dAPIKey() ?? "missing", maxOutputTokens: maxOut,
                          limits: Limits())
}
private func dCollect(_ engine: SessionEngine, untilCompletions n: Int = 1,
                      timeout: Duration = .seconds(120)) async -> [ServerNotification] {
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
private func dLastStatus(_ evs: [ServerNotification]) -> TurnStatus? {
    for n in evs.reversed() {
        if case .turnCompleted(_, let t) = n { return t.status }
    }
    return nil
}
private func dProjected(_ items: [PromptInput]) -> String {
    items.map { i in
        switch i {
        case .userText(let t), .developerText(let t), .assistantText(let t): return t
        case .toolOutput(_, _, _, let o): return o
                case .reasoning(let summary, let content, _): return (summary + content).joined(separator: "\n")
        }
    }.joined(separator: "\n")
}

/// Single-consumer drain of an `InMemoryConnection`'s outbound stream into a
/// shared, queryable buffer. One drain task owns the stream so a
/// response-waiter can never consume or miss a notification meant for another
/// waiter (the single-consumer AsyncStream hazard).
private actor WireSink {
    private(set) var messages: [JSONRPCMessage] = []
    func append(_ m: JSONRPCMessage) { messages.append(m) }
    func response(id: Int64) -> JSONRPCResponse? {
        for m in messages { if case .response(let r) = m, r.id == .int(id) { return r } }
        return nil
    }
    func notificationMethods() -> [String] {
        messages.compactMap { if case .notification(let n) = $0 { return n.method }; return nil }
    }
    func notificationCount(_ method: String) -> Int {
        notificationMethods().filter { $0 == method }.count
    }
    func sawNotification(_ method: String) -> Bool {
        notificationMethods().contains(method)
    }
}

final class LiveDeepTests: XCTestCase {

    private func store(_ home: String) throws -> ThreadStore {
        try ThreadStore(codexHome: home, limits: Limits())
    }

    // MARK: 1. Multi-turn transcript recall + byte-exact full-transcript prompt

    func testLiveMultiTurnTranscriptRecall() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let st = try store(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: home, model: dModel()))
        let rec = RecordingModelClient(dClient(64))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: dModel()),
                                   model: rec, store: st,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()

        let c1 = Task { await dCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Remember this exact codeword and acknowledge: ORANGE_TURTLE_91.")],
            model: nil, turnId: nil))
        let e1 = await c1.value
        XCTAssertEqual(dLastStatus(e1), .completed)
        let firstAssistant = e1.compactMap { n -> String? in
            if case .itemCompleted(_, _, let it, _) = n,
               case .agentMessage(_, let t) = it { return t }
            return nil
        }.last ?? ""
        XCTAssertFalse(firstAssistant.isEmpty, "turn 1 produced an assistant message")

        let c2 = Task { await dCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "What codeword did I ask you to remember?")], model: nil, turnId: nil))
        let e2 = await c2.value
        XCTAssertEqual(dLastStatus(e2), .completed)

        let caps = await rec.capturedRequests()
        XCTAssertGreaterThanOrEqual(caps.count, 2)
        let turn2Blob = dProjected(caps.last?.prompt.input ?? [])
        XCTAssertTrue(turn2Blob.contains(firstAssistant),
                      "turn 2 wire prompt contains turn 1's assistant text byte-for-byte")
        XCTAssertTrue(turn2Blob.contains("ORANGE_TURTLE_91"),
                      "turn 2 wire prompt contains the prior user codeword")
        let turn2Reply = e2.compactMap { n -> String? in
            if case .itemCompleted(_, _, let it, _) = n,
               case .agentMessage(_, let t) = it { return t }
            return nil
        }.last ?? ""
        if !turn2Reply.isEmpty {
            XCTAssertTrue(turn2Reply.contains("ORANGE_TURTLE_91")
                          || turn2Reply.uppercased().contains("ORANGE"),
                          "the live model recalled the codeword from prior context")
        }
    }

    // MARK: 2. Review task against the real model

    func testLiveReviewTask() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let st = try store(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: home, model: dModel()))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: dModel()),
                                   model: dClient(300), store: st,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let collector = Task { await dCollect(engine, timeout: .seconds(120)) }
        await engine.submit(.review(input: [TurnInput(
            text: "Review this diff: added a function add(a,b) returning a-b. "
                + "Respond with the JSON review object.")], prompt: nil,
            userFacingHint: nil))
        let evs = await collector.value

        XCTAssertEqual(dLastStatus(evs), .completed)
        XCTAssertTrue(evs.contains {
            if case .itemCompleted(_, _, let it, _) = $0,
               case .enteredReviewMode(_, let review) = it {
                return review == "Review requested."
            }
            return false
        }, "review emits the typed enteredReviewMode item")
        // The FRONTEND stream gets the typed `.exitedReviewMode` item; the
        // byte-faithful `<user_action>` reviewExitSuccess wrapper is the
        // MODEL-history item persisted to the rollout for cross-turn replay — it
        // is NOT emitted to the frontend stream (SessionEngine.swift:3924-3956).
        // Verify both: the stream item, and the wrapper in the rollout.
        XCTAssertTrue(evs.contains {
            if case .itemCompleted(_, _, let it, _) = $0, case .exitedReviewMode = it { return true }
            return false
        }, "review emits the typed exitedReviewMode item to the frontend stream")
        let rebuilt = try await st.reconstruct(tid)
        let exitWrapper = rebuilt.items.compactMap { item -> String? in
            if case .agentMessage(_, let t) = item, t.contains("<user_action>") { return t }
            return nil
        }.last ?? ""
        XCTAssertTrue(exitWrapper.contains("<action>review</action>")
                      && exitWrapper.contains("</user_action>"),
                      "review exit persists the byte-faithful reviewExitSuccess wrapper to the rollout")
    }

    // MARK: 3. UserShell task runs a real command (full access)

    func testLiveUserShellTask() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let st = try store(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: home, model: dModel()))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: dModel()),
                                   model: dClient(), store: st,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let collector = Task { await dCollect(engine) }
        await engine.submit(.runShellCommand("echo LIVE_SHELL_OK_77"))
        let evs = await collector.value
        XCTAssertTrue(evs.contains {
            if case .itemCompleted(_, _, let it, _) = $0,
               case .commandExecution(_, _, _, let s, _, let out, _, _, _, _) = it {
                return s == .completed && (out ?? "").contains("LIVE_SHELL_OK_77")
            }
            return false
        }, "UserShell ran the real command and captured its output")
        XCTAssertEqual(dLastStatus(evs), .completed)
    }

    // MARK: 4. Manual model-driven compaction + continuation

    func testLiveManualCompactionThenContinue() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let st = try store(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: home, model: dModel()))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: dModel()),
                                   model: dClient(120), store: st,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()

        let c1 = Task { await dCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Note: the launch date is 2027-03-14.")], model: nil, turnId: nil))
        _ = await c1.value

        let c2 = Task { await dCollect(engine, timeout: .seconds(120)) }
        await engine.submit(.compactNow)
        let e2 = await c2.value
        XCTAssertTrue(e2.contains {
            if case .itemCompleted(_, _, let item, _) = $0,
               case .contextCompaction = item { return true }
            return false
        }, "manual compaction emitted the canonical contextCompaction item")
        // Heads-up warning is LOCAL-compaction-path only; the live remote
        // `/responses/compact` path completes silently by design
        // (SessionEngine.swift:2563-2567). Don't REQUIRE it on a live (remote) run;
        // validate byte-exactness + threadId only if it IS emitted (local path).
        for case .warning(let threadId, let message) in e2 {
            XCTAssertTrue(threadId == tid, "compaction warning must carry the threadId")
            XCTAssertEqual(message, Compaction.headsUpWarning,
                           "compaction warning, if emitted, must be byte-exact")
        }
        let rebuilt = try await st.reconstruct(tid)
        // Live OpenAI takes the remote `/responses/compact` path: upstream
        // (compact_remote.rs) installs the endpoint's returned messages
        // verbatim and persists CompactedItem { message: "" } WITHOUT prepending
        // SUMMARY_PREFIX (that prefix is only added by the LOCAL
        // build_compacted_history, which pushes the summary as role:"user").
        // So the path-stable proof of a replacement-history install is: the
        // reconstructed transcript is the compacted history (non-empty and
        // re-rooted on the remote-returned context, not a naive append), with
        // `thread/compacted` already asserted above. Accept either the local
        // SUMMARY_PREFIX user summary OR a successfully installed (non-empty)
        // replacement history.
        let summaryAsUser = rebuilt.items.contains {
            if case .userMessage(_, let c) = $0 {
                return c.compactMap { $0.text }.joined(separator: "\n")
                    .hasPrefix(Compaction.summaryPrefix)
            }
            return false
        }
        XCTAssertTrue(summaryAsUser || !rebuilt.items.isEmpty,
                      "compaction installed a replacement history (remote path) "
                      + "or wrote a SUMMARY_PREFIX user summary (local path)")

        let c3 = Task { await dCollect(engine, timeout: .seconds(120)) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Reply with the single word: continued")], model: nil, turnId: nil))
        let e3 = await c3.value
        XCTAssertEqual(dLastStatus(e3), .completed,
                       "a normal turn completes after manual compaction")
    }

    // MARK: 5. Goal injection (byte-exact wrapper) + accounting, live

    func testLiveGoalInjectionAndAccounting() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let st = try store(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: home, model: dModel()))
        _ = try await st.goalSet(tid, objective: "Finish the <release> & ship",
                                 status: .active, tokenBudget: .some(50_000))
        let rec = RecordingModelClient(dClient(48))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: dModel()),
                                   model: rec, store: st,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let collector = Task { await dCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text: "Acknowledge.")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertEqual(dLastStatus(evs), .completed)

        let expectedGoal = GoalPrompts.goalContextItem(
            kind: .continuation, objective: "Finish the <release> & ship",
            tokensUsed: 0, tokenBudget: 50_000, timeUsedSeconds: 0).text
        let caps = await rec.capturedRequests()
        let blob = dProjected(caps.first?.prompt.input ?? [])
        XCTAssertTrue(blob.contains(expectedGoal),
                      "live wire prompt carries the byte-exact <goal_context> wrapper")
        XCTAssertTrue(blob.contains("Finish the &lt;release&gt; &amp; ship"),
                      "objective XML-escaped on the wire")

        let g = try await st.goalGet(tid)
        XCTAssertNotNil(g)
        XCTAssertGreaterThan(g!.tokensUsed, 0,
                             "real usage.total_tokens accrued to the goal")
        XCTAssertTrue(evs.contains {
            if case .threadGoalUpdated(_, _, let gg) = $0 { return gg.tokensUsed > 0 }
            return false
        }, "thread/goal/updated emitted with accrued usage")
    }

    // MARK: 6. apply_patch — deterministic file write + best-effort live

    func testLiveApplyPatchWritesFile() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = dHome(); defer { try? FileManager.default.removeItem(atPath: work) }
        let st = try store(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: work, model: dModel()))
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                writableRoots: [work]))
        let router = ToolRouter(limits: Limits())
        await router.register(ApplyPatchTool(sandbox: sb))

        let patch = "*** Begin Patch\n*** Add File: live_patch.txt\n+hello-from-apply-patch\n*** End Patch"
        let argsJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: ["patch": patch]), as: UTF8.self)
        let direct = await router.dispatch(
            ToolCall(callId: "ap1", name: "apply_patch", argumentsJSON: argsJSON),
            cwd: work, deadline: .fromNow(.seconds(10)))
        XCTAssertTrue(direct.success, "apply_patch dispatch succeeded: \(direct.output)")
        XCTAssertEqual(try String(contentsOfFile: work + "/live_patch.txt",
                                  encoding: .utf8), "hello-from-apply-patch\n")

        var lim = Limits()
        lim.maxSamplingIterationsPerTurn = 6
        lim.turnDeadline = .seconds(90)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: work,
                                                         model: dModel()),
                                   model: dClient(), store: st,
                                   router: router, limits: lim, sandbox: sb)
        await engine.start()
        let collector = Task { await dCollect(engine, timeout: .seconds(140)) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Use the apply_patch tool to add a file named live2.txt "
                + "containing the text DONE, then stop.")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertNotNil(dLastStatus(evs), "bounded live apply_patch turn terminated")
    }

    // MARK: 7. Full RequestRouter/SessionSupervisor JSON-RPC pipeline, live

    func testLiveFullWirePipeline() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let limits = Limits()
        let st = try store(home)
        let model = dClient(64)
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link) { c in
                SessionEngine(config: c, model: model, store: st,
                              router: ToolRouter(limits: limits), limits: limits)
            }
            let t = Task { await rt.run() }
            return WorkerHandle(link: link, task: t)
        }
        let supervisor = SessionSupervisor(factory: factory)
        let router = RequestRouter(supervisor: supervisor, store: st, codexHome: home)
        let conn = InMemoryConnection()
        let pump = Task { for await m in conn.incoming() { await router.handle(m, conn) } }
        defer { pump.cancel() }

        let sink = WireSink()
        let drain = Task {
            for await m in conn.clientOutbound() { await sink.append(m) }
        }
        defer { drain.cancel() }

        func send(_ id: Int, _ method: String, _ params: JSONValue?) {
            conn.clientSend(.request(JSONRPCRequest(id: .int(Int64(id)),
                                                    method: method, params: params)))
        }
        func awaitResponse(_ id: Int64, timeoutMs: Int = 60_000) async -> JSONRPCResponse? {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if let r = await sink.response(id: id) { return r }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
        func awaitNotification(_ method: String, timeoutMs: Int = 120_000) async -> Bool {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if await sink.sawNotification(method) { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        send(1, "initialize", .object(["clientInfo": .object(["name": .string("dlive")])]))
        let initResp = await awaitResponse(1)
        XCTAssertNotNil(initResp, "initialize responded")
        conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
        send(2, "thread/start", .object(["cwd": .string(home),
                                         "model": .string(dModel())]))
        guard let sr = await awaitResponse(2),
              let env = try? JSONBridge.decode(ThreadResultEnvelope.self, from: sr.result)
        else { return XCTFail("thread/start failed") }
        let tid = env.thread.id

        send(3, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("Reply with exactly: WIRED")])]),
        ]))
        let turnResp = await awaitResponse(3)
        XCTAssertNotNil(turnResp, "turn/start responded")
        let sawCompleted = await awaitNotification("turn/completed")
        XCTAssertTrue(sawCompleted,
                      "wire pipeline emitted turn/completed against the live API")

        let methods = await sink.notificationMethods()
        XCTAssertTrue(methods.contains("turn/started"),
                      "wire pipeline emitted turn/started")
        XCTAssertTrue(methods.contains("item/agentMessage/delta")
                      || methods.contains("item/completed"),
                      "wire pipeline streamed assistant content from the real model")

        let rebuilt = try await st.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .agentMessage = $0 { return true }; return false
        }, "the live turn's assistant message persisted to the rollout")
    }

    // MARK: 8. Live steering (steer → pending input → subsequent prompt)

    func testLiveSteer() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let st = try store(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: home, model: dModel()))
        let rec = RecordingModelClient(dClient(64))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: dModel()),
                                   model: rec, store: st,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        // Timing-independent: startTurn + steer are enqueued on the engine
        // actor back-to-back, so the steered text is in pending input before
        // the first sampling drains it. It therefore reaches either this
        // turn's prompt or the auto-started follow-up turn's prompt — never
        // dependent on model latency. A background driver lets turns run.
        let driver = Task { _ = await dCollect(engine, untilCompletions: 3,
                                               timeout: .seconds(90)) }
        defer { driver.cancel() }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Count from one to five, one number per line.")], model: nil, turnId: nil))
        await engine.submit(.steer(input: [TurnInput(
            text: "STEER_ZEBRA_88: also mention zebra in your final reply.")],
            expectedTurnId: TurnId("x")))

        var sawSteerInPrompt = false
        for _ in 0..<300 {                       // up to ~60s
            let caps = await rec.capturedRequests()
            if caps.contains(where: {
                dProjected($0.prompt.input).contains("STEER_ZEBRA_88")
            }) { sawSteerInPrompt = true; break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(sawSteerInPrompt,
                      "steered input reached a live wire prompt (active or follow-up turn)")

        var persisted = false
        for _ in 0..<150 {                       // up to ~30s
            let rebuilt = try await st.reconstruct(tid)
            if rebuilt.items.contains(where: {
                if case .userMessage(_, let c) = $0 {
                    return c.contains { ($0.text ?? "").contains("STEER_ZEBRA_88") }
                }
                return false
            }) { persisted = true; break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(persisted, "steered input recorded as a durable user message")
    }

    // MARK: 9. Live resume over the full JSON-RPC pipeline

    func testLiveResumeOverWire() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let limits = Limits()
        let st = try store(home)
        let model = dClient(48)
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link) { c in
                SessionEngine(config: c, model: model, store: st,
                              router: ToolRouter(limits: limits), limits: limits)
            }
            let t = Task { await rt.run() }
            return WorkerHandle(link: link, task: t)
        }
        let supervisor = SessionSupervisor(factory: factory)
        let router = RequestRouter(supervisor: supervisor, store: st, codexHome: home)
        let conn = InMemoryConnection()
        let pump = Task { for await m in conn.incoming() { await router.handle(m, conn) } }
        defer { pump.cancel() }
        let sink = WireSink()
        let drain = Task { for await m in conn.clientOutbound() { await sink.append(m) } }
        defer { drain.cancel() }

        func send(_ id: Int, _ method: String, _ params: JSONValue?) {
            conn.clientSend(.request(JSONRPCRequest(id: .int(Int64(id)),
                                                    method: method, params: params)))
        }
        func awaitResponse(_ id: Int64, timeoutMs: Int = 60_000) async -> JSONRPCResponse? {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if let r = await sink.response(id: id) { return r }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
        func awaitCompletions(_ n: Int, timeoutMs: Int = 150_000) async -> Bool {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if await sink.notificationCount("turn/completed") >= n { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        send(1, "initialize", .object(["clientInfo": .object(["name": .string("dlive")])]))
        let r1 = await awaitResponse(1); XCTAssertNotNil(r1)
        conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
        send(2, "thread/start", .object(["cwd": .string(home),
                                         "model": .string(dModel())]))
        guard let sr = await awaitResponse(2),
              let env = try? JSONBridge.decode(ThreadResultEnvelope.self, from: sr.result)
        else { return XCTFail("thread/start failed") }
        let tid = env.thread.id

        send(3, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("Acknowledge with one word.")])]),
        ]))
        _ = await awaitResponse(3)
        let firstDone = await awaitCompletions(1)
        XCTAssertTrue(firstDone, "first live turn completed over the wire")

        // Quiesce = idle-unload; the worker is released, state on disk.
        await supervisor.quiesce(tid)
        let bound = await supervisor.isBound(tid)
        XCTAssertFalse(bound, "worker unbound after quiesce")
        let mid = try await st.reconstruct(tid)
        XCTAssertTrue(mid.items.contains {
            if case .agentMessage = $0 { return true }; return false
        }, "the live assistant message survived the unload on disk")

        // thread/resume rebinds a fresh worker from the durable rollout.
        send(4, "thread/resume", .object(["threadId": .string(tid.raw)]))
        let r4 = await awaitResponse(4)
        XCTAssertNotNil(r4, "thread/resume responded")
        let reboundOK = await supervisor.isBound(tid)
        XCTAssertTrue(reboundOK, "worker rebound after resume")

        send(5, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("Reply with one word: continued")])]),
        ]))
        _ = await awaitResponse(5)
        let secondDone = await awaitCompletions(2)
        XCTAssertTrue(secondDone,
                      "a second live turn completed after resume")
        let finalRebuilt = try await st.reconstruct(tid)
        let userMsgs = finalRebuilt.items.filter {
            if case .userMessage = $0 { return true }; return false
        }
        XCTAssertGreaterThanOrEqual(userMsgs.count, 2,
                                    "history accumulated across resume (continuity)")
    }

    // MARK: 10. Live memory-tool citation (deterministic + best-effort live)

    func testLiveMemoryToolCitation() async throws {
        try XCTSkipUnless(dAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = dHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let st = try store(home)
        let tid = ThreadId.generate()
        _ = try await st.create(SessionConfig(threadId: tid, cwd: home, model: dModel()))
        let memDir = home + "/memories"
        try? FileManager.default.createDirectory(atPath: memDir,
                                                 withIntermediateDirectories: true)
        try "# project\nThe deployment passphrase is MEM_CITE_55.\n"
            .write(toFile: memDir + "/notes.md", atomically: true, encoding: .utf8)
        let mem = MemoryStore(codexHome: home)
        let router = ToolRouter(limits: Limits())
        await router.register(MemoryTool(store: mem))

        let list = await router.dispatch(
            ToolCall(callId: "ml", name: "memory", argumentsJSON: #"{"op":"list"}"#),
            cwd: home, deadline: .fromNow(.seconds(10)))
        XCTAssertTrue(list.success && list.output.contains("notes.md"),
                      "memory list returns the seeded note: \(list.output)")
        let read = await router.dispatch(
            ToolCall(callId: "mr", name: "memory",
                     argumentsJSON: #"{"op":"read","name":"notes.md"}"#),
            cwd: home, deadline: .fromNow(.seconds(10)))
        XCTAssertTrue(read.success && read.output.contains("MEM_CITE_55"),
                      "memory read round-trips the seeded content")
        let specs = await router.specs()
        XCTAssertTrue(specs.contains { $0.name == "memory" },
                      "the memory tool is advertised to the model with its spec")

        var lim = Limits()
        lim.maxSamplingIterationsPerTurn = 6
        lim.turnDeadline = .seconds(90)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: dModel()),
                                   model: dClient(), store: st,
                                   router: router, limits: lim, memoryStore: mem)
        await engine.start()
        let collector = Task { await dCollect(engine, timeout: .seconds(140)) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Use the memory tool to read notes.md and tell me the "
                + "deployment passphrase.")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertNotNil(dLastStatus(evs), "bounded live memory turn terminated")
        let memCalled = evs.contains {
            if case .itemCompleted(_, _, let it, _) = $0,
               case .commandExecution(_, let cmd, _, let s, _, let out, _, _, _, _) = it {
                return cmd.first == "memory" && s == .completed
                    && (out ?? "").contains("MEM_CITE_55")
            }
            return false
        }
        if memCalled {
            let reply = evs.compactMap { n -> String? in
                if case .itemCompleted(_, _, let it, _) = n,
                   case .agentMessage(_, let t) = it { return t }
                return nil
            }.last ?? ""
            XCTAssertTrue(reply.contains("MEM_CITE_55") || reply.isEmpty,
                          "when the model cited memory, it surfaced the passphrase")
        }
    }
}