import Foundation
import ProtocolModel
import ModelClient
import Persistence
import Tools
import HarnessCore
import InfraPrimitives

/// Captures the arguments of a `final_answer` tool call (the GPT analog of
/// Claude's forced `StructuredOutput` tool).
final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var json: String?
    func set(_ s: String) { lock.lock(); json = s; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return json }
}

/// `final_answer` — schema-forced structured output for a workflow subagent.
/// Its `jsonSchema` (parameters) IS the caller's `agent({schema})`, so the model
/// is told to emit exactly that shape.
///
/// Validation happens HERE, at the tool boundary: the submitted arguments are
/// checked against the schema and a nonconforming submission is rejected with a
/// `success:false` result that lists the violations. The subagent sees that
/// failure mid-turn and retries; the capture box is only ever set with a
/// schema-valid object, so the orchestration script receives validated data and
/// nothing else (WORKFLOW.md "the type boundary stops at the schema").
struct FinalAnswerTool: Tool {
    let name = "final_answer"
    let parallelSafe = false
    var toolDescription: String {
        "Submit your FINAL structured answer for this task. Call this exactly once, when you are done. The arguments must match the required schema."
    }
    let schema: String
    var jsonSchema: String { schema }
    let box: CaptureBox
    func run(_ call: ToolCall, cwd _: String) async throws -> ToolResult {
        let violations = WorkflowSchemaValidator.validate(instanceJSON: call.argumentsJSON,
                                                          schemaJSON: schema)
        guard violations.isEmpty else {
            let msg = "Your final_answer arguments do not match the required schema. "
                + "Fix them and call final_answer again:\n- " + violations.joined(separator: "\n- ")
            let out = (try? JSONSerialization.data(withJSONObject: ["accepted": false, "error": msg],
                                                   options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"accepted":false}"#
            return ToolResult(callId: call.callId, output: out, success: false, truncated: false)
        }
        box.set(call.argumentsJSON)
        return ToolResult(callId: call.callId, output: #"{"accepted":true}"#,
                          success: true, truncated: false)
    }
}

/// Mutable, lock-guarded box for the per-turn watchdog clock + observed counters.
private final class TurnObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastEventAt = Date()
    private var _outputTokens = 0
    private var _toolCalls = 0
    private var _lastText = ""
    func touch() { lock.lock(); _lastEventAt = Date(); lock.unlock() }
    func setTokens(_ n: Int) { lock.lock(); _outputTokens = n; lock.unlock() }
    func bumpToolCalls() { lock.lock(); _toolCalls += 1; lock.unlock() }
    func setText(_ s: String) { lock.lock(); _lastText = s; lock.unlock() }
    var idleMs: Int { lock.lock(); defer { lock.unlock() }; return Int(Date().timeIntervalSince(_lastEventAt) * 1000) }
    var outputTokens: Int { lock.lock(); defer { lock.unlock() }; return _outputTokens }
    var toolCalls: Int { lock.lock(); defer { lock.unlock() }; return _toolCalls }
    var text: String { lock.lock(); defer { lock.unlock() }; return _lastText }
}

/// Drives one GPT subagent per `agent()` call via a `SessionEngine`, with
/// schema-forced output, a fine-grained stall watchdog + throttle backoff,
/// stall-retry loop, per-agent model, and optional git worktree isolation.
/// Faithful analog of Claude's local subagent runner (`S`).
public struct WorkflowAgentRunner: Sendable {
    let store: ThreadStore
    let limits: Limits
    let model: any ModelClient
    let routerFactory: @Sendable (_ cwd: String, _ extra: [any Tool]) async -> ToolRouter
    let collectTimeout: Duration
    /// Serializes worktree creation (Claude runs worktree setup at concurrency 1).
    private let worktreeGate = WorkflowSemaphore(1)

    public init(store: ThreadStore, limits: Limits, model: any ModelClient,
                routerFactory: @escaping @Sendable (_ cwd: String, _ extra: [any Tool]) async -> ToolRouter,
                collectTimeout: Duration = .seconds(600)) {
        self.store = store; self.limits = limits; self.model = model
        self.routerFactory = routerFactory; self.collectTimeout = collectTimeout
    }

    public func runAgent(_ spec: WorkflowAgentSpec) async -> WorkflowAgentOutcome {
        if spec.opts.isolation == "remote" {
            return .failure("agent({isolation:'remote'}) is not available in this build.")
        }

        // Worktree isolation setup (serialized).
        var effectiveCwd = spec.cwd
        var worktree: WorkflowWorktree.Handle?
        var isolationNotice = ""
        if spec.opts.isolation == "worktree" {
            await worktreeGate.acquire()
            worktree = await WorkflowWorktree.create(runId: spec.runId, index: spec.index, cwd: spec.cwd)
            await worktreeGate.release()
            if let h = worktree {
                effectiveCwd = h.path
                isolationNotice = WorkflowWorktree.isolationNotice(path: h.path, mainCwd: spec.cwd)
            }
        }
        defer {
            if let h = worktree {
                // auto-remove if unchanged (keep it for inspection if the agent
                // left edits behind).
                Task.detached { if await !WorkflowWorktree.hasChanges(h) { await WorkflowWorktree.remove(h) } }
            }
        }

        let started = Date()
        let schema = spec.opts.schemaJSON
        let box = CaptureBox()
        let extraTools: [any Tool] = schema.map { [FinalAnswerTool(schema: $0, box: box)] } ?? []
        let framed = framedPrompt(spec, hasSchema: schema != nil) + isolationNotice
        let chosenModel = spec.opts.model ?? spec.defaultModel

        var totalTokens = 0
        var totalToolCalls = 0
        var attempt = 0
        var throttleRetried = false
        var lastText = ""

        while attempt < max(1, WF.maxStallRetries) {
            attempt += 1
            let prompt = attempt == 1 ? framed : nudgePrompt(framed, hasSchema: schema != nil)
            let t = await runTurn(prompt: prompt, model: chosenModel, cwd: effectiveCwd,
                                  extraTools: extraTools, stallMs: spec.stallMs)
            totalTokens += t.outputTokens
            totalToolCalls += t.toolCalls
            lastText = t.text

            // schema mode: success the moment final_answer is captured (even if
            // the turn itself then stalled).
            if let captured = box.value {
                return .value(captured, tokens: totalTokens, toolCalls: totalToolCalls,
                              durationMs: ms(started), attempts: attempt)
            }

            if t.stalled {
                // stall-retry loop (no sleep; up to WF.maxStallRetries).
                continue
            }

            if schema == nil {
                // throttle heuristic: tiny output, slow turn → likely a throttled
                // / degraded response. Sleep once, then retry.
                let throttled = t.completed && t.outputTokens < WF.throttleMinOutputTokens
                    && t.durationMs > spec.stallMs / 2
                if throttled && !throttleRetried {
                    throttleRetried = true
                    try? await Task.sleep(for: .milliseconds(WF.throttleSleepMs))
                    continue
                }
                if t.completed { return .value(jsonStringify(t.text), tokens: totalTokens,
                                               toolCalls: totalToolCalls, durationMs: ms(started),
                                               attempts: attempt) }
                // not completed (failed/aborted) and not stalled → retry.
                continue
            }
            // schema mode, no capture, not stalled → nudge-retry.
        }

        if schema != nil {
            return .failure("agent({schema}): subagent completed without calling final_answer after \(WF.maxStallRetries) attempts")
        }
        return .value(jsonStringify(lastText), tokens: totalTokens, toolCalls: totalToolCalls,
                      durationMs: ms(started), attempts: attempt)
    }

    // MARK: - one turn (with fine-grained stall watchdog)

    private struct TurnResult { var text: String; var completed: Bool; var stalled: Bool
                                var outputTokens: Int; var toolCalls: Int; var durationMs: Int }

    private func runTurn(prompt: String, model chosenModel: String?, cwd: String,
                         extraTools: [any Tool], stallMs: Int) async -> TurnResult {
        let turnStart = Date()
        let sanitized = String("wf_\(UUID().uuidString)".map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber)) ? c : "_"
        })
        let tid = ThreadId("thr_" + sanitized)
        let cfg = SessionConfig(threadId: tid, cwd: cwd,
                                model: chosenModel ?? "gpt-5.5", ephemeral: true)
        _ = try? await store.create(cfg)
        let router = await routerFactory(cwd, extraTools)
        let engine = SessionEngine(config: cfg, model: model, store: store,
                                   router: router, limits: limits)
        await engine.start()
        let stream = await engine.events()

        let obs = TurnObservation()

        let collector = Task { () -> (text: String, completed: Bool) in
            var last = ""
            for await ev in stream {
                if Task.isCancelled { break }
                obs.touch()
                switch ev {
                case .itemCompleted(_, _, let item, _):
                    if case .agentMessage(_, let text) = item { last = text; obs.setText(text) }
                    else { obs.bumpToolCalls() }
                case .tokenUsageUpdated(_, _, let total, _, _):
                    obs.setTokens(total.outputTokens)
                case .turnCompleted(_, let turn):
                    return (last, turn.status == .completed)
                default:
                    continue
                }
            }
            return (last, false)
        }

        // Fine-grained stall watchdog: re-armed on every event (via `obs.touch`),
        // checked on a short cadence; fires when no progress for `stallMs`.
        let armEvery = min(max(stallMs / 10, 100), 1000)
        let watchdog = Task { () -> Bool in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(armEvery))
                if obs.idleMs >= stallMs { return true }   // stalled
            }
            return false
        }
        // Coarse overall ceiling.
        let ceiling = Task {
            try? await Task.sleep(for: collectTimeout)
            collector.cancel()
        }

        // Race the collector against the watchdog.
        let stalledTask = Task { () -> Bool in
            let s = await watchdog.value
            if s { collector.cancel() }
            return s
        }

        // Kick off the turn (now that the event collector is attached).
        await engine.submit(.startTurn(input: [TurnInput(text: prompt)], model: chosenModel, turnId: nil))

        let (text, completed) = await collector.value
        watchdog.cancel()
        ceiling.cancel()
        let stalled = (await stalledTask.value) && !completed
        await engine.quiesce()

        return TurnResult(text: obs.text.isEmpty ? text : obs.text, completed: completed,
                          stalled: stalled, outputTokens: obs.outputTokens,
                          toolCalls: obs.toolCalls, durationMs: Int(Date().timeIntervalSince(turnStart) * 1000))
    }

    // MARK: - prompt framing

    private func framedPrompt(_ spec: WorkflowAgentSpec, hasSchema: Bool) -> String {
        var preamble = """
        You are a focused sub-agent inside a larger automated workflow. Complete the task below \
        independently and thoroughly. You have the normal tool set available. Your final message \
        is consumed programmatically by the orchestrator — return the requested result directly, \
        with no preamble or chatter.
        """
        if hasSchema {
            preamble += """


            IMPORTANT: When you are done, you MUST call the `final_answer` tool EXACTLY ONCE with \
            arguments that match the required schema. Do not put the answer in a normal message — \
            the orchestrator only reads the `final_answer` arguments.
            """
        }
        return preamble + "\n\n--- TASK ---\n" + spec.prompt
    }

    private func nudgePrompt(_ framed: String, hasSchema: Bool) -> String {
        if hasSchema {
            return "You did not call the `final_answer` tool. You MUST call it exactly once now with arguments matching the schema.\n\n" + framed
        }
        return framed
    }

    // MARK: - helpers

    private func jsonStringify(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let str = String(data: d, encoding: .utf8) { return String(str.dropFirst().dropLast()) }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
    private func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}
