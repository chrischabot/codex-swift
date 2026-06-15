import Foundation
import MemoryStore
import PinnedFetcher
import EgressGuard

/// `codex-memory wiki-refresh --due [--threshold T --limit N --now TS --json]` — re-fetch
/// + re-verify stale sources. Selects sources past one volatility half-life since their
/// last `verified_at`, re-fetches each (EgressGuard-screened), and stamps verified_at on
/// unchanged sources / flags changed ones for re-ingest. Network-bearing but bounded by
/// `--limit` and the due-selection.
enum CodexMemoryWikiRefresh {
    struct Options {
        var json = false
        var threshold: Double = 0.5
        var limit = 50
        var now: Int64?
    }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let opt = try parse(args)
        let bundle = try await CodexMemoryRun.assemble()
        let now = opt.now ?? Int64(Date().timeIntervalSince1970)
        let fetcher = PinnedRefreshFetcher(fetcher: PinnedFetcher(guard_: EgressGuard(EgressPolicy(allowHTTP: true))))
        let results = await WikiRefresh.run(store: bundle.store, fetcher: fetcher, now: now,
                                            threshold: opt.threshold, limit: opt.limit)
        return (format(results, opt: opt), true)
    }

    static func format(_ results: [WikiRefresh.Result], opt: Options) -> String {
        func count(_ o: WikiRefresh.Outcome) -> Int { results.filter { $0.outcome == o }.count }
        if opt.json {
            let rows = results.prefix(opt.limit).map { r -> [String: Any] in
                ["documentID": NSNumber(value: r.documentID), "sourceURI": r.sourceURI, "outcome": r.outcome.rawValue]
            }
            let obj: [String: Any] = ["due": results.count, "reverified": count(.unchanged),
                                      "changed": count(.changed), "unreachable": count(.unreachable),
                                      "results": rows]
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "wiki-refresh: \(results.count) due — \(count(.unchanged)) re-verified, \(count(.changed)) changed, \(count(.unreachable)) unreachable\n"
        for r in results.prefix(opt.limit) {
            let mark = r.outcome == .changed ? "✎ " : (r.outcome == .unreachable ? "✗ " : "✓ ")
            out += "  \(mark)doc \(r.documentID)  \(r.outcome.rawValue)  \(r.sourceURI)\n"
        }
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
            case "--due": break   // explicit opt-in alias; due-selection is the only mode
            case "--json": o.json = true
            case "--threshold":
                guard let t = Double(try value("--threshold")), t > 0, t <= 1 else {
                    throw CLIError(message: "--threshold must be in (0,1]")
                }
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
