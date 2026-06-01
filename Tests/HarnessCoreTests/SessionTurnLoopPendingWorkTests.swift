import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives

/// Targeted coverage for the `session-turn-loop` audit unit (v12):
///   1. Turn-terminal token-usage emit dropped (per-call only, matching
///      upstream `bespoke_event_handling.rs handle_token_count_event`).
///   2. Interrupt + queued pending input restarts a fresh turn
///      (`abort_all_tasks` -> `maybe_start_turn_for_pending_work`).
///   3. A trigger-turn mailbox message wakes an idle session
///      (`maybe_start_turn_for_pending_work` trigger-turn arm).
final class SessionTurnLoopPendingWorkTests: XCTestCase {

    private func makeStore() throws -> (ThreadStore, String) {
        let home = NSTemporaryDirectory() + "stl-" + UUID().uuidString
        return (try ThreadStore(codexHome: home, limits: Limits()), home)
    }

    // MARK: Finding 1 — no turn-terminal token-usage emit.

    /// Upstream emits a `thread/tokenUsage/updated` notification strictly PER
    /// MODEL CALL; `on_task_finished` records only telemetry and sends no
    /// notification. A single-call regular turn must therefore produce exactly
    /// ONE token-usage notification (the per-call emit), not two (per-call plus
    /// a turn-terminal aggregate whose `last` zeroed the per-category split).
    func testRegularTurnEmitsTokenUsageOnlyPerCall() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: MockModelClient([.hello("done")]),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let c = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await c.value
        let tokenUsages = evs.filter { if case .tokenUsageUpdated = $0 { return true }; return false }
        XCTAssertEqual(tokenUsages.count, 1,
            "a single-call turn must emit exactly one token-usage notification (per-call only); a turn-terminal emit would make it two")
        // The single emit is the per-call delta carrying the call's total.
        guard case .tokenUsageUpdated(_, _, _, let last, _)? = tokenUsages.first else {
            return XCTFail("expected the per-call token-usage notification")
        }
        XCTAssertEqual(last.totalTokens, 12,
            "the surviving emit is the per-call breakdown (`.hello` reports totalTokens=12)")
    }

    // MARK: Finding 2 — interrupt + queued steer restarts a turn.

    /// A steer that lands together with an interrupt queues `pendingInput`; the
    /// abort gate must then restart a fresh turn for that queued input (upstream
    /// `abort_all_tasks` -> `maybe_start_turn_for_pending_work` on
    /// `TurnAbortReason::Interrupted`). Before the fix the interrupt gate
    /// dropped the queued input until the next explicit submit.
    func testInterruptWithQueuedSteerRestartsTurn() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // Turn 1 is slow so the steer + interrupt land mid-turn; turn 2 (the
        // restarted turn for the queued steer) answers quickly and ends.
        let model = MockModelClient([
            MockScenario([.created, .slowMillis(400),
                          .agentDone(itemId: "m1", "blocked"),
                          .completeEndTurn(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "m2", "restarted answer"),
                          .completeEndTurn(responseId: "r2", tokens: 2)]),
        ])
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let box = TurnIdBox()
        let collector = Task { await collectHCCapturingTurnId(engine, into: box) { ev in
            if case .turnCompleted = ev { return true }; return false
        } }
        await engine.submit(.startTurn(input: [TurnInput(text: "long task")], model: nil, turnId: nil))
        let activeId = await box.waitForId()
        XCTAssertNotNil(activeId, "turn 1 must publish a turn id")
        // Steer queues pending input against the active turn, THEN interrupt.
        await engine.submit(.steer(input: [TurnInput(text: "steered")],
                                   expectedTurnId: activeId!))
        await engine.submit(.interrupt(turnId: activeId!))
        // Collect through both terminal turns: the interrupted turn 1 AND the
        // restarted turn 2 that consumes the queued steer.
        let first = await collector.value
        let completed1 = first.compactMap { ev -> TurnObject? in
            if case .turnCompleted(_, let t) = ev { return t }; return nil
        }
        XCTAssertEqual(completed1.last?.status, .interrupted,
                       "the interrupted turn completes with status interrupted")
        // The restart fires a fresh turn for the queued steer. Wait for its
        // terminal turn/completed.
        let c2 = Task { await collectTasks(engine, untilCompletions: 1) }
        let restarted = await c2.value
        let restartedCompleted = restarted.compactMap { ev -> TurnObject? in
            if case .turnCompleted(_, let t) = ev { return t }; return nil
        }
        XCTAssertEqual(restartedCompleted.last?.status, .completed,
            "the queued steer must restart a fresh turn that runs to completion after the interrupt")
        // The restarted turn sampled the steer text as a user message.
        let sawSteer = restarted.contains { ev in
            if case .itemStarted(_, _, .userMessage(_, let content), _) = ev {
                return content.contains { $0.text == "steered" }
            }
            return false
        }
        XCTAssertTrue(sawSteer, "the restarted turn must carry the queued steer input as its user message")
    }

    // MARK: Finding 3 — trigger-turn mailbox mail wakes an idle session.

    /// An inter-agent `send_message{trigger_turn:true}` delivered to an idle
    /// session must start a turn (upstream `maybe_start_turn_for_pending_work`
    /// trigger-turn arm). The drained trigger-turn mail surfaces as the woken
    /// turn's input.
    func testTriggerTurnMailWakesIdleSession() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: MockModelClient([
                                    MockScenario([.created,
                                                  .agentDone(itemId: "m1", "woke up"),
                                                  .completeEndTurn(responseId: "r", tokens: 3)]),
                                   ]),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        // Session is idle (no active turn). Deliver a trigger-turn message.
        let collector = Task { await collectTasks(engine, untilCompletions: 1) }
        await engine.deliverInterAgentMail(InterAgentCommunication(
            author: "/other", recipient: "/root",
            content: "ping from peer", triggerTurn: true))
        let evs = await collector.value
        let completed = evs.compactMap { ev -> TurnObject? in
            if case .turnCompleted(_, let t) = ev { return t }; return nil
        }
        XCTAssertEqual(completed.last?.status, .completed,
            "a trigger-turn mailbox message must wake the idle session and run a turn to completion")
        // The woken turn surfaced the trigger-turn mail content as input.
        let sawMail = evs.contains { ev in
            if case .itemStarted(_, _, .userMessage(_, let content), _) = ev {
                return content.contains { ($0.text ?? "").contains("ping from peer") }
            }
            return false
        }
        XCTAssertTrue(sawMail, "the woken turn must carry the drained trigger-turn mail as its input")
    }

    /// A NON-trigger inter-agent message delivered to an idle session must NOT
    /// start a turn (only `trigger_turn` mail wakes an idle session).
    func testNonTriggerMailDoesNotWakeIdleSession() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: MockModelClient([.hello("should not run")]),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let stream = await engine.events()
        await engine.deliverInterAgentMail(InterAgentCommunication(
            author: "/other", recipient: "/root",
            content: "fyi", triggerTurn: false))
        // Give any erroneous wake a chance to emit a turn/started.
        var sawTurn = false
        let waiter = Task {
            for await ev in stream {
                if case .turnStarted = ev { return true }
            }
            return false
        }
        try await Task.sleep(for: .milliseconds(150))
        waiter.cancel()
        sawTurn = (await waiter.value)
        XCTAssertFalse(sawTurn, "non-trigger mail must not wake an idle session")
        let stillQueued = await engine.mailboxHasPendingTriggerTurn()
        XCTAssertFalse(stillQueued, "non-trigger mail is not a trigger-turn item")
    }
}
