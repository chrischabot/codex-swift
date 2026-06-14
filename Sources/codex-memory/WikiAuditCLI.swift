import Foundation
import MemoryStore

/// `codex-memory wiki-audit [--json --limit N]` — the audit output-drift scan over
/// the compiled wiki pages: which pages were compiled from a claim that has since
/// changed (so the page may no longer reflect its evidence). Pure timestamps, no
/// model — the cheap structural pass before any truth-escalation. Drifted pages
/// list first.
enum CodexMemoryWikiAudit {
    struct Options { var json = false; var limit = 50 }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let opt = try parse(args)
        let bundle = try await CodexMemoryRun.assemble()
        let scan = try await bundle.store.auditDriftScan()
        return (format(scan, opt: opt), true)
    }

    static func format(_ scan: [(id: Int64, status: DriftStatus)], opt: Options) -> String {
        let drifted = scan.filter { $0.status == .drifted }
        let indirect = scan.filter { $0.status == .indirectlyDrifted }
        if opt.json {
            let rows = scan.prefix(opt.limit).map { ["id": NSNumber(value: $0.id), "status": $0.status.rawValue] }
            let obj: [String: Any] = ["pages": scan.count, "drifted": drifted.count,
                                      "indirectlyDrifted": indirect.count, "pagesDetail": rows]
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "wiki-audit: \(scan.count) page(s) — \(drifted.count) drifted, \(indirect.count) indirectly drifted\n"
        for row in scan.prefix(opt.limit) where row.status != .current {
            out += "  ⚠ doc \(row.id)  \(row.status.rawValue)\n"
        }
        if drifted.isEmpty && indirect.isEmpty { out += "  (all pages current)\n" }
        return out
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options(); var i = 0
        while i < args.count {
            switch args[i] {
            case "--json": o.json = true
            case "--limit":
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else { throw CLIError(message: "--limit must be a positive integer") }
                o.limit = n
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        return o
    }
}
