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
@testable import Workflows
@testable import WireProtocol

/// Live-LLM E2E coverage for the workflows-progress feature:
///   - debounced `workflow/progress` `ServerNotification.raw` relayed onto the
///     parent session stream (only when a sink is wired);
///   - progress batch events carry the real `workflow_log` + `workflow_agent`
///     records produced by genuine sub-agent dispatches;
///   - the final batch is flushed on completion (`flushNow`);
///   - with NO sink wired, ZERO progress notifications surface, yet the run
///     itself is unaffected (snapshot still records logs + status "completed").
///
/// Every assertion is an observable side-effect that occurs ONLY if the feature
/// worked — an emitted `.raw` notification with decoded params, or its proven
/// absence paired with an intact on-disk snapshot — never that the model
/// "said" anything.
final class LiveWorkflowsProgressTests: XCTestCase {

    override func tearDown() async throws {
        // The bus + WorkflowHolder are process-global (last-install-wins).
        await WorkflowBus.shared.clearAll()
        try await super.tearDown()
    }

    /// Build a bare SessionEngine used purely as a notification relay/collector.
    /// The orchestrator's `progressSink` is wired to this engine's
    /// `injectNotification`, so debounced `workflow/progress` batches land on
    /// this engine's event stream exactly as they would on a live session.
    private func makeRelayEngine(home: String, work: String) async throws
    -> (SessionEngine, ThreadId) {
        let tid = ThreadId("thr_progrelay_" + UUID().uuidString.prefix(8).lowercased())
        let store = try lxStore(home)
        let router = ToolRouter(limits: Limits())
        let engine = lxBareEngine(home: home, work: work, tid: tid, store: store,
                                  router: router, model: lxRecording(64))
        return (engine, tid)
    }

    // MARK: happy — multi-agent fan-out emits workflow/progress on the session stream

    func testMultiAgentWorkflowEmitsWorkflowProgressOnSessionStream() async throws {
        try lxSkipUnlessLiveKey()
        #if canImport(JavaScriptCore)
        let home = lxTmp("prog-happy")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = home + "/work"
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

        // Relay engine first, so the orchestrator sink can push onto its stream.
        let (engine, _) = try await makeRelayEngine(home: home, work: work)
        let sink: WorkflowProgressNotifier.Sink = { [weak engine] n in
            Task { await engine?.injectNotification(n) }
        }

        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, maxOut: 64, collectTimeout: .seconds(120),
            progressSink: sink)

        let script = "export const meta = { name: \"e2e-prog\", description: \"d\", phases: [{title:'fanout'}] };\nphase('fanout');\nlog('PROG_MARK_1');\nconst [a,b] = await parallel([ () => agent('say x'), () => agent('say y') ]);\nreturn { a, b };"

        // Start collecting the parent session stream concurrently, THEN launch.
        let collectTask = Task { await lxCollectFor(engine, window: .seconds(150)) }

        let resp = try await harness.orchestrator.launch(
            WorkflowBus.LaunchRequest(script: script, argsJSON: nil, cwd: work))
        let runId = resp.runId

        // Detached run — poll the bus until terminal before asserting.
        let terminal = await lxPollWorkflowTerminal(runId, timeout: .seconds(130))
        // Give the debounced notifier a final beat to flush + relay.
        try? await Task.sleep(for: .milliseconds(300))

        let evs = await collectTask.value

        // Snapshot-level sanity: the run actually completed with two real agents.
        if let snap = lxReadSnapshot(codexHome: home, runId: runId) {
            XCTAssertEqual(snap["status"] as? String, "completed",
                           "run reached completed (terminal=\(terminal))")
        }

        // Provable side-effect #1: at least one workflow/progress .raw landed on
        // the parent session stream — occurs ONLY because a sink was wired.
        let progressCount = lxRawCount(evs, method: "workflow/progress")
        XCTAssertGreaterThanOrEqual(progressCount, 1,
            "at least one workflow/progress .raw notification relayed onto the session stream")

        // Provable side-effect #2: the union of decoded params.events across all
        // batches contains the real workflow_log marker AND a workflow_agent.
        let progressEvents = lxWorkflowProgressEvents(evs)
        XCTAssertFalse(progressEvents.isEmpty, "decoded progress events present")

        let hasLogMarker = progressEvents.contains { ev in
            guard case .object(let o) = ev else { return false }
            guard case .string("workflow_log") = o["type"] else { return false }
            if case .string("PROG_MARK_1") = o["message"] { return true }
            return false
        }
        XCTAssertTrue(hasLogMarker,
            "progress union contains a workflow_log event with message==PROG_MARK_1")

        let hasAgentEvent = progressEvents.contains { ev in
            guard case .object(let o) = ev else { return false }
            if case .string("workflow_agent") = o["type"] { return true }
            return false
        }
        XCTAssertTrue(hasAgentEvent,
            "progress union contains at least one workflow_agent event (real sub-agents ran)")
        #else
        throw XCTSkip("workflows require JavaScriptCore (macOS build)")
        #endif
    }

    // MARK: adversarial — no sink wired ⇒ ZERO progress, run still unaffected

    func testProgressNotEmittedWhenNoSinkWired() async throws {
        try lxSkipUnlessLiveKey()
        #if canImport(JavaScriptCore)
        let home = lxTmp("prog-nosink")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = home + "/work"
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

        // Relay engine exists, but we deliberately do NOT wire its
        // injectNotification into the orchestrator: progressSink == nil.
        let (engine, _) = try await makeRelayEngine(home: home, work: work)

        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, maxOut: 64, collectTimeout: .seconds(120),
            progressSink: nil)

        let script = "export const meta = { name: \"e2e-nosink\", description: \"d\" };\nlog('SHOULD_NOT_SURFACE');\nconst a = await agent('say z');\nreturn { a };"

        // Collect the parent session stream for the full run window. Nothing
        // should ever be relayed onto it because no sink was wired.
        let collectTask = Task { await lxCollectFor(engine, window: .seconds(150)) }

        let resp = try await harness.orchestrator.launch(
            WorkflowBus.LaunchRequest(script: script, argsJSON: nil, cwd: work))
        let runId = resp.runId

        let terminal = await lxPollWorkflowTerminal(runId, timeout: .seconds(130))
        // Extra settle: had a sink existed, the debounced flush would land here.
        try? await Task.sleep(for: .milliseconds(300))

        let evs = await collectTask.value

        // Provable side-effect #1: ZERO workflow/progress .raw notifications
        // surfaced on the session stream (progress is sink-gated).
        XCTAssertEqual(lxRawCount(evs, method: "workflow/progress"), 0,
            "no sink wired ⇒ zero workflow/progress notifications on the session stream")
        XCTAssertTrue(lxWorkflowProgressEvents(evs).isEmpty,
            "no decoded progress events when the sink is absent")

        // Provable side-effect #2: the run itself is UNAFFECTED — snapshot.json
        // still records the log line and a completed status.
        let snap = lxReadSnapshot(codexHome: home, runId: runId)
        XCTAssertNotNil(snap, "snapshot.json written for the sink-less run")
        if let snap {
            XCTAssertEqual(snap["status"] as? String, "completed",
                           "sink-less run still completes (terminal=\(terminal))")
            let logs = (snap["logs"] as? [Any]) ?? []
            let logStrings = logs.compactMap { $0 as? String }
            XCTAssertTrue(logStrings.contains("SHOULD_NOT_SURFACE"),
                "snapshot logs still record SHOULD_NOT_SURFACE — the run is unaffected by the missing sink")
        }
        #else
        throw XCTSkip("workflows require JavaScriptCore (macOS build)")
        #endif
    }
}
