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
    /// Whether this failure is TURN-FATAL rather than model-recoverable.
    ///
    /// Upstream distinguishes `FunctionCallError::Fatal(message)` — which
    /// `tools/parallel.rs:70` maps to `Err(CodexErr::Fatal(message))` and
    /// aborts the whole turn — from an ordinary `RespondToModel` failure,
    /// which becomes a `function_call_output` with `success:false` fed back to
    /// the model (`parallel.rs:71,158-165`). A `ToolResult` with `isFatal ==
    /// true` is the port's equivalent of the Fatal arm: the SessionEngine turn
    /// loop must abort the turn instead of returning the output to the model.
    /// `false` for every model-recoverable failure (the common case).
    public var isFatal: Bool
    public init(callId: String, output: String, success: Bool, truncated: Bool,
                isFatal: Bool = false) {
        self.callId = callId; self.output = output
        self.success = success; self.truncated = truncated
        self.isFatal = isFatal
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
    /// When non-nil, the tool is advertised to the Responses API as a Freeform
    /// custom-grammar tool (`type:"custom"`) rather than a JSON function tool.
    /// `toolDescription` is still used as the model-visible description; the
    /// `format` here supplies the grammar block. Only `apply_patch` overrides
    /// this; every other tool keeps the default `nil` (JSON function spec).
    /// Mirrors upstream `codex_tools::ToolSpec::Freeform(FreeformTool)`.
    var freeformToolFormat: FreeformToolFormat? { get }
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult
}

public extension Tool {
    var toolDescription: String { "" }
    var jsonSchema: String { #"{"type":"object","additionalProperties":true}"# }
    var outputSchemaJSON: String? { nil }
    var freeformToolFormat: FreeformToolFormat? { nil }
}

public struct ToolError: Error, Sendable, Equatable { public let message: String }

/// A TURN-FATAL tool error. A `Tool.run` that throws this signals an
/// unrecoverable condition (upstream `FunctionCallError::Fatal`, e.g. an
/// incompatible payload kind or a tool that produced no output —
/// `core/src/tools/registry.rs:391,525`). `dispatch` surfaces it as a
/// `ToolResult` with `isFatal == true`; the SessionEngine turn loop then
/// aborts the turn (parity with `parallel.rs:70`'s `Err(CodexErr::Fatal)`)
/// rather than feeding the message back to the model as a recoverable failure.
public struct FatalToolError: Error, Sendable, Equatable { public let message: String
    public init(message: String) { self.message = message }
}

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
    /// Tools that are CALLABLE but never advertised — neither in `specs()` nor
    /// discoverable via `tool_search`. Mirrors upstream tool names that exist
    /// only as internal handlers (e.g. `unified_exec`, which upstream uses as an
    /// approval-cache key / parallel-category label but never exposes as a
    /// model-visible `ToolSpec`). Kept for back-compat dispatch.
    private var hidden: [String: any Tool] = [:]
    /// Registration order of directly-visible tools. A Swift dictionary does not
    /// preserve insertion order, but upstream emits the model-visible tool list
    /// in deterministic executor-collection order (`spec_plan.rs:122-148`
    /// pushes specs in the order executors were collected — NOT alphabetically).
    /// We track registration order here so `specs()` can reproduce that
    /// insertion ordering for prompt-cache key parity.
    private var toolOrder: [String] = []
    private var activated: Set<String> = []
    /// Activation order of deferred tools (upstream appends newly-activated
    /// dynamic tools in the order they are surfaced, not alphabetically).
    private var activatedOrder: [String] = []
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

    public func register(_ tool: any Tool) {
        if tools[tool.name] == nil { toolOrder.append(tool.name) }
        tools[tool.name] = tool
    }

    /// Register a discoverable-but-hidden tool. It is NOT advertised in
    /// `specs()` until activated (codex lazy/dynamic tool loading), yet it
    /// remains directly callable once the model knows its name.
    public func registerDeferred(_ tool: any Tool) { deferred[tool.name] = tool }

    /// Register a callable-but-never-advertised tool (excluded from both
    /// `specs()` and `tool_search`). See `hidden`.
    public func registerHidden(_ tool: any Tool) { hidden[tool.name] = tool }

    /// Whether a registered tool declares itself `parallelSafe` (the author's
    /// signal that it is side-effect-free / concurrency-safe — a sound proxy for
    /// "read-only"). Returns `false` for an UNKNOWN tool so a coarse owner-gate
    /// keyed on this stays FAIL-SAFE (an unknown/dynamic tool is treated as
    /// non-read-only → gated). Consulted by `SessionEngine.toolDispatchGate` so
    /// the channel owner-gate can let a non-owner run a benign read-only dynamic
    /// tool while still blocking mutating ones.
    public func isReadOnlyTool(_ name: String) -> Bool {
        (tools[name] ?? deferred[name] ?? hidden[name])?.parallelSafe ?? false
    }

    /// Sorted names of all deferred (discoverable) tools.
    public func deferredToolNames() -> [String] { deferred.keys.sorted() }

    /// Sorted names of currently activated deferred tools.
    public func activatedToolNames() -> [String] { activated.sorted() }

    /// Activate deferred tools by name (idempotent); unknown names ignored.
    public func activate(_ names: [String]) {
        for n in names where deferred[n] != nil {
            if activated.insert(n).inserted { activatedOrder.append(n) }
        }
    }

    /// Model-visible tool specs for the current inventory (Codex
    /// `router.model_visible_specs()`).
    ///
    /// Upstream (`core/src/tools/spec_plan.rs:122-148`
    /// `build_model_visible_specs_and_registry`) emits specs in deterministic
    /// executor-collection order — NOT alphabetically. Top-level order follows
    /// the registration sequence (with code-mode executors prepended and hosted
    /// tools appended); only intra-namespace tools are sorted
    /// (`merge_into_namespaces:296-301`). We therefore preserve registration
    /// insertion order for directly-visible tools, then append activated
    /// deferred tools in activation order, to keep prompt-cache key parity with
    /// upstream rather than imposing a flat alphabetical sort.
    public func specs() -> [ToolSpec] {
        var all: [any Tool] = []
        for name in toolOrder {
            if let t = tools[name] { all.append(t) }
        }
        for name in activatedOrder where activated.contains(name) {
            if let t = deferred[name] { all.append(t) }
        }
        return all.map {
            ToolSpec(name: $0.name, description: $0.toolDescription,
                     parametersJSON: $0.jsonSchema,
                     outputSchemaJSON: $0.outputSchemaJSON,
                     freeformFormat: $0.freeformToolFormat)
        }
    }

    /// Dispatch one call with gating, fan-out cap, timeout, and a head/tail
    /// output ring so a chatty tool can't exhaust memory. Abort/failure
    /// shaping matches Codex `tools/parallel.rs`.
    public func dispatch(_ call: ToolCall, cwd: String,
                         deadline: Deadline) async -> ToolResult {
        guard let tool = tools[call.name] ?? deferred[call.name] ?? hidden[call.name] else {
            // Upstream `registry.rs::unsupported_tool_call_message`: an
            // unrecognized tool name yields "unsupported call: <name>" (and
            // "unsupported custom tool call: <name>" for a Custom payload). The
            // dispatch path here only sees function-style calls, so emit the
            // plain form.
            return ToolResult(callId: call.callId,
                              output: "unsupported call: \(call.name)", success: false, truncated: false)
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
        } catch let e as FatalToolError {
            // Upstream `FunctionCallError::Fatal` → `CodexErr::Fatal` aborts the
            // whole turn (`parallel.rs:70`). Surface it as a fatal ToolResult so
            // the SessionEngine turn loop aborts instead of returning the
            // message to the model.
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false, isFatal: true)
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
        guard let tool = tools[name] ?? deferred[name] ?? hidden[name] else {
            return "unsupported call: \(name)"
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
        } catch let e as FatalToolError {
            // Nested (code-mode) dispatch cannot abort the outer turn from
            // inside the JS sandbox, so a Fatal surfaces to the script as a
            // failed-tool string (the script may itself decide to stop). The
            // outer `code` invocation's own result then flows through the
            // normal turn loop.
            return "tool \(name) failed: \(e.message)"
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
        // Upstream `tools/parallel.rs::abort_message` restricts the "Wall time:"
        // form to namespace-less `shell_command` and `unified_exec` only; every
        // other tool (including `exec_command`) gets "aborted by user after Xs".
        if toolName == "shell_command" || toolName == "unified_exec" {
            return "Wall time: \(secsStr) seconds\naborted by user"
        }
        return "aborted by user after \(secsStr)s"
    }
}

/// Built-in `tool_search` tool (parallel-safe; read-only discovery). It does
/// a BM25-lite keyword search over deferred tools and activates the best
/// matches so they become callable on the next turn.
///
/// INTENTIONAL PORT DIVERGENCE (audit tools-router finding 4): upstream
/// `core/src/tools/handlers/tool_search_spec.rs::create_tool_search_tool`
/// returns `ToolSpec::ToolSearch { execution: "client", … }`, which
/// `tools/src/tool_spec.rs:21-26` serializes as the dedicated wire envelope
/// `{"type":"tool_search","execution":"client","description":…,"parameters":…}`;
/// `router.rs::build_tool_call` then routes the model's reply as a
/// `ResponseItem::ToolSearchCall` and the result as a `tool_search_output`
/// item, NOT as a `function_call`/`function_call_output` pair.
///
/// codex-swift has no `tool_search`-typed wire path: every registered `Tool`
/// is serialized by `OpenAIResponsesClient` as `{"type":"function", …}`, the
/// model therefore returns a `function_call` named `tool_search`, and the
/// router dispatches it like any other function (decoding {query, limit} and
/// emitting a plain `function_call_output`). The description, parameter schema
/// (`query` required, `limit` typed `number`), and the `TOOL_SEARCH_DEFAULT_LIMIT
/// = 8` fallback are reproduced verbatim, so the discovery BEHAVIOR is
/// identical for function-only clients — only the wire ENVELOPE differs.
///
/// Emitting the `{"type":"tool_search"}` spec WITHOUT also teaching the
/// response-item parser / dispatcher about `tool_search_call` /
/// `tool_search_output` would break discovery outright (the model's reply would
/// arrive as an unhandled `tool_search_call` item), so the spec half is NOT
/// emitted in isolation. Full round-trip support is deferred as a coordinated
/// `ProtocolModel` + `ModelClient` + `ToolRouter` change; this is an accepted,
/// documented divergence alongside the hosted `web_search` note
/// (`ShellTool.swift`), consistent for strict function-only JSON-RPC clients.
public struct ToolSearchTool: Tool {
    public let name = "tool_search"
    public let parallelSafe = true
    public var toolDescription: String {
        // Verbatim upstream `tool_search_spec.rs::create_tool_search_tool`
        // description (the `# Tool discovery` framing, BM25 wording, and the
        // `tool_search`/MCP-discovery guidance). The dynamic
        // `source_descriptions` list is rendered as upstream's empty-sources
        // fallback ("None currently enabled.") because the port advertises a
        // single static spec rather than recomputing per searchable source.
        "# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\nYou have access to tools from the following sources:\nNone currently enabled.\nSome of the tools may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search` instead of `list_mcp_resources` or `list_mcp_resource_templates`."
    }
    public var jsonSchema: String {
        // Mirrors upstream `create_tool_search_tool`: `query` is a string with
        // the upstream description, `limit` is typed `number` (NOT integer) and
        // carries the "defaults to 8" wording (`TOOL_SEARCH_DEFAULT_LIMIT = 8`).
        // Only `query` is required; `additionalProperties:false`.
        #"{"type":"object","properties":{"query":{"type":"string","description":"Search query for deferred tools."},"limit":{"type":"number","description":"Maximum number of tools to return (defaults to 8)."}},"required":["query"],"additionalProperties":false}"#
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
        // Upstream `tool_search.rs:94`: `args.limit.unwrap_or(TOOL_SEARCH_DEFAULT_LIMIT)`
        // with `TOOL_SEARCH_DEFAULT_LIMIT = 8`.
        let out = await search(args.query, args.limit ?? 8)
        return ToolResult(callId: call.callId, output: out, success: true, truncated: false)
    }
}

/// Built-in `apply_patch` tool (serial — it mutates the workspace).
public struct ApplyPatchTool: Tool {
    public let name = "apply_patch"
    public let parallelSafe = false
    public var jsonSchema: String {
        #"{"type":"object","properties":{"patch":{"type":"string","description":"The *** Begin Patch / *** End Patch envelope"}},"required":["patch"],"additionalProperties":false}"#
    }

    /// Verbatim model-facing description for the Freeform custom-grammar tool
    /// (upstream `apply_patch_spec.rs:20`). Distinct from `toolDescription`
    /// (the host-facing summary used by the legacy JSON-function path).
    public static let freeformDescription =
        "Use the `apply_patch` tool to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON."

    /// The Lark grammar that constrains the freeform patch envelope, reproduced
    /// byte-for-byte from upstream `core/src/tools/handlers/apply_patch.lark`.
    /// When `includeEnvironmentId` is true the `start:` rule is rewritten to
    /// permit an optional `*** Environment ID:` line, mirroring upstream
    /// `create_apply_patch_freeform_tool`'s conditional `.replace(…)`.
    public static func larkGrammar(includeEnvironmentId: Bool = false) -> String {
        let base = applyPatchLarkGrammar
        guard includeEnvironmentId else { return base }
        return base.replacingOccurrences(
            of: "start: begin_patch hunk+ end_patch",
            with: "start: begin_patch environment_id? hunk+ end_patch\nenvironment_id: \"*** Environment ID: \" filename LF")
    }

    /// Freeform tool format (`{"type":"grammar","syntax":"lark","definition":…}`)
    /// for the model request builder.
    public static func freeformFormat(includeEnvironmentId: Bool = false) -> FreeformToolFormat {
        FreeformToolFormat(type: "grammar", syntax: "lark",
                           definition: larkGrammar(includeEnvironmentId: includeEnvironmentId))
    }

    private struct JSONArgs: Decodable { let patch: String }

    /// True when `s`, after leading whitespace, begins with the apply_patch
    /// sentinel — the fast path for a raw freeform envelope.
    static func looksLikePatchEnvelope(_ s: String) -> Bool {
        s.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .hasPrefix("*** Begin Patch")
    }

    /// True when `s` contains the apply_patch sentinel anywhere (lenient final
    /// fallback for non-JSON freeform input).
    static func containsPatchEnvelope(_ s: String) -> Bool {
        s.contains("*** Begin Patch")
    }

    /// Advertise apply_patch as a Freeform custom-grammar tool. Upstream's
    /// `create_apply_patch_freeform_tool` ALWAYS returns the freeform spec (no
    /// gating); the `include_environment_id` flag is `false` for the standard
    /// REST path, so we default to the non-environment-id grammar here.
    public var freeformToolFormat: FreeformToolFormat? {
        Self.freeformFormat(includeEnvironmentId: false)
    }
    /// Model-visible description for the freeform tool path (overrides the
    /// host-facing summary so the wire matches upstream byte-for-byte).
    public var toolDescription: String { Self.freeformDescription }

    private let sandbox: any Sandbox
    public init(sandbox: any Sandbox) { self.sandbox = sandbox }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        // apply_patch is advertised as a Freeform custom-grammar tool, so a
        // model may deliver the raw `*** Begin Patch … *** End Patch` envelope
        // directly (custom_tool_call `input`, NOT wrapped in JSON). Older /
        // JSON-function clients still deliver `{"patch":"…"}`. Accept BOTH:
        //   1. Prefer the raw envelope when the argument text itself looks like
        //      an apply_patch envelope (starts with `*** Begin Patch`).
        //   2. Otherwise fall back to decoding the legacy JSON `{patch:…}`.
        //   3. As a final fallback, treat the raw text as the patch envelope so
        //      a custom_tool_call with leading whitespace/comments still works.
        let raw = call.argumentsJSON
        let patch: String
        if Self.looksLikePatchEnvelope(raw) {
            patch = raw
        } else if let data = raw.data(using: .utf8),
                  let args = try? JSONDecoder().decode(JSONArgs.self, from: data) {
            patch = args.patch
        } else if Self.containsPatchEnvelope(raw) {
            // Not JSON, but contains a patch envelope somewhere — use as-is.
            patch = raw
        } else {
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
            let applied = try ap.apply(patch, root: cwd)
            // Surface the committed per-file delta so the host's per-turn
            // `TurnDiffTracker` can accumulate it and emit `turn/diff/updated`
            // (upstream `ToolEventCtx.turn_diff_tracker.track_delta`). Carried
            // as a JSON string over the bus so this module stays decoupled.
            let delta = applied.appliedPatchDelta()
            if !delta.isEmpty,
               let data = try? JSONEncoder().encode(delta),
               let payload = String(data: data, encoding: .utf8) {
                await ApplyPatchDeltaBus.shared.publish(callId: call.callId,
                                                        payloadJSON: payload)
            } else {
                // Success with no committed delta → invalidate the turn diff
                // tracker (upstream maps a success-with-absent-delta to
                // `TurnDiffTrackerUpdate::Invalidate`).
                await ApplyPatchDeltaBus.shared.publish(
                    callId: call.callId,
                    payloadJSON: ApplyPatchDeltaBus.invalidateSentinel)
            }
            // Upstream `print_summary` (apply-patch/src/lib.rs:855): fixed
            // header + single-letter A/M/D status codes, grouped added →
            // modified → deleted.
            var lines = ["Success. Updated the following files:"]
            lines += applied.filter { $0.kind == .add }.map { "A \($0.path)" }
            // Upstream emits the move destination for renames: `affected_path =
            // hunk.path()` returns `move_path` for an Update-with-move
            // (parser.rs:92-106, lib.rs:524).
            lines += applied.filter { $0.kind == .update }.map { "M \($0.movePath ?? $0.path)" }
            lines += applied.filter { $0.kind == .delete }.map { "D \($0.path)" }
            // Upstream `print_summary` (lib.rs:851-866) uses `writeln!` for the
            // header and EACH file line, so its stdout ends with a trailing
            // '\n'. Append one to the joined output to be byte-identical.
            return ToolResult(callId: call.callId,
                              output: lines.joined(separator: "\n") + "\n",
                              success: true, truncated: false)
        } catch {
            // A failed apply_patch invalidates any accumulated turn diff
            // (upstream maps `ToolEventFailure::Output` → `Invalidate`). The
            // applier is all-or-nothing for well-formed inputs — it verifies
            // every hunk in-memory before any write (mirroring
            // `verify_apply_patch_args`), so a context-mismatch or
            // missing-target in a later file leaves the workspace untouched. We
            // still invalidate here so any partial diff from a genuine I/O fault
            // during the write pass (disk full, permission) is cleared rather
            // than emitted as an incorrect cumulative diff.
            await ApplyPatchDeltaBus.shared.publish(
                callId: call.callId,
                payloadJSON: ApplyPatchDeltaBus.invalidateSentinel)
            // Surface upstream's exact model-facing text: the handler wraps the
            // parse/apply error as "apply_patch verification failed: {error}"
            // (core/src/tools/handlers/apply_patch.rs:423-425), where `{error}`
            // is the error's Display (e.g. "invalid hunk at line N, ...").
            let message: String
            if case let ApplyPatchError.emptyPatch(text) = error {
                // Upstream surfaces an empty (boundary-valid) patch as a bare
                // apply-time stderr line ("No files were modified.") with NO
                // "apply_patch verification failed:" prefix (lib.rs:371-373
                // anyhow::bail! → apply_hunks writeln at lib.rs:336).
                message = text
            } else if let ap = error as? ApplyPatchError {
                message = "apply_patch verification failed: \(ap.formatted)"
            } else {
                message = "apply_patch verification failed: \(error)"
            }
            return ToolResult(callId: call.callId, output: message,
                              success: false, truncated: false)
        }
    }
}

/// Verbatim reproduction of upstream
/// `core/src/tools/handlers/apply_patch.lark` (578 bytes, trailing `\n`
/// preserved). Embedded via `include_str!` upstream; here it is a string
/// constant so the freeform `definition` field is byte-faithful on the wire.
/// Built from an explicit line list joined with `\n` (the grammar contains no
/// backslash escapes) so the bytes cannot drift through editor reflow.
let applyPatchLarkGrammar: String = ([
    "start: begin_patch hunk+ end_patch",
    "begin_patch: \"*** Begin Patch\" LF",
    "end_patch: \"*** End Patch\" LF?",
    "",
    "hunk: add_hunk | delete_hunk | update_hunk",
    "add_hunk: \"*** Add File: \" filename LF add_line+",
    "delete_hunk: \"*** Delete File: \" filename LF",
    "update_hunk: \"*** Update File: \" filename LF change_move? change?",
    "",
    "filename: /(.+)/",
    "add_line: \"+\" /(.*)/ LF -> line",
    "",
    "change_move: \"*** Move to: \" filename LF",
    "change: (change_context | change_line)+ eof_line?",
    "change_context: (\"@@\" | \"@@ \" /(.+)/) LF",
    "change_line: (\"+\" | \"-\" | \" \") /(.*)/ LF",
    "eof_line: \"*** End of File\" LF",
    "",
    "%import common.LF",
] as [String]).joined(separator: "\n") + "\n"
