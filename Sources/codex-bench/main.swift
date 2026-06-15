import Foundation
import BenchKit

// codex-bench — native macOS runner for the deep-swe benchmark suite.
// See docs/benchmarks/DEEP_SWE_RUNNER.md.

@main
struct CodexBench {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        guard let cmd = argv.first else { usage(); exit(2) }
        let opts = Options(Array(argv.dropFirst()))
        do {
            switch cmd {
            case "list":    try listCmd(opts)
            case "doctor":  await doctorCmd(opts)
            case "prepare": try await prepareCmd(opts)
            case "run":     try await runCmd(opts)
            case "report":  try reportCmd(opts)
            case "analyze": try analyzeCmd(opts)
            case "skill-score": try await skillScoreCmd(opts)
            case "-h", "--help", "help": usage()
            default: err("unknown command: \(cmd)"); usage(); exit(2)
            }
        } catch {
            err("error: \(error)")
            exit(1)
        }
    }

    // MARK: commands

    static func listCmd(_ o: Options) throws {
        let catalog = try loadCatalog(o)
        let tasks = select(catalog, o, allowNoSelector: true)
        for t in tasks {
            print("\(t.id.padding(toLength: 48, withPad: " ", startingAt: 0))  \(t.language.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0))  \(t.category.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0))  \(t.displayTitle)")
        }
        err("\(tasks.count) task(s)")
    }

    static func doctorCmd(_ o: Options) async {
        func line(_ ok: Bool, _ label: String, _ detail: String) {
            print("\(ok ? "✅" : "❌")  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(detail)")
        }
        let osv = await Subprocess.run("/usr/bin/sw_vers", ["-productVersion"])
        let arch = await Subprocess.run("/usr/bin/uname", ["-m"])
        line(true, "macOS", osv.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
             + " (" + arch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) + ")")
        let runtime = AppleContainerRuntime()
        do { try await runtime.ensureAvailable(); line(true, "apple/container", "running") }
        catch { line(false, "apple/container", "\(error)") }
        let codex = await Subprocess.run("/usr/bin/env", ["codex", "--version"])
        line(codex.ok, "codex CLI (judge)", codex.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        if let root = TaskCatalog.defaultRoot(), let c = try? TaskCatalog(root: root) {
            line(true, "task catalog", "\(c.tasks.count) tasks @ \(root.path)")
        } else { line(false, "task catalog", "not found (set CODEX_BENCH_TASKS)") }
        let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        line(key, "OPENAI_API_KEY", key ? "set (agent mode available)" : "unset (reference/empty modes only)")
        line(true, "cache root", BenchPaths().cacheRoot.path)
    }

    static func prepareCmd(_ o: Options) async throws {
        let catalog = try loadCatalog(o)
        let tasks = select(catalog, o, allowNoSelector: false)
        let runtime = AppleContainerRuntime()
        try await runtime.ensureAvailable()
        let paths = BenchPaths(); paths.ensureDirs()
        let resolver = ImageResolver(runtime: runtime, paths: paths)
        for t in tasks {
            err("preparing \(t.id)…")
            let image = try await resolver.ensureImage(t) { err("  " + $0) }
            _ = try await resolver.ensureTemplate(t, image: image) { err("  " + $0) }
        }
        err("prepared \(tasks.count) task(s)")
    }

    static func runCmd(_ o: Options) async throws {
        let catalog = try loadCatalog(o)
        let tasks = select(catalog, o, allowNoSelector: false)
        guard !tasks.isEmpty else { err("no tasks selected"); exit(2) }
        let mode = AgentMode(rawValue: o.string("mode") ?? "agent") ?? .agent
        let model = o.string("model")
            ?? ProcessInfo.processInfo.environment["CODEXKIT_BENCH_MODEL"]
            ?? ProcessInfo.processInfo.environment["CODEXKIT_LIVE_MODEL"]
            ?? "gpt-5.5"
        let effort = o.string("effort") ?? "high"
        setenv("CODEX_BENCH_EFFORT", effort, 1)   // read in-process by CodexSwiftSession
        let runtime = AppleContainerRuntime()
        try await runtime.ensureAvailable()
        let paths = BenchPaths(); paths.ensureDirs()

        if mode == .agent && ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil {
            err("warning: OPENAI_API_KEY unset — agent mode cannot drive the model")
        }
        let agent: any AgentDriving = (mode == .agent)
            ? CodexSwiftAgentDriver()
            : NullAgentDriver()

        let runId = newRunId()
        let config = RunConfig(
            runId: runId, mode: mode, model: model, arch: runtime.arch,
            runtimeName: runtime.name, concurrency: o.int("concurrency") ?? 2,
            attempts: o.int("attempts") ?? 1, judge: o.flag("judge"), quality: o.flag("quality"),
            effort: effort, seed: o.seed, selectedTaskIds: tasks.map { $0.id },
            startedAt: iso8601(), codexSwiftGitSHA: await gitSHA(catalog.root))

        err("run \(runId): mode=\(mode.rawValue) model=\(model) tasks=\(tasks.count) concurrency=\(config.concurrency)")
        let runner = BenchRunner(runtime: runtime, paths: paths, agent: agent)
        let result = try await runner.run(tasks: tasks, config: config) { err($0) }

        let s = result.score
        print("")
        print(String(format: "Pass@1: %.1f%% (%d/%d)  CI95 %.1f%%–%.1f%%  ±%.1f%%",
                     s.pass1 * 100, s.resolved, s.n,
                     s.wilsonLow * 100, s.wilsonHigh * 100, s.waldHalfWidth * 100))
        print("report: \(paths.runDir(runId).appendingPathComponent("report.md").path)")
    }

    static func reportCmd(_ o: Options) throws {
        guard let runId = o.positional.first ?? o.string("run") else {
            err("usage: codex-bench report <run-id>"); exit(2)
        }
        let url = BenchPaths().runDir(runId).appendingPathComponent("report.json")
        let data = try Data(contentsOf: url)
        let run = try JSONDecoder().decode(RunResult.self, from: data)
        print(Reporter.markdown(run))
    }

    static func analyzeCmd(_ o: Options) throws {
        let paths = BenchPaths()
        // Default to the most recent run (run-ids are timestamp-sortable) if none given.
        var runId = o.positional.first ?? o.string("run")
        if runId == nil {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.resultsRoot.path)) ?? []
            runId = names.filter { !$0.hasPrefix(".") }.sorted().last
        }
        guard let runId else { err("usage: codex-bench analyze <run-id>"); exit(2) }
        let stats = RolloutAnalyzer.analyze(runDir: paths.runDir(runId))
        print("run \(runId)\n")
        print(RolloutAnalyzer.render(stats))
    }

    // MARK: selection / helpers

    static func loadCatalog(_ o: Options) throws -> TaskCatalog {
        let root = o.string("tasks").map { URL(fileURLWithPath: $0) } ?? TaskCatalog.defaultRoot()
        guard let root else { throw BenchError.catalogNotFound("Benchmarks/deep-swe") }
        return try TaskCatalog(root: root)
    }

    static func select(_ catalog: TaskCatalog, _ o: Options, allowNoSelector: Bool) -> [TaskSpec] {
        let langs = o.list("lang").compactMap { BenchLanguage(loose: $0) }
        let cats = o.list("category").map { BenchCategory(loose: $0) }
        let pool = catalog.filtered(
            languages: langs.isEmpty ? nil : Set(langs),
            categories: cats.isEmpty ? nil : Set(cats))
        if let id = o.string("task") {
            return pool.filter { $0.id == id }
        }
        if o.flag("all") { return pool }
        if let n = o.int("random") {
            return catalog.randomSample(n, seed: o.seed ?? defaultSeed(), from: pool)
        }
        return allowNoSelector ? pool : []
    }

    static func defaultSeed() -> UInt64 { UInt64(bitPattern: Int64(Date().timeIntervalSince1970)) }
    static func newRunId() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date()) + "-" + String(format: "%04x", UInt16.random(in: 0...0xFFFF))
    }
    static func iso8601() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func gitSHA(_ root: URL) async -> String {
        let r = await Subprocess.run("/usr/bin/env", ["git", "rev-parse", "--short", "HEAD"], cwd: root.path)
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? "unknown" : sha
    }

    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    static func usage() {
        print("""
        codex-bench — native deep-swe runner (apple/container, arm64)

        USAGE:
          codex-bench list      [--lang go,python] [--category bugfix]
          codex-bench doctor
          codex-bench prepare   (--task ID | --all | --random N) [--lang ...]
          codex-bench run       (--task ID | --random N | --all)
                                [--mode agent|reference|empty] [--model M]
                                [--concurrency K] [--lang ...] [--category ...] [--seed S]
                                [--judge] [--quality]
          codex-bench report    <run-id>
          codex-bench analyze   [<run-id>]   # harness-health forensics (default: latest run)
          codex-bench skill-score --cases <file.json> [--skill ID] [--prompt-version V]
                                [--rubric-judge] [--model M] [--baseline receipt.json]
                                [--tolerance T] [--out receipt.json] [--json]
                                # held-out rule/llm/qrels scoring; --baseline → regression gate (exit 3 on fail)

        MODES:
          agent      codex-swift solves the task (needs OPENAI_API_KEY)
          reference  apply the task's reference solution  (harness self-test → expect reward 1)
          empty      no changes                            (harness self-test → expect reward 0)
        """)
    }
}

/// Minimal `--key value` / `--flag` / positional parser.
struct Options {
    var map: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []
    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    map[key] = args[i + 1]; i += 2
                } else { flags.insert(key); i += 1 }
            } else { positional.append(a); i += 1 }
        }
    }
    func string(_ k: String) -> String? { map[k] }
    func int(_ k: String) -> Int? { map[k].flatMap(Int.init) }
    func double(_ k: String) -> Double? { map[k].flatMap(Double.init) }
    func flag(_ k: String) -> Bool { flags.contains(k) || map[k] == "true" }
    func list(_ k: String) -> [String] {
        (map[k] ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }
    var seed: UInt64? { map["seed"].flatMap { UInt64($0) } }
}

// MARK: - skill-score (held-out rule/llm/qrels scoring + regression gate)
//
// gbrain.md Wave 5, §9.6 #1/#2. Scores already-produced skill outputs over a case
// file with the three judges, emits a SHA-8 receipt, and (with --baseline) runs the
// regression gate. A failing gate exits 3 so CI can wire it. Kept in main.swift (not
// a second file) so the `@main`/single-file entry mode is preserved.
extension CodexBench {
    static func skillScoreCmd(_ o: Options) async throws {
        guard let casesPath = o.string("cases") else {
            err("usage: codex-bench skill-score --cases <file.json> [--skill ID] [--prompt-version V]")
            err("                              [--rubric-judge] [--model M] [--baseline receipt.json]")
            err("                              [--tolerance T] [--out receipt.json] [--json]")
            exit(2)
        }
        let cases: [SkillCase]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: casesPath))
            cases = try JSONDecoder().decode([SkillCase].self, from: data)
        } catch {
            err("error: could not load cases from \(casesPath): \(error)"); exit(1)
        }
        guard !cases.isEmpty else { err("error: case file has no cases"); exit(2) }

        let skillId = o.string("skill") ?? "skill"
        let promptVersion = o.string("prompt-version") ?? "unversioned"
        let weights = SkillJudgeWeights(
            rule: o.double("weight-rule") ?? 1, llm: o.double("weight-llm") ?? 1,
            qrels: o.double("weight-qrels") ?? 1)
        // --rubric-judge wires the real model-backed rubric judge; absent ⇒ llm dimension
        // is skipped (rule/qrels still score). Warn if cases want a rubric but no judge.
        let judge: SkillRubricJudge? = o.flag("rubric-judge") ? CodexCLIRubricJudge(judgeModel: o.string("model")) : nil
        if judge == nil, cases.contains(where: { $0.rubric != nil }) {
            err("note: cases carry rubrics but --rubric-judge was not set — the llm dimension is skipped")
        }

        let receipt = await SkillScorer.score(skillId: skillId, promptVersion: promptVersion,
                                              cases: cases, rubricJudge: judge, weights: weights)

        // Optional regression gate against a stored baseline receipt.
        var gate: SkillRegressionVerdict?
        if let baselinePath = o.string("baseline") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
                let baseline = try JSONDecoder().decode(SkillReceipt.self, from: data)
                gate = try SkillScorer.regressionGate(baseline: baseline, candidate: receipt,
                                                      tolerance: o.double("tolerance") ?? 0)
            } catch let e as SkillScorerError {
                err("error: regression gate: \(e)"); exit(1)
            } catch {
                err("error: could not load baseline \(baselinePath): \(error)"); exit(1)
            }
        }

        if let outPath = o.string("out") {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(receipt).write(to: URL(fileURLWithPath: outPath))
            err("receipt written: \(outPath)")
        }

        if o.flag("json") {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            struct Out: Encodable { let receipt: SkillReceipt; let gate: SkillRegressionVerdict? }
            if let data = try? enc.encode(Out(receipt: receipt, gate: gate)) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            skillScorePrintReceipt(receipt)
            if let gate { skillScorePrintGate(gate) }
        }

        if let gate, !gate.passed { exit(3) }   // CI signal (distinct from usage=2/error=1)
    }

    private static func skillScorePrintReceipt(_ r: SkillReceipt) {
        print("skill: \(r.skillId)  prompt-version: \(r.promptVersion)")
        print("eval set: \(r.caseSetSha8)   run: \(r.sha8)")
        print(String(format: "aggregate: %.4f  over %d case(s)", r.aggregate, r.caseScores.count))
        print("")
        for c in r.caseScores.sorted(by: { $0.caseId < $1.caseId }) {
            func col(_ d: Double?) -> String { d.map { String(format: "%.3f", $0) } ?? "  -  " }
            print(String(format: "  %@  agg %.3f   rule %@  llm %@  qrels %@",
                         c.caseId.padding(toLength: 24, withPad: " ", startingAt: 0),
                         c.aggregate, col(c.ruleScore), col(c.llmScore), col(c.qrelsScore)))
            for rr in c.ruleResults where !rr.passed { print("      ✗ \(rr.rule)") }
        }
    }

    private static func skillScorePrintGate(_ g: SkillRegressionVerdict) {
        print("")
        print("regression gate: \(g.passed ? "✅ PASS" : "❌ FAIL")  "
              + String(format: "Δ %+.4f (baseline %.4f → candidate %.4f, tol %.4f)",
                       g.delta, g.baselineAggregate, g.candidateAggregate, g.tolerance))
        if !g.regressedCases.isEmpty { print("  regressed cases: \(g.regressedCases.joined(separator: ", "))") }
        if !g.missingCases.isEmpty { print("  eval drift (cases present in only one receipt): \(g.missingCases.joined(separator: ", "))") }
    }
}
