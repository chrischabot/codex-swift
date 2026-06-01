import Foundation

public struct ScoreSummary: Sendable, Codable {
    public var n: Int                 // task-attempts scored
    public var resolved: Int          // attempts with reward == 1
    public var pass1: Double          // resolved / n  — variance-averaged Pass@1
    public var wilsonLow: Double
    public var wilsonHigh: Double
    public var waldHalfWidth: Double  // ± for direct comparison to the leaderboard
    public var attempts: Int          // attempts per task
    public var tasksCovered: Int      // distinct tasks
    public var passAtK: Double        // fraction of tasks solved in >=1 attempt
    public var perTaskPassRate: [String: Double]   // taskId -> passes/attempts
    public var avgCostUSD: Double
    public var avgWallSec: Double
    public var avgOutputTokens: Double
    public var byLanguage: [String: LanguageScore]
    public var qualityAvg: Double?
    public var judgeAgreement: Double?
}

public struct LanguageScore: Sendable, Codable {
    public var n: Int
    public var resolved: Int
    public var pass1: Double
}

public enum Scorer {
    /// Pass@1 = mean binary reward over all attempted tasks (errors/timeouts
    /// count as 0, matching SWE-bench/deepswe semantics). 95% Wilson + Wald CIs.
    public static func summarize(_ tasks: [TaskResult]) -> ScoreSummary {
        let n = tasks.count
        let resolved = tasks.filter { $0.reward == 1 }.count
        let p = n > 0 ? Double(resolved) / Double(n) : 0
        let (lo, hi) = wilson(success: resolved, n: n)
        let wald = n > 0 ? 1.96 * (p * (1 - p) / Double(n)).squareRoot() : 0

        let agents = tasks.compactMap { $0.agent }
        func avg(_ f: (AgentRunInfo) -> Double) -> Double {
            agents.isEmpty ? 0 : agents.map(f).reduce(0, +) / Double(agents.count)
        }

        var byLang: [String: LanguageScore] = [:]
        for lang in Set(tasks.map { $0.language }) {
            let sub = tasks.filter { $0.language == lang }
            let r = sub.filter { $0.reward == 1 }.count
            byLang[lang.rawValue] = LanguageScore(
                n: sub.count, resolved: r,
                pass1: sub.isEmpty ? 0 : Double(r) / Double(sub.count))
        }

        let quals = tasks.compactMap { $0.quality?.score }
        let judged = tasks.compactMap { $0.judge?.agreesWithVerifier }

        // Multi-attempt: group by task for per-task pass-rate + Pass@k.
        let byTask = Dictionary(grouping: tasks, by: { $0.taskId })
        var perTask: [String: Double] = [:]
        var solvedTasks = 0
        for (tid, runs) in byTask {
            let passes = runs.filter { $0.reward == 1 }.count
            perTask[tid] = runs.isEmpty ? 0 : Double(passes) / Double(runs.count)
            if passes > 0 { solvedTasks += 1 }
        }
        let tasksCovered = byTask.count
        let attempts = tasksCovered > 0 ? Int((Double(n) / Double(tasksCovered)).rounded()) : 1

        return ScoreSummary(
            n: n, resolved: resolved, pass1: p,
            wilsonLow: lo, wilsonHigh: hi, waldHalfWidth: wald,
            attempts: attempts, tasksCovered: tasksCovered,
            passAtK: tasksCovered > 0 ? Double(solvedTasks) / Double(tasksCovered) : 0,
            perTaskPassRate: perTask,
            avgCostUSD: avg { $0.costUSD },
            avgWallSec: tasks.isEmpty ? 0 : tasks.map { $0.wallTimeSec }.reduce(0, +) / Double(tasks.count),
            avgOutputTokens: avg { Double($0.outputTokens) },
            byLanguage: byLang,
            qualityAvg: quals.isEmpty ? nil : quals.reduce(0, +) / Double(quals.count),
            judgeAgreement: judged.isEmpty ? nil : Double(judged.filter { $0 }.count) / Double(judged.count))
    }

    /// 95% Wilson score interval for a binomial proportion.
    public static func wilson(success: Int, n: Int, z: Double = 1.96) -> (Double, Double) {
        guard n > 0 else { return (0, 0) }
        let nD = Double(n), p = Double(success) / nD
        let z2 = z * z
        let denom = 1 + z2 / nD
        let center = (p + z2 / (2 * nD)) / denom
        let margin = (z / denom) * ((p * (1 - p) / nD) + z2 / (4 * nD * nD)).squareRoot()
        return (max(0, center - margin), min(1, center + margin))
    }
}
