import Foundation
import WikiResearch
import MemoryStore
import MemoryScore

/// A live LLM-backed contradiction judge. Reuses `WikiClaimExtractor.chatCall`
/// for the HTTP + the shared `SpendGate` for budget admission, and parses the
/// response through the robust `ContradictionJudge.parse`. On rate-limit / error
/// it returns a safe `noContradiction@0` (never invents a conflict).
struct LiveContradictionJudge: ContradictionJudgeBackend {
    let apiKey: String
    let model: String
    let spendGate: SpendGate?
    private let systemPrompt =
        "You are a careful fact-comparison judge. Reply with ONLY the requested JSON object."

    func judge(_ a: ClaimRow, _ b: ClaimRow, context: JudgeContext) async -> JudgedPair {
        let prompt = ContradictionJudge.buildPrompt(a, b, context: context)
        let sys = systemPrompt, key = apiKey
        let call: SpendGate.TokenCall = { p, m, _ in
            try await WikiClaimExtractor.chatCall(
                endpoint: "https://api.openai.com/v1/chat/completions",
                apiKey: key, model: m, sys: sys, user: p)
        }
        let raw: String
        if let gate = spendGate {
            guard let outcome = try? await gate.run(prompt: prompt, model: model, call),
                  case let .ran(receipt) = outcome
            else { return JudgedPair(verdict: .noContradiction, confidence: 0, reasoning: "rate-limited") }
            raw = receipt.text
        } else {
            guard let r = try? await call(prompt, model, .distantFuture)
            else { return JudgedPair(verdict: .noContradiction, confidence: 0, reasoning: "error") }
            raw = r.text
        }
        return ContradictionJudge.parse(raw)
    }
}

/// `codex-memory wiki-contradictions [--scope active|stale] [--apply] [--json]
/// [--max-judge N] [--max-usd X]` — scans claims for temporal contradictions /
/// supersessions and (with `--apply`, the explicit operator opt-in) executes the
/// high-confidence lifecycle transitions. (gbrain.md Wave 3.24.)
enum CodexMemoryWikiContradictions {
    struct Options {
        var scope: ClaimStatus = .active
        var apply = false
        var json = false
        var limit = 5000
        var maxJudge = 200
        var maxUSD: Double?
    }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let opt = try parse(args)
        let env = ProcessInfo.processInfo.environment
        guard let apiKey = env["OPENAI_API_KEY"], !apiKey.isEmpty else {
            throw CLIError(message: "wiki-contradictions requires OPENAI_API_KEY")
        }
        let bundle = try await CodexMemoryRun.assemble()
        let maxUSD = opt.maxUSD ?? Double(env["CODEX_MEMORY_WIKI_BUDGET_USD"] ?? "") ?? 40
        let gate = SpendGate(store: bundle.store, config: .init(
            monthlyCeilingUSD: maxUSD, bucket: "wiki-contradictions",
            inputUSDPerMTok: 0.15, outputUSDPerMTok: 0.60))
        let judge = LiveContradictionJudge(
            apiKey: apiKey, model: env["CODEXKIT_WIKI_JUDGE_MODEL"] ?? "gpt-4o-mini", spendGate: gate)

        let claims = try await bundle.store.claimsByStatus(opt.scope, limit: opt.limit)
        let probe = ContradictionProbe(judge: judge, maxJudgeCalls: opt.maxJudge)
        let now = Int64(Date().timeIntervalSince1970)
        // --apply IS the explicit operator opt-in gesture (gbrain.md note).
        let report = await probe.run(claims: claims, now: now, apply: opt.apply, store: bundle.store)
        // Close the loop: score the judge's confidence-in-conflict per domain.
        let scorecards = CalibrationScorer.scoreByDomain(report.resolvedItems)
        return (format(report, scope: opt.scope, applied: opt.apply, json: opt.json, scorecards: scorecards), true)
    }

    static func format(_ r: ContradictionProbeReport, scope: ClaimStatus,
                       applied: Bool, json: Bool, scorecards: [DomainScorecard] = []) -> String {
        if json {
            let obj: [String: Any] = [
                "scope": scope.rawValue, "apply": applied,
                "considered": r.pairsConsidered, "judged": r.pairsJudged,
                "verdicts": r.verdicts, "applied": r.applied,
                "truncated": r.truncated, "reviewQueue": r.reviewQueue,
                "calibration": scorecards.map { c -> [String: Any] in
                    ["domain": c.domain, "n": c.n, "coldStart": c.coldStart,
                     "brier": c.brier, "accuracy": c.accuracy,
                     "partialRate": c.partialRate, "coverage": c.coverage]
                },
            ]
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
                ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "wiki-contradictions [scope=\(scope.rawValue)\(applied ? " --apply" : "")]: "
        out += "considered=\(r.pairsConsidered) judged=\(r.pairsJudged) applied=\(r.applied)"
        out += r.truncated ? " (truncated at budget)\n" : "\n"
        if !r.verdicts.isEmpty {
            out += "  verdicts: " + r.verdicts.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "\n"
        }
        for line in r.reviewQueue.prefix(50) { out += "  · \(line)\n" }
        if !scorecards.isEmpty {
            out += "  calibration (per-domain confidence→outcome):\n"
            for c in scorecards {
                if c.coldStart {
                    out += String(format: "    %@: cold-start (n=%d, coverage=%.2f)\n", c.domain, c.n, c.coverage)
                } else {
                    out += String(format: "    %@: brier=%.3f acc=%.2f n=%d coverage=%.2f\n",
                                  c.domain, c.brier, c.accuracy, c.n, c.coverage)
                }
            }
        }
        return out
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options(); var i = 0
        func val(_ f: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--scope":
                let raw = try val(a).lowercased()
                guard let s = ClaimStatus(rawValue: raw) else { throw CLIError(message: "--scope must be a claim status (active|stale|draft|contradicted|archived)") }
                o.scope = s
            case "--apply": o.apply = true
            case "--json": o.json = true
            case "--limit": o.limit = Int(try val(a)) ?? 5000
            case "--max-judge": o.maxJudge = Int(try val(a)) ?? 200
            case "--max-usd": o.maxUSD = Double(try val(a))
            default:
                if a.hasPrefix("-") { throw CLIError(message: "unknown flag \(a)") }
            }
            i += 1
        }
        return o
    }
}
