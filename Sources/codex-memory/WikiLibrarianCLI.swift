import Foundation
import MemoryStore
import MemoryScore

/// `codex-memory wiki-librarian scan [flags]` — run the Librarian Tier-1 staleness
/// scan over the compiled wiki pages in the production store. Pure local arithmetic
/// (no model, no network): every page is scored cheaply; the flagged subset is what
/// a Tier-2 model pass reviews. With `--tier2` (and `OPENAI_API_KEY`), the flagged
/// subset is scored for coherence/utility via an OpenAI-quick pass (spend-gated) and
/// the combined report is persisted to `<vault>/.librarian/scan-results.json`. Emits a
/// human or JSON report.
enum CodexMemoryWikiLibrarian {
    struct Options {
        var json = false
        var threshold: Double = 50
        var limit = 20            // how many stalest pages to list / Tier-2 score
        var now: Int64?           // override clock (testing); default = wall clock
        var tier2 = false         // run the model coherence/utility pass over the flagged subset
    }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        // first positional is the verb (only `scan` today)
        var rest = args
        if let first = rest.first, !first.hasPrefix("-") {
            guard first == "scan" else { throw CLIError(message: "unknown wiki-librarian verb '\(first)' (expected: scan)") }
            rest = Array(rest.dropFirst())
        }
        let opt = try parse(rest)
        let bundle = try await CodexMemoryRun.assemble()
        let now = opt.now ?? Int64(Date().timeIntervalSince1970)
        let scores = try await bundle.store.librarianScan(now: now, tier2Threshold: opt.threshold)

        var tier2: [LibrarianTier2Score] = []
        var tier2Note: String?
        if opt.tier2 {
            let env = ProcessInfo.processInfo.environment
            if let key = env["OPENAI_API_KEY"], !key.isEmpty {
                let model = env["CODEXKIT_WIKI_LIBRARIAN_MODEL"] ?? "gpt-4o-mini"
                // Tier-2 is the "quick" lane (gpt-4o-mini pricing), spend-gated on its
                // own bucket so it never eats the frontier research budget.
                let gate = SpendGate(store: bundle.store, config: SpendGate.Config(
                    monthlyCeilingUSD: 20, bucket: "wiki-librarian",
                    inputUSDPerMTok: 0.15, outputUSDPerMTok: 0.60,
                    // Tier-2 review is serial (one page at a time) and each call is a
                    // tiny gpt-4o-mini classification (~$0.0005), so the pessimistic
                    // per-call reservation can be small — the default $0.50 would
                    // rate-limit ~$0.50 early on a near-exhausted budget.
                    reservationUSD: 0.02))
                let scorer = WikiCoherenceScorer(apiKey: key, model: model, spendGate: gate)
                let vaultRoot = (MemoryStoreConfig.defaultPath() as NSString).deletingLastPathComponent
                tier2 = await LibrarianTier2.review(store: bundle.store, scores: scores,
                                                    scorer: scorer, limit: opt.limit, vaultRoot: vaultRoot)
                LibrarianTier2.persist(vaultRoot: vaultRoot, scores: scores, tier2: tier2, now: now)
            } else {
                tier2Note = "Tier-2 skipped: set OPENAI_API_KEY to score the flagged subset"
            }
        }
        return (format(scores, tier2: tier2, tier2Note: tier2Note, opt: opt), true)
    }

    static func format(_ scores: [LibrarianPageScore], tier2: [LibrarianTier2Score] = [],
                       tier2Note: String? = nil, opt: Options) -> String {
        let flagged = scores.filter(\.needsTier2)
        let tier2ByID = Dictionary(uniqueKeysWithValues: tier2.map { ($0.documentID, $0) })
        if opt.json {
            let top = scores.prefix(opt.limit).map { s -> [String: Any] in
                var row: [String: Any] = [
                    "documentID": NSNumber(value: s.documentID),
                    "volatility": s.volatility.rawValue,
                    "staleness": (s.staleness.score * 100).rounded() / 100,
                    "needsTier2": s.needsTier2,
                    "sourceCount": s.quality.sourceCount,
                    "depthProxy": s.quality.depthProxy,
                ]
                if let t = tier2ByID[s.documentID] {
                    row["coherence"] = t.coherence; row["utility"] = t.utility; row["rationale"] = t.rationale
                }
                return row
            }
            var obj: [String: Any] = [
                "pages": scores.count, "flagged": flagged.count, "stalest": top,
                "tier2_scored": tier2.count,
            ]
            if let note = tier2Note { obj["tier2_note"] = note }
            let data = (try? JSONSerialization.data(withJSONObject: obj,
                        options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        var out = "wiki-librarian: \(scores.count) page(s), \(flagged.count) flagged for Tier-2 review"
        out += tier2.isEmpty ? "\n" : ", \(tier2.count) Tier-2 scored\n"
        for s in scores.prefix(opt.limit) {
            let mark = s.needsTier2 ? "⚠ " : "  "
            out += String(format: "  %@doc %-6d  staleness %5.1f/100  %-4@  sources %d  depth %d",
                          mark, s.documentID, s.staleness.score, s.volatility.rawValue as NSString,
                          s.quality.sourceCount, s.quality.depthProxy)
            if let t = tier2ByID[s.documentID] {
                out += String(format: "  [coh %d util %d]", t.coherence, t.utility)
            }
            out += "\n"
        }
        if let note = tier2Note { out += "  · \(note)\n" }
        return out
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options(); var i = 0
        func value(_ flag: String) throws -> String {
            i += 1; guard i < args.count else { throw CLIError(message: "\(flag) requires a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--json": o.json = true
            case "--tier2": o.tier2 = true
            case "--threshold":
                guard let t = Double(try value("--threshold")) else { throw CLIError(message: "--threshold must be a number") }
                o.threshold = t
            case "--limit":
                guard let n = Int(try value("--limit")), n > 0 else { throw CLIError(message: "--limit must be a positive integer") }
                o.limit = n
            case "--now":
                guard let n = Int64(try value("--now")), n > 0 else { throw CLIError(message: "--now must be a positive epoch second") }
                o.now = n
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        return o
    }
}
