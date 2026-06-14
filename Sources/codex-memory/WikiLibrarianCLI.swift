import Foundation
import MemoryStore

/// `codex-memory wiki-librarian scan [flags]` — run the Librarian Tier-1 staleness
/// scan over the compiled wiki pages in the production store. Pure local arithmetic
/// (no model, no network): every page is scored cheaply; the flagged subset is what
/// a Tier-2 model pass would then review. Emits a human or JSON report.
enum CodexMemoryWikiLibrarian {
    struct Options {
        var json = false
        var threshold: Double = 50
        var limit = 20            // how many stalest pages to list
        var now: Int64?           // override clock (testing); default = wall clock
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
        return (format(scores, opt: opt), true)
    }

    static func format(_ scores: [LibrarianPageScore], opt: Options) -> String {
        let flagged = scores.filter(\.needsTier2)
        if opt.json {
            let top = scores.prefix(opt.limit).map { s -> [String: Any] in
                [
                    "documentID": NSNumber(value: s.documentID),
                    "volatility": s.volatility.rawValue,
                    "staleness": (s.staleness.score * 100).rounded() / 100,
                    "needsTier2": s.needsTier2,
                    "sourceCount": s.quality.sourceCount,
                    "depthProxy": s.quality.depthProxy,
                ]
            }
            let obj: [String: Any] = [
                "pages": scores.count, "flagged": flagged.count, "stalest": top,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: obj,
                        options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        var out = "wiki-librarian: \(scores.count) page(s), \(flagged.count) flagged for Tier-2 review\n"
        for s in scores.prefix(opt.limit) {
            let mark = s.needsTier2 ? "⚠ " : "  "
            out += String(format: "  %@doc %-6d  staleness %5.1f/100  %-4@  sources %d  depth %d\n",
                          mark, s.documentID, s.staleness.score, s.volatility.rawValue as NSString,
                          s.quality.sourceCount, s.quality.depthProxy)
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
            case "--json": o.json = true
            case "--threshold":
                guard let t = Double(try value("--threshold")) else { throw CLIError(message: "--threshold must be a number") }
                o.threshold = t
            case "--limit":
                guard let n = Int(try value("--limit")), n > 0 else { throw CLIError(message: "--limit must be a positive integer") }
                o.limit = n
            case "--now":
                guard let n = Int64(try value("--now")) else { throw CLIError(message: "--now must be an epoch second") }
                o.now = n
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        return o
    }
}
