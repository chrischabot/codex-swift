import Foundation

/// Runs a single task end-to-end: resolve image → clone workspace → start
/// container → (agent | reference | empty) → verify → score. Any throw becomes a
/// `.error` TaskResult rather than sinking the whole run.
public struct TaskRunner: Sendable {
    public let runtime: any ContainerRuntime
    public let resolver: ImageResolver
    public let verifier: Verifier
    public let agent: any AgentDriving
    public let paths: BenchPaths

    public init(runtime: any ContainerRuntime, paths: BenchPaths, agent: any AgentDriving) {
        self.runtime = runtime
        self.paths = paths
        self.resolver = ImageResolver(runtime: runtime, paths: paths)
        self.verifier = Verifier(runtime: runtime)
        self.agent = agent
    }

    public func run(task: TaskSpec, mode: AgentMode, model: String,
                    judge: Bool = false, quality: Bool = false, attempt: Int = 1, attempts: Int = 1,
                    runDir: URL, log: @escaping @Sendable (String) -> Void) async -> TaskResult {
        let start = Date()
        // Distinct output dir + container names per attempt so concurrent
        // attempts of the same task never collide.
        let outName = attempts > 1 ? "\(task.id)__a\(attempt)" : task.id
        let taskOut = runDir.appendingPathComponent("tasks/\(outName)", isDirectory: true)
        let workspace = taskOut.appendingPathComponent("workspace", isDirectory: true)
        let logsDir = taskOut.appendingPathComponent("logs", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        func result(_ status: TaskStatus, reward: Int, verifier: VerifierOutcome? = nil,
                    agent: AgentRunInfo? = nil, quality: QualityScore? = nil,
                    judge: JudgeVerdict? = nil, error: String? = nil) -> TaskResult {
            TaskResult(taskId: task.id, attempt: attempt, extId: task.extId, language: task.language,
                       category: task.category, mode: mode, status: status, reward: reward,
                       verifier: verifier, agent: agent, quality: quality, judge: judge,
                       wallTimeSec: Date().timeIntervalSince(start), error: error)
        }

        var liveContainers: [String] = []
        defer { for cid in liveContainers { let r = cid; Task { await runtime.remove(r) } } }

        do {
            log("[\(task.id)] resolving image…")
            let image = try await resolver.ensureImage(task, log: log)
            let template = try await resolver.ensureTemplate(task, image: image, log: log)

            log("[\(task.id)] cloning workspace (APFS clonefile)…")
            try Workspace.clone(from: template, to: workspace)

            // WORK container: the agent only sees /app. It must NOT see /tests
            // (the hidden grading tests) or /logs. Reference mode adds /solution.
            var workMounts = [Mount(workspace.path, "/app")]
            if mode == .reference { workMounts.append(Mount(task.taskDir + "/solution", "/solution")) }
            // Give the AGENT fast search tools (rg/fd) — best-effort; never the
            // verifier (keep grading pristine).
            let toolsDir = (mode == .agent)
                ? await ToolsProvisioner.shared.ensure(cacheRoot: paths.cacheRoot, log: log) : nil
            if let toolsDir { workMounts.append(Mount(toolsDir.path, "/opt/cbtools")) }
            // Honor the task's memory envelope (some tasks — e.g. bounded-memory
            // ones — assert behavior that depends on it); give generous CPUs for
            // build/test speed.
            let cpus = max(task.cpus, 4)
            let memMB = max(task.memoryMB, 2048)
            let workName = Self.sanitize("cb-\(task.extId)-a\(attempt)-work")
            await runtime.remove(workName)
            let workId = try await runtime.startDetached(image: image, mounts: workMounts,
                                                         network: .none, name: workName,
                                                         cpus: cpus, memoryMB: memMB)
            liveContainers.append(workId)
            if toolsDir != nil {   // link rg/fd onto PATH without shadowing existing bins
                _ = await runtime.exec(workId, workdir: "/app", env: [:],
                    command: ["bash", "-lc", "for t in rg fd; do [ -x /opt/cbtools/$t ] && ln -sf /opt/cbtools/$t /usr/local/bin/$t; done; true"],
                    timeout: .seconds(20))
            }

            var agentInfo: AgentRunInfo?
            switch mode {
            case .empty:
                break
            case .reference:
                log("[\(task.id)] applying reference solution…")
                let r = await runtime.exec(workId, workdir: "/app", env: [:],
                                           command: ["bash", "/solution/solve.sh"],
                                           timeout: .seconds(300))
                if !r.ok {
                    return result(.error, reward: 0,
                                  error: "solve.sh failed: \(String((r.stderr + r.stdout).suffix(300)))")
                }
            case .agent:
                log("[\(task.id)] running codex-swift agent…")
                // `CODEX_BENCH_AGENT_TIMEOUT` (seconds) caps the agent turn —
                // handy for smoke runs; defaults to the task's full budget.
                let agentTimeout = ProcessInfo.processInfo.environment["CODEX_BENCH_AGENT_TIMEOUT"]
                    .flatMap(Double.init) ?? task.agentTimeoutSec
                agentInfo = await agent.solve(task: task, workspace: workspace, containerId: workId,
                                              runtime: runtime, model: model,
                                              timeout: .seconds(agentTimeout), log: log)
            }

            // Tear down the work container BEFORE grading — this kills any
            // processes the agent left running in-guest (e.g. a deadlocked
            // `go test`) that would otherwise hang/poison the verifier. The
            // agent's edits live on the host workspace clone, so a fresh
            // container sees them.
            await runtime.remove(workId)
            liveContainers.removeAll { $0 == workId }

            log("[\(task.id)] verifying (fresh container)…")
            let verName = Self.sanitize("cb-\(task.extId)-a\(attempt)-ver")
            await runtime.remove(verName)
            let verMounts = [Mount(workspace.path, "/app"),
                             Mount(task.taskDir + "/tests", "/tests"),
                             Mount(logsDir.path, "/logs")]
            let verId = try await runtime.startDetached(image: image, mounts: verMounts,
                                                        network: .none, name: verName,
                                                        cpus: cpus, memoryMB: memMB)
            liveContainers.append(verId)
            let outcome = await verifier.run(containerId: verId, hostLogsDir: logsDir, task: task)
            // Report the diff size the verifier actually captured (not a separate
            // git pass, which could race the agent and leave a stale index.lock).
            if var info = agentInfo { info.diffBytes = outcome.modelPatchBytes; agentInfo = info }
            let status: TaskStatus = outcome.timedOut ? .timeout : (outcome.reward == 1 ? .passed : .failed)
            log("[\(task.id)] reward=\(outcome.reward) (base=\(outcome.baseExit.map(String.init) ?? "?") new=\(outcome.newExit.map(String.init) ?? "?"))")

            let modelPatch = logsDir.appendingPathComponent("artifacts/model.patch").path
            var q: QualityScore?
            if quality { q = QualityScorer().score(task: task, modelPatchPath: modelPatch, verifier: outcome) }
            var j: JudgeVerdict?
            if judge {
                log("[\(task.id)] judging (codex CLI)…")
                j = await LLMJudge().judge(task: task, modelPatchPath: modelPatch, verifier: outcome, log: log)
            }
            // Persist a readable transcript for mining (agent mode).
            if mode == .agent, let roll = TranscriptRenderer.findRollout(taskDir: taskOut) {
                try? Data(TranscriptRenderer.render(rollout: roll).utf8)
                    .write(to: taskOut.appendingPathComponent("transcript.md"))
            }
            return result(status, reward: outcome.reward, verifier: outcome,
                          agent: agentInfo, quality: q, judge: j)
        } catch {
            log("[\(task.id)] ERROR: \(error)")
            return result(.error, reward: 0, error: "\(error)")
        }
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = s.lowercased().map { ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" }
        return String(allowed.prefix(58))
    }
}
