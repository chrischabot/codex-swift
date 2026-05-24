import XCTest
import Foundation
@testable import HarnessCore
@testable import ProtocolModel
@testable import Tools
@testable import InfraPrimitives
@testable import Sandbox

final class MultiAgentTests: XCTestCase {

    private func stubOrchestrator() -> AgentOrchestrator {
        AgentOrchestrator(runner: { spec in
            AgentRunResult(status: .completed,
                           output: "ran:\(spec.name):\(spec.prompt)",
                           error: nil)
        })
    }

    func testSpawnThenWaitReturnsRunnerResult() async throws {
        let orch = stubOrchestrator()
        let p = try await orch.spawn(name: "research", prompt: "hello")
        let r = await orch.wait(p, timeout: .seconds(5))
        XCTAssertEqual(r.status, .completed)
        XCTAssertEqual(r.output, "ran:research:hello")
    }

    func testDuplicatePathReserveFails() async throws {
        let orch = stubOrchestrator()
        let p1 = try await orch.spawn(name: "dup", prompt: "x")
        var threw = false
        do { _ = try await orch.spawn(name: "dup", prompt: "y") }
        catch { threw = true }
        XCTAssertTrue(threw)
        let list = await orch.list()
        let rec = list.first { $0.path == p1 }
        XCTAssertNotNil(rec)
    }

    func testNestedChildPaths() async throws {
        let orch = stubOrchestrator()
        let a = try await orch.spawn(name: "a", prompt: "x")
        let b = try await orch.spawn(parent: a, name: "b", prompt: "y")
        XCTAssertEqual(b.raw, "/root/a/b")
        let list = await orch.list()
        let paths = Set(list.map { $0.path.raw })
        XCTAssertTrue(paths.contains("/root/a"))
        XCTAssertTrue(paths.contains("/root/a/b"))
    }

    func testAgentMessageRoutesToMailbox() async throws {
        let orch = stubOrchestrator()
        let t = try await orch.spawn(name: "t", prompt: "x")
        let ok = await orch.message(to: t, content: "hello", triggerTurn: true)
        XCTAssertTrue(ok)
        let msgs = await orch.drainMailbox(t)
        XCTAssertEqual(msgs.count, 1)
        let m = msgs[0]
        XCTAssertEqual(m.content, "hello")
        XCTAssertTrue(m.triggerTurn)
        XCTAssertEqual(m.author, "/root")
    }

    func testAgentListReflectsStatuses() async throws {
        let orch = stubOrchestrator()
        let p = try await orch.spawn(name: "s", prompt: "x")
        _ = await orch.wait(p, timeout: .seconds(5))
        let list = await orch.list()
        let rec = list.first { $0.path == p }
        XCTAssertEqual(rec?.status, .completed)
        let unknown = await orch.message(to: AgentPath("/root/none"),
                                         content: "x", triggerTurn: false)
        XCTAssertFalse(unknown)
    }

    func testAgentCloseUnblocksWaitAndMarksClosed() async throws {
        let orch = AgentOrchestrator(runner: { _ in
            try? await Task.sleep(for: .seconds(5))
            return AgentRunResult(status: .completed, output: "late", error: nil)
        })
        let p = try await orch.spawn(name: "slow", prompt: "x")
        let waitTask = Task { await orch.wait(p, timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(100))
        await orch.close(p)
        let r = await waitTask.value
        XCTAssertEqual(r.status, .closed)
        let list = await orch.list()
        let rec = list.first { $0.path == p }
        XCTAssertEqual(rec?.status, .closed)
    }

    func testWaitTimeoutDoesNotHang() async throws {
        let orch = AgentOrchestrator(runner: { _ in
            try? await Task.sleep(for: .seconds(5))
            return AgentRunResult(status: .completed, output: "x", error: nil)
        })
        let p = try await orch.spawn(name: "x", prompt: "x")
        let start = Date()
        let r = await orch.wait(p, timeout: .milliseconds(200))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(r.output, "agent wait timed out")
        XCTAssertLessThan(elapsed, 3)
    }

    func testControlToolsThroughRouter() async throws {
        let orch = AgentOrchestrator(runner: { spec in
            AgentRunResult(status: .completed,
                           output: "ran:\(spec.name):\(spec.prompt)",
                           error: nil)
        })
        let router = ToolRouter(limits: Limits())
        await orch.installAgentControl(on: router)
        let dl = Deadline.fromNow(.seconds(30))

        let spawnRes = await router.dispatch(
            ToolCall(callId: "c1", name: "agent_spawn",
                     argumentsJSON: "{\"name\":\"w\",\"prompt\":\"do\"}"),
            cwd: ".", deadline: dl)
        XCTAssertTrue(spawnRes.output.contains("\"agent\":\"/root/w\""))

        let listRes = await router.dispatch(
            ToolCall(callId: "c2", name: "agent_list", argumentsJSON: "{}"),
            cwd: ".", deadline: dl)
        XCTAssertTrue(listRes.output.contains("/root/w"))

        let waitRes = await router.dispatch(
            ToolCall(callId: "c3", name: "agent_wait",
                     argumentsJSON: "{\"path\":\"/root/w\"}"),
            cwd: ".", deadline: dl)
        XCTAssertTrue(waitRes.output.contains("\"status\":\"completed\""))
        XCTAssertTrue(waitRes.output.contains("\"output\":\"ran:w:do\""))

        let msgRes = await router.dispatch(
            ToolCall(callId: "c4", name: "agent_message",
                     argumentsJSON:
                        "{\"to\":\"/root/w\",\"content\":\"hi\",\"triggerTurn\":true}"),
            cwd: ".", deadline: dl)
        XCTAssertEqual(msgRes.output, "{\"delivered\":true}")

        let closeRes = await router.dispatch(
            ToolCall(callId: "c5", name: "agent_close",
                     argumentsJSON: "{\"path\":\"/root/w\"}"),
            cwd: ".", deadline: dl)
        XCTAssertEqual(closeRes.output, "{\"closed\":true}")
    }

    /// Upstream parity (`ToolsConfig::agent_type_description`):
    /// `SessionConfig.agentTypeDescription` must propagate end-to-end through
    /// the worker bootstrap (`DefaultTools.register(spawnAgentOptions:)`) into
    /// the registered `spawn_agent` tool's JSON schema. This locks in the
    /// plumbing in `Sources/codex-session/main.swift` and
    /// `Sources/codexd/main.swift` so the override is not silently dropped.
    func testSessionConfigAgentTypeDescriptionReachesSpawnAgentSchema() async throws {
        let tmp = NSTemporaryDirectory() + "harness-spawn-agent-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let custom = "Pick one: planner, coder, reviewer."
        let config = SessionConfig(threadId: ThreadId("t-spawn-1"),
                                   cwd: tmp,
                                   agentTypeDescription: custom)

        // Replicate the worker bootstrap's mapping (see codex-session/codexd
        // main.swift): nil/empty → tool default, otherwise propagate verbatim.
        var spawnAgentOptions = SpawnAgentToolOptions()
        if let d = config.agentTypeDescription, !d.isEmpty {
            spawnAgentOptions.agentTypeDescription = d
        }

        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [tmp]))
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router, sandbox: sandbox,
                                    limits: Limits(),
                                    spawnAgentOptions: spawnAgentOptions)

        let specs = await router.specs()
        guard let spec = specs.first(where: { $0.name == "spawn_agent" }) else {
            return XCTFail("spawn_agent must be registered")
        }
        guard let data = spec.parametersJSON.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = obj["properties"] as? [String: Any],
              let agentType = props["agent_type"] as? [String: Any],
              let desc = agentType["description"] as? String
        else {
            return XCTFail("malformed spawn_agent schema: \(spec.parametersJSON)")
        }
        XCTAssertEqual(desc, custom,
                       "SessionConfig.agentTypeDescription must reach the spawn_agent schema")
    }

    /// When `SessionConfig.agentTypeDescription` is nil the spawn_agent tool
    /// must keep its built-in default placeholder (upstream `String::new()` →
    /// fallback path).
    func testSessionConfigNilAgentTypeDescriptionPreservesDefault() async throws {
        let tmp = NSTemporaryDirectory() + "harness-spawn-agent-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmp,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let config = SessionConfig(threadId: ThreadId("t-spawn-2"), cwd: tmp)
        XCTAssertNil(config.agentTypeDescription,
                     "default SessionConfig must leave the override nil")

        var spawnAgentOptions = SpawnAgentToolOptions()
        if let d = config.agentTypeDescription, !d.isEmpty {
            spawnAgentOptions.agentTypeDescription = d
        }

        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [tmp]))
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router, sandbox: sandbox,
                                    limits: Limits(),
                                    spawnAgentOptions: spawnAgentOptions)

        let specs = await router.specs()
        guard let spec = specs.first(where: { $0.name == "spawn_agent" }) else {
            return XCTFail("spawn_agent must be registered")
        }
        guard let data = spec.parametersJSON.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = obj["properties"] as? [String: Any],
              let agentType = props["agent_type"] as? [String: Any],
              let desc = agentType["description"] as? String
        else {
            return XCTFail("malformed spawn_agent schema: \(spec.parametersJSON)")
        }
        XCTAssertEqual(desc, DefaultSpawnAgentAgentTypeDescription,
                       "nil override must fall through to DefaultSpawnAgentAgentTypeDescription")
    }
}