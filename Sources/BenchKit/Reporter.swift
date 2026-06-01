import Foundation

public enum Reporter {
    public static let caveatBanner = """
    ⚠️ Comparability: this runs codex-swift's FULL native tool surface as the agent \
    (not deepswe's single-bash mini-swe-agent), on native arm64 (their prebuilt \
    images are amd64). The Pass@1 here measures *codex-swift + model*; it is not \
    apples-to-apples with the leaderboard's *mini-swe-agent + model* for the same \
    model. See docs/benchmarks/DEEP_SWE_RUNNER.md §11.
    """

    public static func write(_ run: RunResult, to runDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(run).write(to: runDir.appendingPathComponent("report.json"))
        try enc.encode(run.config).write(to: runDir.appendingPathComponent("run.json"))
        try Data(markdown(run).utf8).write(to: runDir.appendingPathComponent("report.md"))
    }

    public static func markdown(_ run: RunResult) -> String {
        let s = run.score
        func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
        var md = "# DeepSWE-on-codex-swift — run `\(run.config.runId)`\n\n"
        md += "> \(run.caveat)\n\n"
        md += "- mode: **\(run.config.mode.rawValue)** · model: **\(run.config.model)** · "
        md += "runtime: \(run.config.runtimeName) (\(run.config.arch)) · "
        md += "tasks: \(s.n) · concurrency: \(run.config.concurrency)\n"
        if let seed = run.config.seed { md += "- random seed: `\(seed)`\n" }
        md += "- codex-swift @ `\(run.config.codexSwiftGitSHA)` · started \(run.config.startedAt)\n\n"

        md += "## Score\n\n"
        if s.attempts > 1 {
            md += "- **\(s.attempts) attempts/task** over \(s.tasksCovered) tasks (\(s.n) runs)\n"
            md += "- **Avg Pass@1: \(pct(s.pass1))** (\(s.resolved)/\(s.n) runs) · **Pass@\(s.attempts): \(pct(s.passAtK))** (tasks solved ≥1×)\n\n"
        }
        md += "| Pass@1 | 95% CI (Wilson) | ± (Wald) | Avg cost | Avg time | Avg out tok |\n"
        md += "|---|---|---|---|---|---|\n"
        md += "| **\(pct(s.pass1))** (\(s.resolved)/\(s.n)) | "
        md += "\(pct(s.wilsonLow))–\(pct(s.wilsonHigh)) | ±\(pct(s.waldHalfWidth)) | "
        md += String(format: "$%.2f", s.avgCostUSD) + " | "
        md += String(format: "%.0fs", s.avgWallSec) + " | "
        md += String(format: "%.0f", s.avgOutputTokens) + " |\n\n"
        if s.attempts > 1 && !s.perTaskPassRate.isEmpty {
            md += "### Per-task pass-rate\n\n| Task | Pass-rate |\n|---|---|\n"
            for (tid, rate) in s.perTaskPassRate.sorted(by: { $0.key < $1.key }) {
                md += "| \(tid) | \(pct(rate)) (\(Int((rate * Double(s.attempts)).rounded()))/\(s.attempts)) |\n"
            }
            md += "\n"
        }
        if let q = s.qualityAvg { md += "- quality (ours): \(pct(q))\n" }
        if let j = s.judgeAgreement { md += "- judge agreement (ours): \(pct(j))\n" }
        md += "\n"

        if !s.byLanguage.isEmpty {
            md += "## By language\n\n| Language | Pass@1 | n |\n|---|---|---|\n"
            for (lang, ls) in s.byLanguage.sorted(by: { $0.key < $1.key }) {
                md += "| \(lang) | \(pct(ls.pass1)) | \(ls.resolved)/\(ls.n) |\n"
            }
            md += "\n"
        }

        md += "## Tasks\n\n| Task | Lang | Reward | Status | base/new | Δbytes | cost | time |\n"
        md += "|---|---|---|---|---|---|---|---|\n"
        for t in run.tasks.sorted(by: { $0.taskId < $1.taskId }) {
            let bn = t.verifier.map { "\($0.baseExit.map(String.init) ?? "?")/\($0.newExit.map(String.init) ?? "?")" } ?? "—"
            let dz = t.agent?.diffBytes ?? t.verifier?.modelPatchBytes ?? 0
            let cost = t.agent.map { String(format: "$%.2f", $0.costUSD) } ?? "—"
            md += "| \(t.taskId) | \(t.language.rawValue) | "
            md += "\(t.reward == 1 ? "✅ 1" : "❌ 0") | \(t.status.rawValue) | \(bn) | \(dz) | \(cost) | "
            md += String(format: "%.0fs", t.wallTimeSec) + " |\n"
        }
        if run.tasks.contains(where: { $0.error != nil }) {
            md += "\n## Errors\n\n"
            for t in run.tasks where t.error != nil {
                md += "- **\(t.taskId)**: \(t.error!)\n"
            }
        }
        return md
    }
}
