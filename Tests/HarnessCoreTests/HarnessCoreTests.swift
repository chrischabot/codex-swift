import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import WireProtocol
@testable import InfraPrimitives
@testable import Prompts

/// File-scope collector: a free function so `Task { await collectHC(...) }`
/// captures only the engine (an actor, Sendable) and a Sendable predicate —
/// never the non-Sendable XCTestCase `self` (Swift 6 sending-closure rule).
func collectHC(_ engine: SessionEngine,
               until: @escaping @Sendable (ServerNotification) -> Bool) async -> [ServerNotification] {
    let stream = await engine.events()
    var out: [ServerNotification] = []
    for await n in stream {
        out.append(n)
        if until(n) { break }
    }
    return out
}

/// Sendable sink the turn-id-capturing collector writes the first `turn/started`
/// id into, so a test can read the engine's actual active turn id (the value a
/// real client would echo back as `expectedTurnId` on `turn/steer`).
actor TurnIdBox {
    private(set) var id: TurnId?
    func set(_ v: TurnId) { if id == nil { id = v } }
    func waitForId(timeout: Duration = .seconds(5)) async -> TurnId? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while id == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return id
    }
}

/// Collector variant that records the first `turn/started` id into `box` while
/// it collects until `until` fires.
func collectHCCapturingTurnId(_ engine: SessionEngine, into box: TurnIdBox,
                              until: @escaping @Sendable (ServerNotification) -> Bool)
async -> [ServerNotification] {
    let stream = await engine.events()
    var out: [ServerNotification] = []
    for await n in stream {
        out.append(n)
        if case .turnStarted(_, let t) = n { await box.set(t.id) }
        if until(n) { break }
    }
    return out
}

final class HarnessCoreTests: XCTestCase {

    private func makeStore() throws -> (ThreadStore, String) {
        let home = NSTemporaryDirectory() + "hc-" + UUID().uuidString
        return (try ThreadStore(codexHome: home, limits: Limits()), home)
    }

    /// v9 finding 1: when a turn's model stream carries a rate-limit snapshot
    /// (upstream `TokenCountEvent.rate_limits`), the engine must emit an
    /// `account/rateLimits/updated` notification alongside the per-call
    /// `thread/tokenUsage/updated` (mirrors
    /// `bespoke_event_handling.rs:1571-1579`).
    func testTurnEmitsAccountRateLimitsUpdatedWhenSnapshotObserved() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let snap = RateLimitSnapshot(
            limitId: "codex",
            primary: RateLimitWindow(usedPercent: 55, windowMinutes: 60,
                                     resetAt: 1_700_000_000))
        let model = MockModelClient([
            MockScenario([
                .created,
                .rateLimits(snap),
                .agentDone(itemId: "m1", "done"),
                .completeEndTurn(responseId: "r1", tokens: 5),
            ]),
        ])
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: model, store: store,
            router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let collector = Task { await collectHC(engine) {
            if case .turnCompleted = $0 { return true }; return false
        } }
        await engine.submit(.startTurn(input: [TurnInput(text: "hi")], model: nil, turnId: nil))
        let events = await collector.value
        let rlEvents = events.compactMap { ev -> JSONValue? in
            if case .accountRateLimitsUpdated(let rl) = ev { return rl }
            return nil
        }
        XCTAssertFalse(rlEvents.isEmpty,
                       "a turn carrying a rate-limit snapshot must emit account/rateLimits/updated")
        guard case .object(let obj)? = rlEvents.first else {
            return XCTFail("rate-limits payload must be an object")
        }
        XCTAssertEqual(obj["limitId"], .string("codex"))
        guard case .object(let primary)? = obj["primary"] else {
            return XCTFail("primary window missing")
        }
        XCTAssertEqual(primary["usedPercent"], .int(55))
        XCTAssertEqual(primary["windowDurationMins"], .int(60))
    }

    func testSingleHelloTurnEmitsLifecycleAndPersists() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let model = MockModelClient([.hello("Hi there")])
        let router = ToolRouter(limits: Limits())
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store, router: router, limits: Limits())
        await engine.start()
        let collector = Task { await collectHC(engine) { if case .turnCompleted = $0 { return true }; return false } }
        await engine.submit(.startTurn(input: [TurnInput(text: "hello")], model: nil, turnId: nil))
        let events = await collector.value

        XCTAssertTrue(events.contains { if case .turnStarted = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .agentMessageDelta(_, _, _, let d) = $0 { return d == "Hi there" }; return false })
        guard case .turnCompleted(_, let turn)? = events.last(where: { if case .turnCompleted = $0 { return true }; return false }) else {
            return XCTFail("no turnCompleted")
        }
        XCTAssertEqual(turn.status, .completed)

        // Durable: a fresh reconstruction sees the user + assistant items.
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains { if case .userMessage = $0 { return true }; return false })
        XCTAssertTrue(rebuilt.items.contains { if case .agentMessage(_, let t) = $0 { return t == "Hi there" }; return false })
        XCTAssertEqual(rebuilt.lastTurnStatus, .completed)
    }

    func testToolCallFollowUpTurn() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "echo", argumentsJSON: "{\"text\":\"TOOLOUT\"}"),
                          .completeContinue(responseId: "r1", tokens: 5)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done after tool"),
                          .completeEndTurn(responseId: "r2", tokens: 6)]),
        ])
        let router = ToolRouter(limits: Limits())
        await router.register(EchoToolHC())
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store, router: router, limits: Limits())
        await engine.start()
        let collector = Task { await collectHC(engine) { if case .turnCompleted = $0 { return true }; return false } }
        await engine.submit(.startTurn(input: [TurnInput(text: "use the tool")], model: nil, turnId: nil))
        let events = await collector.value

        XCTAssertTrue(events.contains {
            if case .itemCompleted(_, _, let item, _) = $0,
               case .commandExecution(_, _, _, let st, _, let out, _, _, _, _) = item {
                return st == .completed && (out ?? "").contains("TOOLOUT")
            }; return false
        }, "tool result item must be completed")
        XCTAssertTrue(events.contains {
            if case .itemCompleted(_, _, let item, _) = $0,
               case .agentMessage(_, let t) = item { return t == "done after tool" }
            return false
        })
        let caps = await model.capturedRequests()
        XCTAssertEqual(caps.count, 2, "tool follow-up makes a second model call")
    }

    /// Finding (app-server-events): `turn/plan/updated` is never emitted because
    /// the `update_plan` tool publishes to `PlanUpdateBus` but nothing
    /// subscribes. SessionEngine must subscribe to the bus for the dispatched
    /// callId and forward the parsed payload as `ServerNotification.planUpdate`
    /// (parity with upstream `handle_turn_plan_update`,
    /// bespoke_event_handling.rs:1241). This drives a real `update_plan` call and
    /// asserts the notification reaches the event stream with the upstream wire
    /// shape (camelCase v2 step status).
    func testUpdatePlanToolEmitsTurnPlanUpdated() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let planArgs = #"{"explanation":"do work","plan":[{"step":"draft","status":"in_progress"},{"step":"ship","status":"pending"}]}"#
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "update_plan",
                                    argumentsJSON: planArgs),
                          .completeContinue(responseId: "r1", tokens: 5)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "r2", tokens: 6)]),
        ])
        let router = ToolRouter(limits: Limits())
        await router.register(UpdatePlanTool())
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store, router: router, limits: Limits())
        await engine.start()
        let collector = Task { await collectHC(engine) { if case .turnCompleted = $0 { return true }; return false } }
        await engine.submit(.startTurn(input: [TurnInput(text: "make a plan")], model: nil, turnId: nil))
        let events = await collector.value

        let planUpdate = events.first { if case .planUpdate = $0 { return true }; return false }
        guard case .planUpdate(let pThread, let pTurn, let explanation, let plan)? = planUpdate else {
            return XCTFail("turn/plan/updated must be emitted for an update_plan tool call")
        }
        XCTAssertEqual(pThread, tid)
        XCTAssertEqual(pTurn.raw.isEmpty, false)
        XCTAssertEqual(explanation, "do work")
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].step, "draft")
        XCTAssertEqual(plan[0].status, .inProgress)
        XCTAssertEqual(plan[1].step, "ship")
        XCTAssertEqual(plan[1].status, .pending)

        // The on-wire frame must carry the v2 camelCase step status.
        guard case .notification(let msg) = planUpdate!.toMessage() else {
            return XCTFail("expected notification frame")
        }
        XCTAssertEqual(msg.method, "turn/plan/updated")
        XCTAssertEqual(msg.params?["explanation"]?.stringValue, "do work")
        guard case .array(let items)? = msg.params?["plan"] else {
            return XCTFail("plan should serialise as a JSON array")
        }
        XCTAssertEqual(items.first?["status"]?.stringValue, "inProgress")

        // Subscription must be torn down once the dispatch resolves (no leak).
        let remaining = await PlanUpdateBus.shared.subscriptionCount()
        XCTAssertEqual(remaining, 0, "PlanUpdateBus subscription must be removed after the call resolves")
    }

    func testStickyPreviousResponseIdWithinTurn() async throws {
        // `previous_response_id` chaining is opt-in (the engine defaults to
        // prompt-prefix replay + prompt_cache_key affinity to avoid the
        // per-request server state-load latency). This test exercises the
        // chaining path, so enable it explicitly.
        setenv("CODEXKIT_USE_PREV_RESPONSE_ID", "1", 1)
        defer { unsetenv("CODEXKIT_USE_PREV_RESPONSE_ID") }
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "echo",
                                    argumentsJSON: "{\"text\":\"x\"}"),
                          .completeContinue(responseId: "resp_A", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "resp_B", tokens: 1)]),
        ])
        let router = ToolRouter(limits: Limits())
        await router.register(EchoToolHC())
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store, router: router,
                                   limits: Limits())
        await engine.start()
        let collector = Task { await collectHC(engine) { if case .turnCompleted = $0 { return true }; return false } }
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        _ = await collector.value
        let caps = await model.capturedRequests()
        XCTAssertEqual(caps.count, 2, "one tool follow-up → two sampling calls")
        XCTAssertNil(caps[0].previousResponseId,
                     "first request carries no previous_response_id")
        XCTAssertEqual(caps[1].previousResponseId, "resp_A",
                       "follow-up replays the prior completed response id (sticky)")
    }

    func testMidTurnAutoCompactionRebuildsHistory() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // s1: tool call (needs follow-up) → s2: compaction summary → s3: final.
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "echo", argumentsJSON: "{\"text\":\"OUT\"}"),
                          .completeContinue(responseId: "r1", tokens: 5)]),
            MockScenario([.created, .agentDone(itemId: "sum", "MODEL SUMMARY"),
                          .completeEndTurn(responseId: "r2", tokens: 3)]),
            MockScenario([.created, .agentDone(itemId: "m1", "final answer"),
                          .completeEndTurn(responseId: "r3", tokens: 2)]),
        ])
        let router = ToolRouter(limits: Limits())
        await router.register(EchoToolHC())
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store, router: router,
                                   limits: Limits(), autoCompactTokens: 1)
        await engine.start()
        let collector = Task { await collectHC(engine) { if case .turnCompleted = $0 { return true }; return false } }
        await engine.submit(.startTurn(input: [TurnInput(text: "do work")], model: nil, turnId: nil))
        let events = await collector.value
        guard case .turnCompleted(_, let turn)? = events.last(where: { if case .turnCompleted = $0 { return true }; return false }) else {
            return XCTFail("no turnCompleted")
        }
        XCTAssertEqual(turn.status, .completed,
                       "Codex compaction reduces tokens and continues; there is no thrash-abort")
        XCTAssertTrue(events.contains {
                          if case .itemCompleted(_, _, let item, _) = $0,
                             case .contextCompaction = item { return true }
                          return false
                      },
                      "mid-turn auto-compaction emits the canonical contextCompaction item (v2 suppresses the deprecated thread/compacted notification)")
        let rebuilt = try await store.reconstruct(tid)
        // P1.1 / F2: reconstruction replays the persisted `replacement_history`
        // (replace-then-replay, mirroring upstream), so the compaction summary
        // is the `.userMessage` bridge that `buildCompactedHistory` appends —
        // not a synthesized `.agentMessage` from the `.compacted` summary field.
        XCTAssertTrue(rebuilt.items.contains {
            if case .userMessage(_, let content) = $0 {
                let t = content.first?.text ?? ""
                return t.hasPrefix(Compaction.summaryPrefix) && t.contains("MODEL SUMMARY")
            }
            return false
        }, "history is replaced by the model-produced SUMMARY_PREFIX summary")
    }

    /// Upstream fidelity (app-server `handle_turn_interrupted`): an interrupted
    /// turn is delivered as a `turn/completed` notification whose
    /// `turn.status == .interrupted`, carrying lifecycle fields
    /// (`completedAt`, `durationMs`). There is NO `turn/aborted` wire method.
    func testInterruptEmitsTurnCompletedInterrupted() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let model = MockModelClient([
            MockScenario([.created, .slowMillis(500),
                          .agentDone(itemId: "m1", "blocked"),
                          .completeEndTurn(responseId: "r", tokens: 1)])
        ])
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let collector = Task {
            await collectHC(engine) { ev in
                if case .turnCompleted = ev { return true }
                return false
            }
        }
        await engine.submit(.startTurn(input: [TurnInput(text: "long task")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(60))
        await engine.submit(.interrupt(turnId: TurnId("x")))
        let events = await collector.value

        // Exactly one terminal turn/completed, status == interrupted.
        let completed = events.compactMap { ev -> TurnObject? in
            if case .turnCompleted(_, let turn) = ev { return turn }
            return nil
        }
        XCTAssertEqual(completed.count, 1, "exactly one turn/completed per interrupt")
        XCTAssertEqual(completed.first?.status, .interrupted,
                       "user-initiated interrupt → turn.status == interrupted")
        XCTAssertNotNil(completed.first?.completedAt, "completedAt populated")
        XCTAssertNotNil(completed.first?.durationMs, "durationMs populated")
    }

    func testInterruptYieldsInterruptedTurn() async throws {
        // Upstream fidelity: an interrupted turn is delivered as
        // `turn/completed` with `turn.status == .interrupted`.
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let model = MockModelClient([
            MockScenario([.created, .slowMillis(500),
                          .agentDone(itemId: "m1", "should not finish"),
                          .completeEndTurn(responseId: "r", tokens: 1)])
        ])
        let router = ToolRouter(limits: Limits())
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store, router: router, limits: Limits())
        await engine.start()
        let collector = Task {
            await collectHC(engine) { ev in
                if case .turnCompleted = ev { return true }
                return false
            }
        }
        await engine.submit(.startTurn(input: [TurnInput(text: "long task")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(60))
        await engine.submit(.interrupt(turnId: TurnId("x")))
        let events = await collector.value
        guard case .turnCompleted(_, let turn)? = events.last(where: {
            if case .turnCompleted = $0 { return true }; return false
        }) else {
            return XCTFail("no turnCompleted")
        }
        XCTAssertEqual(turn.status, .interrupted,
            "user-initiated interrupt maps to turn.status interrupted")
    }

    func testShellToolCallProceedsUnderNeverPolicyEvenWithEscalationRequest() async throws {
        // Defect #3 reproducer. The CRM and Flightdeck runs showed
        // gpt-5.4-mini / gpt-5.5 attempting `npm install` with a
        // `sandbox_permissions: "require_escalated"` field on the tool call
        // — and reporting that the harness rejected them ("blocked by the
        // approval gate"). Under approvalPolicy=never + sandbox=
        // danger-full-access, the engine MUST run the command in the
        // sandbox path (which under danger-full-access is unwrapped) and
        // NOT deny it just because the model also included an escalation
        // request the model shouldn't have included.
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(
            threadId: tid, cwd: home,
            approvalPolicy: .never,
            sandboxMode: .dangerFullAccess,
            networkAccess: true))
        let model = MockModelClient([
            // Model calls "shell_command" with the escalation request the prompt
            // told it not to include.
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "shell_command",
                                    argumentsJSON: #"{"command":["/bin/echo","installed"],"sandbox_permissions":"require_escalated","justification":"npm install"}"#),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "r2", tokens: 1)]),
        ])
        let router = ToolRouter(limits: Limits())
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .dangerFullAccess,
                                                writableRoots: [home],
                                                networkAllowed: true))
        await DefaultTools.register(on: router, sandbox: sb, limits: Limits())
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: home,
                                  approvalPolicy: .never,
                                  sandboxMode: .dangerFullAccess,
                                  networkAccess: true),
            model: model, store: store, router: router, limits: Limits(),
            sandbox: sb)
        await engine.start()
        let collector = Task { await collectHC(engine) {
            if case .turnCompleted = $0 { return true }; return false
        } }
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let events = await collector.value

        // The shell call must have completed without an approval denial.
        let shellItem = events.compactMap { ev -> ThreadItem? in
            if case .itemCompleted(_, _, let item, _) = ev,
               case .commandExecution = item { return item }
            return nil
        }.first
        guard let item = shellItem,
              case let .commandExecution(_, _, _, _, _, output, exitCode, _, _, _) = item else {
            return XCTFail("no commandExecution item; events: \(events)")
        }
        XCTAssertEqual(exitCode, 0,
                       "echo should exit 0; got \(String(describing: exitCode)), output=\(output ?? "")")
        XCTAssertTrue((output ?? "").contains("installed"),
                      "shell output should reflect command run; got: \(output ?? "")")
        XCTAssertFalse((output ?? "").contains("Not approved"),
                       "engine must not deny the call: \(output ?? "")")
    }

    func testPermissionsInstructionsNeverDangerFullAccessIsConcise() throws {
        // Defect #3 from the Flightdeck run: with approvalPolicy=never +
        // sandbox=danger-full-access, the model still tried to escalate via
        // `sandbox_permissions: "require_escalated"`, which the harness
        // then denies as "Not approved by user". The prompt should leave
        // the model with a single, unambiguous instruction in this combo:
        // do NOT provide sandbox_permissions.
        let p = Prompts.PermissionsInstructions(
            sandboxMode: .dangerFullAccess,
            networkAccess: .enabled,
            approvalPolicy: .never,
            approvalsReviewer: .user,
            writableRoots: ["/work"])
        let body = p.body()
        XCTAssertTrue(body.contains("danger-full-access"),
                      "should mention sandbox mode")
        XCTAssertTrue(body.contains("Do not provide the `sandbox_permissions`"),
                      "should tell the model NOT to provide sandbox_permissions; got:\n\(body)")
        // The big "How to request escalation" block must NOT be included
        // under policy=never; otherwise the model gets contradictory guidance.
        XCTAssertFalse(body.contains("How to request escalation"),
                       "policy=never must NOT include the escalation tutorial; got:\n\(body)")
        XCTAssertFalse(body.contains("require_escalated"),
                       "policy=never must NOT mention require_escalated; got:\n\(body)")
    }

    func testCompactionStreamsAgentMessageDeltas() async throws {
        // Bug surfaced by the Flightdeck live runs: every multi-turn build
        // hit auto-compaction, and during the compaction-summary streaming
        // the SessionEngine emitted exactly two events (`itemStarted` at
        // the start and `itemCompleted` at the end). Anything driving the
        // session from outside saw 30-90 s of silence and either timed out
        // its own stall-detector or burned its budget waiting.
        //
        // Upstream codex streams the compaction summary via `OutputTextDelta`
        // events. We should mirror that: forward each `agentDelta` from the
        // model into an `agentMessageDelta` event during compaction, so the
        // driver / client sees a steady drip of activity.
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let model = MockModelClient([
            // The manual compactNow flow: model streams the summary as deltas
            // before finalising via agentDone.
            MockScenario([
                .created,
                .delta(itemId: "compact-1", "First "),
                .delta(itemId: "compact-1", "chunk "),
                .delta(itemId: "compact-1", "of summary."),
                .agentDone(itemId: "compact-1", "First chunk of summary."),
                .completeEndTurn(responseId: "rc", tokens: 5),
            ]),
        ])
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: model, store: store, router: ToolRouter(limits: Limits()),
            limits: Limits(),
            autoCompactTokens: 10_000)
        await engine.start()
        let collector = Task { await collectHC(engine) {
            if case .turnCompleted = $0 { return true }; return false
        } }
        await engine.submit(.compactNow)
        let events = await collector.value
        let compactDeltas = events.compactMap { ev -> String? in
            if case .agentMessageDelta(_, _, _, let delta) = ev { return delta }
            return nil
        }
        XCTAssertGreaterThanOrEqual(
            compactDeltas.count, 3,
            "compaction streaming must surface model deltas so external clients " +
            "see progress instead of silence; got \(compactDeltas.count) deltas: " +
            "\(compactDeltas)")
        XCTAssertTrue(
            compactDeltas.contains(where: { $0.contains("First") }),
            "first compaction delta should land verbatim, got: \(compactDeltas)")
    }

    /// P5.1 / H-39: after compaction, the engine MUST emit a
    /// `thread/tokenUsage/updated` notification carrying the recomputed
    /// (whole-history-estimate) total, not the stale pre-compact server total.
    /// Mirrors upstream `compact.rs` → `recompute_token_usage` →
    /// `send_token_count_event` (`core/src/session/mod.rs:2960`).
    func testCompactionEmitsTokenCountEventAfter() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // Manual compactNow path: a single scenario streams the summary then
        // a high server-reported total. The recompute should overwrite that
        // high total with the (much smaller) estimate of the compact history.
        let model = MockModelClient([
            MockScenario([
                .created,
                .agentDone(itemId: "sum-1", "TIGHT SUMMARY"),
                // Synthesize a deliberately inflated server total here so we
                // can verify the post-compact event reports a SMALLER number
                // — i.e. the engine actually recomputed instead of echoing
                // back the stale server count.
                .completeEndTurn(responseId: "rc", tokens: 250_000),
            ]),
        ])
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: model, store: store, router: ToolRouter(limits: Limits()),
            limits: Limits(),
            autoCompactTokens: 10_000)
        await engine.start()
        let collector = Task { await collectHC(engine) {
            if case .turnCompleted = $0 { return true }; return false
        } }
        await engine.submit(.compactNow)
        let events = await collector.value
        let buckets = events.compactMap { ev -> (TokenUsageBucket, TokenUsageBucket)? in
            if case .tokenUsageUpdated(_, _, let total, let last, _) = ev {
                return (total, last)
            }
            return nil
        }
        XCTAssertFalse(buckets.isEmpty,
                       "compaction must emit at least one thread/tokenUsage/updated notification")
        // After H-39, the recompute event should report a `last.totalTokens`
        // far below the stale 250000 — the new history (just one user-role
        // summary message) is tiny. Anything close to 250000 here means we're
        // echoing the stale server total back to the client.
        guard let postCompact = buckets.last(where: { _ in true }) else {
            return XCTFail("expected a post-compaction token-usage event")
        }
        XCTAssertLessThan(postCompact.1.totalTokens, 10_000,
                          "post-compaction recompute should produce a tight estimate (<<10000), got \(postCompact.1.totalTokens)")
        XCTAssertGreaterThan(postCompact.1.totalTokens, 0,
                             "post-compaction estimate is the whole-history bytes/4 estimate, not zero")
    }

    /// Parity P2.3 (H-06): when the SessionEngine catches a retryable stream
    /// failure within budget, the emitted `error` notification must carry
    /// `willRetry == true` and the active `turnId`, so clients can suppress
    /// the transient-error UI while the retry is in flight. After the retry
    /// succeeds the turn must still complete normally — i.e. the transient
    /// emission does not poison the turn.
    func testStreamErrorEmitsWillRetryTrueWhenRetrying() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // Compaction-flow retry path: SessionEngine.runCompactionFlow opens
        // the stream, retries on `ModelError.retryable` within
        // `limits.streamMaxRetries`. The first scenario fails after `.created`
        // (mid-stream — must throw from the inner events stream so the
        // engine's per-iteration catch sees it); the second succeeds.
        let model = MockModelClient([
            MockScenario([.created, .failRetryable("transient 503 mid-stream")]),
            MockScenario([
                .created,
                .delta(itemId: "c1", "summary "),
                .delta(itemId: "c1", "ok"),
                .agentDone(itemId: "c1", "summary ok"),
                .completeEndTurn(responseId: "rc", tokens: 5),
            ]),
        ])
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: model, store: store, router: ToolRouter(limits: Limits()),
            limits: Limits(),
            autoCompactTokens: 10_000)
        await engine.start()
        let collector = Task { await collectHC(engine) {
            if case .turnCompleted = $0 { return true }; return false
        } }
        await engine.submit(.compactNow)
        let events = await collector.value

        // Exactly one transient error notification was emitted with
        // willRetry=true and a non-nil turnId tying it to the active turn.
        let retryErrors = events.compactMap { ev -> (TurnId?, Bool, ErrorBody)? in
            if case .error(_, let turnId, let willRetry, let body) = ev {
                return (turnId, willRetry, body)
            }
            return nil
        }
        XCTAssertEqual(retryErrors.count, 1,
                       "expected exactly one transient error notification; got \(retryErrors.count)")
        guard let (turnId, willRetry, body) = retryErrors.first else { return }
        XCTAssertTrue(willRetry, "stream-error during retry must set willRetry=true")
        XCTAssertNotNil(turnId,
                        "stream-error during a turn must carry the active turnId for UI grouping")
        // Internal fine-grained reason is StreamError; the wire-facing
        // codexErrorInfo collapses it to `.other` (no upstream analogue).
        XCTAssertEqual(body.reason, "StreamError")
        XCTAssertEqual(body.codexErrorInfo, .other)
        XCTAssertTrue(body.message.contains("transient"),
                      "error message should propagate the underlying failure; got: \(body.message)")

        // The retry must succeed and the compaction turn must still complete.
        let completed = events.contains { ev in
            if case .turnCompleted(_, let turn) = ev { return turn.status == .completed }
            return false
        }
        XCTAssertTrue(completed,
                      "compaction turn must complete after the retry succeeds; events=\(events.map { $0.method })")
    }

    func testSessionSandboxBuilderHonorsClientSuppliedMode() async throws {
        // Regression for the wire-through fix: SessionConfig values that the
        // client passes at thread/start (sandboxMode, writableRoots,
        // networkAccess) must reach the WorkspaceSandbox the worker uses.
        // Previously the spawned worker hardcoded `.workspaceWrite` and
        // `writableRoots: [c.cwd]`, silently downgrading danger-full-access
        // sessions and dropping extra writable roots.
        let execPolicy = ExecPolicy()
        let wsWrite = SessionSandboxBuilder.make(
            config: SessionConfig(
                threadId: ThreadId("sb-ws"),
                cwd: "/work",
                sandboxMode: .workspaceWrite,
                writableRoots: ["/work", "/scratch"],
                networkAccess: false),
            execPolicy: execPolicy)
        XCTAssertEqual(wsWrite.policy.mode, .workspaceWrite)
        XCTAssertEqual(wsWrite.policy.writableRoots, ["/work", "/scratch"])
        XCTAssertFalse(wsWrite.policy.networkAllowed)

        let full = SessionSandboxBuilder.make(
            config: SessionConfig(
                threadId: ThreadId("sb-full"),
                cwd: "/work",
                sandboxMode: .dangerFullAccess,
                networkAccess: false),
            execPolicy: execPolicy)
        XCTAssertEqual(full.policy.mode, .dangerFullAccess)
        // Danger-full-access implies network egress regardless of the
        // boolean — fast clients shouldn't have to set both.
        XCTAssertTrue(full.policy.networkAllowed)

        let readOnly = SessionSandboxBuilder.make(
            config: SessionConfig(
                threadId: ThreadId("sb-ro"),
                cwd: "/work",
                sandboxMode: .readOnly,
                networkAccess: true),
            execPolicy: execPolicy)
        XCTAssertEqual(readOnly.policy.mode, .readOnly)
        XCTAssertTrue(readOnly.policy.networkAllowed,
                      "explicit networkAccess=true should pass through even under read-only")
    }

    // P2.6: `can_drain_pending_input` gate (Codex turn.rs:385/476/515).
    //
    // After mid-turn auto-compaction, if the model still has a follow-up
    // sampling to produce (because a tool just ran), steer input MUST NOT
    // be drained into history before that follow-up sampling. Otherwise we
    // interleave a user message between a tool call and its expected model
    // response, corrupting the conversation history. Upstream sets
    // `can_drain_pending_input = !model_needs_follow_up` after compaction
    // (turn.rs:515). Pre-fix Swift unconditionally drained at the top of
    // every iteration.
    func testSteerInputDeferredUntilToolFollowUpReturns() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))

        // Scenarios for the regular turn loop + one mid-turn compaction
        // pass. autoCompactTokens=1 forces mid-turn compaction immediately
        // after the first sampling iteration.
        //   s1 (iter 1 sampling): toolCall — sets model_needs_follow_up.
        //   s2 (compaction inner call): summary.
        //   s3 (iter 2 sampling, post-compaction follow-up): final agentDone.
        //   s4 (follow-up turn driven by drained pendingInput): hello.
        let model = RecordingModelClient(MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "gated_echo",
                                    argumentsJSON: "{\"text\":\"TOOLOUT\"}"),
                          .completeContinue(responseId: "r1", tokens: 5)]),
            MockScenario([.created,
                          .agentDone(itemId: "sum", "MODEL SUMMARY"),
                          .completeEndTurn(responseId: "r2", tokens: 3)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done after tool"),
                          .completeEndTurn(responseId: "r3", tokens: 2)]),
            .hello("steer follow-up turn"),
        ]))

        // Gated tool: starts immediately, suspends, releases on demand —
        // this gives the test a deterministic window during which the
        // engine is awaiting a tool result and a steer can be submitted.
        let gate = ToolGate()
        let tool = GatedEchoTool(gate: gate)
        let router = ToolRouter(limits: Limits())
        await router.register(tool)

        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store, router: router,
                                   limits: Limits(), autoCompactTokens: 1)
        await engine.start()

        // Collector that stops after the FIRST turnCompleted (the
        // steer-driven follow-up turn that may run afterwards is separate),
        // capturing the active turn id so the steer can echo it as
        // expectedTurnId (the upstream `turn/steer` contract).
        let turnIdBox = TurnIdBox()
        let firstTurnCompleted = Task {
            await collectHCCapturingTurnId(engine, into: turnIdBox) {
                if case .turnCompleted = $0 { return true }; return false
            }
        }

        await engine.submit(.startTurn(input: [TurnInput(text: "use the tool")], model: nil, turnId: nil))

        // Wait until the tool has actually started executing — this proves
        // the engine task is suspended awaiting the tool result, with a
        // pending follow-up sampling owed to the model.
        await gate.waitForToolStart()

        // Steer mid-flight — submitted between the model's toolCall
        // emission and the follow-up sampling. Without the
        // `can_drain_pending_input = !followUp` gate after mid-turn
        // compaction, the next loop iteration would drain this BEFORE the
        // follow-up sampling, interleaving a user message between the tool
        // call and its model response.
        let activeTurnId = await turnIdBox.waitForId() ?? TurnId("t")
        await engine.submit(.steer(input: [TurnInput(text: "STEER_PAYLOAD_42")],
                                   expectedTurnId: activeTurnId))

        // Tiny pause so the steer enqueue commits before the tool returns
        // (deterministic ordering for the race we want to test).
        try await Task.sleep(for: .milliseconds(20))

        // Release the tool — the engine then completes the first sampling,
        // runs mid-turn compaction (token limit reached + follow-up
        // needed), and proceeds to the follow-up sampling.
        await gate.release()

        _ = await firstTurnCompleted.value

        let caps = await model.capturedRequests()
        // Expect within the first turn: s1 (initial), s2 (compaction inner),
        // s3 (post-compaction follow-up).
        XCTAssertGreaterThanOrEqual(caps.count, 3,
            "expected initial + compaction summary + post-compaction follow-up sampling")

        // CRITICAL: the post-compaction follow-up sampling MUST NOT see the
        // steer payload. After mid-turn compaction with `followUp == true`
        // (a tool ran), upstream sets `can_drain_pending_input = false`,
        // so the next iteration must not drain steer into history. The
        // model's follow-up continuation runs first.
        let followUpPromptText = caps[2].prompt.input.map { item -> String in
            switch item {
            case .userText(let t), .developerText(let t), .assistantText(let t): return t
            case .toolOutput(_, let o): return o
            case .reasoning(let summary, let content, _): return (summary + content).joined(separator: "\n")
            }
        }.joined(separator: "\n")
        XCTAssertFalse(followUpPromptText.contains("STEER_PAYLOAD_42"),
            "steer must not interleave between a tool call and its model follow-up across mid-turn compaction")

        // The first prompt must of course NOT contain the steer either
        // (steer was submitted long after first sampling began).
        let firstPromptText = caps[0].prompt.input.map { item -> String in
            switch item {
            case .userText(let t), .developerText(let t), .assistantText(let t): return t
            case .toolOutput(_, let o): return o
            case .reasoning(let summary, let content, _): return (summary + content).joined(separator: "\n")
            }
        }.joined(separator: "\n")
        XCTAssertFalse(firstPromptText.contains("STEER_PAYLOAD_42"))

        // But the steer DID get processed: deferred, not dropped. It
        // persists as a durable user message once the engine drains it
        // (either on a later iteration when followUp is false, or on the
        // post-turn pending-input → follow-up-turn handoff at line 1010).
        var sawSteerInRollout = false
        for _ in 0..<50 {
            let rebuilt = try await store.reconstruct(tid)
            sawSteerInRollout = rebuilt.items.contains {
                if case .userMessage(_, let c) = $0 {
                    return c.contains { ($0.text ?? "").contains("STEER_PAYLOAD_42") }
                }
                return false
            }
            if sawSteerInRollout { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(sawSteerInRollout,
            "steer input must eventually be recorded — deferred, not dropped")
    }

    /// P4.1 / H-25: SessionEngine.buildInitialContextMessages must derive the
    /// PermissionsInstructions sandbox mode, network access, and writable
    /// roots from the live `SessionConfig` rather than hardcoded fallback
    /// values. Validates the readOnly + never + restricted permutation —
    /// previously the prompt was always "workspace-write, restricted, [cwd]"
    /// regardless of config.
    func testSessionEngineReadsPermissionsFromConfig() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        // Lock the session down: read-only sandbox, never approve, no network.
        let cfg = SessionConfig(threadId: tid, cwd: "/locked/cwd",
                                approvalPolicy: .never,
                                sandboxMode: .readOnly,
                                writableRoots: [],
                                networkAccess: false)
        _ = try await store.create(cfg)
        let model = MockModelClient([.hello("ok")])
        let router = ToolRouter(limits: Limits())
        let engine = SessionEngine(config: cfg, model: model, store: store,
                                   router: router, limits: Limits())

        let msgs = await engine.buildInitialContextMessages()
        // The PermissionsInstructions message is the first developer section.
        let permsText = msgs
            .filter { $0.role == "developer" }
            .flatMap(\.sections)
            .first { $0.contains("<permissions instructions>") }
        XCTAssertNotNil(permsText, "permissions instructions section missing")
        let text = permsText ?? ""

        // 1. Sandbox mode must be `read-only` — previously hardcoded to
        //    workspace-write.
        XCTAssertTrue(text.contains("`sandbox_mode` is `read-only`:"),
                      "permissions text must reflect config.sandboxMode = .readOnly")
        XCTAssertFalse(text.contains("`sandbox_mode` is `workspace-write`"),
                       "permissions text must NOT mention workspace-write when config is read-only")

        // 2. Network access must reflect config.networkAccess = false →
        //    "restricted".
        XCTAssertTrue(text.contains("Network access is restricted."),
                      "permissions text must reflect config.networkAccess = false")

        // 3. Approval policy must reflect config.approvalPolicy = .never.
        XCTAssertTrue(text.contains("Approval policy is currently never."),
                      "permissions text must reflect config.approvalPolicy = .never")

        // 4. Read-only / danger-full-access modes must NOT emit a writable
        //    roots sentence (upstream `sandbox_prompt_from_profile` returns
        //    `None` for these and the renderer suppresses the line).
        XCTAssertFalse(text.contains("The writable root"),
                       "read-only sandbox must NOT advertise writable roots")
    }

    /// Workspace-write counterpart: writable roots must include the cwd plus
    /// any extras the config provides, and network access true must render
    /// "enabled".
    func testSessionEngineWorkspaceWritePermissionsFromConfig() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: "/proj",
                                approvalPolicy: .onRequest,
                                sandboxMode: .workspaceWrite,
                                writableRoots: ["/proj", "/tmp/extra"],
                                networkAccess: true)
        _ = try await store.create(cfg)
        let model = MockModelClient([.hello("ok")])
        let router = ToolRouter(limits: Limits())
        let engine = SessionEngine(config: cfg, model: model, store: store,
                                   router: router, limits: Limits())

        let msgs = await engine.buildInitialContextMessages()
        let text = msgs.filter { $0.role == "developer" }.flatMap(\.sections)
            .first { $0.contains("<permissions instructions>") } ?? ""

        XCTAssertTrue(text.contains("`sandbox_mode` is `workspace-write`:"))
        XCTAssertTrue(text.contains("Network access is enabled."))
        // Roots sorted, plural phrasing — `/proj` and `/tmp/extra` (dedup'd).
        XCTAssertTrue(text.contains("The writable roots are `/proj`, `/tmp/extra`."),
                      "workspace-write must list cwd + config.writableRoots; got: \(text)")
    }

    // MARK: - P6.3 / H-45: context-window trim-and-retry

    /// Parity P6.3 (H-45): when the model returns a
    /// `context_window_exceeded` error mid-turn, the turn-loop must drop the
    /// oldest non-essential history item and retry the same sampling
    /// iteration. Upstream `compact.rs:223-237` codifies this; codex-swift
    /// applies the same trim-and-retry pattern in the regular sampling loop
    /// so large conversations don't fail hard before a compaction can run.
    func testTurnLoopTrimsAndRetriesOnContextWindowExceeded() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // Pre-seed history with multiple items so `removeFirstItem` has
        // something to drop. We do this by running a successful "hello" turn
        // first, which appends a user + assistant pair.
        let model = MockModelClient([
            // Turn 1: simple hello (seeds history).
            .hello("seed assistant"),
            // Turn 2 — first sampling attempt fails with context_window_exceeded
            // at stream-open. The engine must trim the oldest item and retry.
            MockScenario([.failContextWindow("context_length_exceeded")]),
            // Turn 2 — retry succeeds with a normal hello.
            .hello("after trim"),
        ])
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()

        // Drain turn 1.
        let t1 = Task { await collectHC(engine) {
            if case .turnCompleted = $0 { return true }; return false } }
        await engine.submit(.startTurn(input: [TurnInput(text: "hi")], model: nil, turnId: nil))
        _ = await t1.value

        // Turn 2: collect everything until the second turnCompleted.
        let t2 = Task { await collectHC(engine) {
            if case .turnCompleted = $0 { return true }; return false } }
        await engine.submit(.startTurn(input: [TurnInput(text: "second turn")], model: nil, turnId: nil))
        let events2 = await t2.value

        // Exactly one ContextWindowExceeded error notification was emitted
        // with willRetry=true.
        let trimErrors = events2.compactMap { ev -> (Bool, ErrorBody)? in
            if case .error(_, _, let willRetry, let body) = ev,
               body.codexErrorInfo == .contextWindowExceeded {
                return (willRetry, body)
            }
            return nil
        }
        XCTAssertEqual(trimErrors.count, 1,
                       "expected exactly one ContextWindowExceeded transient error")
        XCTAssertTrue(trimErrors.first?.0 ?? false,
                      "context-window trim retry must set willRetry=true")

        // The turn completed successfully — sampling retried after the trim.
        guard case .turnCompleted(_, let turn)? = events2.last(where: {
            if case .turnCompleted = $0 { return true }; return false
        }) else { return XCTFail("no turnCompleted on turn 2") }
        XCTAssertEqual(turn.status, .completed,
                       "turn must complete after a successful trim-and-retry")

        // The mock saw 3 requests total (turn 1 + turn 2 failed attempt +
        // turn 2 retry).
        let caps = await model.capturedRequests()
        XCTAssertEqual(caps.count, 3,
                       "expected 3 stream() calls (1 seed + 2 attempts on turn 2), got \(caps.count)")
    }

    /// Parity P6.3 (H-45): trim-and-retry terminates when there is nothing
    /// left to trim. Upstream `compact.rs:223-237` only gates further trims on
    /// `turn_input_len > 1`; once the prompt is down to a single item the
    /// turn fails. Codex-swift mirrors this with `ctx.history.count > 1`.
    /// The trim itself is uncapped (it does NOT share the `streamMaxRetries`
    /// budget used for non-trim retryable errors).
    func testTurnLoopGivesUpWhenHistoryCannotBeTrimmedFurther() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // Seed a small history: 3 successful turns → roughly 6 items
        // (user+assistant per turn). Pick a number larger than
        // `streamMaxRetries` so that if the old monotonic cap regressed we'd
        // bail early instead of trimming all the way down to history.count==1.
        var seedScenarios: [MockScenario] = []
        let seedTurns = 8
        XCTAssertGreaterThan(seedTurns, Limits().streamMaxRetries,
                             "test must outstrip the old monotonic cap")
        for i in 0..<seedTurns { seedScenarios.append(.hello("seed \(i)")) }
        // Then enough persistent context-window failures to exhaust trims
        // (one per history item, plus a few spares).
        var failingScenarios: [MockScenario] = []
        for _ in 0..<(seedTurns * 4) {
            failingScenarios.append(MockScenario([.failContextWindow("ctx full")]))
        }
        let model = MockModelClient(seedScenarios + failingScenarios)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()

        for i in 0..<seedTurns {
            let t = Task { await collectHC(engine) {
                if case .turnCompleted = $0 { return true }; return false } }
            await engine.submit(.startTurn(input: [TurnInput(text: "seed-\(i)")],
                                           model: nil, turnId: nil))
            _ = await t.value
        }

        let final = Task { await collectHC(engine) {
            if case .turnCompleted = $0 { return true }; return false } }
        await engine.submit(.startTurn(input: [TurnInput(text: "explode")], model: nil, turnId: nil))
        let events = await final.value

        guard case .turnCompleted(_, let turn)? = events.last(where: {
            if case .turnCompleted = $0 { return true }; return false
        }) else { return XCTFail("no turnCompleted on target turn") }
        XCTAssertEqual(turn.status, .failed,
                       "turn must fail once history is trimmed to a single item")

        let willRetryCount = events.reduce(0) { acc, ev -> Int in
            if case .error(_, _, let willRetry, let body) = ev,
               willRetry, body.codexErrorInfo == .contextWindowExceeded {
                return acc + 1
            }
            return acc
        }
        // Parity check: we must have trimmed MORE than `streamMaxRetries`
        // times before giving up — proving the cap was lifted. Upstream
        // resets retries to 0 on each trim, so there's no shared budget.
        XCTAssertGreaterThan(willRetryCount, Limits().streamMaxRetries,
                             "trim should not be bounded by streamMaxRetries; got \(willRetryCount)")
    }

    /// Parity P6.3 (H-45): multiple successive trims must succeed —
    /// the engine must not bail at the previous monotonic-counter cap.
    /// Upstream `compact.rs:230` resets `retries = 0` on every successful
    /// trim, so the trim path is effectively unbounded except by
    /// `turn_input_len > 1`.
    func testTurnLoopAllowsMoreTrimsThanStreamMaxRetries() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // Seed enough history that we can trim more times than the old
        // monotonic cap before recovering.
        var seedScenarios: [MockScenario] = []
        let seedTurns = Limits().streamMaxRetries + 3   // > old cap
        for i in 0..<seedTurns { seedScenarios.append(.hello("seed \(i)")) }
        // Target turn: `streamMaxRetries + 1` consecutive context-window
        // failures followed by a normal hello. Under the old monotonic cap
        // this turn would have failed; under upstream parity it succeeds.
        var targetSteps: [MockScenario] = []
        for _ in 0..<(Limits().streamMaxRetries + 1) {
            targetSteps.append(MockScenario([.failContextWindow("ctx full")]))
        }
        targetSteps.append(.hello("recovered"))
        let model = MockModelClient(seedScenarios + targetSteps)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()

        for i in 0..<seedTurns {
            let t = Task { await collectHC(engine) {
                if case .turnCompleted = $0 { return true }; return false } }
            await engine.submit(.startTurn(input: [TurnInput(text: "seed-\(i)")],
                                           model: nil, turnId: nil))
            _ = await t.value
        }

        let final = Task { await collectHC(engine) {
            if case .turnCompleted = $0 { return true }; return false } }
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let events = await final.value

        guard case .turnCompleted(_, let turn)? = events.last(where: {
            if case .turnCompleted = $0 { return true }; return false
        }) else { return XCTFail("no turnCompleted on target turn") }
        XCTAssertEqual(turn.status, .completed,
                       "turn must succeed after > streamMaxRetries successive trims")

        let willRetryCount = events.reduce(0) { acc, ev -> Int in
            if case .error(_, _, let willRetry, let body) = ev,
               willRetry, body.codexErrorInfo == .contextWindowExceeded {
                return acc + 1
            }
            return acc
        }
        XCTAssertEqual(willRetryCount, Limits().streamMaxRetries + 1,
                       "expected \(Limits().streamMaxRetries + 1) trim retries, got \(willRetryCount)")
    }

    /// Parity P6.3 + P5.2: when the oldest history item is a tool call that
    /// shares its ItemId with a recorded output (a split call/output pair in
    /// upstream's ResponseItem model), `removeFirstItem` removes both halves
    /// — preserving the "no orphan tool output" invariant after a trim.
    func testTrimRemovesPairedCallAndOutput() {
        var ctx = ContextManager()
        // Construct a synthetic split pair: two .commandExecution items
        // sharing the same ItemId — one in-progress (no output) and one
        // completed (with output). This mirrors the upstream split-record
        // representation that `removeCorrespondingFor` is designed to handle.
        let id = ItemId.generate("c")
        let pending = ThreadItem.commandExecution(
            id: id, command: ["echo"], cwd: "/w",
            status: .inProgress, commandActions: [], aggregatedOutput: nil, exitCode: nil)
        let completed = ThreadItem.commandExecution(
            id: id, command: ["echo"], cwd: "/w",
            status: .completed, commandActions: [], aggregatedOutput: "out", exitCode: 0)
        ctx.appendItem(pending)
        ctx.appendItem(completed)
        XCTAssertEqual(ctx.history.count, 2,
                       "precondition: history contains the split pair")
        let removed = ctx.removeFirstItem()
        XCTAssertEqual(removed, 2,
                       "removeFirstItem must drop BOTH halves of a paired call/output")
        XCTAssertTrue(ctx.history.isEmpty,
                      "history must be empty after removing both halves of the pair")
    }
}

/// Async gate used by `GatedEchoTool` to coordinate with the test: the tool
/// signals `started` when it begins executing, then suspends until the test
/// calls `release()`.
actor ToolGate {
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func signalStart() {
        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
    }
    func waitForToolStart() async {
        if hasStarted { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            startContinuation = c
        }
    }
    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            releaseContinuation = c
        }
    }
    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

struct GatedEchoTool: Tool {
    let name = "gated_echo"
    let parallelSafe = false
    let gate: ToolGate
    func run(_ call: ToolCall, cwd _: String) async throws -> ToolResult {
        await gate.signalStart()
        await gate.waitForRelease()
        struct A: Decodable { let text: String }
        let a = (try? JSONDecoder().decode(A.self,
                                           from: Data(call.argumentsJSON.utf8)))?.text ?? ""
        return ToolResult(callId: call.callId, output: a, success: true, truncated: false)
    }
}

struct EchoToolHC: Tool {
    let name = "echo"; let parallelSafe = true
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct A: Decodable { let text: String }
        let a = (try? JSONDecoder().decode(A.self, from: Data(call.argumentsJSON.utf8)))?.text ?? ""
        return ToolResult(callId: call.callId, output: a, success: true, truncated: false)
    }
}