import Foundation
import InfraPrimitives
import ProtocolModel
import ModelClient
import Sandbox

public struct ToolCall: Sendable, Equatable {
    public var callId: String
    public var name: String
    public var argumentsJSON: String
    public init(callId: String, name: String, argumentsJSON: String) {
        self.callId = callId; self.name = name; self.argumentsJSON = argumentsJSON
    }
}

public struct ToolResult: Sendable, Equatable {
    public var callId: String
    public var output: String
    public var success: Bool
    public var truncated: Bool
    public init(callId: String, output: String, success: Bool, truncated: Bool) {
        self.callId = callId; self.output = output
        self.success = success; self.truncated = truncated
    }
}

public protocol Tool: Sendable {
    var name: String { get }
    /// Parallel-safe tools take the shared (read) side of the gate; serial
    /// tools take the exclusive (write) side (Codex `tools/parallel.rs`).
    var parallelSafe: Bool { get }
    /// Model-visible description (Codex tool spec). Default: empty.
    var toolDescription: String { get }
    /// Model-visible JSON-Schema object for the tool arguments. Default: a
    /// permissive object.
    var jsonSchema: String { get }
    /// Optional model-visible JSON-Schema for the structured output the tool
    /// returns. Emitted as `output_schema` next to `parameters` in the
    /// Responses API tool definition (mirrors `output_schema` on upstream
    /// `codex_tools::ResponsesApiTool`). Default: nil (no schema declared).
    var outputSchemaJSON: String? { get }
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult
}

public extension Tool {
    var toolDescription: String { "" }
    var jsonSchema: String { #"{"type":"object","additionalProperties":true}"# }
    var outputSchemaJSON: String? { nil }
}

public struct ToolError: Error, Sendable, Equatable { public let message: String }

/// Read/write gate: many `parallelSafe` tools run concurrently (shared), a
/// non-parallel tool runs exclusively (no readers, no other writer). Mirrors
/// Codex's per-turn `RwLock` gating.
actor ParallelGate {
    private var readers = 0
    private var writerActive = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    func acquireRead() async {
        if !writerActive && writeWaiters.isEmpty { readers += 1; return }
        await withCheckedContinuation { readWaiters.append($0) }
        readers += 1
    }
    func releaseRead() {
        readers -= 1
        if readers == 0, let w = writeWaiters.first {
            writeWaiters.removeFirst(); writerActive = true; w.resume()
        }
    }
    func acquireWrite() async {
        if !writerActive && readers == 0 { writerActive = true; return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }
    func releaseWrite() {
        writerActive = false
        if !readWaiters.isEmpty {
            let waiters = readWaiters; readWaiters.removeAll()
            for w in waiters { w.resume() }
        } else if let w = writeWaiters.first {
            writeWaiters.removeFirst(); writerActive = true; w.resume()
        }
    }
}

/// Bounds concurrent tool tasks per turn (hardening §5 fan-out cap).
actor FanoutSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { available = max(1, n) }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if let w = waiters.first { waiters.removeFirst(); w.resume() }
        else { available += 1 }
    }
}

public actor ToolRouter {
    private var tools: [String: any Tool] = [:]
    private var deferred: [String: any Tool] = [:]
    private var activated: Set<String> = []
    private let gate = ParallelGate()
    private let fanout: FanoutSemaphore
    private let perToolTimeout: Duration
    private let maxOutputBytes: Int

    public init(limits: Limits) {
        let l = limits.clamped()
        self.fanout = FanoutSemaphore(l.maxConcurrentTools)
        self.perToolTimeout = l.turnDeadline   // per-tool ceiling; turn deadline also applies
        self.maxOutputBytes = l.maxToolOutputBytes
    }

    public func register(_ tool: any Tool) { tools[tool.name] = tool }

    /// Register a discoverable-but-hidden tool. It is NOT advertised in
    /// `specs()` until activated (codex lazy/dynamic tool loading), yet it
    /// remains directly callable once the model knows its name.
    public func registerDeferred(_ tool: any Tool) { deferred[tool.name] = tool }

    /// Sorted names of all deferred (discoverable) tools.
    public func deferredToolNames() -> [String] { deferred.keys.sorted() }

    /// Sorted names of currently activated deferred tools.
    public func activatedToolNames() -> [String] { activated.sorted() }

    /// Activate deferred tools by name (idempotent); unknown names ignored.
    public func activate(_ names: [String]) {
        for n in names where deferred[n] != nil { activated.insert(n) }
    }

    /// Model-visible tool specs for the current inventory (Codex
    /// `router.model_visible_specs()`), sorted for prompt-cache stability.
    public func specs() -> [ToolSpec] {
        var all = Array(tools.values)
        for name in activated {
            if let t = deferred[name] { all.append(t) }
        }
        return all
            .map { ToolSpec(name: $0.name, description: $0.toolDescription,
                            parametersJSON: $0.jsonSchema,
                            outputSchemaJSON: $0.outputSchemaJSON) }
            .sorted { $0.name < $1.name }
    }

    /// Dispatch one call with gating, fan-out cap, timeout, and a head/tail
    /// output ring so a chatty tool can't exhaust memory. Abort/failure
    /// shaping matches Codex `tools/parallel.rs`.
    public func dispatch(_ call: ToolCall, cwd: String,
                         deadline: Deadline) async -> ToolResult {
        guard let tool = tools[call.name] ?? deferred[call.name] else {
            return ToolResult(callId: call.callId,
                              output: "unknown tool: \(call.name)", success: false, truncated: false)
        }
        await fanout.acquire()
        defer { Task { await fanout.release() } }

        let parallel = tool.parallelSafe
        if parallel { await gate.acquireRead() } else { await gate.acquireWrite() }
        defer {
            if parallel { Task { await gate.releaseRead() } }
            else { Task { await gate.releaseWrite() } }
        }

        let started = MonotonicClock.now()
        let timeoutSecs = min(perToolTimeout.seconds, max(0.001, deadline.remaining.seconds))
        do {
            let result = try await withThrowingTaskGroup(of: ToolResult.self) { group -> ToolResult in
                group.addTask { try await tool.run(call, cwd: cwd) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSecs))
                    throw ToolError(message: "__codex_tool_aborted__")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            var ring = HeadTailBuffer(maxBytes: maxOutputBytes)
            ring.append(result.output)
            return ToolResult(callId: result.callId, output: ring.rendered(),
                              success: result.success, truncated: ring.didTruncate)
        } catch is CancellationError {
            return ToolResult(callId: call.callId,
                              output: Self.abortMessage(call.name, MonotonicClock.now() - started),
                              success: false, truncated: false)
        } catch let e as ToolError where e.message == "__codex_tool_aborted__" {
            return ToolResult(callId: call.callId,
                              output: Self.abortMessage(call.name, MonotonicClock.now() - started),
                              success: false, truncated: false)
        } catch let e as ToolError {
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "tool error: \(error)",
                              success: false, truncated: false)
        }
    }

    /// Dispatch a tool call from inside the `code` tool. The outer `code`
    /// invocation already holds the exclusive tool gate, so reacquiring the
    /// gate here would deadlock when JavaScript calls another serial tool
    /// such as `write_file` or `shell`. Keep the same timeout/output bounds,
    /// but deliberately skip fanout/gate acquisition for this nested call.
    public func dispatchNestedFromCode(name: String,
                                       argumentsJSON: String,
                                       cwd: String,
                                       timeoutMs: Int) async -> String {
        guard CodeMode.isNestedTool(name) else {
            return "nested tool not allowed: \(name)"
        }
        guard let tool = tools[name] ?? deferred[name] else {
            return "unknown tool: \(name)"
        }
        let cap = Swift.min(Swift.max(timeoutMs, 100), 60_000)
        let call = ToolCall(callId: "code-\(UUID().uuidString)",
                            name: name,
                            argumentsJSON: argumentsJSON)
        let started = MonotonicClock.now()
        do {
            let result = try await withThrowingTaskGroup(of: ToolResult.self) { group -> ToolResult in
                group.addTask { try await tool.run(call, cwd: cwd) }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(cap))
                    throw ToolError(message: "__codex_tool_aborted__")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            var ring = HeadTailBuffer(maxBytes: maxOutputBytes)
            ring.append(result.output)
            let out = ring.rendered()
            return result.success ? out : "tool \(name) failed: \(out)"
        } catch is CancellationError {
            return Self.abortMessage(name, MonotonicClock.now() - started)
        } catch let e as ToolError where e.message == "__codex_tool_aborted__" {
            return Self.abortMessage(name, MonotonicClock.now() - started)
        } catch let e as ToolError {
            return "tool \(name) failed: \(e.message)"
        } catch {
            return "tool \(name) failed: \(error)"
        }
    }

    /// Deterministic BM25-lite (k1=1.5, b=0.75) keyword search over deferred
    /// tools' tokenized `name + description`. Activates the top matches and
    /// returns a human + machine readable result.
    func performToolSearch(query: String, limit: Int) -> String {
        func tokenize(_ s: String) -> [String] {
            s.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { !$0.isEmpty }
        }
        let header = "# tool_search results"
        let empty = "\(header)\n(no matching tools)\n\n{\"activated\":[]}"

        let names = deferred.keys.sorted()
        let docs: [(name: String, tokens: [String])] = names.map { n in
            let t = deferred[n]!
            return (n, tokenize("\(n) \(t.toolDescription)"))
        }
        let qTokens = tokenize(query)
        let n = docs.count
        if n == 0 || qTokens.isEmpty { return empty }

        let totalLen = docs.reduce(0) { $0 + $1.tokens.count }
        let avgdl = Double(totalLen) / Double(n)
        let k1 = 1.5
        let b = 0.75

        let qSet = Set(qTokens)
        var df: [String: Int] = [:]
        for term in qSet {
            var c = 0
            for d in docs where d.tokens.contains(term) { c += 1 }
            df[term] = c
        }

        var scored: [(name: String, score: Double)] = []
        for d in docs {
            var score = 0.0
            let dl = Double(d.tokens.count)
            for term in qSet {
                let dft = df[term] ?? 0
                if dft == 0 { continue }
                let tf = Double(d.tokens.filter { $0 == term }.count)
                if tf == 0 { continue }
                let idf = log((Double(n) - Double(dft) + 0.5) / (Double(dft) + 0.5) + 1.0)
                let denom = tf + k1 * (1 - b + b * (dl / avgdl))
                score += idf * (tf * (k1 + 1)) / denom
            }
            if score > 0 { scored.append((d.name, score)) }
        }
        scored.sort { a, c in
            if a.score != c.score { return a.score > c.score }
            return a.name < c.name
        }
        let cap = Swift.min(Swift.max(limit, 1), 25)
        let top = Array(scored.prefix(cap))
        if top.isEmpty { return empty }

        activate(top.map { $0.name })

        var lines = [header]
        for m in top {
            let t = deferred[m.name]!
            lines.append("- \(m.name): \(t.toolDescription)")
        }
        let arr: [[String: String]] = top.map { m in
            let t = deferred[m.name]!
            return ["name": m.name,
                    "description": t.toolDescription,
                    "parametersJSON": t.jsonSchema]
        }
        let jsonObj: [String: Any] = ["activated": arr]
        var jsonLine = "{\"activated\":[]}"
        if let data = try? JSONSerialization.data(withJSONObject: jsonObj,
                                                  options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            jsonLine = s
        }
        return lines.joined(separator: "\n") + "\n\n" + jsonLine
    }

    /// Construct and register the always-active built-in `tool_search` tool,
    /// bound to this actor's `performToolSearch` via a Sendable closure (no
    /// reference cycle; `ToolSearchTool` stays a value type).
    public func installToolSearch() {
        let tool = ToolSearchTool(search: { [self] q, l in
            await self.performToolSearch(query: q, limit: l)
        })
        register(tool)
    }

    private static func abortMessage(_ toolName: String, _ elapsed: Double) -> String {
        let secs = Swift.max(0.1, elapsed)
        let secsStr = String(format: "%.1f", secs)
        if toolName == "shell_command" || toolName == "unified_exec" || toolName == "shell" {
            return "Wall time: \(secsStr) seconds\naborted by user"
        }
        return "aborted by user after \(secsStr)s"
    }
}

/// Built-in `tool_search` tool (parallel-safe; read-only discovery). It does
/// a BM25-lite keyword search over deferred tools and activates the best
/// matches so they become callable on the next turn.
public struct ToolSearchTool: Tool {
    public let name = "tool_search"
    public let parallelSafe = true
    public var toolDescription: String {
        "Searches over additional (deferred) tools by keyword (BM25) and loads the best matches so they become callable on the next turn."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"],"additionalProperties":false}"#
    }
    private let search: @Sendable (String, Int) async -> String
    public init(search: @escaping @Sendable (String, Int) async -> String) {
        self.search = search
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable { let query: String; let limit: Int? }
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid tool_search arguments",
                              success: false, truncated: false)
        }
        let out = await search(args.query, args.limit ?? 5)
        return ToolResult(callId: call.callId, output: out, success: true, truncated: false)
    }
}

/// Built-in `apply_patch` tool (serial — it mutates the workspace).
public struct ApplyPatchTool: Tool {
    public let name = "apply_patch"
    public let parallelSafe = false
    public var toolDescription: String {
        "Apply a Codex apply_patch envelope to the workspace (Add/Update/Delete File)."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"patch":{"type":"string","description":"The *** Begin Patch / *** End Patch envelope"}},"required":["patch"],"additionalProperties":false}"#
    }
    private let sandbox: any Sandbox
    public init(sandbox: any Sandbox) { self.sandbox = sandbox }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable { let patch: String }
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid apply_patch arguments",
                              success: false, truncated: false)
        }
        // Sandbox policy gate before mutating the filesystem.
        let decision = sandbox.evaluateWrite(path: cwd)
        if decision.outcome == .deny {
            return ToolResult(callId: call.callId,
                              output: "sandbox denied write: \(decision.reason)",
                              success: false, truncated: false)
        }
        let ap = ApplyPatch()
        do {
            let applied = try ap.apply(args.patch, root: cwd)
            let summary = applied.map { "\($0.kind.rawValue) \($0.path)" }.joined(separator: "\n")
            return ToolResult(callId: call.callId, output: "applied:\n\(summary)",
                              success: true, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "apply_patch failed: \(error)",
                              success: false, truncated: false)
        }
    }
}
