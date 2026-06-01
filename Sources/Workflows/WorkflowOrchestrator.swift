import Foundation
import InfraPrimitives
import ProtocolModel

/// Live state for one detached workflow run. Thread-safe (the detached run task
/// and the orchestrator both touch it).
public final class WorkflowRunRecord: @unchecked Sendable {
    public let runId: String
    public let taskId: String
    public let name: String?
    public let abort = AbortFlag()
    public let startTime: Double
    public var task: Task<Void, Never>?

    private let lock = NSLock()
    private var _status = "running"
    private var _logs: [String] = []
    private var _agentsStarted = 0
    private var _agentsDone = 0
    private var _phases: [String] = []
    private var _result: WorkflowRunResult?

    init(runId: String, taskId: String, name: String?, startTime: Double) {
        self.runId = runId; self.taskId = taskId; self.name = name; self.startTime = startTime
    }

    func note(_ p: WorkflowProgress) {
        lock.lock(); defer { lock.unlock() }
        switch p {
        case .log(let m): if _logs.count < 200 { _logs.append(m) }
        case .phase(_, let title, _): if !_phases.contains(title) { _phases.append(title) }
        case .agent(_, _, _, _, let state, _, _, _, _, _, _, _, _, _):
            if state == .start { _agentsStarted += 1 }
            if state == .done || state == .error { _agentsDone += 1 }
        }
    }
    func setStatus(_ s: String) { lock.lock(); _status = s; lock.unlock() }
    func setResult(_ r: WorkflowRunResult) { lock.lock(); _result = r; _status = r.status.rawValue; lock.unlock() }
    public var status: String { lock.lock(); defer { lock.unlock() }; return _status }

    func summaryJSON() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "runId": runId, "taskId": taskId, "name": name as Any? ?? NSNull(),
            "status": _status, "agentsStarted": _agentsStarted, "agentsDone": _agentsDone,
            "phases": _phases, "logTail": Array(_logs.suffix(10)),
            "result": _result?.resultJSON as Any? ?? NSNull(),
            "error": _result?.error as Any? ?? NSNull(),
        ]
    }
}

/// Host-side owner of detached workflow runs. Installs the `WorkflowBus`
/// providers, validates input (the 6-code ladder), launches/stops runs, and
/// reports status. Anchors detached runs the way `AgentOrchestrator` anchors
/// subagents.
public actor WorkflowOrchestrator {
    private let store: WorkflowStore
    private let discovery = WorkflowsDiscovery()
    private let codexHome: String
    private let engine = WorkflowEngine()
    private let runner: WorkflowAgentRunner
    private let defaultModel: String?
    private let env: [String: String]
    private let progressSink: WorkflowProgressNotifier.Sink?
    private var records: [String: WorkflowRunRecord] = [:]   // keyed by runId
    private var idCounter = 0

    /// Outer wall-clock deadline (seconds). Defaults to `WF.runDeadlineSecs`
    /// (3600); overridable via `CODEX_WORKFLOW_DEADLINE_SECS` for ops tuning
    /// and deterministic tests.
    private let deadlineSecs: Int

    public init(store: WorkflowStore, codexHome: String, runner: WorkflowAgentRunner,
                defaultModel: String? = nil,
                env: [String: String] = ProcessInfo.processInfo.environment,
                progressSink: WorkflowProgressNotifier.Sink? = nil) {
        self.store = store; self.codexHome = codexHome; self.runner = runner
        self.defaultModel = defaultModel; self.env = env; self.progressSink = progressSink
        self.deadlineSecs = env["CODEX_WORKFLOW_DEADLINE_SECS"].flatMap { Int($0) }.map { max(1, $0) }
            ?? WF.runDeadlineSecs
    }

    /// Install the bus providers. `self` is captured strongly so the (global)
    /// bus keeps the orchestrator alive for the process; the host should hold
    /// at most one orchestrator and re-install to replace it.
    public func installOnBus(_ bus: WorkflowBus = .shared) async {
        await bus.installValidate { req in await self.validate(req) }
        await bus.installLaunch { req in try await self.launch(req) }
        await bus.installStop { id in await self.stop(id) }
        await bus.installList { await self.listJSON() }
        await bus.installStatus { runId in await self.statusJSON(runId) }
    }

    // MARK: - resolve

    private struct Resolved { var name: String?; var scriptBody: String; var rawSource: String
                              var seedPhases: [String]; var seedPhaseModels: [String: String] }
    private enum ResolveOutcome { case ok(Resolved); case err(String) }

    private func resolveScript(_ req: WorkflowBus.LaunchRequest) -> ResolveOutcome {
        // precedence: scriptPath > name > script
        if let path = req.scriptPath {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return .err("could not read workflow script at \(path)")
            }
            return parse(text, name: nil)
        }
        if let name = req.name {
            guard let def = discovery.resolve(name: name, codexHome: codexHome, cwds: [req.cwd]) else {
                let avail = discovery.discover(codexHome: codexHome, cwds: [req.cwd]).map(\.name).joined(separator: ", ")
                return .err("Workflow \"\(name)\" not found. Available: \(avail)")
            }
            return parse(def.script, name: def.name)
        }
        if let script = req.script {
            return parse(script, name: nil)
        }
        return .err("workflow requires one of `script`, `name`, or `scriptPath`")
    }

    private func parse(_ text: String, name: String?) -> ResolveOutcome {
        do {
            let meta = try WorkflowMeta.parse(text)
            var phaseModels: [String: String] = [:]
            for p in meta.phases { if let m = p.model { phaseModels[p.title] = m } }
            return .ok(Resolved(name: name ?? meta.name, scriptBody: meta.scriptBody,
                                rawSource: text, seedPhases: meta.phases.map(\.title),
                                seedPhaseModels: phaseModels))
        } catch {
            return .err("Invalid workflow script: \(error)")
        }
    }

    // MARK: - validate (6-code ladder)

    public func validate(_ req: WorkflowBus.LaunchRequest) -> WorkflowBus.Validation {
        // code 6 — not enabled
        if !WorkflowGating.isEnabled(env: env) {
            return .init(ok: false, errorCode: 6,
                         message: "Dynamic workflows are not enabled for this session (set CODEX_FEATURE_WORKFLOWS=1 or unset CODEX_WORKFLOWS_DISABLE).")
        }
        // code 1 — resolve error / code 2 — invalid meta
        let resolved: Resolved
        switch resolveScript(req) {
        case .err(let m):
            // distinguish invalid-meta (code 2) from not-found/io (code 1)
            let code = m.hasPrefix("Invalid workflow script") ? 2 : 1
            return .init(ok: false, errorCode: code, message: m)
        case .ok(let r): resolved = r
        }
        // code 4 — determinism violation (all sources: inline, named, disk).
        // The runtime shim also throws, but the static check rejects cleanly
        // up-front regardless of where the script came from.
        if WorkflowDeterminismGuard.violates(resolved.scriptBody) {
            return .init(ok: false, errorCode: 4,
                         message: "Workflow scripts must be deterministic: Date.now()/Math.random()/new Date() are unavailable (they break resume).")
        }
        // syntax check (folds into code 2)
        do { _ = try WorkflowCompiler.compile(scriptBody: resolved.scriptBody) }
        catch { return .init(ok: false, errorCode: 2, message: "Invalid workflow script: \(error)") }
        // code 3 — resume target still running
        if let rid = req.resumeFromRunId, let rec = records[rid], rec.status == "running" {
            return .init(ok: false, errorCode: 3,
                         message: "Workflow \(rid) is still running (task \(rec.taskId)). Stop it first with workflow_stop before resuming.")
        }
        return .valid
    }

    // MARK: - launch

    public func launch(_ req: WorkflowBus.LaunchRequest) async throws -> WorkflowBus.LaunchResponse {
        let v = validate(req)
        guard v.ok else { throw WorkflowBus.WorkflowError.launchFailed(v.message ?? "invalid workflow input") }
        guard case .ok(let resolved) = resolveScript(req) else {
            throw WorkflowBus.WorkflowError.launchFailed("resolve failed")
        }

        let runId = req.resumeFromRunId ?? newRunId()
        let taskId = "task_" + runId
        let now = Date().timeIntervalSince1970

        // resume: load journal index; block if still running
        var journalIndex = JournalIndex()
        if req.resumeFromRunId != nil, let jp = try? store.journalPath(runId) {
            journalIndex = WorkflowJournal.loadIndex(path: jp)
        }
        store.persistScript(resolved.rawSource, slug: resolved.name ?? "workflow", runId: runId)
        let journal = WorkflowJournal(path: (try? store.journalPath(runId)) ?? (store.root + "/runs/\(runId)/journal.jsonl"))

        let record = WorkflowRunRecord(runId: runId, taskId: taskId, name: resolved.name, startTime: now)
        records[runId] = record

        let runner = self.runner
        let engine = self.engine
        let store = self.store
        let defaultModel = self.defaultModel
        let scriptBody = resolved.scriptBody
        let seedPhases = resolved.seedPhases
        let seedPhaseModels = resolved.seedPhaseModels
        let argsJSON = req.argsJSON
        let cwd = req.cwd
        let name = resolved.name
        let rawSource = resolved.rawSource
        let notifier = progressSink.map {
            WorkflowProgressNotifier(runId: runId, taskId: taskId, sink: $0)
        }
        // One scope shared by this run and every nested workflow() child:
        // concurrency, the agent-count cap, and the token budget pool.
        let scope = WorkflowRunScope(budgetTotal: req.budget)
        let deadline = deadlineSecs

        record.task = Task.detached { [weak self] in
            // Strong ref only for the run's duration (released when the task
            // ends) — avoids a permanent records→task→self retain cycle.
            guard let me = self else { return }
            let progress: @Sendable (WorkflowProgress) -> Void = { p in
                record.note(p)
                if let n = notifier { Task { await n.enqueue(p) } }
            }
            // Outer wall-clock deadline: trips the abort latch so the engine
            // pump unwinds and the run is reported `killed` (WF.runDeadlineSecs).
            let deadlineTask = Task {
                try? await Task.sleep(for: .seconds(deadline))
                record.abort.set()
            }
            defer { deadlineTask.cancel() }
            let opts = WorkflowEngine.RunOpts(
                runId: runId, cwd: cwd, argsJSON: argsJSON,
                budgetTotal: req.budget, defaultModel: defaultModel,
                seedPhaseTitles: seedPhases, seedPhaseModels: seedPhaseModels,
                allowNested: true, scope: scope,
                journalIndex: journalIndex, abort: record.abort, progress: progress,
                runAgent: { spec in await runner.runAgent(spec) },
                journalStarted: { key, id in await journal.appendStarted(key: key, agentId: id) },
                journalResult: { key, id, json in await journal.appendResult(key: key, agentId: id, resultJSON: json) },
                resolveNested: { ref, childArgs in
                    await me.runNested(ref: ref, argsJSON: childArgs, cwd: cwd,
                                       runner: runner, engine: engine, defaultModel: defaultModel,
                                       abort: record.abort, scope: scope, parentProgress: progress)
                })
            let result = await engine.runWorkflow(scriptBody: scriptBody, opts: opts)
            record.setResult(result)
            await notifier?.flushNow()
            await me.writeSnapshot(record: record, result: result, name: name,
                                   rawSource: rawSource, store: store)
        }

        return WorkflowBus.LaunchResponse(
            runId: runId, taskId: taskId, status: "async_launched",
            summary: name.map { "launched workflow \"\($0)\"" } ?? "launched inline workflow",
            transcriptDir: (try? store.runDir(runId)),
            scriptPath: store.root + "/scripts/\((name ?? "workflow"))-\(runId).js")
    }

    private func runNested(ref: String, argsJSON: String?, cwd: String,
                           runner: WorkflowAgentRunner, engine: WorkflowEngine,
                           defaultModel: String?, abort: AbortFlag,
                           scope: WorkflowRunScope,
                           parentProgress: @escaping @Sendable (WorkflowProgress) -> Void) async -> WorkflowAgentOutcome {
        // Resolve the child by name (or treat ref as an inline script).
        let text: String
        if let def = discovery.resolve(name: ref, codexHome: codexHome, cwds: [cwd]) {
            text = def.script
        } else if FileManager.default.fileExists(atPath: ref),
                  let t = try? String(contentsOfFile: ref, encoding: .utf8) {
            text = t
        } else {
            return .failure("workflow(\(ref)): no such workflow")
        }
        guard let meta = try? WorkflowMeta.parse(text) else {
            return .failure("workflow(\(ref)): invalid script")
        }
        let childName = meta.name
        // Child progress is surfaced under a single "[name]" group: its agents
        // and logs are prefixed. The child engine emits no phases of its own
        // (child phase() is a no-op), so there are no child .phase indices to
        // collide with the parent's; a .phase here would only arrive if forced.
        let childProgress: @Sendable (WorkflowProgress) -> Void = { p in
            switch p {
            case .log(let m): parentProgress(.log(message: "[\(childName)] \(m)"))
            case .phase(let i, let title, _): parentProgress(.phase(index: i, title: "[\(childName)] \(title)", kind: "nested"))
            case .agent(let i, let label, let pi, let pt, let st, let c, let sk, let e, let tk, let tc, let d, let m, let at, let pp):
                parentProgress(.agent(index: i, label: "[\(childName)] \(label)", phaseIndex: pi,
                                      phaseTitle: pt.isEmpty ? childName : pt, state: st, cached: c, skipped: sk, error: e,
                                      tokens: tk, toolCalls: tc, durationMs: d, model: m, attempt: at,
                                      promptPreview: pp))
            }
        }
        let childRunId = newRunId()
        // No seeded phases for a nested child (phase() is a no-op) and the
        // shared scope carries concurrency/budget/agent-cap from the parent.
        let opts = WorkflowEngine.RunOpts(
            runId: childRunId, cwd: cwd, argsJSON: argsJSON, budgetTotal: scope.budgetTotal,
            defaultModel: defaultModel, seedPhaseTitles: [], seedPhaseModels: [:],
            allowNested: false, scope: scope,
            journalIndex: JournalIndex(), abort: abort, progress: childProgress,
            runAgent: { spec in await runner.runAgent(spec) })
        let result = await engine.runWorkflow(scriptBody: meta.scriptBody, opts: opts)
        if let err = result.error { return .failure("workflow(\(ref)) failed: \(err)") }
        return .value(result.resultJSON ?? "null")
    }

    // MARK: - stop / list / status

    public func stop(_ idOrRunId: String) -> String {
        // accept runId or taskId
        let rec = records[idOrRunId] ?? records.values.first { $0.taskId == idOrRunId }
        guard let rec else { return jsonObj(["error": "no such workflow run: \(idOrRunId)"]) }
        rec.abort.set()
        rec.setStatus("killed")
        return jsonObj(["stopped": rec.runId, "status": "killed"])
    }

    public func listJSON() -> String {
        var live = records.values.map { $0.summaryJSON() }
        // merge on-disk snapshots not currently live
        let liveIds = Set(records.keys)
        for snap in store.readSnapshots() where !(snap["runId"] as? String).map({ liveIds.contains($0) }).orFalse() {
            live.append(["runId": snap["runId"] as Any? ?? NSNull(),
                         "name": snap["workflowName"] as Any? ?? NSNull(),
                         "status": snap["status"] as Any? ?? "completed",
                         "result": snap["result"] as Any? ?? NSNull()])
        }
        return jsonArr(live)
    }

    public func statusJSON(_ runId: String) -> String {
        if let rec = records[runId] { return jsonObj(rec.summaryJSON()) }
        if let snap = store.readSnapshots().first(where: { ($0["runId"] as? String) == runId }) {
            return jsonObj(snap)
        }
        return jsonObj(["error": "no such workflow run: \(runId)"])
    }

    // MARK: - snapshot

    private func writeSnapshot(record: WorkflowRunRecord, result: WorkflowRunResult,
                               name: String?, rawSource: String, store: WorkflowStore) {
        var snap: [String: Any] = [
            "runId": record.runId, "taskId": record.taskId, "status": result.status.rawValue,
            "startTime": record.startTime, "timestamp": Date().timeIntervalSince1970,
            "agentCount": result.agentCount, "durationMs": result.durationMs,
            "logs": result.logs, "totalTokens": result.totalTokens,
            "totalToolCalls": result.totalToolCalls, "script": rawSource,
        ]
        if let n = name { snap["workflowName"] = n }
        if let r = result.resultJSON,
           let v = try? JSONSerialization.jsonObject(with: Data(r.utf8), options: [.fragmentsAllowed]) {
            snap["result"] = v
        }
        if let e = result.error { snap["error"] = e }
        if !result.failures.isEmpty { snap["failures"] = result.failures }
        store.writeSnapshot(snap, runId: record.runId)
    }

    // MARK: - helpers

    private func newRunId() -> String {
        idCounter += 1
        let raw = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return "wf_" + String(raw.prefix(12))
    }
    private func jsonObj(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    private func jsonArr(_ a: [[String: Any]]) -> String {
        (try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

private extension Optional where Wrapped == Bool {
    func orFalse() -> Bool { self ?? false }
}

/// Process-global strong reference to the live orchestrator. The `WorkflowBus`
/// providers capture `self` strongly, but the host should also hold the
/// orchestrator here so it (and the bus closures) survive past the bootstrap
/// scope that created it.
public final class WorkflowHolder: @unchecked Sendable {
    public static let shared = WorkflowHolder()
    private let lock = NSLock()
    private var orchestrator: WorkflowOrchestrator?
    public func set(_ o: WorkflowOrchestrator) { lock.lock(); orchestrator = o; lock.unlock() }
    public var current: WorkflowOrchestrator? { lock.lock(); defer { lock.unlock() }; return orchestrator }
}
