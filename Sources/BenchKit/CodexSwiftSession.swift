import Foundation
import InfraPrimitives
import ProtocolModel
import ModelClient
import Persistence
import Tools
import HarnessCore
import Prompts

/// Runs the **real** codex-swift agent against a benchmark task inside its
/// container. This is a thin TRANSPORT, not a custom harness: it wires the
/// engine exactly as the production app (`codex-session`) does — codex's own
/// model-selected system prompt, the real default tool surface
/// (`RemoteExecServerTools`, the same remote toolset the app uses when a
/// `remoteEnvironment` is set), the engine's normal single-turn loop, and the
/// model's default reasoning level — and feeds the task instruction as the one
/// and only user message, the way a real user would. The ONLY bench-specific
/// additions are the container/exec-server transport and a hard wall-clock
/// bound so an unattended run can't hang forever. No custom prompt, no goals
/// override, no continuation/convergence/watchdog behavior injection — whatever
/// the agent scores here is what the real harness scores, so improving the
/// score means improving the real harness.
enum CodexSwiftSession {
    static func run(task: TaskSpec, workspace: URL, containerId: String,
                    runtime: any ContainerRuntime, model: String, timeout: Duration,
                    log: @escaping @Sendable (String) -> Void) async -> AgentRunInfo {
        var info = AgentRunInfo(model: model)
        #if canImport(Network)
        let start = Date()
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
            log("[\(task.id)] OPENAI_API_KEY unset — cannot run agent")
            return info
        }

        // 1. Container transport: the exec-server bridges the engine's remote
        // tool calls (fs/process) to the task's container, workspace mounted at /app.
        let cmdLog = workspace.deletingLastPathComponent().appendingPathComponent("commands.jsonl")
        let server = ContainerExecServer(workspace: workspace.path, mountPoint: "/app",
                                         runtime: runtime, containerId: containerId, commandLog: cmdLog)
        let wsURL: String
        do { wsURL = try await server.start() }
        catch { log("[\(task.id)] exec-server failed: \(error)"); return info }
        defer { server.stop() }
        log("[\(task.id)] exec-server @ \(wsURL)")

        // 2. Engine wiring — IDENTICAL to the production app (codex-session), only
        // the tool transport is remote and a turn deadline is set.
        let codexHome = workspace.deletingLastPathComponent().appendingPathComponent("codexhome").path
        try? FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        guard let store = try? ThreadStore(codexHome: codexHome, limits: Limits()) else {
            log("[\(task.id)] failed to open ThreadStore"); return info
        }
        var limits = Limits()
        limits.turnDeadline = timeout
        // BUG FIX: the default `maxSamplingIterationsPerTurn` LoopGuard is 100, which
        // force-FAILS a turn ("sampling loop guard fired") after 100 sample->tool
        // iterations. Deep-swe tasks are long-horizon and meant to be bounded by the
        // TIME budget (agent.timeout_sec, default 5400s ≈ 90min) — but at ~8s/iter the
        // 100-cap fires after only ~13min, truncating the agent mid-task (observed:
        // both tasks stopped at EXACTLY 100 iters well before the deadline). The turn
        // deadline + `maxIdenticalToolRepeats` (64) already bound true runaway loops,
        // so raise the iteration cap to its safe ceiling (1000) and let the deadline
        // be the binding constraint. Override via CODEX_BENCH_MAX_ITERS.
        limits.maxSamplingIterationsPerTurn =
            ProcessInfo.processInfo.environment["CODEX_BENCH_MAX_ITERS"].flatMap(Int.init) ?? 1000
        // Model-facing exec-output budget: codex uses a per-model TruncationPolicy
        // (~10KB head+tail for gpt-5.x, keeping the failing assertion visible); the
        // port's flat 1 MiB default lets one test/grep flood the window and trigger
        // premature compaction that evicts the spec. Set the codex gpt-5.x value.
        // (TODO: derive per-model from models.json truncation_policy in the engine.)
        limits.maxToolOutputBytes = 10_000
        limits = limits.clamped()

        // The real remote tool surface the app registers when remoteEnvironment is
        // set (codex-session/main.swift). NOT a hand-picked subset.
        let router = ToolRouter(limits: limits)
        await RemoteExecServerTools.register(on: router, websocketURL: wsURL, limits: limits)
        // update_plan is a LOCAL planning tool (no remote exec) the real app
        // registers via DefaultTools and the gpt-5.x prompt references for
        // multi-step work; the remote tool set omits it, so register it here to
        // match the real agent's surface.
        await router.register(UpdatePlanTool())

        let modelClient = URLSessionResponsesClient(apiKey: apiKey, limits: limits)

        // Reasoning effort: model DEFAULT (nil) unless explicitly overridden, exactly
        // like the app. CODEX_BENCH_EFFORT lets us measure effort sweeps without
        // changing default behavior.
        let effort = ProcessInfo.processInfo.environment["CODEX_BENCH_EFFORT"]
        let tid = ThreadId("thr_bench_" + sanitize(task.id) + "_" + String(UInt16.random(in: 0...0xFFFF), radix: 16))
        let config = SessionConfig(
            threadId: tid, cwd: "/app", model: model,
            sandboxMode: .dangerFullAccess,    // tools execute remotely in the container; host sandbox is moot
            remoteEnvironment: .init(environmentId: "container", execServerUrl: wsURL),
            reasoningEffort: (effort?.isEmpty == false) ? effort : nil)
        // baseInstructions defaults to nil ⇒ the engine sends codex's real
        // model-selected system prompt (gpt-5.5 base_instructions).

        // Auto-compact near the model's real context limit (compaction rarely
        // fires on these tasks; this mirrors the app's model-aware limit).
        let ctxWindow = model.lowercased().contains("4o") || model.lowercased().contains("4.1") ? 128_000 : 272_000
        let autoCompact = Int(Double(ctxWindow) * 0.85)
        let engine = SessionEngine(config: config, model: modelClient, store: store,
                                   router: router, limits: limits,
                                   autoCompactTokens: autoCompact, workflowsEnabled: false)

        // 3. Drive ONE turn with ONLY the task instruction as the user message —
        // exactly what a real user/SWE-harness sends. codex's system prompt drives
        // the agent to resolve the task fully within the turn before yielding.
        await engine.start()
        let stream = await engine.events()
        await engine.submit(.startTurn(input: [TurnInput(text: task.instruction)], model: nil, turnId: nil))

        let overallDeadline = Date().addingTimeInterval(Self.durationSeconds(timeout))
        let tracker = TurnTracker()
        let box = AccBox()
        // Collector: capture token usage; the agent's turn ends naturally when the
        // model stops calling tools (turnCompleted). That is the run — one turn,
        // run to completion, like the real agent. No goals/continuation injection.
        let collector = Task { () -> BenchAcc in
            var acc = BenchAcc()
            for await ev in stream {
                if Date() >= overallDeadline { acc.completed = false; await box.set(acc); return acc }
                switch ev {
                case .tokenUsageUpdated(_, let turnId, let total, _, _):
                    await tracker.set(turnId)
                    acc.inTok = total.inputTokens
                    acc.cachedTok = total.cachedInputTokens
                    acc.outTok = total.outputTokens
                    acc.total = total.totalTokens
                    await box.set(acc)
                case .turnCompleted(_, let turn):
                    acc.turns += 1
                    acc.completed = (turn.status == .completed)
                    log("[\(task.id)] turn complete (status=\(turn.status.rawValue)) tokens(in/out)=\(acc.inTok)/\(acc.outTok)")
                    await box.set(acc); return acc
                default: break
                }
            }
            return acc
        }
        // Deadline safety: interrupt the turn + stop the server at the timeout.
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if let tid = await tracker.get() { await engine.submit(.interrupt(turnId: tid)) }
            try? await Task.sleep(for: .seconds(15))
            server.stop()
        }
        // HARD wall-clock bound: a turn blocked inside the model client (e.g. 429
        // backoff) won't emit events, so the for-await could hang. Race the
        // collector against an absolute deadline and take the last partial.
        let acc: BenchAcc = await withTaskGroup(of: BenchAcc?.self) { g in
            g.addTask { await collector.value }
            g.addTask { try? await Task.sleep(for: timeout + .seconds(90)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            collector.cancel()
            if let a = first { return a }
            log("[\(task.id)] agent phase hit HARD timeout (likely stalled awaiting model) — abandoning")
            return await box.get()
        }
        timer.cancel()
        let q = Task { await engine.quiesce() }
        let qTimer = Task { try? await Task.sleep(for: .seconds(20)); q.cancel() }
        _ = await q.result; qTimer.cancel()

        info.turns = max(acc.turns, 1)
        info.inputTokens = acc.inTok
        info.cachedInputTokens = acc.cachedTok
        info.outputTokens = acc.outTok
        info.totalTokens = acc.total
        info.costUSD = Pricing.cost(model: model, inputTokens: acc.inTok,
                                    cachedInputTokens: acc.cachedTok, outputTokens: acc.outTok)
        info.agentWallSec = Date().timeIntervalSince(start)
        info.completed = acc.completed
        log("[\(task.id)] agent done: completed=\(acc.completed) tokens(in/out)=\(acc.inTok)/\(acc.outTok) \(Int(info.agentWallSec))s")
        #else
        log("[\(task.id)] Network framework unavailable; agent mode requires macOS")
        #endif
        return info
    }

    private static func durationSeconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private static func sanitize(_ s: String) -> String {
        String(s.map { ($0.isLetter || $0.isNumber) ? $0 : "_" }.prefix(32))
    }
}

/// Tracks the live turn id so the deadline timer can interrupt it.
private actor TurnTracker {
    private var id: TurnId?
    func set(_ t: TurnId) { id = t }
    func get() -> TurnId? { id }
}

/// Accumulated per-turn telemetry (file-scope so `AccBox` can publish it).
struct BenchAcc: Sendable {
    var completed = false; var inTok = 0; var cachedTok = 0
    var outTok = 0; var total = 0; var turns = 0; var retries = 0
}

/// Holds the latest partial `BenchAcc` so the hard-timeout path can still report
/// tokens/cost when the collector overruns and is abandoned.
private actor AccBox {
    private var acc = BenchAcc()
    func set(_ a: BenchAcc) { acc = a }
    func get() -> BenchAcc { acc }
}
