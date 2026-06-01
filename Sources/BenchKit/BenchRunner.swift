import Foundation

/// Orchestrates a run across many tasks with bounded concurrency, then scores,
/// persists, and reports.
public struct BenchRunner: Sendable {
    public let runtime: any ContainerRuntime
    public let paths: BenchPaths
    public let agent: any AgentDriving

    public init(runtime: any ContainerRuntime, paths: BenchPaths, agent: any AgentDriving) {
        self.runtime = runtime
        self.paths = paths
        self.agent = agent
    }

    public func run(tasks: [TaskSpec], config: RunConfig,
                    log: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        let runDir = paths.runDir(config.runId)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let taskRunner = TaskRunner(runtime: runtime, paths: paths, agent: agent)
        let concurrency = max(1, config.concurrency)
        let attempts = max(1, config.attempts)
        // One work item per (task, attempt) — N attempts/task gives a
        // variance-averaged Pass@1 instead of an n=1 coin flip.
        let work = tasks.flatMap { t in (1...attempts).map { (t, $0) } }
        let indexed = Array(work.enumerated())

        let results = await withTaskGroup(of: (Int, TaskResult).self) { group -> [TaskResult] in
            var collected: [(Int, TaskResult)] = []
            var next = 0
            func launch(_ i: Int, _ t: TaskSpec, _ attempt: Int) {
                group.addTask {
                    (i, await taskRunner.run(task: t, mode: config.mode, model: config.model,
                                             judge: config.judge, quality: config.quality,
                                             attempt: attempt, attempts: attempts,
                                             runDir: runDir, log: log))
                }
            }
            while next < indexed.count && next < concurrency {
                let (i, item) = indexed[next]; next += 1; launch(i, item.0, item.1)
            }
            while let done = await group.next() {
                collected.append(done)
                Self.persistPartial(done.1, runDir: runDir, multiAttempt: attempts > 1)
                if next < indexed.count {
                    let (i, item) = indexed[next]; next += 1; launch(i, item.0, item.1)
                }
            }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        let score = Scorer.summarize(results)
        let run = RunResult(config: config, tasks: results, score: score,
                            caveat: Reporter.caveatBanner)
        try Reporter.write(run, to: runDir)
        log("report: \(runDir.appendingPathComponent("report.md").path)")
        return run
    }

    private static func persistPartial(_ t: TaskResult, runDir: URL, multiAttempt: Bool) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dirName = multiAttempt ? "\(t.taskId)__a\(t.attempt)" : t.taskId
        let url = runDir.appendingPathComponent("tasks/\(dirName)/result.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? enc.encode(t).write(to: url)
    }
}
