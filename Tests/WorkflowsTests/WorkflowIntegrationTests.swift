import XCTest
import Foundation
import ModelClient
import Persistence
import Tools
import InfraPrimitives
@testable import Workflows

/// End-to-end: the `workflow` tool → WorkflowBus → WorkflowOrchestrator →
/// WorkflowEngine → WorkflowAgentRunner → SessionEngine → MockModelClient.
// Runs the live WorkflowEngine (JSC-only). Guard out on non-JSC platforms
// (Linux CI), where the engine returns `.failed`.
#if canImport(JavaScriptCore)
final class WorkflowIntegrationTests: XCTestCase {

    func testInlineWorkflowEndToEnd() async throws {
        let tmp = NSTemporaryDirectory() + "wfe2e-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = try ThreadStore(codexHome: tmp, limits: Limits())
        let model = MockModelClient(repeating: .hello("MOCK-AGENT-REPLY"), times: 256)
        let runner = WorkflowAgentRunner(
            store: store, limits: Limits(), model: model,
            routerFactory: { _, extra in
                let r = ToolRouter(limits: Limits())
                for t in extra { await r.register(t) }
                return r
            },
            collectTimeout: .seconds(10))
        let orch = WorkflowOrchestrator(
            store: WorkflowStore(codexHome: tmp), codexHome: tmp, runner: runner,
            env: ["CODEX_FEATURE_WORKFLOWS": "1"])
        await orch.installOnBus()
        defer { Task { await WorkflowBus.shared.clearAll() } }

        // Launch via the model-facing tool.
        let tool = WorkflowTool()
        let scriptBody = """
        export const meta = { name: "e2e", description: "d" };
        const a = await agent('say hi');
        return { reply: a };
        """
        let args = String(data: try JSONSerialization.data(withJSONObject: ["script": scriptBody]),
                          encoding: .utf8)!
        let result = try await tool.run(ToolCall(callId: "c1", name: "workflow", argumentsJSON: args), cwd: tmp)
        XCTAssertTrue(result.success, result.output)
        let launched = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        XCTAssertEqual(launched?["status"] as? String, "async_launched")
        let runId = try XCTUnwrap(launched?["runId"] as? String)

        // Poll status until terminal.
        var status = "running"
        var resultObj: [String: Any]?
        for _ in 0..<100 {
            let s = await WorkflowBus.shared.status(runId)
            resultObj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
            status = (resultObj?["status"] as? String) ?? "running"
            if status == "completed" || status == "failed" || status == "killed" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(status, "completed", "status JSON: \(resultObj ?? [:])")

        // The workflow's return value (a JSON string in the status payload)
        // carries the mock agent reply.
        let rStr = try XCTUnwrap(resultObj?["result"] as? String, "no result: \(resultObj ?? [:])")
        let rJSON = try JSONSerialization.jsonObject(with: Data(rStr.utf8)) as? [String: Any]
        XCTAssertEqual(rJSON?["reply"] as? String, "MOCK-AGENT-REPLY")

        // A snapshot was persisted on disk.
        let snaps = WorkflowStore(codexHome: tmp).readSnapshots()
        XCTAssertTrue(snaps.contains { ($0["runId"] as? String) == runId })
    }

    /// Live end-to-end through SessionEngine: a subagent first submits
    /// schema-INVALID `final_answer` args (rejected at the tool boundary),
    /// then valid args. The runner must return the validated object and never
    /// leak the invalid submission. Verifies the in-turn reject→re-call→capture
    /// loop, not just the unit boundary.
    func testSchemaRejectThenRecallThroughLiveEngine() async throws {
        let tmp = NSTemporaryDirectory() + "wfschema-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = try ThreadStore(codexHome: tmp, limits: Limits())
        // Turn 1: bad final_answer (ok must be boolean) → tool rejects, turn continues.
        // Turn 2: good final_answer → captured. Turn 3: end the turn.
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "t1", name: "final_answer", argumentsJSON: #"{"ok":"yes"}"#),
                          .completeContinue(responseId: "r1", tokens: 5)]),
            MockScenario([.created,
                          .toolCall(callId: "t2", name: "final_answer", argumentsJSON: #"{"ok":true}"#),
                          .completeContinue(responseId: "r2", tokens: 5)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "r3", tokens: 5)]),
        ])
        let runner = WorkflowAgentRunner(
            store: store, limits: Limits(), model: model,
            routerFactory: { _, extra in
                let r = ToolRouter(limits: Limits())
                for t in extra { await r.register(t) }
                return r
            },
            collectTimeout: .seconds(10))

        let spec = WorkflowAgentSpec(
            index: 1, prompt: "produce the answer",
            opts: AgentOpts(schemaJSON: #"{"type":"object","required":["ok"],"properties":{"ok":{"type":"boolean"}}}"#),
            label: "l", phaseTitle: "", phaseIndex: -1, stallMs: 180_000,
            cacheKey: nil, defaultModel: nil, cwd: tmp, runId: "wf_schematest")

        let outcome = await runner.runAgent(spec)
        XCTAssertEqual(outcome.kind, .value, "expected a captured value")
        XCTAssertEqual(outcome.payloadJSON, #"{"ok":true}"#,
                       "must return the VALID submission, never the rejected one")
    }

    /// Full orchestrator path for a nested `workflow()`: the child runs, its
    /// result is embedded in the parent's, and its logs surface prefixed with
    /// `[child-name]` (Task #3 progress/log grouping).
    func testNestedWorkflowEndToEndWithLogPrefix() async throws {
        let tmp = NSTemporaryDirectory() + "wfnest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp + "/workflows", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // A discoverable child workflow (codexHome/workflows → .admin source).
        try """
        export const meta = { name: "child-wf", description: "child" };
        log('child running');
        const a = await agent('child-agent');
        return { fromChild: a };
        """.write(toFile: tmp + "/workflows/child-wf.js", atomically: true, encoding: .utf8)

        let store = try ThreadStore(codexHome: tmp, limits: Limits())
        let model = MockModelClient(repeating: .hello("MOCK-AGENT-REPLY"), times: 256)
        let runner = WorkflowAgentRunner(
            store: store, limits: Limits(), model: model,
            routerFactory: { _, extra in
                let r = ToolRouter(limits: Limits())
                for t in extra { await r.register(t) }
                return r
            },
            collectTimeout: .seconds(10))
        let orch = WorkflowOrchestrator(
            store: WorkflowStore(codexHome: tmp), codexHome: tmp, runner: runner,
            env: ["CODEX_FEATURE_WORKFLOWS": "1"])
        await orch.installOnBus()
        defer { Task { await WorkflowBus.shared.clearAll() } }

        let tool = WorkflowTool()
        // Parent runs its OWN agent plus the child's: with a shared scope the
        // run's agentCount is 2; a regression giving the child a fresh scope
        // would report 1.
        let scriptBody = """
        export const meta = { name: "parent-wf", description: "parent" };
        log('parent running');
        const p = await agent('parent-agent');
        const c = await workflow('child-wf');
        return { parent: p, child: c };
        """
        let args = String(data: try JSONSerialization.data(withJSONObject: ["script": scriptBody, "budget": 1_000_000]),
                          encoding: .utf8)!
        let result = try await tool.run(ToolCall(callId: "c1", name: "workflow", argumentsJSON: args), cwd: tmp)
        XCTAssertTrue(result.success, result.output)
        let launched = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        let runId = try XCTUnwrap(launched?["runId"] as? String)

        var status = "running"
        var resultObj: [String: Any]?
        for _ in 0..<200 {
            let s = await WorkflowBus.shared.status(runId)
            resultObj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
            status = (resultObj?["status"] as? String) ?? "running"
            if status == "completed" || status == "failed" || status == "killed" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(status, "completed", "status: \(resultObj ?? [:])")

        // The child's return value is embedded in the parent's result.
        let rStr = try XCTUnwrap(resultObj?["result"] as? String)
        let rJSON = try JSONSerialization.jsonObject(with: Data(rStr.utf8)) as? [String: Any]
        let child = rJSON?["child"] as? [String: Any]
        XCTAssertEqual(child?["fromChild"] as? String, "MOCK-AGENT-REPLY")

        // The child's log surfaced under the [child-wf] group.
        let logTail = (resultObj?["logTail"] as? [String]) ?? []
        XCTAssertTrue(logTail.contains("[child-wf] child running"),
                      "expected prefixed child log, got: \(logTail)")

        // The on-disk snapshot's agentCount proves the shared scope counter:
        // parent agent (1) + child agent (1) = 2 via the real orchestrator path.
        let snap = WorkflowStore(codexHome: tmp).readSnapshots().first { ($0["runId"] as? String) == runId }
        XCTAssertEqual(snap?["agentCount"] as? Int, 2,
                       "shared agent counter must include the child's agent (got \(snap?["agentCount"] ?? "nil"))")
    }
}
#endif  // canImport(JavaScriptCore)
