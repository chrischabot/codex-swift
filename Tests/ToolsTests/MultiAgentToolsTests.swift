import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import InfraPrimitives

/// Parity tests for the multi-agent tool surface (upstream H-19 / P3.5):
/// `spawn_agent`, `wait_agent`, `close_agent`, `send_input`, `resume_agent`.
final class MultiAgentToolsTests: XCTestCase {

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "multi-agent-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Clear any provider state left by a prior test to keep tests hermetic.
    override func setUp() async throws {
        await MultiAgentBus.shared.clearAll()
    }

    override func tearDown() async throws {
        await MultiAgentBus.shared.clearAll()
    }

    // MARK: - Registration

    func testMultiAgentToolsRegistered() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [root]))
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router, sandbox: sandbox)
        let names = await router.specs().map { $0.name }
        for tool in ["spawn_agent", "wait_agent", "close_agent",
                     "send_input", "resume_agent"] {
            XCTAssertTrue(names.contains(tool),
                          "DefaultTools must register \(tool) (P3.5 / H-19); got \(names)")
        }
    }

    // MARK: - Schema parity

    func testSpawnAgentSchemaMatchesUpstream() {
        let tool = SpawnAgentTool()
        XCTAssertEqual(tool.name, "spawn_agent")
        let obj = parseSchema(tool.jsonSchema)
        XCTAssertEqual(obj["type"] as? String, "object")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false,
                       "upstream `additionalProperties: false`")
        // Upstream v1 has no `required` array (all props optional).
        XCTAssertNil(obj["required"], "spawn_agent v1 has no required fields")
        let props = obj["properties"] as? [String: Any] ?? [:]
        for k in ["message", "items", "agent_type", "fork_context",
                  "model", "reasoning_effort", "service_tier"] {
            XCTAssertNotNil(props[k], "missing property \(k)")
        }
    }

    func testSpawnAgentTypeDescriptionIsRuntimeConfigurable() {
        // The default tool advertises the upstream default placeholder.
        let defaultTool = SpawnAgentTool()
        let defaultProps = (parseSchema(defaultTool.jsonSchema)["properties"]
                              as? [String: Any]) ?? [:]
        let defaultAgentType = defaultProps["agent_type"] as? [String: Any] ?? [:]
        XCTAssertEqual(defaultAgentType["description"] as? String,
                       DefaultSpawnAgentAgentTypeDescription,
                       "default agent_type description must match the parity placeholder")

        // A session-supplied description must propagate into the schema —
        // mirrors upstream `ToolsConfig::agent_type_description` flow
        // (`SpawnAgentToolOptions.agent_type_description`).
        let custom = "Pick from: planner, coder, reviewer, executor."
        let configured = SpawnAgentTool(options: SpawnAgentToolOptions(
            agentTypeDescription: custom))
        let props = (parseSchema(configured.jsonSchema)["properties"]
                       as? [String: Any]) ?? [:]
        let agentType = props["agent_type"] as? [String: Any] ?? [:]
        XCTAssertEqual(agentType["description"] as? String, custom,
                       "session-configured agent_type description must reach the JSON schema")
    }

    /// Ordering parity: upstream `spawn_agent_common_properties_v1` builds a
    /// BTreeMap, so the property keys serialize in sorted order:
    /// agent_type, fork_context, items, message, model, reasoning_effort,
    /// service_tier. The nested collab input-items object sorts to
    /// image_url, name, path, text, type.
    func testSpawnAgentSchemaPropertyOrderIsAlphabetical() {
        let schema = SpawnAgentTool().jsonSchema
        let topOrder = orderedTopLevelPropertyKeys(schema)
        XCTAssertEqual(topOrder,
                       ["agent_type", "fork_context", "items", "message",
                        "model", "reasoning_effort", "service_tier"],
                       "spawn_agent properties must be in upstream BTreeMap order")
        let itemsOrder = orderedItemsPropertyKeys(schema)
        XCTAssertEqual(itemsOrder,
                       ["image_url", "name", "path", "text", "type"],
                       "collab input-items properties must be in upstream BTreeMap order")
    }

    /// Ordering parity for send_input: top-level sorts to interrupt, items,
    /// message, target; nested items object identical to spawn_agent.
    func testSendInputSchemaPropertyOrderIsAlphabetical() {
        let schema = SendInputTool().jsonSchema
        let topOrder = orderedTopLevelPropertyKeys(schema)
        XCTAssertEqual(topOrder,
                       ["interrupt", "items", "message", "target"],
                       "send_input properties must be in upstream BTreeMap order")
        let itemsOrder = orderedItemsPropertyKeys(schema)
        XCTAssertEqual(itemsOrder,
                       ["image_url", "name", "path", "text", "type"],
                       "collab input-items properties must be in upstream BTreeMap order")
    }

    /// Finding 5: the default `agent_type` description reproduces upstream
    /// `spawn_tool_spec::build(&BTreeMap::new())` — the omit-default sentence,
    /// the "Available roles:" header, and the built-in role catalog (default,
    /// explorer, worker) in sorted order.
    func testDefaultAgentTypeDescriptionPortsBuiltInRoleCatalog() {
        let desc = DefaultSpawnAgentAgentTypeDescription
        XCTAssertTrue(desc.hasPrefix(
            "Optional type name for the new agent. If omitted, `default` is used.\nAvailable roles:\n"),
            "must emit the upstream omit-default + Available roles prefix; got: \(desc.prefix(120))")
        XCTAssertTrue(desc.contains("default: {\nDefault agent.\n}"),
                      "built-in `default` role entry missing")
        XCTAssertTrue(desc.contains("explorer: {\nUse `explorer` for specific codebase questions."),
                      "built-in `explorer` role entry missing")
        XCTAssertTrue(desc.contains("worker: {\nUse for execution and production work."),
                      "built-in `worker` role entry missing")
        // Sorted role order: default before explorer before worker.
        guard let d = desc.range(of: "default: {"),
              let e = desc.range(of: "explorer: {"),
              let w = desc.range(of: "worker: {") else {
            return XCTFail("all three role entries must be present")
        }
        XCTAssertTrue(d.lowerBound < e.lowerBound && e.lowerBound < w.lowerBound,
                      "roles must be in sorted order default < explorer < worker")
    }

    func testSpawnAgentDescriptionIncludesUpstreamUsageHint() {
        // Default options have `includeUsageHint=true` with no override,
        // so the rendered description must contain the full upstream
        // delegation rubric (parity with `spawn_agent_tool_description`
        // in `multi_agents_spec.rs`).
        let tool = SpawnAgentTool()
        let desc = tool.toolDescription
        XCTAssertTrue(desc.contains(
            "Spawn a sub-agent for a well-scoped task."),
            "core sentence missing")
        XCTAssertTrue(desc.contains(
            "Spawned agents inherit your current model by default. Omit `model` to use that preferred default; set `model` only when an explicit override is needed."),
            "inherited-model guidance missing")
        XCTAssertTrue(desc.contains(
            "Only use `spawn_agent` if and only if the user explicitly asks for sub-agents, delegation, or parallel agent work."),
            "authorization rule missing from description")
        XCTAssertTrue(desc.contains(
            "Requests for depth, thoroughness, research, investigation, or detailed codebase analysis do not count as permission to spawn."),
            "non-authorization clarification missing")
        XCTAssertTrue(desc.contains("### When to delegate vs. do the subtask yourself"),
                      "delegation rubric header missing")
        XCTAssertTrue(desc.contains("### Parallel delegation patterns"),
                      "parallel delegation header missing")
    }

    func testSpawnAgentDescriptionRespectsUsageHintToggle() {
        // include_usage_hint=false → only the short core sentence + the
        // inherited-model guidance, no delegation rubric.
        let opts = SpawnAgentToolOptions(includeUsageHint: false)
        let desc = SpawnAgentTool(options: opts).toolDescription
        XCTAssertTrue(desc.contains("Spawn a sub-agent for a well-scoped task."))
        XCTAssertFalse(desc.contains("### When to delegate vs. do the subtask yourself"),
                       "rubric should be omitted when include_usage_hint=false")
        XCTAssertFalse(desc.contains("Only use `spawn_agent` if and only if"),
                       "rubric should be omitted when include_usage_hint=false")
    }

    func testWaitAgentSchemaMatchesUpstream() {
        let tool = WaitAgentTool()
        XCTAssertEqual(tool.name, "wait_agent")
        let obj = parseSchema(tool.jsonSchema)
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertEqual(obj["required"] as? [String], ["targets"])
        let props = obj["properties"] as? [String: Any] ?? [:]
        let targets = props["targets"] as? [String: Any] ?? [:]
        XCTAssertEqual(targets["type"] as? String, "array")
        let timeout = props["timeout_ms"] as? [String: Any] ?? [:]
        XCTAssertEqual(timeout["type"] as? String, "number")
    }

    func testCloseAgentSchemaMatchesUpstream() {
        let tool = CloseAgentTool()
        XCTAssertEqual(tool.name, "close_agent")
        let obj = parseSchema(tool.jsonSchema)
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertEqual(obj["required"] as? [String], ["target"])
        let props = obj["properties"] as? [String: Any] ?? [:]
        let target = props["target"] as? [String: Any] ?? [:]
        XCTAssertEqual(target["type"] as? String, "string")
    }

    func testSendInputSchemaMatchesUpstream() {
        let tool = SendInputTool()
        XCTAssertEqual(tool.name, "send_input")
        let obj = parseSchema(tool.jsonSchema)
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertEqual(obj["required"] as? [String], ["target"])
        let props = obj["properties"] as? [String: Any] ?? [:]
        for k in ["target", "message", "items", "interrupt"] {
            XCTAssertNotNil(props[k], "missing property \(k)")
        }
    }

    func testResumeAgentSchemaMatchesUpstream() {
        let tool = ResumeAgentTool()
        XCTAssertEqual(tool.name, "resume_agent")
        let obj = parseSchema(tool.jsonSchema)
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertEqual(obj["required"] as? [String], ["id"])
        let props = obj["properties"] as? [String: Any] ?? [:]
        let id = props["id"] as? [String: Any] ?? [:]
        XCTAssertEqual(id["type"] as? String, "string")
    }

    // MARK: - Unconfigured bus → structured error

    func testToolsReturnStructuredErrorWhenBusUnconfigured() async throws {
        // Ensure no providers are installed.
        await MultiAgentBus.shared.clearAll()
        let tools: [(any Tool, String)] = [
            (SpawnAgentTool(), #"{"message":"hi"}"#),
            (WaitAgentTool(), #"{"targets":["thr_1"]}"#),
            (CloseAgentTool(), #"{"target":"thr_1"}"#),
            (SendInputTool(), #"{"target":"thr_1","message":"hi"}"#),
            (ResumeAgentTool(), #"{"id":"thr_1"}"#),
        ]
        for (tool, args) in tools {
            let r = try await tool.run(
                ToolCall(callId: "c1", name: tool.name, argumentsJSON: args),
                cwd: "/tmp")
            XCTAssertFalse(r.success,
                           "\(tool.name) should fail when bus is unconfigured")
            XCTAssertTrue(r.output.contains("not configured"),
                          "\(tool.name) error message: \(r.output)")
        }
    }

    // MARK: - Basic happy-path flows (with stub providers)

    func testSpawnAgentBasicFlow() async throws {
        await MultiAgentBus.shared.installSpawn { req in
            XCTAssertEqual(req.message, "research dependency graph")
            XCTAssertEqual(req.model, "gpt-5.1-codex")
            return MultiAgentBus.SpawnResponse(
                agentId: "thr_xyz", nickname: "Codex Explorer")
        }
        let tool = SpawnAgentTool()
        let args = #"{"message":"research dependency graph","model":"gpt-5.1-codex"}"#
        let r = try await tool.run(
            ToolCall(callId: "c1", name: "spawn_agent", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertTrue(r.success, r.output)
        let body = parseJSON(r.output)
        XCTAssertEqual(body["agent_id"] as? String, "thr_xyz")
        XCTAssertEqual(body["nickname"] as? String, "Codex Explorer")
    }

    func testWaitAgentBasicFlowReportsTimeout() async throws {
        await MultiAgentBus.shared.installWait { req in
            XCTAssertEqual(req.targets, ["thr_a", "thr_b"])
            // Default 30000 ms when omitted.
            XCTAssertEqual(req.timeoutMs, MultiAgentTimeouts.defaultMs)
            return MultiAgentBus.WaitResponse(
                statusByAgent: [
                    ("thr_a", .completed("ok")),
                    ("thr_b", .running),
                ],
                timedOut: false)
        }
        let tool = WaitAgentTool()
        let args = #"{"targets":["thr_a","thr_b"]}"#
        let r = try await tool.run(
            ToolCall(callId: "c1", name: "wait_agent", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertTrue(r.success, r.output)
        let body = parseJSON(r.output)
        XCTAssertEqual(body["timed_out"] as? Bool, false)
        let status = body["status"] as? [String: Any] ?? [:]
        // thr_a is completed → object form {completed: "ok"}
        let completed = status["thr_a"] as? [String: Any] ?? [:]
        XCTAssertEqual(completed["completed"] as? String, "ok")
        // thr_b is running → bare string
        XCTAssertEqual(status["thr_b"] as? String, "running")
    }

    func testWaitAgentRejectsMissingTargets() async throws {
        await MultiAgentBus.shared.installWait { _ in
            XCTFail("provider should not be called when targets is missing")
            return MultiAgentBus.WaitResponse(statusByAgent: [], timedOut: true)
        }
        let tool = WaitAgentTool()
        let r = try await tool.run(
            ToolCall(callId: "c1", name: "wait_agent", argumentsJSON: "{}"),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("targets"), r.output)
    }

    func testWaitAgentClampsTimeoutToUpstreamBounds() async throws {
        // Pass an obviously-too-small timeout; the tool must clamp to the
        // upstream `MIN_WAIT_TIMEOUT_MS = 10_000`.
        let captured = CapturedTimeout()
        await MultiAgentBus.shared.installWait { req in
            await captured.set(req.timeoutMs)
            return MultiAgentBus.WaitResponse(statusByAgent: [], timedOut: true)
        }
        let tool = WaitAgentTool()
        let args = #"{"targets":["thr_a"],"timeout_ms":100}"#
        _ = try await tool.run(
            ToolCall(callId: "c1", name: "wait_agent", argumentsJSON: args),
            cwd: "/tmp")
        let value = await captured.get()
        XCTAssertEqual(value, MultiAgentTimeouts.minMs)
    }

    private actor CapturedTimeout {
        private var value: Int64 = -1
        func set(_ v: Int64) { value = v }
        func get() -> Int64 { value }
    }

    func testCloseAgentBasicFlow() async throws {
        await MultiAgentBus.shared.installClose { target in
            XCTAssertEqual(target, "thr_xyz")
            return .running
        }
        let tool = CloseAgentTool()
        let r = try await tool.run(
            ToolCall(callId: "c1", name: "close_agent",
                     argumentsJSON: #"{"target":"thr_xyz"}"#),
            cwd: "/tmp")
        XCTAssertTrue(r.success, r.output)
        let body = parseJSON(r.output)
        XCTAssertEqual(body["previous_status"] as? String, "running")
    }

    func testSendInputBasicFlow() async throws {
        await MultiAgentBus.shared.installSendInput { req in
            XCTAssertEqual(req.target, "thr_xyz")
            XCTAssertEqual(req.message, "hello")
            XCTAssertTrue(req.interrupt)
            return "sub_42"
        }
        let tool = SendInputTool()
        let args = #"{"target":"thr_xyz","message":"hello","interrupt":true}"#
        let r = try await tool.run(
            ToolCall(callId: "c1", name: "send_input", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertTrue(r.success, r.output)
        let body = parseJSON(r.output)
        XCTAssertEqual(body["submission_id"] as? String, "sub_42")
    }

    func testResumeAgentBasicFlow() async throws {
        await MultiAgentBus.shared.installResume { id in
            XCTAssertEqual(id, "thr_xyz")
            return .shutdown
        }
        let tool = ResumeAgentTool()
        let r = try await tool.run(
            ToolCall(callId: "c1", name: "resume_agent",
                     argumentsJSON: #"{"id":"thr_xyz"}"#),
            cwd: "/tmp")
        XCTAssertTrue(r.success, r.output)
        let body = parseJSON(r.output)
        XCTAssertEqual(body["status"] as? String, "shutdown")
    }

    // MARK: - Status rendering parity

    func testAgentStatusJSONRendering() async {
        // Unit cases serialise as bare strings per upstream
        // `agent_status_output_schema`.
        XCTAssertEqual(MultiAgentBus.AgentStatus.pendingInit.jsonValue() as? String,
                       "pending_init")
        XCTAssertEqual(MultiAgentBus.AgentStatus.running.jsonValue() as? String,
                       "running")
        XCTAssertEqual(MultiAgentBus.AgentStatus.interrupted.jsonValue() as? String,
                       "interrupted")
        XCTAssertEqual(MultiAgentBus.AgentStatus.shutdown.jsonValue() as? String,
                       "shutdown")
        XCTAssertEqual(MultiAgentBus.AgentStatus.notFound.jsonValue() as? String,
                       "not_found")
        // `completed` and `errored` carry a payload (object form).
        let completedNull = MultiAgentBus.AgentStatus.completed(nil)
            .jsonValue() as? [String: Any] ?? [:]
        XCTAssertTrue(completedNull["completed"] is NSNull)
        let completedMsg = MultiAgentBus.AgentStatus.completed("done")
            .jsonValue() as? [String: Any] ?? [:]
        XCTAssertEqual(completedMsg["completed"] as? String, "done")
        let errored = MultiAgentBus.AgentStatus.errored("boom")
            .jsonValue() as? [String: Any] ?? [:]
        XCTAssertEqual(errored["errored"] as? String, "boom")
    }

    // MARK: - Helpers

    private func parseSchema(_ s: String) -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { XCTFail("schema not valid JSON: \(s)"); return [:] }
        return obj
    }

    private func parseJSON(_ s: String) -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { XCTFail("result not valid JSON: \(s)"); return [:] }
        return obj
    }

    /// Extract the property keys, in their literal emission order, from the
    /// brace-balanced object that follows a given `"properties":{` occurrence.
    /// Used to assert hand-crafted schema strings emit keys in upstream
    /// BTreeMap (sorted) order, which `JSONSerialization` would otherwise lose.
    private func orderedPropertyKeys(_ schema: String, afterMarkerIndex: String.Index)
        -> [String] {
        let chars = Array(schema)
        // afterMarkerIndex points at the opening `{` of the properties object.
        let start = schema.distance(from: schema.startIndex, to: afterMarkerIndex)
        var depth = 0
        var keys: [String] = []
        var i = start
        var atKeyPosition = false
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                depth += 1
                // The properties object's direct children start at depth 1.
                if depth == 1 { atKeyPosition = true }
            } else if c == "}" {
                depth -= 1
                if depth == 0 { break }
            } else if c == "\"" && depth == 1 && atKeyPosition {
                // Read a key string at the top level of the properties object.
                var j = i + 1
                var key = ""
                while j < chars.count && chars[j] != "\"" { key += String(chars[j]); j += 1 }
                keys.append(key)
                i = j
                atKeyPosition = false
            } else if c == "," && depth == 1 {
                atKeyPosition = true
            }
            i += 1
        }
        return keys
    }

    private func orderedTopLevelPropertyKeys(_ schema: String) -> [String] {
        guard let r = schema.range(of: "\"properties\":{") else { return [] }
        return orderedPropertyKeys(schema, afterMarkerIndex: schema.index(before: r.upperBound))
    }

    /// The nested collab input-items property object. It is the SECOND
    /// `"properties":{` in the schema (inside `items.items`).
    private func orderedItemsPropertyKeys(_ schema: String) -> [String] {
        guard let first = schema.range(of: "\"properties\":{"),
              let second = schema.range(of: "\"properties\":{",
                                        range: first.upperBound..<schema.endIndex)
        else { return [] }
        return orderedPropertyKeys(schema, afterMarkerIndex: schema.index(before: second.upperBound))
    }
}
