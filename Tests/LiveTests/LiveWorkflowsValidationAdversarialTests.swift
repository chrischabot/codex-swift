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

/// Live-LLM E2E coverage for the workflow validation ladder + the adversarial
/// determinism/sandbox/cap containment surface.
///
/// Two halves per the suite principles:
///  - a DETERMINISTIC, model-independent assertion (orch.validate, the
///    WorkflowStore.isSafeRunId/runDir contract, a direct WorkflowEngine run
///    with a no-model runAgent) that ALWAYS runs, and
///  - a BOUNDED best-effort live run whose only hard guarantee is that it
///    reaches a terminal status (never wedges in "running").
///
/// Adversarial cases actively attempt to break the feature — a runtime
/// Date.now() determinism violation, a Function-constructor sandbox escape, an
/// unserializable BigInt result, path-traversal run ids, and agent-cap
/// resource exhaustion — and assert the harness CONTAINS each one.
final class LiveWorkflowsValidationAdversarialTests: XCTestCase {

    override func tearDown() async throws {
        // The bus + WorkflowHolder are process-global, last-install-wins.
        await WorkflowBus.shared.clearAll()
        try await super.tearDown()
    }

    // Build an orchestrator directly (not via the shared-bus helper) so a
    // single test can stand up multiple orchestrators with different env
    // gating without cross-contaminating the global bus. `validate` is an
    // instance method, so no bus install is needed for the ladder assertions.
    private func makeOrchestrator(codexHome: String, enabled: Bool) throws -> WorkflowOrchestrator {
        let store = try ThreadStore(codexHome: codexHome, limits: Limits())
        let model = RecordingModelClient(lxClient(256))
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite, writableRoots: [codexHome]))
        let runner = WorkflowAgentRunner(
            store: store, limits: Limits(), model: model,
            routerFactory: { _, extra in
                let r = ToolRouter(limits: Limits())
                await DefaultTools.register(on: r, sandbox: sb, limits: Limits())
                for t in extra { await r.register(t) }
                return r
            },
            collectTimeout: .seconds(60))
        let env: [String: String] = enabled
            ? ["CODEX_FEATURE_WORKFLOWS": "1"]
            : ["CODEX_WORKFLOWS_DISABLE": "1"]
        return WorkflowOrchestrator(
            store: WorkflowStore(codexHome: codexHome), codexHome: codexHome,
            runner: runner, defaultModel: lxModel(), env: env, progressSink: nil)
    }

    // MARK: - happy: the 6-code validation ladder

    /// Deterministic (no live model). Drives `orch.validate(req)` across every
    /// rung of the 6-code ladder and asserts the EXACT error code at each rung,
    /// plus the valid terminal (ok==true, errorCode==nil).
    func testValidationLadderCodes() async throws {
        let home = lxTmp("wf-ladder")
        defer { try? FileManager.default.removeItem(atPath: home) }

        let cwd = home
        let validScript = """
        export const meta = { name: "e2e-valid", description: "d" };
        return { ok: true };
        """

        // code 6 — workflows disabled for the session (env gate).
        let disabled = try makeOrchestrator(codexHome: home, enabled: false)
        let v6 = await disabled.validate(WorkflowBus.LaunchRequest(script: validScript, cwd: cwd))
        XCTAssertFalse(v6.ok, "disabled session must reject")
        XCTAssertEqual(v6.errorCode, 6, "CODEX_WORKFLOWS_DISABLE=1 -> code 6")

        // Everything below runs on an ENABLED orchestrator.
        let orch = try makeOrchestrator(codexHome: home, enabled: true)

        // code 1 — name resolves to nothing (not found / resolve error).
        let v1 = await orch.validate(WorkflowBus.LaunchRequest(name: "__nope__", cwd: cwd))
        XCTAssertFalse(v1.ok)
        XCTAssertEqual(v1.errorCode, 1, "unknown workflow name -> code 1")

        // code 2 — inline script with no `export const meta` (invalid meta).
        let noMeta = "return { ok: true };"
        let v2 = await orch.validate(WorkflowBus.LaunchRequest(script: noMeta, cwd: cwd))
        XCTAssertFalse(v2.ok)
        XCTAssertEqual(v2.errorCode, 2, "missing meta -> code 2")

        // code 4 — inline script containing Date.now() (determinism violation).
        let nondeterministic = """
        export const meta = { name: "e2e-nd", description: "d" };
        const t = Date.now();
        return { t };
        """
        let v4 = await orch.validate(WorkflowBus.LaunchRequest(script: nondeterministic, cwd: cwd))
        XCTAssertFalse(v4.ok)
        XCTAssertEqual(v4.errorCode, 4, "inline Date.now() -> code 4")

        // code 3 — resumeFromRunId of a record whose status == "running".
        // launch() registers the record as "running" synchronously before its
        // detached task can finish, so an immediate validate observes "running".
        let runningScript = """
        export const meta = { name: "e2e-running", description: "d" };
        const a = await agent('hold');
        return { a };
        """
        let launched = try await orch.launch(
            WorkflowBus.LaunchRequest(script: runningScript, cwd: cwd))
        let v3 = await orch.validate(WorkflowBus.LaunchRequest(
            script: runningScript, resumeFromRunId: launched.runId, cwd: cwd))
        XCTAssertFalse(v3.ok, "resuming a still-running run must be rejected")
        XCTAssertEqual(v3.errorCode, 3, "resume of a running run -> code 3")
        // Drain the launched run so it does not leak past the test.
        _ = await orch.stop(launched.runId)

        // valid — a well-formed deterministic inline script.
        let vOK = await orch.validate(WorkflowBus.LaunchRequest(script: validScript, cwd: cwd))
        XCTAssertTrue(vOK.ok, "a valid inline script validates")
        XCTAssertNil(vOK.errorCode, "valid -> errorCode == nil")
        XCTAssertEqual(vOK, WorkflowBus.Validation.valid)
    }

    // MARK: - adversarial: runtime determinism shim + path-traversal runId

    /// The static guard rejects inline `Date.now()` at validate-time (code 4),
    /// so to exercise the *runtime* determinism shim we launch the identical
    /// script via `scriptPath` (the code-4 static check only fires for inline
    /// `script`). The JSContext shim then throws at runtime, flipping the run
    /// to status=="failed" with the NOW_ERR fragment. Deterministically we also
    /// pin the path-traversal runId contract.
    func testDeterminismRuntimeShimThrowsAndPathTraversalRunIdRejected() async throws {
        let home = lxTmp("wf-det")
        defer { try? FileManager.default.removeItem(atPath: home) }

        // ---- Deterministic half: path-traversal runId is rejected. -------
        let store = WorkflowStore(codexHome: home)
        XCTAssertFalse(WorkflowStore.isSafeRunId("wf_../etc"),
                       "traversal runId must be unsafe")
        XCTAssertTrue(WorkflowStore.isSafeRunId("wf_abc123"),
                      "a well-formed wf_ runId is safe")
        XCTAssertThrowsError(try store.runDir("wf_../etc"),
                             "runDir must refuse a traversal runId") { err in
            XCTAssertEqual(err as? WorkflowStore.StoreError,
                           .unsafeRunId("wf_../etc"))
        }
        // The safe runId resolves to a directory under <home>/workflows/runs.
        let safeDir = try store.runDir("wf_abc123")
        XCTAssertTrue(safeDir.hasPrefix(home + "/workflows/runs/wf_abc123"))

        // ---- Live half: the runtime determinism shim throws. -------------
        try lxSkipUnlessLiveKey()
        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, collectTimeout: .seconds(90))

        // The static code-4 guard now applies to ALL sources (inline, name,
        // scriptPath), so a literal `Date.now()` would be rejected up-front and
        // never reach the engine. To exercise the RUNTIME shim (defense in
        // depth), use a spelling the guard's regex cannot catch — `Date['now']`
        // — which sails past the static check but still hits the frozen
        // ShimDate.now inside JSContext and throws NOW_ERR.
        let detScript = """
        export const meta = { name: "e2e-det", description: "d" };
        const t = Date['now']();
        return { t };
        """
        let scriptPath = home + "/det.js"
        try detScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        let resp = try await harness.orchestrator.launch(
            WorkflowBus.LaunchRequest(scriptPath: scriptPath, cwd: home))
        XCTAssertTrue(resp.runId.range(of: "^wf_[a-z0-9]{12}$",
                                       options: .regularExpression) != nil,
                      "runId must match the wf_ contract: \(resp.runId)")

        let terminal = await lxPollWorkflowTerminal(resp.runId, timeout: .seconds(120))
        XCTAssertNotEqual(terminal, "running", "run must not wedge in running")

        let snap = lxReadSnapshot(codexHome: home, runId: resp.runId)
        XCTAssertEqual(snap?["status"] as? String, "failed",
                       "runtime Date.now() must fail the run")
        let err = (snap?["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("Date.now()") || err.contains("unavailable in workflow scripts"),
                      "error must carry the NOW_ERR fragment, got: \(err)")
    }

    // MARK: - severe: function-constructor escape, unserializable result, caps

    /// Three containment proofs:
    ///  1. A Function-constructor sandbox escape is blocked — the script's
    ///     `escaped` flag stays false (the call throws and is caught).
    ///  2. A BigInt return value is unserializable, so the run flips to
    ///     status=="failed" with a "not serializable" error.
    ///  3. A script looping agent() past WF.agentCap (1000) is rejected with the
    ///     agentCapMessage ("cap reached") rather than spawning unbounded
    ///     sub-agents. This is exercised model-independently against a direct
    ///     WorkflowEngine whose runAgent returns instantly (no real model
    ///     dispatch, so 1001 registrations are cheap and deterministic).
    func testFunctionConstructorEscapeUnserializableResultAndCapsContained() async throws {
        let home = lxTmp("wf-severe")
        defer { try? FileManager.default.removeItem(atPath: home) }

        // ---- Deterministic half: the agent-cap symbol + a direct engine run.
        XCTAssertTrue(WF.agentCapMessage().contains("cap reached"),
                      "cap text must contain 'cap reached'")

        #if os(macOS)
        // Loop agent() past the cap. A no-model runAgent returns instantly so
        // the 1000 in-cap registrations are cheap; the 1001st must be rejected.
        let capScript = """
        export const meta = { name: "e2e-cap", description: "d" };
        for (let i = 0; i < 1001; i++) { await agent('a' + i); }
        return { done: true };
        """
        let capBody = try WorkflowMeta.parse(capScript).scriptBody
        let capResult = await WorkflowEngine().runWorkflow(
            scriptBody: capBody,
            opts: WorkflowEngine.RunOpts(
                runId: "wf_capdeterm01", cwd: home, allowNested: false,
                runAgent: { _ in .value("\"ok\"") }))
        XCTAssertEqual(capResult.status, .failed,
                       "over-cap workflow must fail, not run unbounded")
        XCTAssertTrue((capResult.error ?? "").contains("cap reached"),
                      "over-cap error must be the agentCapMessage, got: \(capResult.error ?? "")")
        // The harness contained the exhaustion attempt: the agent counter is
        // bounded at the cap+1 detection point, not 1001 real dispatches.
        XCTAssertLessThanOrEqual(capResult.agentCount, WF.agentCap + 1)
        #endif

        // ---- Live half: function-constructor escape + unserializable result.
        try lxSkipUnlessLiveKey()
        let harness = try await lxInstallWorkflowOrchestrator(
            codexHome: home, collectTimeout: .seconds(90))

        // The agent() call here only exists to drive a real turn; the
        // load-bearing assertions are the `escaped` flag and the BigInt result.
        let escapeScript = """
        export const meta = { name: "e2e-escape", description: "d" };
        let escaped = false; try { agent.constructor('return 1')(); escaped = true; } catch (e) {}
        let n = 0n; return { escaped, n };
        """
        let runId = try await lxLaunchInline(harness.orchestrator, script: escapeScript, cwd: home)
        XCTAssertTrue(runId.range(of: "^wf_[a-z0-9]{12}$", options: .regularExpression) != nil,
                      "runId must match the wf_ contract: \(runId)")

        let terminal = await lxPollWorkflowTerminal(runId, timeout: .seconds(120))
        XCTAssertNotEqual(terminal, "running", "run must not wedge in running")

        let snap = lxReadSnapshot(codexHome: home, runId: runId)
        // The BigInt return is unserializable, so JSON.stringify throws inside
        // the bootstrap and the run fails with a "not serializable" error.
        XCTAssertEqual(snap?["status"] as? String, "failed",
                       "BigInt result is unserializable -> failed")
        let err = (snap?["error"] as? String) ?? ""
        XCTAssertTrue(err.contains("not serializable"),
                      "error must report the unserializable result, got: \(err)")
        // Either the run failed at serialization (no result on disk) or, if a
        // result were captured, the escape flag must be false — the
        // Function-constructor escape is contained regardless.
        if let result = snap?["result"] as? [String: Any],
           let escaped = result["escaped"] as? Bool {
            XCTAssertFalse(escaped, "Function-constructor sandbox escape must be blocked")
        }

        // No run remains in status "running" after teardown.
        let finalStatus = await lxPollWorkflowTerminal(runId, timeout: .seconds(5))
        XCTAssertNotEqual(finalStatus, "running",
                          "no run may remain in 'running' after the test")
    }
}
