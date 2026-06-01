import XCTest
import Foundation
import ModelClient
import Persistence
import Tools
import InfraPrimitives
@testable import Workflows

/// Adversarial verification for Task #4: per-phase model application,
/// determinism guard on ALL sources (not just inline), and the run deadline.
// Drives `WorkflowEngine.runWorkflow` (JSC-only). Guard out on non-JSC
// platforms (Linux CI), where the engine returns `.failed`.
#if canImport(JavaScriptCore)
final class WorkflowSmallerDivergencesTests: XCTestCase {

    /// Captures the effective `defaultModel` each agent spec was launched with,
    /// keyed by prompt.
    private final class ModelCapture: @unchecked Sendable {
        private let lock = NSLock(); private var map: [String: String?] = [:]
        func record(_ prompt: String, _ model: String?) { lock.lock(); map[prompt] = model; lock.unlock() }
        func model(_ prompt: String) -> String?? { lock.lock(); defer { lock.unlock() }; return map[prompt] }
    }

    // MARK: - Task #4c: meta.phases[].model becomes a per-phase default

    func testPerPhaseModelAppliedAsDefault() async {
        let cap = ModelCapture()
        let runAgent: @Sendable (WorkflowAgentSpec) async -> WorkflowAgentOutcome = { spec in
            cap.record(spec.prompt, spec.defaultModel)
            return .value("\"ok\"")
        }
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(
            runId: "wf_phasemodel0", cwd: ".", defaultModel: "small",
            seedPhaseModels: ["Heavy": "big-model"], runAgent: runAgent)
        // 'h' runs under phase Heavy (model override); 'l' under Light (none).
        let r = await engine.runWorkflow(scriptBody: """
        phase('Heavy'); await agent('h');
        phase('Light'); await agent('l');
        return 'done';
        """, opts: opts)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertEqual(cap.model("h"), .some("big-model"), "phase model must override the run default")
        XCTAssertEqual(cap.model("l"), .some("small"), "no phase model → falls back to run default")
    }

    func testAgentLevelModelStillWinsOverPhaseModel() async {
        // The runner resolves opts.model ?? defaultModel; the engine only sets
        // the per-phase default, so an explicit agent model must survive.
        let cap = ModelCapture()
        let runAgent: @Sendable (WorkflowAgentSpec) async -> WorkflowAgentOutcome = { spec in
            // Effective model the runner would use: opts.model ?? defaultModel.
            cap.record(spec.prompt, spec.opts.model ?? spec.defaultModel)
            return .value("\"ok\"")
        }
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(
            runId: "wf_phasemodel1", cwd: ".", defaultModel: "small",
            seedPhaseModels: ["Heavy": "big-model"], runAgent: runAgent)
        let r = await engine.runWorkflow(scriptBody: """
        phase('Heavy'); await agent('x', { model: 'explicit' });
        return 'done';
        """, opts: opts)
        XCTAssertEqual(r.status, .completed, r.error ?? "")
        XCTAssertEqual(cap.model("x"), .some("explicit"))
    }

    // MARK: - Task #4a: determinism guard applies to named/disk workflows

    func testDeterminismGuardRejectsNamedWorkflow() async throws {
        let tmp = NSTemporaryDirectory() + "wfdet-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp + "/workflows", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try """
        export const meta = { name: "rng-wf", description: "uses rng" };
        return Math.random();
        """.write(toFile: tmp + "/workflows/rng-wf.js", atomically: true, encoding: .utf8)

        let store = try ThreadStore(codexHome: tmp, limits: Limits())
        let model = MockModelClient(repeating: .hello("x"), times: 8)
        let runner = WorkflowAgentRunner(store: store, limits: Limits(), model: model,
            routerFactory: { _, extra in let r = ToolRouter(limits: Limits()); for t in extra { await r.register(t) }; return r })
        let orch = WorkflowOrchestrator(store: WorkflowStore(codexHome: tmp), codexHome: tmp,
                                        runner: runner, env: ["CODEX_FEATURE_WORKFLOWS": "1"])

        // Resolved by NAME (not inline script) — previously skipped the static guard.
        let v = await orch.validate(.init(name: "rng-wf", cwd: tmp))
        XCTAssertFalse(v.ok)
        XCTAssertEqual(v.errorCode, 4, "named workflow with Math.random() must fail code 4")
    }

    /// Defense in depth: the static guard's regex intentionally cannot catch
    /// every spelling (e.g. `Date['now']`), but the RUNTIME shim must still
    /// throw. Locks the contract the live determinism test relies on and guards
    /// against making the static regex over-aggressive.
    func testRegexBypassingDeterminismViolationCaughtAtRuntime() async {
        XCTAssertFalse(WorkflowDeterminismGuard.violates("const t = Date['now']();"),
                       "the static regex does not (and need not) catch bracket-access spellings")
        let engine = WorkflowEngine()
        let opts = WorkflowEngine.RunOpts(runId: "wf_runtimeshim", cwd: ".",
                                          runAgent: { _ in .value("\"x\"") })
        let r = await engine.runWorkflow(scriptBody: "return Date['now']();", opts: opts)
        XCTAssertEqual(r.status, .failed, "the runtime shim must throw on the bypassing spelling")
        let e = r.error ?? ""
        XCTAssertTrue(e.contains("unavailable in workflow scripts") || e.contains("Date.now()"),
                      "must carry the NOW_ERR fragment, got: \(e)")
    }

    // MARK: - Task #4b: outer run deadline trips the abort latch

    func testRunDeadlineKillsLongRun() async throws {
        let tmp = NSTemporaryDirectory() + "wfdl-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = try ThreadStore(codexHome: tmp, limits: Limits())
        // The single agent turn takes ~2s; the deadline is 1s.
        let model = MockModelClient([
            MockScenario([.created, .slowMillis(2000),
                          .agentDone(itemId: "m", "slow"),
                          .completeEndTurn(responseId: "r", tokens: 1)]),
        ])
        let runner = WorkflowAgentRunner(store: store, limits: Limits(), model: model,
            routerFactory: { _, extra in let r = ToolRouter(limits: Limits()); for t in extra { await r.register(t) }; return r },
            collectTimeout: .seconds(10))
        let orch = WorkflowOrchestrator(store: WorkflowStore(codexHome: tmp), codexHome: tmp,
                                        runner: runner,
                                        env: ["CODEX_FEATURE_WORKFLOWS": "1",
                                              "CODEX_WORKFLOW_DEADLINE_SECS": "1"])
        await orch.installOnBus()
        defer { Task { await WorkflowBus.shared.clearAll() } }

        let tool = WorkflowTool()
        let body = #"export const meta = { name: "slow", description: "d" }; await agent('go'); return 'done';"#
        let args = String(data: try JSONSerialization.data(withJSONObject: ["script": body]), encoding: .utf8)!
        let res = try await tool.run(ToolCall(callId: "c", name: "workflow", argumentsJSON: args), cwd: tmp)
        let runId = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(res.output.utf8)) as? [String: Any])?["runId"] as? String)

        var status = "running"
        for _ in 0..<120 {
            let s = await WorkflowBus.shared.status(runId)
            status = ((try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])?["status"] as? String) ?? "running"
            if status == "completed" || status == "failed" || status == "killed" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(status, "killed", "the 1s deadline must abort the ~2s run")
    }

    /// The deadline/stop abort must wake a pump that is PARKED on an in-flight
    /// agent — it must not wait for that agent to finish. Drives the engine
    /// directly with a 5s mock agent and an abort fired at 300ms; the run must
    /// report `.killed` well before the agent's 5s completion.
    func testAbortWakesParkedPumpPromptly() async {
        let abort = AbortFlag()
        let engine = WorkflowEngine()
        let slowAgent: @Sendable (WorkflowAgentSpec) async -> WorkflowAgentOutcome = { _ in
            try? await Task.sleep(for: .seconds(5))   // long in-flight agent
            return .value("\"late\"")
        }
        // Fire the abort shortly after the agent is in flight.
        let fired = Task { try? await Task.sleep(for: .milliseconds(300)); abort.set() }
        defer { fired.cancel() }

        let start = Date()
        let opts = WorkflowEngine.RunOpts(runId: "wf_promptabort", cwd: ".",
                                          abort: abort, runAgent: slowAgent)
        let r = await engine.runWorkflow(scriptBody: "await agent('x'); return 'done';", opts: opts)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(r.status, .killed)
        XCTAssertLessThan(elapsed, 2.0,
                          "abort must wake the parked pump promptly (~0.4s), not wait for the 5s agent; took \(elapsed)s")
    }
}
#endif  // canImport(JavaScriptCore)
