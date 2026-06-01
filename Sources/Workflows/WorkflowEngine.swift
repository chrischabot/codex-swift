import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Bounded async semaphore for the subagent concurrency cap.
actor WorkflowSemaphore {
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

/// The JavaScriptCore orchestration runtime. Runs a compiled workflow script,
/// exposing `agent()/parallel()/pipeline()/phase()/log()/budget/workflow()`
/// over two native bridges, and drives subagent fan-out via a faithful Promise
/// pump: `agent()`/`workflow()` return real JS Promises whose resolve/reject
/// are captured Swift-side; a pump runs each wave of queued work concurrently
/// then resolves the promises on the JS thread, advancing the script. This
/// reproduces Claude's `parallel`/`pipeline` semantics (including independent
/// pipeline stage chains) without a fidelity gap.
public final class WorkflowEngine: Sendable {

    public struct RunOpts: Sendable {
        public var runId: String
        public var cwd: String
        public var argsJSON: String?
        public var budgetTotal: Int?
        public var defaultModel: String?
        public var seedPhaseTitles: [String]
        /// Per-phase default model from `meta.phases[].model`, keyed by title.
        public var seedPhaseModels: [String: String]
        public var allowNested: Bool
        /// Shared concurrency/budget/agent-cap pool. Top-level runs leave this
        /// nil (a fresh scope is derived from `budgetTotal`); nested runs pass
        /// the parent's scope so resources are shared across the tree.
        public var scope: WorkflowRunScope?
        public var journalIndex: JournalIndex
        public var abort: AbortFlag
        public var progress: (@Sendable (WorkflowProgress) -> Void)?
        public var runAgent: @Sendable (WorkflowAgentSpec) async -> WorkflowAgentOutcome
        public var journalStarted: (@Sendable (String, Int) async -> Void)?
        public var journalResult: (@Sendable (String, Int, String) async -> Void)?
        public var resolveNested: (@Sendable (_ ref: String, _ argsJSON: String?) async -> WorkflowAgentOutcome)?

        public init(runId: String, cwd: String, argsJSON: String? = nil,
                    budgetTotal: Int? = nil, defaultModel: String? = nil,
                    seedPhaseTitles: [String] = [], seedPhaseModels: [String: String] = [:],
                    allowNested: Bool = true, scope: WorkflowRunScope? = nil,
                    journalIndex: JournalIndex = JournalIndex(),
                    abort: AbortFlag = AbortFlag(),
                    progress: (@Sendable (WorkflowProgress) -> Void)? = nil,
                    runAgent: @escaping @Sendable (WorkflowAgentSpec) async -> WorkflowAgentOutcome,
                    journalStarted: (@Sendable (String, Int) async -> Void)? = nil,
                    journalResult: (@Sendable (String, Int, String) async -> Void)? = nil,
                    resolveNested: (@Sendable (String, String?) async -> WorkflowAgentOutcome)? = nil) {
            self.runId = runId; self.cwd = cwd; self.argsJSON = argsJSON
            self.budgetTotal = budgetTotal; self.defaultModel = defaultModel
            self.seedPhaseTitles = seedPhaseTitles; self.seedPhaseModels = seedPhaseModels
            self.allowNested = allowNested; self.scope = scope
            self.journalIndex = journalIndex; self.abort = abort
            self.progress = progress; self.runAgent = runAgent
            self.journalStarted = journalStarted; self.journalResult = journalResult
            self.resolveNested = resolveNested
        }
    }

    public init() {}

    public func runWorkflow(scriptBody: String, opts: RunOpts) async -> WorkflowRunResult {
        #if canImport(JavaScriptCore)
        return await Run(scriptBody: scriptBody, opts: opts).execute()
        #else
        return WorkflowRunResult(status: .failed, resultJSON: nil, agentCount: 0, logs: [],
                                 failures: [], durationMs: 0,
                                 error: "workflows require the JavaScriptCore runtime (macOS build)",
                                 totalTokens: 0, totalToolCalls: 0)
        #endif
    }
}

#if canImport(JavaScriptCore)

/// A single workflow run. Confines all JSContext/JSValue access to `jsQueue`.
final class Run: @unchecked Sendable {
    private enum PendingKind { case agent(WorkflowAgentSpec); case workflow(ref: String, argsJSON: String?) }
    private struct PendingWork { let id: Int; let kind: PendingKind }

    private let scriptBody: String
    private let opts: WorkflowEngine.RunOpts
    private let jsQueue: DispatchQueue
    private let pulse = Pulse()
    private let scope: WorkflowRunScope    // shared across nested children
    private var ctx: JSContext?    // queue-only

    // queue-only state
    private var phaseMap: [String: Int] = [:]
    private var phaseCounter = 0
    private var currentPhaseTitle = ""
    private var currentPhaseIndex = -1
    private var logs: [String] = []
    private var diverged = false
    private var prevKey = ""
    private var nextWorkId = 0
    private var pending: [PendingWork] = []
    private var items: [Int: (resolve: JSValue, reject: JSValue)] = [:]
    private var inFlight = 0
    private var failures: [String] = []

    // budget/spend accounting lives on the shared scope
    private func addSpend(tokens: Int, toolCalls: Int) { scope.addSpend(tokens: tokens, toolCalls: toolCalls) }
    private var spent: Int { scope.spent }
    private var toolCallsTotal: Int { scope.toolCalls }
    private var budgetTotal: Int? { scope.budgetTotal }
    /// True inside a nested `workflow()` child (one-level rule: nested runs are
    /// launched with `allowNested == false`). Drives the child `phase()` no-op
    /// and forces child agents into a single group.
    private var isNested: Bool { !opts.allowNested }

    /// Emit a terminal `.error` progress event for an agent rejected at
    /// dispatch (e.g. budget-capped) — pairs with the `.start` emitted at
    /// registration. Safe to call off the JS queue (progress is `@Sendable`).
    private func emitAgentError(_ spec: WorkflowAgentSpec, message: String) {
        opts.progress?(.agent(index: spec.index, label: spec.label, phaseIndex: spec.phaseIndex,
                              phaseTitle: spec.phaseTitle, state: .error, cached: false,
                              skipped: false, error: message, tokens: 0, toolCalls: 0,
                              durationMs: 0, model: spec.opts.model, attempt: 1,
                              promptPreview: Self.preview(spec.prompt)))
    }

    init(scriptBody: String, opts: WorkflowEngine.RunOpts) {
        self.scriptBody = scriptBody
        self.opts = opts
        self.jsQueue = DispatchQueue(label: "codex.workflow.jsc.\(opts.runId)")
        self.scope = opts.scope ?? WorkflowRunScope(budgetTotal: opts.budgetTotal)
    }

    // Run a closure on the JS queue, awaiting its result. The body receives an
    // OPTIONAL JSContext: after teardown (`ctx = nil`, set on this same serial
    // queue) a late in-flight-agent callback can still be enqueued here, and a
    // force-unwrap (`ctx!`) would crash the whole process. Such late callbacks'
    // results are discarded anyway, so passing nil lets the body no-op safely.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable (JSContext?) -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            jsQueue.async { [self] in c.resume(returning: body(ctx)) }
        }
    }

    func execute() async -> WorkflowRunResult {
        let start = Date()

        let buildOK: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            jsQueue.async { [self] in
                guard let context = JSContext() else { c.resume(returning: false); return }
                ctx = context
                install(context)
                context.evaluateScript(WorkflowJS.determinismShim)
                context.evaluateScript(WorkflowJS.hardeningShim)
                context.evaluateScript(WorkflowJS.prelude(allowNested: opts.allowNested))
                for t in opts.seedPhaseTitles { _ = resolvePhase(t) }
                if let argsJSON = opts.argsJSON {
                    context.evaluateScript("globalThis.args = (function(){ try { return JSON.parse(\(Self.jsStringLiteral(argsJSON))); } catch(e){ return undefined; } })();")
                } else {
                    context.evaluateScript("globalThis.args = undefined;")
                }
                c.resume(returning: context.exception == nil)
            }
        }
        guard buildOK else {
            return WorkflowRunResult(status: .failed, resultJSON: nil, agentCount: 0, logs: [],
                                     failures: [], durationMs: Self.ms(start),
                                     error: "failed to initialize the workflow runtime",
                                     totalTokens: 0, totalToolCalls: 0)
        }

        let wrapped = WorkflowCompiler.wrap(scriptBody)
        let bootstrap = """
        globalThis.__wf_done = false; globalThis.__wf_result = undefined; globalThis.__wf_err = undefined;
        Promise.resolve(\(wrapped)).then(
          function(v){ try { globalThis.__wf_result = (v === undefined ? null : JSON.stringify(v)); } catch(e){ globalThis.__wf_err = 'workflow result is not serializable: ' + String(e); } globalThis.__wf_done = true; },
          function(e){ globalThis.__wf_err = (e && e.message) ? String(e.message) : String(e); globalThis.__wf_done = true; }
        );
        """
        await onQueue { ctx in _ = ctx?.evaluateScript(bootstrap) }

        // Abort watcher: aborts (stop()/deadline) are set on a flag the pump
        // only re-reads at its loop top. When the pump is parked on
        // `pulse.wait()` for an in-flight agent, nothing would wake it until
        // that agent returns — making the deadline a soft bound. Poking the
        // pulse the moment abort is observed turns it into a prompt bound: the
        // pump wakes, sees `abort.isSet`, and returns `.killed`. (An in-flight
        // agent's own Task still runs to completion detached; its result is
        // discarded once `ctx` is torn down.)
        let abortWatcher = Task { [self] in
            while !Task.isCancelled {
                if opts.abort.isSet { await pulse.poke(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await pump()
        abortWatcher.cancel()

        struct Outcome: Sendable { var done: Bool; var result: String?; var err: String? }
        let outcome: Outcome = await onQueue { ctx in
            let done = ctx?.objectForKeyedSubscript("__wf_done")?.toBool() ?? false
            let resVal = ctx?.objectForKeyedSubscript("__wf_result")
            let result: String? = (resVal?.isUndefined == false && resVal?.isNull == false) ? resVal?.toString() : nil
            let errVal = ctx?.objectForKeyedSubscript("__wf_err")
            let err: String? = (errVal?.isUndefined == false && errVal?.isNull == false) ? errVal?.toString() : nil
            return Outcome(done: done, result: result, err: err)
        }
        let logsOut = await onQueue { [self] _ in logs }
        let failuresOut = await onQueue { [self] _ in failures }
        let agentCount = scope.agentCount
        let tokens = spent
        let calls = toolCallsTotal
        await onQueue { [self] _ in ctx = nil }   // tear down on the queue

        let status: WorkflowRunResult.Status
        var errOut = outcome.err
        if opts.abort.isSet {
            status = .killed; if errOut == nil { errOut = "workflow stopped" }
        } else if outcome.err != nil {
            status = .failed
        } else if !outcome.done {
            status = .failed
            errOut = "workflow stalled (no pending work and the script did not complete)"
        } else {
            status = .completed
        }
        return WorkflowRunResult(status: status, resultJSON: outcome.result,
                                 agentCount: agentCount, logs: logsOut, failures: failuresOut,
                                 durationMs: Self.ms(start), error: errOut,
                                 totalTokens: tokens, totalToolCalls: calls)
    }

    // MARK: pump

    private func pump() async {
        while true {
            if opts.abort.isSet { return }
            let (specs, done): ([PendingWork], Bool) = await onQueue { [self] ctx in
                _ = ctx?.evaluateScript("void 0")    // drain microtasks
                let d = ctx?.objectForKeyedSubscript("__wf_done")?.toBool() ?? false
                let taken = pending; pending.removeAll()
                return (taken, d)
            }
            if done { return }
            if specs.isEmpty {
                let busy = await onQueue { [self] _ in inFlight }
                if busy == 0 { return }
                await pulse.wait()
                continue
            }
            for work in specs {
                await onQueue { [self] _ in inFlight += 1 }
                Task { [self] in
                    let outcome: WorkflowAgentOutcome
                    if opts.abort.isSet {
                        outcome = .failure("workflow stopped")
                    } else {
                        switch work.kind {
                        case .agent(let spec):
                            // Only agents draw down the shared concurrency pool.
                            await scope.concurrency.acquire()
                            // Budget gate at DISPATCH (after acquiring a slot).
                            // Under fan-out, an entire wave registers in one JS
                            // turn before any spend resolves, so the
                            // registration-time check sees spent==0 and cannot
                            // bound the wave. Re-checking here caps total
                            // overshoot to the concurrency window — only the
                            // in-flight agents run, matching the spec's "the
                            // ceiling is hard; in-flight agents complete".
                            if let total = budgetTotal, spent >= total {
                                await scope.concurrency.release()
                                let msg = WF.budgetCapMessage(spent: spent, total: total)
                                emitAgentError(spec, message: msg)
                                outcome = .failure(msg)
                            } else {
                                await opts.journalStarted?(spec.cacheKey ?? "", spec.index)
                                let o = await opts.runAgent(spec)
                                // Record spend BEFORE releasing the slot, so the
                                // next agent to acquire sees it and the budget
                                // gate stays honest under concurrency (release
                                // directly resumes the next waiter).
                                addSpend(tokens: o.tokens, toolCalls: o.toolCalls)
                                if o.kind == .value, let key = spec.cacheKey {
                                    await opts.journalResult?(key, spec.index, o.payloadJSON)
                                }
                                await scope.concurrency.release()
                                outcome = o
                            }
                        case .workflow(let ref, let argsJSON):
                            // A nested workflow manages its own agents' slots from
                            // the shared pool; the node itself holds no slot.
                            if let r = opts.resolveNested { outcome = await r(ref, argsJSON) }
                            else { outcome = .failure("workflow(\(ref)) is not available") }
                        }
                    }
                    await onQueue { [self] _ in resolveWork(work.id, outcome: outcome) }
                    await onQueue { [self] _ in inFlight -= 1 }
                    await pulse.poke()
                }
            }
        }
    }

    /// Resolve/reject a pending promise (already on the JS queue), then drain.
    private func resolveWork(_ id: Int, outcome: WorkflowAgentOutcome) {
        guard let context = ctx, let pair = items[id] else { return }
        items[id] = nil
        // NOTE: spend is recorded in the pump (before the concurrency slot is
        // released) so the budget gate stays honest under fan-out; it is NOT
        // re-added here.
        switch outcome.kind {
        case .value:
            let v = Self.jsonToValue(outcome.payloadJSON, ctx: context)
            pair.resolve.call(withArguments: [v as Any])
        case .null:
            pair.resolve.call(withArguments: [JSValue(nullIn: context) as Any])
        case .thrown:
            failures.append(outcome.payloadJSON)
            let err = JSValue(newErrorFromMessage: outcome.payloadJSON, in: context)
            pair.reject.call(withArguments: [err as Any])
        }
        _ = context.evaluateScript("void 0")    // drain microtasks
    }

    // MARK: bridges (installed on the queue)

    private func install(_ context: JSContext) {
        let sync: @convention(block) (String, String) -> String = { [weak self] verb, argsJSON in
            guard let self else { return "null" }
            return self.handleSync(verb: verb, argsJSON: argsJSON)
        }
        context.setObject(sync, forKeyedSubscript: "__wf_sync" as NSString)

        let asyncBridge: @convention(block) (String, String) -> JSValue? = { [weak self] verb, argsJSON in
            guard let self, let cur = JSContext.current() else { return nil }
            return self.handleAsync(verb: verb, argsJSON: argsJSON, ctx: cur)
        }
        context.setObject(asyncBridge, forKeyedSubscript: "__wf_async" as NSString)
    }

    private func handleSync(verb: String, argsJSON: String) -> String {
        let dict = Self.parseObject(argsJSON)
        switch verb {
        case "phase":
            // Child phase() is a no-op (PORT_DESIGN §nesting): a nested run does
            // not create its own phases; all its agents are forced into one
            // child group (surfaced under "[name]" by the orchestrator).
            if isNested { return "0" }
            return String(resolvePhase((dict["title"] as? String) ?? ""))
        case "log":
            let msg = (dict["message"] as? String) ?? ""
            if logs.count < WF.maxLogs { logs.append(msg) }
            else {
                if logs.count >= WF.logRetentionFloor { logs.removeFirst(logs.count - WF.logRetentionFloor + 1) }
                logs.append(msg)
            }
            opts.progress?(.log(message: msg))
            return "null"
        case "budget_total":
            return budgetTotal.map(String.init) ?? "null"
        case "budget_spent":
            return String(spent)
        case "budget_remaining":
            guard let total = budgetTotal else { return "null" }
            return String(max(0, total - spent))
        default:
            return "null"
        }
    }

    private func handleAsync(verb: String, argsJSON: String, ctx cur: JSContext) -> JSValue? {
        var resolveCap: JSValue?
        var rejectCap: JSValue?
        let promise = JSValue(newPromiseIn: cur) { resolve, reject in
            resolveCap = resolve; rejectCap = reject
        }
        guard let resolve = resolveCap, let reject = rejectCap, let promise else { return nil }
        if opts.abort.isSet {
            // Deliberate divergence from the reference's "never-resolves on
            // abort": we REJECT instead. A never-resolving promise hangs the
            // script's await forever; rejecting lets it unwind cleanly. It is
            // safe because the pump checks `abort.isSet` at the top of its loop
            // and returns regardless of whether the script catches this — so a
            // caught rejection cannot keep an aborted run alive. The run is
            // still reported `.killed` (see `execute()`).
            reject.call(withArguments: [JSValue(newErrorFromMessage: "workflow stopped", in: cur) as Any])
            return promise
        }
        let dict = Self.parseObject(argsJSON)
        if verb == "agent" {
            registerAgent(dict: dict, ctx: cur, resolve: resolve, reject: reject)
        } else if verb == "workflow" {
            let id = nextWorkId; nextWorkId += 1
            items[id] = (resolve, reject)
            let ref = (dict["ref"] as? String) ?? ""
            pending.append(PendingWork(id: id, kind: .workflow(ref: ref, argsJSON: Self.reserialize(dict["args"]))))
        } else {
            reject.call(withArguments: [JSValue(newErrorFromMessage: "unknown workflow verb: \(verb)", in: cur) as Any])
        }
        return promise
    }

    private func registerAgent(dict: [String: Any], ctx context: JSContext,
                               resolve: JSValue, reject: JSValue) {
        let idx = scope.nextAgentOrdinal()
        if idx > WF.agentCap {
            reject.call(withArguments: [JSValue(newErrorFromMessage: WF.agentCapMessage(), in: context) as Any])
            return
        }
        if let total = budgetTotal, spent >= total {
            reject.call(withArguments: [JSValue(newErrorFromMessage: WF.budgetCapMessage(spent: spent, total: total), in: context) as Any])
            return
        }
        let prompt = (dict["prompt"] as? String) ?? ""
        let agentOpts = AgentOpts.parse((dict["opts"] as? [String: Any]) ?? [:])
        let label = agentOpts.label ?? Self.previewLabel(prompt)
        // Nested children force every agent into a single group (no per-agent
        // phase, no phase cursor); the orchestrator labels it "[name]".
        let phaseTitle = isNested ? "" : (agentOpts.phase ?? currentPhaseTitle)
        let phaseIndex = isNested ? -1 : (agentOpts.phase.map { resolvePhase($0) } ?? currentPhaseIndex)
        let stallMs = agentOpts.stallMs ?? WF.defaultStallMs
        // Per-phase default model (meta.phases[].model): agent opts.model wins,
        // then the phase's model, then the run default. Applied via spec's
        // defaultModel since the runner resolves `opts.model ?? defaultModel`.
        let effectiveDefaultModel = opts.seedPhaseModels[phaseTitle] ?? opts.defaultModel

        let cacheKey = WorkflowCacheKey.compute(prompt: prompt, opts: agentOpts, prevKey: prevKey)
        prevKey = cacheKey

        if !diverged, let cached = opts.journalIndex.results[cacheKey] {
            opts.progress?(.agent(index: idx, label: label, phaseIndex: phaseIndex,
                                  phaseTitle: phaseTitle, state: .done, cached: true,
                                  skipped: false, error: nil, tokens: 0, toolCalls: 0,
                                  durationMs: 0, model: agentOpts.model, attempt: 1,
                                  promptPreview: Self.preview(prompt)))
            resolve.call(withArguments: [Self.jsonToValue(cached, ctx: context) as Any])
            return
        }
        diverged = true

        opts.progress?(.agent(index: idx, label: label, phaseIndex: phaseIndex,
                              phaseTitle: phaseTitle, state: .start, cached: false,
                              skipped: false, error: nil, tokens: 0, toolCalls: 0,
                              durationMs: 0, model: agentOpts.model, attempt: 1,
                              promptPreview: Self.preview(prompt)))

        let spec = WorkflowAgentSpec(index: idx, prompt: prompt, opts: agentOpts, label: label,
                                     phaseTitle: phaseTitle, phaseIndex: phaseIndex, stallMs: stallMs,
                                     cacheKey: cacheKey, defaultModel: effectiveDefaultModel,
                                     cwd: opts.cwd, runId: opts.runId)
        let id = nextWorkId; nextWorkId += 1
        items[id] = (resolve, reject)
        pending.append(PendingWork(id: id, kind: .agent(spec)))
    }

    private func resolvePhase(_ title: String) -> Int {
        if let i = phaseMap[title] { currentPhaseTitle = title; currentPhaseIndex = i; return i }
        let i = phaseCounter; phaseCounter += 1
        phaseMap[title] = i; currentPhaseTitle = title; currentPhaseIndex = i
        opts.progress?(.phase(index: i, title: title, kind: nil))
        return i
    }

    // MARK: helpers

    static func parseObject(_ json: String) -> [String: Any] {
        guard let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? [String: Any]
        else { return [:] }
        return o
    }
    static func reserialize(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let d = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let s = String(data: d, encoding: .utf8) { return s }
        return nil
    }
    static func jsonToValue(_ json: String, ctx: JSContext) -> JSValue {
        guard let jsonObj = ctx.objectForKeyedSubscript("JSON"),
              let parse = jsonObj.objectForKeyedSubscript("parse"),
              let v = parse.call(withArguments: [json]), !v.isUndefined else {
            return JSValue(nullIn: ctx)
        }
        return v
    }
    static func jsStringLiteral(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let str = String(data: d, encoding: .utf8) { return String(str.dropFirst().dropLast()) }
        return "\"\(s)\""
    }
    static func preview(_ s: String) -> String { String(s.prefix(WF.previewLen)) }
    static func previewLabel(_ s: String) -> String {
        String(s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(WF.labelPreviewLen))
    }
    static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}

#endif
