import Foundation
import ProtocolModel
import ModelClient
import Persistence
import Tools
import InfraPrimitives
import Sandbox
import Prompts

// MARK: - AgentPath

/// `/root/...` path in the multi-agent tree (codex `core/src/agent`).
public struct AgentPath: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public let raw: String

    public static let root = AgentPath("/root")

    public init(_ raw: String) {
        var s = raw
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty || !s.hasPrefix("/root") { s = "/root" }
        self.raw = s
    }

    public func child(_ name: String) -> AgentPath {
        let safe = String(name.map { c -> Character in
            if c.isASCII && (c.isLetter || c.isNumber) { return c }
            if c == "." || c == "_" || c == "-" { return c }
            return "_"
        })
        return AgentPath(raw + "/" + (safe.isEmpty ? "_" : safe))
    }

    public var isRoot: Bool { raw == "/root" }

    public var parent: AgentPath? {
        if isRoot { return nil }
        guard let idx = raw.lastIndex(of: "/") else { return nil }
        let p = String(raw[raw.startIndex..<idx])
        return p.isEmpty ? AgentPath.root : AgentPath(p)
    }

    public var description: String { raw }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(try c.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

// MARK: - Status / records / specs

public enum AgentStatus: String, Sendable, Codable, Equatable {
    case pending, running, completed, failed, closed
}

public struct AgentRunResult: Sendable, Equatable {
    public var status: AgentStatus
    public var output: String
    public var error: String?
    public init(status: AgentStatus, output: String, error: String? = nil) {
        self.status = status; self.output = output; self.error = error
    }
}

public struct AgentSpawnSpec: Sendable, Equatable {
    public var path: AgentPath
    public var name: String
    public var prompt: String
    public var model: String?
    public var role: String
    public init(path: AgentPath, name: String, prompt: String,
                model: String? = nil, role: String = "default") {
        self.path = path; self.name = name; self.prompt = prompt
        self.model = model; self.role = role
    }
}

public struct AgentRecord: Sendable, Equatable {
    public var path: AgentPath
    public var status: AgentStatus
    public var result: String?
    public var error: String?
    public var parent: AgentPath?
    public var createdAt: Double
    public init(path: AgentPath, status: AgentStatus, result: String?,
                error: String?, parent: AgentPath?, createdAt: Double) {
        self.path = path; self.status = status; self.result = result
        self.error = error; self.parent = parent; self.createdAt = createdAt
    }
}

public enum AgentError: Error, Sendable, Equatable {
    case pathExists(String)
    case unknownAgent(String)
}

// MARK: - AgentRegistry

public actor AgentRegistry {
    private var records: [String: AgentRecord] = [:]

    public init() {}

    public func reserve(_ p: AgentPath, parent: AgentPath?) throws {
        if records[p.raw] != nil { throw AgentError.pathExists(p.raw) }
        records[p.raw] = AgentRecord(path: p, status: .pending, result: nil,
                                     error: nil, parent: parent,
                                     createdAt: MonotonicClock.now())
    }

    public func register(_ rec: AgentRecord) {
        records[rec.path.raw] = rec
    }

    public func setStatus(_ p: AgentPath, _ s: AgentStatus) {
        records[p.raw]?.status = s
    }

    public func setResult(_ p: AgentPath, output: String?, error: String?,
                          status: AgentStatus) {
        guard records[p.raw] != nil else { return }
        records[p.raw]?.result = output
        records[p.raw]?.error = error
        records[p.raw]?.status = status
    }

    public func get(_ p: AgentPath) -> AgentRecord? { records[p.raw] }

    public func list() -> [AgentRecord] {
        records.values.sorted { $0.path.raw < $1.path.raw }
    }

    public func remove(_ p: AgentPath) { records[p.raw] = nil }

    public func releaseReserved(_ p: AgentPath) { records[p.raw] = nil }
}

// MARK: - AgentOrchestrator

public actor AgentOrchestrator {
    public let registry: AgentRegistry
    private var mailboxes: [String: Mailbox] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var waiters: [String: [CheckedContinuation<AgentRunResult, Never>]] = [:]
    private let runner: @Sendable (AgentSpawnSpec) async -> AgentRunResult
    public let selfPath: AgentPath

    public init(selfPath: AgentPath = .root,
                runner: @escaping @Sendable (AgentSpawnSpec) async -> AgentRunResult) {
        self.registry = AgentRegistry()
        self.selfPath = selfPath
        self.runner = runner
    }

    public init(selfPath: AgentPath = .root) {
        self.registry = AgentRegistry()
        self.selfPath = selfPath
        self.runner = { _ in
            AgentRunResult(status: .completed, output: "(no runner configured)",
                           error: nil)
        }
    }

    public func mailbox(for p: AgentPath) -> Mailbox {
        if let m = mailboxes[p.raw] { return m }
        let m = Mailbox()
        mailboxes[p.raw] = m
        return m
    }

    public func spawn(parent: AgentPath? = nil, name: String, prompt: String,
                      model: String? = nil, role: String = "default")
    async throws -> AgentPath {
        let base = parent ?? selfPath
        let path = base.child(name)
        try await registry.reserve(path, parent: base)
        await registry.setStatus(path, .running)
        _ = mailbox(for: path)
        let runner = self.runner
        tasks[path.raw] = Task { [weak self] in
            let spec = AgentSpawnSpec(path: path, name: name, prompt: prompt,
                                      model: model, role: role)
            let r = await runner(spec)
            await self?.complete(path, r)
        }
        return path
    }

    private func complete(_ path: AgentPath, _ r: AgentRunResult) async {
        // `close()` is terminal — a late runner result must not resurrect it.
        if await registry.get(path)?.status == .closed {
            tasks[path.raw] = nil
            return
        }
        await registry.setResult(path, output: r.output, error: r.error,
                                 status: r.status)
        if let ws = waiters[path.raw] {
            waiters[path.raw] = nil
            for c in ws { c.resume(returning: r) }
        }
        tasks[path.raw] = nil
    }

    private func timeoutWait(_ path: AgentPath) {
        guard let ws = waiters[path.raw], !ws.isEmpty else { return }
        waiters[path.raw] = nil
        let r = AgentRunResult(status: .failed, output: "agent wait timed out",
                               error: "timeout")
        for c in ws { c.resume(returning: r) }
    }

    public func wait(_ path: AgentPath,
                     timeout: Duration = .seconds(120)) async -> AgentRunResult {
        if let rec = await registry.get(path),
           rec.status == .completed || rec.status == .failed
            || rec.status == .closed {
            return AgentRunResult(status: rec.status,
                                  output: rec.result ?? "",
                                  error: rec.error)
        }
        return await withCheckedContinuation {
            (c: CheckedContinuation<AgentRunResult, Never>) in
            waiters[path.raw, default: []].append(c)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeoutWait(path)
            }
        }
    }

    public func message(from: AgentPath? = nil, to: AgentPath,
                        content: String, triggerTurn: Bool = false) async -> Bool {
        if await registry.get(to) == nil { return false }
        let mb = mailbox(for: to)
        await mb.send(InterAgentCommunication(
            author: (from ?? selfPath).raw,
            recipient: to.raw,
            content: content,
            triggerTurn: triggerTurn))
        return true
    }

    public func close(_ path: AgentPath) async {
        tasks[path.raw]?.cancel()
        tasks[path.raw] = nil
        await registry.setResult(path, output: nil, error: "closed",
                                 status: .closed)
        if let ws = waiters[path.raw] {
            waiters[path.raw] = nil
            let r = AgentRunResult(status: .closed, output: "", error: "closed")
            for c in ws { c.resume(returning: r) }
        }
    }

    public func list() async -> [AgentRecord] { await registry.list() }

    public func drainMailbox(_ path: AgentPath) async -> [InterAgentCommunication] {
        await mailbox(for: path).drain()
    }
}

// MARK: - Deterministic JSON helper

func agentJSONObject(_ obj: [String: Any]) -> String {
    if let d = try? JSONSerialization.data(withJSONObject: obj,
                                           options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        return s.replacingOccurrences(of: "\\/", with: "/")
    }
    return "{}"
}

func agentParseArgs(_ json: String) -> [String: Any] {
    guard let d = json.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    else { return [:] }
    return o
}

// MARK: - Control tools

public struct AgentSpawnTool: Tool {
    // Upstream multi-agent tool name (multi_agents_spec.rs): `spawn_agent`.
    public let name = "spawn_agent"
    public let parallelSafe = false
    public var toolDescription: String { "Spawn a child agent at /root/<name> and run it with the given prompt." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"name":{"type":"string"},"prompt":{"type":"string"},"model":{"type":"string"}},"required":["name","prompt"],"additionalProperties":false}"#
    }
    private let spawn: @Sendable (String, String, String?) async -> String?

    public init(spawn: @escaping @Sendable (String, String, String?) async -> String?) {
        self.spawn = spawn
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = agentParseArgs(call.argumentsJSON)
        guard let nm = a["name"] as? String,
              let pr = a["prompt"] as? String else {
            return ToolResult(callId: call.callId,
                              output: agentJSONObject(["error": "missing name/prompt"]),
                              success: false, truncated: false)
        }
        let model = a["model"] as? String
        if let path = await spawn(nm, pr, model) {
            return ToolResult(callId: call.callId,
                              output: agentJSONObject(["agent": path,
                                                       "status": "running"]),
                              success: true, truncated: false)
        }
        return ToolResult(callId: call.callId,
                          output: agentJSONObject(["error": "spawn failed"]),
                          success: false, truncated: false)
    }
}

public struct AgentWaitTool: Tool {
    // Upstream multi-agent tool name (multi_agents_spec.rs): `wait_agent`.
    public let name = "wait_agent"
    // Serial: no multi_agents_v2 handler overrides supports_parallel_tool_calls,
    // so all multi-agent tools inherit the default `false`
    // (tools/src/tool_executor.rs:49-51).
    public let parallelSafe = false
    public var toolDescription: String { "Wait for an agent to finish and return its result." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"},"timeoutSeconds":{"type":"number"}},"required":["path"],"additionalProperties":false}"#
    }
    private let wait: @Sendable (String, Double) async -> AgentRunResult

    public init(wait: @escaping @Sendable (String, Double) async -> AgentRunResult) {
        self.wait = wait
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = agentParseArgs(call.argumentsJSON)
        let p = (a["path"] as? String) ?? "/root"
        let t = (a["timeoutSeconds"] as? Double)
            ?? Double((a["timeoutSeconds"] as? Int) ?? 120)
        let r = await wait(p, t)
        return ToolResult(callId: call.callId,
                          output: agentJSONObject([
                            "status": r.status.rawValue,
                            "output": r.output,
                            "error": r.error as Any? ?? NSNull(),
                          ]),
                          success: r.status == .completed, truncated: false)
    }
}

public struct AgentMessageTool: Tool {
    // Upstream multi-agent tool name (multi_agents_spec.rs v2): `send_message`.
    public let name = "send_message"
    public let parallelSafe = false
    public var toolDescription: String { "Send an inter-agent message into a target agent's mailbox." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"to":{"type":"string"},"content":{"type":"string"},"triggerTurn":{"type":"boolean"}},"required":["to","content"],"additionalProperties":false}"#
    }
    private let message: @Sendable (String, String, Bool) async -> Bool

    public init(message: @escaping @Sendable (String, String, Bool) async -> Bool) {
        self.message = message
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = agentParseArgs(call.argumentsJSON)
        let to = (a["to"] as? String) ?? "/root"
        let content = (a["content"] as? String) ?? ""
        let trig = (a["triggerTurn"] as? Bool) ?? false
        let ok = await message(to, content, trig)
        return ToolResult(callId: call.callId,
                          output: agentJSONObject(["delivered": ok]),
                          success: ok, truncated: false)
    }
}

public struct AgentCloseTool: Tool {
    // Upstream multi-agent tool name (multi_agents_spec.rs): `close_agent`.
    public let name = "close_agent"
    public let parallelSafe = false
    public var toolDescription: String { "Close an agent (cancel its task and mark it closed)." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#
    }
    private let close: @Sendable (String) async -> Bool

    public init(close: @escaping @Sendable (String) async -> Bool) {
        self.close = close
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = agentParseArgs(call.argumentsJSON)
        let p = (a["path"] as? String) ?? "/root"
        _ = await close(p)
        return ToolResult(callId: call.callId,
                          output: agentJSONObject(["closed": true]),
                          success: true, truncated: false)
    }
}

public struct AgentListTool: Tool {
    // Upstream multi-agent tool name (multi_agents_spec.rs): `list_agents`.
    public let name = "list_agents"
    // Serial: no multi_agents_v2 handler overrides supports_parallel_tool_calls,
    // so all multi-agent tools inherit the default `false`
    // (tools/src/tool_executor.rs:49-51).
    public let parallelSafe = false
    public var toolDescription: String { "List all known agents and their statuses." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{},"additionalProperties":false}"#
    }
    private let list: @Sendable () async -> [AgentRecord]

    public init(list: @escaping @Sendable () async -> [AgentRecord]) {
        self.list = list
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let recs = await list().sorted { $0.path.raw < $1.path.raw }
        let arr: [[String: Any]] = recs.map {
            ["path": $0.path.raw,
             "status": $0.status.rawValue,
             "error": $0.error as Any? ?? NSNull()]
        }
        return ToolResult(callId: call.callId,
                          output: agentJSONObject(["agents": arr]),
                          success: true, truncated: false)
    }
}

public extension AgentOrchestrator {
    func installAgentControl(on router: ToolRouter) async {
        let spawnTool = AgentSpawnTool { [self] name, prompt, model in
            (try? await self.spawn(name: name, prompt: prompt, model: model))?.raw
        }
        let waitTool = AgentWaitTool { [self] p, t in
            await self.wait(AgentPath(p), timeout: .seconds(t))
        }
        let msgTool = AgentMessageTool { [self] to, content, trig in
            await self.message(to: AgentPath(to), content: content,
                               triggerTurn: trig)
        }
        let closeTool = AgentCloseTool { [self] p in
            await self.close(AgentPath(p)); return true
        }
        let listTool = AgentListTool { [self] in
            await self.list()
        }
        await router.register(spawnTool)
        await router.register(waitTool)
        await router.register(msgTool)
        await router.register(closeTool)
        await router.register(listTool)
    }
}

// MARK: - SessionEngine-backed runner (optional, production path)

public enum SessionEngineAgentRunner {
    public static func make(store: ThreadStore,
                            limits: Limits,
                            model: any ModelClient,
                            router: @escaping @Sendable (AgentSpawnSpec) async -> ToolRouter,
                            cwd: String,
                            collectTimeout: Duration = .seconds(120),
                            hooks: HookEngine? = nil,
                            parentSessionId: String? = nil,
                            parentTurnId: String? = nil)
    -> @Sendable (AgentSpawnSpec) async -> AgentRunResult {
        return { spec in
            let sanitized = String(spec.path.raw.map { c -> Character in
                if c.isASCII && (c.isLetter || c.isNumber) { return c }
                return "_"
            })
            let tid = ThreadId("thr_agent_" + sanitized)
            let subModel = spec.model ?? "gpt-5.5"
            let cfg = SessionConfig(threadId: tid, cwd: cwd,
                                    model: subModel,
                                    ephemeral: true,
                                    subagentSourceLabel: "collab_spawn")
            _ = try? await store.create(cfg)
            let r = await router(spec)
            let engine = SessionEngine(config: cfg, model: model, store: store,
                                       router: r, limits: limits)

            // SubagentStart fires at the spawned subagent's start instead of the
            // root session-start (upstream `HookEventName::SubagentStart`). The
            // subagent's own SessionEngine is intentionally hookless so it does
            // not ALSO fire session-start/stop — upstream replaces those with the
            // subagent variants for thread-spawned child turns.
            let subagentExtra = ["agent_id": spec.path.raw, "agent_type": spec.role]
            if let hooks {
                _ = await hooks.fire(.subagentStart, HookRequest(
                    eventName: .subagentStart,
                    sessionId: parentSessionId ?? tid.raw, cwd: cwd,
                    turnId: parentTurnId, model: subModel,
                    extra: subagentExtra))
            }

            await engine.start()
            let stream = await engine.events()

            let collector = Task { () -> (String, TurnStatus) in
                var last = ""
                var status: TurnStatus = .failed
                for await ev in stream {
                    if Task.isCancelled { break }
                    switch ev {
                    case .itemCompleted(_, _, let item, _):
                        if case .agentMessage(_, let text) = item { last = text }
                    case .turnCompleted(_, let turn):
                        // Interrupted/aborted turns now arrive here too, as
                        // `turn/completed` with `status == .interrupted`.
                        status = turn.status
                        return (last, status)
                    default:
                        continue
                    }
                }
                return (last, status)
            }
            let timeoutTask = Task {
                try? await Task.sleep(for: collectTimeout)
                collector.cancel()
            }

            await engine.submit(.startTurn(input: [TurnInput(text: spec.prompt)],
                                           model: spec.model, turnId: nil))
            let (out, st) = await collector.value
            timeoutTask.cancel()
            await engine.quiesce()

            // SubagentStop fires when the child turn ends — upstream runs this
            // INSTEAD OF Stop for thread-spawned child turns. Carries the final
            // assistant message + the subagent-only agent_* fields.
            if let hooks {
                var stopExtra = subagentExtra
                stopExtra["agent_transcript_path"] = ""
                _ = await hooks.fire(.subagentStop, HookRequest(
                    eventName: .subagentStop,
                    sessionId: parentSessionId ?? tid.raw, cwd: cwd,
                    turnId: parentTurnId, model: subModel,
                    stopHookActive: false,
                    lastAssistantMessage: out.isEmpty ? nil : out,
                    extra: stopExtra))
            }

            let ok = (st == .completed)
            return AgentRunResult(status: ok ? .completed : .failed,
                                  output: out,
                                  error: ok ? nil : "turn \(st)")
        }
    }
}