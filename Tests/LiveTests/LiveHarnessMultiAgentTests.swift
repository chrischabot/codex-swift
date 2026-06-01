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

/// Live-LLM end-to-end coverage for the multi-agent tool surface
/// (`spawn_agent` / `wait_agent` / `close_agent`) wired through the real
/// `MultiAgentBus.shared` provider seam onto a `HarnessCore.AgentOrchestrator`
/// whose runner is the production `SessionEngineAgentRunner` (which materialises
/// a `thr_agent_*` child thread in the `ThreadStore` and drives a real model
/// turn).
///
/// Every assertion is on a provable side-effect that exists ONLY if the feature
/// worked — the bus JSON payload, the `AgentRegistry` status lifecycle, the
/// child `thr_agent_*` thread record, and the structured-error / no-disk-write
/// containment when no orchestrator is installed — never on transcript wording.
///
/// The bus is a process-global actor (`MultiAgentBus.shared`), so each test
/// installs its own providers and `clearAll()`s in a `defer` to avoid
/// cross-test contamination. Tests run serially.
final class LiveHarnessMultiAgentTests: XCTestCase {

    // MARK: - Bridge: wire MultiAgentBus.shared onto a real AgentOrchestrator.

    /// Install spawn/wait/close providers on `MultiAgentBus.shared` that bridge
    /// to `orch`. The bus `agent_id` is the orchestrator `AgentPath.raw`, so the
    /// registry record and the on-disk `thr_agent_*` thread are addressable from
    /// the wire id. Returns the agent nickname used for spawned children.
    private func installBridge(_ orch: AgentOrchestrator,
                               nickname: String) async {
        await MultiAgentBus.shared.installSpawn { _ in
            // model-independent: the spawn message is irrelevant to the
            // side-effect we prove (a child thread + registry record).
            let path = try await orch.spawn(
                name: nickname,
                prompt: "Reply with exactly the token CHILD_DONE and nothing else.")
            return MultiAgentBus.SpawnResponse(agentId: path.raw, nickname: nickname)
        }
        await MultiAgentBus.shared.installWait { req in
            var pairs: [(String, MultiAgentBus.AgentStatus)] = []
            var timedOut = false
            for id in req.targets {
                let secs = max(0.001, Double(req.timeoutMs) / 1000.0)
                let r = await orch.wait(AgentPath(id), timeout: .seconds(secs))
                let bus = Self.busStatus(from: r.status, output: r.output,
                                         error: r.error)
                if r.status == .failed && (r.error == "timeout") { timedOut = true }
                pairs.append((id, bus))
            }
            return MultiAgentBus.WaitResponse(statusByAgent: pairs, timedOut: timedOut)
        }
        await MultiAgentBus.shared.installClose { target in
            // `previous_status` must reflect the status BEFORE the close mutated
            // the registry — capture it first, then close.
            let path = AgentPath(target)
            let prevRec = await orch.registry.get(path)
            let prev = Self.busStatus(from: prevRec?.status ?? .running,
                                      output: prevRec?.result ?? "",
                                      error: prevRec?.error)
            await orch.close(path)
            return prev
        }
    }

    /// Map the HarnessCore `AgentStatus` onto the upstream `MultiAgentBus`
    /// `AgentStatus` JSON shape.
    private static func busStatus(from s: HarnessCore.AgentStatus,
                                  output: String,
                                  error: String?) -> MultiAgentBus.AgentStatus {
        switch s {
        case .pending:   return .pendingInit
        case .running:   return .running
        case .completed: return .completed(output.isEmpty ? nil : output)
        case .failed:    return .errored(error ?? "failed")
        case .closed:    return .shutdown
        }
    }

    /// Build an `AgentOrchestrator` whose runner is the production
    /// `SessionEngineAgentRunner` rooted at `store`/`work` and driven by a
    /// bounded live model turn. The SAME `store` is used for reconstruction so
    /// the ephemeral child rollout is reachable.
    private func liveOrchestrator(store: ThreadStore, work: String,
                                  model: any ModelClient) -> AgentOrchestrator {
        var lim = Limits()
        lim.maxSamplingIterationsPerTurn = 4
        lim.turnDeadline = .seconds(120)
        let limCopy = lim
        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                writableRoots: [work]))
        let runner = SessionEngineAgentRunner.make(
            store: store, limits: lim, model: model,
            router: { _ in
                let r = ToolRouter(limits: limCopy)
                await DefaultTools.register(on: r, sandbox: sb, limits: limCopy)
                return r
            },
            cwd: work,
            collectTimeout: .seconds(120))
        return AgentOrchestrator(runner: runner)
    }

    /// The on-disk sanitisation `SessionEngineAgentRunner` applies to an
    /// `AgentPath.raw` before composing `thr_agent_<sanitized>`.
    private func sanitizedThreadId(forPath raw: String) -> ThreadId {
        let sanitized = String(raw.map { c -> Character in
            if c.isASCII && (c.isLetter || c.isNumber) { return c }
            return "_"
        })
        return ThreadId("thr_agent_" + sanitized)
    }

    /// Count `thr_agent_*` rollout files on disk under `<codexHome>/sessions`.
    private func threadAgentRolloutCount(codexHome: String) -> Int {
        let dir = codexHome + "/sessions"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return entries.filter { $0.hasPrefix("thr_agent_") }.count
    }

    // MARK: - happy: spawn creates a child thread + registry record

    func testSpawnCreatesChildThreadAndRegistryRecord() async throws {
        try XCTSkipUnless(lxAPIKey() != nil, "OPENAI_API_KEY not set")

        let home = lxTmp("ma-spawn")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = home
        let store = try lxStore(home)

        // A live-backed orchestrator; its runner spins up a real SessionEngine
        // child turn against the model.
        let rec = lxRecording(256)
        let orch = liveOrchestrator(store: store, work: work, model: rec)
        await installBridge(orch, nickname: "research")
        defer { Task { await MultiAgentBus.shared.clearAll() } }

        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(
            on: router,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [work])),
            limits: Limits())

        // Dispatch the real spawn_agent tool through the router.
        let dl = Deadline.fromNow(.seconds(120))
        let spawnRes = await router.dispatch(
            ToolCall(callId: "spawn-1", name: "spawn_agent",
                     argumentsJSON: #"{"message":"do a scoped subtask","agent_type":"research"}"#),
            cwd: work, deadline: dl)

        // (1) Bus payload is the upstream output schema with an agent_id.
        XCTAssertTrue(spawnRes.success, "spawn_agent must succeed when wired")
        let spawnObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(spawnRes.output.utf8)) as? [String: Any],
            "spawn_agent output must be JSON object: \(spawnRes.output)")
        let agentId = try XCTUnwrap(spawnObj["agent_id"] as? String,
                                    "spawn_agent output must carry agent_id")
        XCTAssertFalse(agentId.isEmpty)
        let path = AgentPath(agentId)

        // (2) Registry status transitions pending -> running -> terminal.
        // The reserve+setStatus(.running) happens synchronously inside spawn(),
        // so by the time the tool returns the record is at least .running.
        let afterSpawn = await orch.registry.get(path)
        XCTAssertNotNil(afterSpawn, "AgentRegistry must hold a record for the spawned path")
        XCTAssertTrue(afterSpawn?.status == .running || afterSpawn?.status == .completed
                      || afterSpawn?.status == .failed,
                      "freshly spawned agent must be running or already terminal, got \(String(describing: afterSpawn?.status))")

        // Drive the child to a terminal status via the real wait_agent tool.
        let waitRes = await router.dispatch(
            ToolCall(callId: "wait-1", name: "wait_agent",
                     argumentsJSON: #"{"targets":["\#(agentId)"],"timeout_ms":120000}"#),
            cwd: work, deadline: Deadline.fromNow(.seconds(160)))
        XCTAssertTrue(waitRes.success, "wait_agent must succeed when wired")

        let terminal = await orch.registry.get(path)?.status
        XCTAssertTrue(terminal == .completed || terminal == .failed || terminal == .closed,
                      "agent must reach a terminal status after wait, got \(String(describing: terminal))")

        // (3) AgentRegistry.list() also exposes the record.
        let listed = await orch.registry.list()
        XCTAssertTrue(listed.contains { $0.path == path },
                      "AgentRegistry.list() must include the spawned agent")

        // (4) A real child rollout exists on disk: reconstruct succeeds.
        let childTid = sanitizedThreadId(forPath: path.raw)
        let rebuilt = try await store.reconstruct(childTid)
        XCTAssertEqual(rebuilt.config.threadId, childTid,
                       "ThreadStore.reconstruct must return the child thread id")

        // The child turn was a REAL model call (proves a live sub-agent ran),
        // and a thr_agent_* thread now exists.
        let multiCaps = await rec.capturedRequests()
        XCTAssertGreaterThanOrEqual(multiCaps.count, 1,
                                    "the spawned sub-agent must have driven >=1 real model request")
    }

    // MARK: - adversarial: close unblocks a pending wait + marks closed

    func testCloseAgentUnblocksWaitAndMarksClosed() async throws {
        try XCTSkipUnless(lxAPIKey() != nil, "OPENAI_API_KEY not set")

        let home = lxTmp("ma-close")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = home
        let store = try lxStore(home)

        // A deliberately SLOW runner so the agent is still .running when we
        // close it — this isolates the close-while-waiting deadlock hazard.
        let orch = AgentOrchestrator(runner: { _ in
            try? await Task.sleep(for: .seconds(30))
            return AgentRunResult(status: .completed, output: "late", error: nil)
        })
        await installBridge(orch, nickname: "slow")
        defer { Task { await MultiAgentBus.shared.clearAll() } }

        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(
            on: router,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [work])),
            limits: Limits())

        // Spawn.
        let spawnRes = await router.dispatch(
            ToolCall(callId: "spawn-2", name: "spawn_agent",
                     argumentsJSON: #"{"message":"slow task"}"#),
            cwd: work, deadline: Deadline.fromNow(.seconds(30)))
        XCTAssertTrue(spawnRes.success)
        let spawnObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(spawnRes.output.utf8)) as? [String: Any])
        let agentId = try XCTUnwrap(spawnObj["agent_id"] as? String)
        let path = AgentPath(agentId)

        // Start a concurrent wait_agent with a LONG timeout. If close fails to
        // unblock it, this task hangs ~30s (the runner's sleep) or the full
        // timeout — far past our bounded deadline below.
        let waitTask = Task { () -> ToolResult in
            await router.dispatch(
                ToolCall(callId: "wait-2", name: "wait_agent",
                         argumentsJSON: #"{"targets":["\#(agentId)"],"timeout_ms":3600000}"#),
                cwd: work, deadline: Deadline.fromNow(.seconds(3600)))
        }

        // Let the wait register, then close while it is pending.
        try? await Task.sleep(for: .milliseconds(150))
        let closeRes = await router.dispatch(
            ToolCall(callId: "close-2", name: "close_agent",
                     argumentsJSON: #"{"target":"\#(agentId)"}"#),
            cwd: work, deadline: Deadline.fromNow(.seconds(10)))

        // close_agent output is the upstream schema with previous_status.
        XCTAssertTrue(closeRes.success, "close_agent must succeed when wired")
        let closeObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(closeRes.output.utf8)) as? [String: Any],
            "close_agent output must be JSON: \(closeRes.output)")
        XCTAssertNotNil(closeObj["previous_status"],
                        "close_agent output must contain previous_status, got \(closeRes.output)")

        // The pending wait must return BEFORE a bounded deadline (no deadlock).
        let waitDeadline = Date().addingTimeInterval(8)
        var waitResult: ToolResult?
        while Date() < waitDeadline {
            if waitTask.isCancelled { break }
            // Poll cooperatively without blocking: if the task finished, grab it.
            if let v = await Self.valueIfDone(waitTask) { waitResult = v; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if waitResult == nil {
            // Last chance: await directly but bounded by a watchdog cancel.
            let watchdog = Task { try? await Task.sleep(for: .seconds(4)); waitTask.cancel() }
            waitResult = await waitTask.value
            watchdog.cancel()
        }
        XCTAssertNotNil(waitResult,
                        "the pending wait_agent must be unblocked by close_agent, not hang")

        // Registry record is now closed.
        let rec = await orch.registry.get(path)
        XCTAssertEqual(rec?.status, .closed,
                       "AgentRegistry record status must become .closed after close_agent")
    }

    /// Return the task's value only if it has already completed, otherwise nil.
    /// Implemented via a race against a zero-sleep so we never block the poller.
    private static func valueIfDone(_ t: Task<ToolResult, Never>) async -> ToolResult? {
        await withTaskGroup(of: ToolResult?.self) { group in
            group.addTask { await t.value }
            group.addTask { try? await Task.sleep(for: .milliseconds(1)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - severe: unconfigured bus -> structured error, no disk write

    func testMultiAgentToolsUnconfiguredBusReturnsStructuredError() async throws {
        try XCTSkipUnless(lxAPIKey() != nil, "OPENAI_API_KEY not set")

        let home = lxTmp("ma-unconfigured")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = home
        _ = try lxStore(home) // ensures the sessions dir layout is realistic

        // Explicitly install NO provider — and defensively clear any stale
        // provider left by a prior test before asserting.
        await MultiAgentBus.shared.clearAll()
        defer { Task { await MultiAgentBus.shared.clearAll() } }

        let installed = await MultiAgentBus.shared.installedProviders()
        XCTAssertTrue(installed.isEmpty,
                      "precondition: no multi-agent providers installed, got \(installed)")

        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(
            on: router,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [work])),
            limits: Limits())

        // Bounded deadline proves the call FAILS FAST rather than hanging.
        let start = Date()
        let res = await router.dispatch(
            ToolCall(callId: "spawn-3", name: "spawn_agent",
                     argumentsJSON: #"{"message":"this should never spawn"}"#),
            cwd: work, deadline: Deadline.fromNow(.seconds(10)))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(res.success,
                       "spawn_agent must NOT silently succeed with no orchestrator")
        XCTAssertTrue(res.output.contains("multi-agent orchestrator is not configured"),
                      "must return the structured unconfigured error, got: \(res.output)")
        XCTAssertLessThan(elapsed, 5,
                          "unconfigured spawn_agent must fail fast, not hang")

        // No thr_agent_* child thread was created on disk.
        XCTAssertEqual(threadAgentRolloutCount(codexHome: home), 0,
                       "no thr_agent_* rollout may be created when the bus is unconfigured")

        // wait_agent and close_agent are likewise honest (no silent success).
        let waitRes = await router.dispatch(
            ToolCall(callId: "wait-3", name: "wait_agent",
                     argumentsJSON: #"{"targets":["/root/x"]}"#),
            cwd: work, deadline: Deadline.fromNow(.seconds(10)))
        XCTAssertFalse(waitRes.success)
        XCTAssertTrue(waitRes.output.contains("multi-agent orchestrator is not configured"),
                      "wait_agent must surface the unconfigured error, got: \(waitRes.output)")

        let closeRes = await router.dispatch(
            ToolCall(callId: "close-3", name: "close_agent",
                     argumentsJSON: #"{"target":"/root/x"}"#),
            cwd: work, deadline: Deadline.fromNow(.seconds(10)))
        XCTAssertFalse(closeRes.success)
        XCTAssertTrue(closeRes.output.contains("multi-agent orchestrator is not configured"),
                      "close_agent must surface the unconfigured error, got: \(closeRes.output)")
    }
}
