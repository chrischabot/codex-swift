import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import Prompts
@testable import Workflows

/// Live-LLM E2E coverage for the dynamic-workflows TRIGGER hook:
///
///   * the deferred `workflow` tool is hidden until a whole-word "workflow"
///     keyword appears in a turn's input, at which point the engine activates
///     it (sticky for the session) AND injects a `<workflow_reminder>` user
///     context message into the rollout — proven on the router wire tool list
///     (deferred -> activated, specs() gains "workflow") and the on-disk
///     rollout, never on what the model "said";
///   * a near-miss ("workflowy"/"subworkflows") must NOT match the bounded
///     whole-word regex, so neither activation nor reminder occurs;
///   * the `workflowsEnabled:false` flag gate suppresses the entire hook even
///     on a literal keyword hit.
///
/// Each live turn is bounded (maxIters/deadline via `lxFullToolEngine`) so a
/// chatty or non-compliant model can only ever satisfy `lastTurnStatus != nil`
/// — every feature-isolating assertion is a model-independent side-effect.
final class LiveWorkflowsTriggerTests: XCTestCase {

    // MARK: happy — trigger word activates the deferred tool + persists reminder.

    func testTriggerWordActivatesDeferredWorkflowToolAndPersistsReminder() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("wf-trigger-home")
        let work = lxTmp("wf-trigger-work")
        defer { try? FileManager.default.removeItem(atPath: home)
                try? FileManager.default.removeItem(atPath: work) }

        let store = try lxStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work, model: lxModel()))

        let (engine, _, router, _) = await lxFullToolEngine(
            home: home, work: work, tid: tid, store: store,
            maxIters: 5, deadline: .seconds(120), workflowsEnabled: true)

        // BEFORE the turn: `workflow` is purely deferred — discoverable but
        // neither activated nor present on the visible wire tool list.
        let deferredBefore = await router.deferredToolNames()
        let activatedBefore = await router.activatedToolNames()
        let specNamesBefore = await router.specs().map(\.name)
        XCTAssertTrue(deferredBefore.contains("workflow"),
                      "the `workflow` tool is registered deferred by DefaultTools")
        XCTAssertFalse(activatedBefore.contains("workflow"),
                       "deferred tool is NOT activated before any trigger")
        XCTAssertFalse(specNamesBefore.contains("workflow"),
                       "deferred tool is absent from the visible wire tool list before trigger")

        await engine.start()
        let collector = Task { await lxCollect(engine, untilCompletions: 1, timeout: .seconds(120)) }
        await engine.submit(.startTurn(
            input: [TurnInput(text:
                "Use a workflow to research three independent angles of this problem and summarize.")],
            model: nil, turnId: nil))
        let evs = await collector.value

        // Bounded live turn must terminate regardless of model behaviour.
        XCTAssertNotNil(lxLastTurnStatus(evs), "bounded live turn terminated")

        // AFTER: the keyword fired the hook — `workflow` is now activated AND
        // visible on the wire tool list (model-independent: regex, not model).
        let activatedAfter = await router.activatedToolNames()
        let specNamesAfter = await router.specs().map(\.name)
        XCTAssertTrue(activatedAfter.contains("workflow"),
                      "trigger word activated the deferred `workflow` tool")
        XCTAssertTrue(specNamesAfter.contains("workflow"),
                      "activated `workflow` is now part of the visible wire tool list")

        // AND the `<workflow_reminder>` context message was persisted to the
        // rollout with the source-of-truth role + start marker.
        let hasReminder = await lxRolloutHasContextMessage(
            store, tid, role: WorkflowReminder.role, containing: WorkflowReminder.startMarker)
        XCTAssertTrue(hasReminder,
                      "a \(WorkflowReminder.role)-role contextMessage containing "
                      + "\(WorkflowReminder.startMarker) was persisted to the rollout")
    }

    // MARK: adversarial — near-miss words must NOT fire the bounded whole-word regex.

    func testNonTriggerWordDoesNotActivateWorkflowTool() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("wf-nontrigger-home")
        let work = lxTmp("wf-nontrigger-work")
        defer { try? FileManager.default.removeItem(atPath: home)
                try? FileManager.default.removeItem(atPath: work) }

        let store = try lxStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work, model: lxModel()))

        let (engine, _, router, _) = await lxFullToolEngine(
            home: home, work: work, tid: tid, store: store,
            maxIters: 5, deadline: .seconds(120), workflowsEnabled: true)

        // The input deliberately uses only "workflowy" and "subworkflows" —
        // both rejected by (?i)(?<![A-Za-z0-9_])workflows?(?![A-Za-z0-9_]) — so
        // the hook MUST stay inert even with workflowsEnabled:true.
        await engine.start()
        let collector = Task { await lxCollect(engine, untilCompletions: 1, timeout: .seconds(120)) }
        await engine.submit(.startTurn(
            input: [TurnInput(text:
                "Please make this codebase more workflowy and add subworkflows to my pipeline; "
                + "do not call any tools.")],
            model: nil, turnId: nil))
        let evs = await collector.value

        XCTAssertNotNil(lxLastTurnStatus(evs), "bounded live turn terminated")

        let activatedAfter = await router.activatedToolNames()
        let specNamesAfter = await router.specs().map(\.name)
        XCTAssertFalse(activatedAfter.contains("workflow"),
                       "near-miss words must NOT activate the deferred `workflow` tool")
        XCTAssertFalse(specNamesAfter.contains("workflow"),
                       "the `workflow` spec must NOT appear on the wire tool list for a near-miss")

        let hasReminder = await lxRolloutHasContextMessage(
            store, tid, role: WorkflowReminder.role, containing: WorkflowReminder.startMarker)
        XCTAssertFalse(hasReminder,
                       "no \(WorkflowReminder.role)-role workflow_reminder context message "
                       + "was persisted for a near-miss input")
    }

    // MARK: severe — the workflowsEnabled:false flag gate suppresses the hook on a keyword hit.

    func testTriggerHookInertWhenWorkflowsDisabledFlag() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("wf-disabled-home")
        let work = lxTmp("wf-disabled-work")
        defer { try? FileManager.default.removeItem(atPath: home)
                try? FileManager.default.removeItem(atPath: work) }

        let store = try lxStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work, model: lxModel()))

        // Built with workflowsEnabled:false even though the prompt contains a
        // literal whole-word "workflow" keyword that WOULD otherwise fire.
        let (engine, _, router, _) = await lxFullToolEngine(
            home: home, work: work, tid: tid, store: store,
            maxIters: 5, deadline: .seconds(120), workflowsEnabled: false)

        await engine.start()
        let collector = Task { await lxCollect(engine, untilCompletions: 1, timeout: .seconds(120)) }
        await engine.submit(.startTurn(
            input: [TurnInput(text:
                "Use a workflow to fan out and gather independent perspectives now.")],
            model: nil, turnId: nil))
        let evs = await collector.value

        XCTAssertNotNil(lxLastTurnStatus(evs), "bounded live turn terminated")

        // The flag gate precedes the keyword test in the engine, so even a
        // matching keyword leaves the tool deferred and injects no reminder.
        let activatedAfter = await router.activatedToolNames()
        XCTAssertFalse(activatedAfter.contains("workflow"),
                       "workflowsEnabled:false suppresses activation despite a keyword hit")

        let hasReminder = await lxRolloutHasContextMessage(
            store, tid, role: WorkflowReminder.role, containing: WorkflowReminder.startMarker)
        XCTAssertFalse(hasReminder,
                       "the flag gate suppresses the workflow_reminder context message "
                       + "even on a matching keyword")
    }
}
