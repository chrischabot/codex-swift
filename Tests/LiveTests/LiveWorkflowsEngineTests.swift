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

/// Live-LLM end-to-end coverage of the workflow ENGINE PRIMITIVES:
///   - `agent()` / `parallel()` fan out to REAL GPT sub-agents,
///   - the async-launch contract (`async_launched` + `wf_` runId + `task_` taskId),
///   - `log()` + `agentCount` round-trip into the on-disk snapshot,
///   - `pipeline()` null short-circuit drops an item to `null` model-independently,
///   - the JavaScriptCore runtime gate fails clean (never hangs / no-ops) off-darwin.
///
/// Every assertion is a provable side-effect (snapshot.json / journal.jsonl
/// fields, RecordingModelClient wire capture, terminal run status) that occurs
/// ONLY if the primitive worked — never that the model "replied". Each live
/// turn is bounded; the suite must never wedge on a chatty model.
final class LiveWorkflowsEngineTests: XCTestCase {

    override func tearDown() async throws {
        // The bus + WorkflowHolder are process-global, last-install-wins.
        await WorkflowBus.shared.clearAll()
        try await super.tearDown()
    }

    // MARK: - happy: inline workflow fans out two real sub-agents and completes

    func testInlineWorkflowFansOutRealSubAgentsAndCompletes() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("wf-fanout")
        defer { try? FileManager.default.removeItem(atPath: home) }

        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, maxOut: 64, collectTimeout: .seconds(120))

        let script =
            "export const meta = { name: \"e2e-fanout\", description: \"d\" };\n" +
            "log('LX_LOG_MARKER_A1');\n" +
            "const [a,b] = await parallel([ () => agent('Reply with exactly the token RED_42'), " +
            "() => agent('Reply with exactly the token BLUE_42') ]);\n" +
            "return { a, b };"

        // Launch is DETACHED and returns immediately with the async contract.
        let resp = try await harness.orchestrator.launch(
            WorkflowBus.LaunchRequest(script: script, cwd: home))

        // async-launch wire contract.
        XCTAssertEqual(resp.status, "async_launched")
        XCTAssertEqual(resp.taskId, "task_" + resp.runId,
                       "taskId is task_<runId>")
        let runIdRe = try NSRegularExpression(pattern: "^wf_[a-z0-9]{12}$")
        XCTAssertNotNil(
            runIdRe.firstMatch(in: resp.runId, range: NSRange(resp.runId.startIndex..., in: resp.runId)),
            "runId matches ^wf_[a-z0-9]{12}$ (got \(resp.runId))")

        // Never assert synchronously after a detached launch: poll to terminal.
        let terminal = await lxPollWorkflowTerminal(resp.runId, timeout: .seconds(150))
        XCTAssertNotEqual(terminal, "running",
                          "the detached run must reach a terminal status, not wedge")

        #if os(macOS)
        // On darwin (JavaScriptCore present) the two agent() calls are real
        // model turns and the run must complete.
        guard let snap = lxReadSnapshot(codexHome: home, runId: resp.runId) else {
            return XCTFail("snapshot.json missing for \(resp.runId)")
        }
        XCTAssertEqual(snap["status"] as? String, "completed",
                       "fan-out workflow completed")
        // Two REAL sub-agent dispatches => agentCount == 2.
        let agentCount = (snap["agentCount"] as? Int) ?? Int((snap["agentCount"] as? Double) ?? -1)
        XCTAssertEqual(agentCount, 2, "two real sub-agent dispatches")
        // log() surfaced into the persisted logs array.
        let logs = (snap["logs"] as? [String]) ?? []
        XCTAssertTrue(logs.contains("LX_LOG_MARKER_A1"),
                      "log() marker persisted into snapshot logs: \(logs)")
        // result is an object with keys a and b.
        let result = snap["result"] as? [String: Any]
        XCTAssertNotNil(result, "result is a JSON object")
        XCTAssertNotNil(result?["a"], "result has key a")
        XCTAssertNotNil(result?["b"], "result has key b")
        // The sub-agents were REAL model turns captured on the wire.
        let engineCaps = await harness.model.capturedRequests()
        XCTAssertGreaterThanOrEqual(engineCaps.count, 2,
            "each agent() drove at least one real model request (>= 2 total)")
        #else
        // Off-darwin the runtime gate fails clean (no JSC) — proven elsewhere.
        let snap = lxReadSnapshot(codexHome: home, runId: resp.runId)
        XCTAssertEqual(snap?["status"] as? String, "failed",
                       "non-darwin run fails clean without JavaScriptCore")
        #endif
    }

    // MARK: - adversarial: pipeline null short-circuit drops item 2 to null

    func testPipelineNullShortCircuitDropsItemToNull() async throws {
        try lxSkipUnlessLiveKey()

        let home = lxTmp("wf-pipe")
        defer { try? FileManager.default.removeItem(atPath: home) }

        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, maxOut: 64, collectTimeout: .seconds(45))

        // Item 1: stage1 -> agent(<terminal prompt>); stage2 -> agent(<terminal
        // prompt referencing prev>). Item 2: stage1 returns null (x!==1); stage2
        // sees null and returns null. The null short-circuit is MODEL-INDEPENDENT:
        // the stages decide it, not GPT. The agent prompts are deliberately
        // crisp/terminal ("Reply with exactly the token …") — matching the proven
        // fan-out test — so item 1's two chained gpt-4o-mini turns finish in one
        // sampling iteration each rather than wandering into tool-call loops that
        // would trip the stall watchdog. (Vague prompts like "say one" let the
        // small model spin on the full tool inventory and never reach
        // turnCompleted within the ceiling, wedging the run — that was test-prompt
        // flakiness, not an engine bug; the null-drop logic itself is correct.)
        let script =
            "export const meta = { name: \"e2e-pipe\", description: \"d\" };\n" +
            "const out = await pipeline([1,2], " +
            "(x) => x===1 ? agent('Reply with exactly the token ONE_42 and nothing else. Do not call any tools.') : null, " +
            "(prev) => prev===null ? null : agent('Reply with exactly the token TWO_42 and nothing else. Do not call any tools.'));\n" +
            "return out;"

        let resp = try await harness.orchestrator.launch(
            WorkflowBus.LaunchRequest(script: script, cwd: home))
        XCTAssertEqual(resp.status, "async_launched")

        let terminal = await lxPollWorkflowTerminal(resp.runId, timeout: .seconds(150))
        XCTAssertNotEqual(terminal, "running",
                          "the run must terminate, never stay running")

        #if os(macOS)
        guard let snap = lxReadSnapshot(codexHome: home, runId: resp.runId) else {
            return XCTFail("snapshot.json missing for \(resp.runId)")
        }
        XCTAssertEqual(snap["status"] as? String, "completed",
                       "pipeline run completed despite the null branch")

        // result is a 2-element array whose SECOND element is JSON null.
        guard let arr = snap["result"] as? [Any] else {
            return XCTFail("result is not a JSON array: \(String(describing: snap["result"]))")
        }
        XCTAssertEqual(arr.count, 2, "pipeline preserved one slot per input item")
        XCTAssertTrue(arr[1] is NSNull,
                      "item 2 short-circuited to JSON null (stage returned null)")

        // journal.jsonl contains NO `\"type\":\"result\"` line for the dropped
        // (null) agent key: null results are never journaled, and item 2 never
        // produced an agent key at all. So every result line must belong to a
        // real (item-1) agent — there is no dangling null-key result line.
        let lines = lxReadJournalLines(codexHome: home, runId: resp.runId)
        let resultLines = lines.filter { $0.contains("\"type\":\"result\"") }
        // Two real agents (item-1 stage1 + stage2). The dropped item never
        // appears; if the short-circuit leaked, we'd see a 3rd result line.
        XCTAssertLessThanOrEqual(resultLines.count, 2,
            "no result line was journaled for the dropped (null) agent: \(resultLines)")

        // Sub-agent dispatch is BOUNDED: item 2 never reaches a model agent.
        // Only item 1's two agents drive the model (allow a little retry slack).
        let n = await harness.model.capturedRequests().count
        XCTAssertGreaterThanOrEqual(n, 2, "item 1's two agents drove real turns")
        XCTAssertLessThanOrEqual(n, 4,
            "dispatch bounded: item 2 (null branch) never reached a model agent (count=\(n))")
        #else
        let snap = lxReadSnapshot(codexHome: home, runId: resp.runId)
        XCTAssertEqual(snap?["status"] as? String, "failed",
                       "non-darwin run fails clean without JavaScriptCore")
        #endif
    }

    // MARK: - severe: workflows require JavaScriptCore; off-darwin fails clean

    func testWorkflowsRequireJavaScriptCoreOnNonDarwinFailsClean() async throws {
        // No live key needed: this asserts the runtime GATE, not a model turn.
        // We still install a real orchestrator so the launch path is exercised
        // end-to-end and the gate is proven to neither hang nor silently no-op.
        let home = lxTmp("wf-jsc")
        defer { try? FileManager.default.removeItem(atPath: home) }

        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, maxOut: 32, collectTimeout: .seconds(30))

        let script =
            "export const meta = { name: \"e2e-jsc\", description: \"d\" };\n" +
            "return { ok: true };"

        let resp = try await harness.orchestrator.launch(
            WorkflowBus.LaunchRequest(script: script, cwd: home))
        XCTAssertEqual(resp.status, "async_launched")

        // The gate must produce a TERMINAL status either way — never "running".
        let terminal = await lxPollWorkflowTerminal(resp.runId, timeout: .seconds(60))
        XCTAssertNotEqual(terminal, "running",
            "the runtime gate must reach a terminal status, never hang")

        let snap = lxReadSnapshot(codexHome: home, runId: resp.runId)
        XCTAssertNotNil(snap, "snapshot.json written for \(resp.runId)")

        #if os(macOS)
        // JavaScriptCore is present: the identical script completes.
        XCTAssertEqual(snap?["status"] as? String, "completed",
                       "on macOS the JSC runtime executes the script to completion")
        XCTAssertNil(snap?["error"],
                     "no JavaScriptCore error on a darwin build")
        #else
        // No JavaScriptCore: the run fails clean with an explicit JSC error.
        XCTAssertEqual(snap?["status"] as? String, "failed",
                       "off-darwin the run fails (no JavaScriptCore), not silently no-ops")
        let err = (snap?["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("JavaScriptCore"),
                      "failure names the missing JavaScriptCore runtime: \(err)")
        #endif
    }
}
