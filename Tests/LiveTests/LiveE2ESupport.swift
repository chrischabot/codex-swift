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
@testable import MCP
@testable import WireProtocol
@testable import Workflows

// MARK: - Shared INTERNAL live-E2E support.
//
// All helpers here are `internal` (NOT file-private) so every new live-test
// file can reuse them. They use a fresh `lx` prefix so they never collide with
// the deliberately-private `live*`/`rw*`/`d*` helpers in the three legacy
// files. The event collectors are FREE functions so the spawned Task does not
// capture the non-Sendable XCTestCase.

// MARK: gating / model / scratch

/// Returns the live API key, or nil when unset/empty. Pair with
/// `lxSkipUnlessLiveKey()` so a missing key skips cleanly in CI.
internal func lxAPIKey() -> String? {
    let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    return (k?.isEmpty == false) ? k : nil
}

/// Throwing skip gate — call at the top of any test whose hard assertions need
/// the network/live model. Deterministic assertions should run BEFORE this.
internal func lxSkipUnlessLiveKey(_ file: StaticString = #filePath, _ line: UInt = #line) throws {
    try XCTSkipUnless(lxAPIKey() != nil, "OPENAI_API_KEY not set")
}

internal func lxModel() -> String {
    ProcessInfo.processInfo.environment["CODEXKIT_LIVE_MODEL"] ?? "gpt-4o-mini"
}

/// Fresh temp dir (auto-created). Callers should remove it in a `defer`.
internal func lxTmp(_ tag: String = "home") -> String {
    let p = NSTemporaryDirectory() + "lx-\(tag)-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

internal func lxStore(_ home: String) throws -> ThreadStore {
    try ThreadStore(codexHome: home, limits: Limits())
}

// MARK: client builders

/// Live model client. On macOS this is the PRODUCTION `URLSessionResponsesClient`
/// (the client `codexd`/`codex-session` actually use) — URLSession pools
/// connections, so it stays correct under heavy workflow sub-agent fan-out.
/// The curl-subprocess `OpenAIResponsesClient` is the off-darwin fallback only;
/// it spawns one curl process (+pipes) per request and exhausts file
/// descriptors under concurrent fan-out (it raises an uncatchable
/// `NSFileHandleOperationException`), so it must NOT back concurrent live tests.
internal func lxClient(_ maxOut: Int = 400) -> any ModelClient {
    #if os(macOS)
    return URLSessionResponsesClient(apiKey: lxAPIKey() ?? "missing", maxOutputTokens: maxOut, limits: Limits())
    #else
    return OpenAIResponsesClient(apiKey: lxAPIKey() ?? "missing", maxOutputTokens: maxOut, limits: Limits())
    #endif
}

/// Re-export of the wire-capturing wrapper for ergonomic use in this target.
internal typealias LXRecording = RecordingModelClient

internal func lxRecording(_ maxOut: Int = 400) -> RecordingModelClient {
    RecordingModelClient(lxClient(maxOut))
}

// MARK: full-tool engine builder (free; takes an explicit store)

/// Canonical full-tool inventory engine rooted at `work`: shell_command +
/// apply_patch + the default file tools, wrapped in a RecordingModelClient,
/// with a bounded sampling/deadline cap so a chatty model cannot wedge a turn.
/// Returns the engine, the recording client, the router, and the sandbox.
internal func lxFullToolEngine(home: String, work: String, tid: ThreadId,
                               store: ThreadStore, maxOut: Int = 800,
                               maxIters: Int = 8,
                               deadline: Duration = .seconds(160),
                               workflowsEnabled: Bool = false)
async -> (SessionEngine, RecordingModelClient, ToolRouter, WorkspaceSandbox) {
    let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite, writableRoots: [work]))
    let router = ToolRouter(limits: Limits())
    await DefaultTools.register(on: router, sandbox: sb, limits: Limits())
    let rec = RecordingModelClient(lxClient(maxOut))
    var lim = Limits()
    lim.maxSamplingIterationsPerTurn = maxIters
    lim.turnDeadline = deadline
    let engine = SessionEngine(
        config: SessionConfig(threadId: tid, cwd: work, model: lxModel()),
        model: rec, store: store, router: router, limits: lim, sandbox: sb,
        workflowsEnabled: workflowsEnabled)
    return (engine, rec, router, sb)
}

/// A bare-router engine (no default tools) for trigger/skill/compaction tests
/// that register exactly what they need.
internal func lxBareEngine(home: String, work: String, tid: ThreadId,
                           store: ThreadStore, router: ToolRouter,
                           model: any ModelClient,
                           maxIters: Int = 8,
                           deadline: Duration = .seconds(120),
                           workflowsEnabled: Bool = false,
                           skills: [PromptComposer.SkillInjection] = [],
                           memoryStore: MemoryStore? = nil,
                           autoCompactTokens: Int? = nil,
                           sandbox: (any Sandbox)? = nil) -> SessionEngine {
    var lim = Limits()
    lim.maxSamplingIterationsPerTurn = maxIters
    lim.turnDeadline = deadline
    return SessionEngine(
        config: SessionConfig(threadId: tid, cwd: work, model: lxModel()),
        model: model, store: store, router: router, limits: lim,
        autoCompactTokens: autoCompactTokens ?? 24_000,
        memoryStore: memoryStore, sandbox: sandbox, skills: skills,
        workflowsEnabled: workflowsEnabled)
}

// MARK: turn driver / event collector (FREE functions)

/// Collect notifications until `n` turn completions or `timeout`. Free function
/// so the Task does not capture the non-Sendable XCTestCase.
internal func lxCollect(_ engine: SessionEngine, untilCompletions n: Int = 1,
                        timeout: Duration = .seconds(120)) async -> [ServerNotification] {
    let stream = await engine.events()
    let collector = Task { () -> [ServerNotification] in
        var out: [ServerNotification] = []
        var c = 0
        for await ev in stream {
            out.append(ev)
            if case .turnCompleted = ev { c += 1; if c == n { break } }
        }
        return out
    }
    let timer = Task { try? await Task.sleep(for: timeout); collector.cancel() }
    let r = await collector.value
    timer.cancel()
    return r
}

/// Collect for a fixed wall-clock window without requiring a completion
/// (used for progress/notification-stream assertions on relayed events).
internal func lxCollectFor(_ engine: SessionEngine,
                           window: Duration) async -> [ServerNotification] {
    let stream = await engine.events()
    let collector = Task { () -> [ServerNotification] in
        var out: [ServerNotification] = []
        for await ev in stream { out.append(ev) }
        return out
    }
    let timer = Task { try? await Task.sleep(for: window); collector.cancel() }
    let r = await collector.value
    timer.cancel()
    return r
}

internal func lxLastTurnStatus(_ evs: [ServerNotification]) -> TurnStatus? {
    for n in evs.reversed() {
        if case .turnCompleted(_, let t) = n { return t.status }
    }
    return nil
}

/// Project a prompt's input items into a single searchable blob (for
/// byte-faithful wire fragment assertions).
internal func lxBlob(_ items: [PromptInput]) -> String {
    items.map { i in
        switch i {
        case .userText(let t), .developerText(let t), .assistantText(let t): return t
        case .toolOutput(_, let o): return o
                case .reasoning(let summary, let content, _): return (summary + content).joined(separator: "\n")
        }
    }.joined(separator: "\n")
}

// MARK: side-effect assertion utilities

/// Byte-faithful wire battery that always holds for a recorded live turn.
internal func lxAssertByteFaithfulWire(_ caps: [RecordingModelClient.Captured],
                                       _ tid: ThreadId,
                                       file: StaticString = #filePath, line: UInt = #line) {
    guard let first = caps.first else {
        XCTFail("no captured wire request", file: file, line: line); return
    }
    XCTAssertEqual(first.settings.threadId, tid.raw,
                   "prompt_cache_key (threadId) is the stable cache key", file: file, line: line)
    XCTAssertEqual(first.prompt.instructions,
                   PromptComposer(personality: .pragmatic).modelInstructions(),
                   "system instructions are byte-stable Codex model instructions",
                   file: file, line: line)
    let blob0 = lxBlob(first.prompt.input)
    XCTAssertTrue(blob0.contains("<permissions instructions>"),
                  "permissions fragment present byte-for-byte", file: file, line: line)
    XCTAssertTrue(blob0.contains("<environment_context>"),
                  "environment-context fragment present byte-for-byte", file: file, line: line)
    for c in caps {
        XCTAssertEqual(c.settings.threadId, tid.raw, file: file, line: line)
    }
}

/// True if the rollout contains a context message with the given role whose
/// rendered sections contain `needle`.
internal func lxRolloutHasContextMessage(_ store: ThreadStore, _ tid: ThreadId,
                                         role: String, containing needle: String) async -> Bool {
    guard let rebuilt = try? await store.reconstruct(tid) else { return false }
    for item in rebuilt.items {
        if case .contextMessage(_, let r, let sections) = item, r == role {
            if sections.joined(separator: "\n").contains(needle) { return true }
        }
    }
    return false
}

internal func lxRolloutUserMessageCount(_ store: ThreadStore, _ tid: ThreadId) async -> Int {
    guard let rebuilt = try? await store.reconstruct(tid) else { return 0 }
    return rebuilt.items.filter { if case .userMessage = $0 { return true }; return false }.count
}

/// (status, output) for every shell command-execution item in an event stream.
internal func lxShellItems(_ evs: [ServerNotification]) -> [(ItemStatus, String)] {
    evs.compactMap { n in
        if case .itemCompleted(_, _, let it, _) = n,
           case .commandExecution(_, let cmd, _, let s, _, let out, _, _, _, _) = it,
           cmd.first == "shell_command" { return (s, out ?? "") }
        return nil
    }
}

// MARK: workflow orchestrator-in-test builder + bus install

/// Everything a workflow live-E2E test needs to drive the full
/// tool -> bus -> orchestrator -> engine -> runner -> SessionEngine path.
internal struct LXWorkflowHarness {
    let codexHome: String
    let store: ThreadStore
    let wfStore: WorkflowStore
    let model: RecordingModelClient
    let orchestrator: WorkflowOrchestrator
}

/// Build + install a workflow orchestrator on the shared bus. `progressSink`
/// is optional (nil to prove progress is suppressed without a sink). Pass
/// `enabledEnv: false` to exercise the code-6 gating path. Caller MUST call
/// `await WorkflowBus.shared.clearAll()` in teardown.
internal func lxInstallWorkflowOrchestrator(
    codexHome: String, maxOut: Int = 256, collectTimeout: Duration = .seconds(90),
    defaultModel: String? = nil, enabledEnv: Bool = true,
    extraEnv: [String: String] = [:],
    progressSink: WorkflowProgressNotifier.Sink? = nil) async throws -> LXWorkflowHarness {
    let store = try ThreadStore(codexHome: codexHome, limits: Limits())
    let model = RecordingModelClient(lxClient(maxOut))
    let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite, writableRoots: [codexHome]))
    let runner = WorkflowAgentRunner(
        store: store, limits: Limits(), model: model,
        routerFactory: { _, extra in
            let r = ToolRouter(limits: Limits())
            await DefaultTools.register(on: r, sandbox: sb, limits: Limits())
            for t in extra { await r.register(t) }
            return r
        },
        collectTimeout: collectTimeout)
    var env = extraEnv
    if enabledEnv { env["CODEX_FEATURE_WORKFLOWS"] = "1" }
    else { env["CODEX_WORKFLOWS_DISABLE"] = "1" }
    let orch = WorkflowOrchestrator(
        store: WorkflowStore(codexHome: codexHome), codexHome: codexHome, runner: runner,
        defaultModel: defaultModel ?? lxModel(), env: env, progressSink: progressSink)
    await orch.installOnBus()
    WorkflowHolder.shared.set(orch)
    return LXWorkflowHarness(codexHome: codexHome, store: store,
                             wfStore: WorkflowStore(codexHome: codexHome),
                             model: model, orchestrator: orch)
}

/// Launch an inline workflow via the bus and return the runId.
internal func lxLaunchInline(_ orch: WorkflowOrchestrator, script: String,
                            argsJSON: String? = nil, cwd: String) async throws -> String {
    let resp = try await orch.launch(WorkflowBus.LaunchRequest(
        script: script, argsJSON: argsJSON, cwd: cwd))
    return resp.runId
}

/// Poll a run to a terminal status (completed/failed/killed) or timeout.
@discardableResult
internal func lxPollWorkflowTerminal(_ runId: String, timeout: Duration = .seconds(120))
async -> String {
    let deadline = Date().addingTimeInterval(durationToSeconds(timeout))
    while Date() < deadline {
        let s = await WorkflowBus.shared.status(runId)
        if let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
           let st = obj["status"] as? String,
           st == "completed" || st == "failed" || st == "killed" { return st }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return "running"
}

private func durationToSeconds(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
}

/// Read a run's snapshot.json from disk (nil if absent / unparsable).
internal func lxReadSnapshot(codexHome: String, runId: String) -> [String: Any]? {
    let p = codexHome + "/workflows/runs/\(runId)/snapshot.json"
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

/// Read a run's journal.jsonl lines from disk.
internal func lxReadJournalLines(codexHome: String, runId: String) -> [String] {
    let p = codexHome + "/workflows/runs/\(runId)/journal.jsonl"
    guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

/// POSIX permission bits for a path (nil if missing).
internal func lxPosixPerms(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
}

/// Collect all decoded `workflow/progress` event objects across batches on a
/// session event stream.
internal func lxWorkflowProgressEvents(_ evs: [ServerNotification]) -> [JSONValue] {
    var out: [JSONValue] = []
    for n in evs {
        if case .raw(let method, let params) = n, method == "workflow/progress",
           case .object(let o)? = Optional(params), case .array(let arr)? = o["events"] {
            out.append(contentsOf: arr)
        }
    }
    return out
}

internal func lxRawCount(_ evs: [ServerNotification], method: String) -> Int {
    evs.filter { if case .raw(let m, _) = $0 { return m == method }; return false }.count
}

// MARK: tiny tools for live tests

/// Echo tool used by trigger / iteration-cap tests.
internal struct LXEchoTool: Tool {
    let name = "echo"
    let parallelSafe = true
    var toolDescription: String { "Echo back the provided text verbatim." }
    var jsonSchema: String {
        #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#
    }
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct A: Decodable { let text: String }
        let t = (try? JSONDecoder().decode(A.self, from: Data(call.argumentsJSON.utf8)))?.text ?? ""
        return ToolResult(callId: call.callId, output: t, success: true, truncated: false)
    }
}
