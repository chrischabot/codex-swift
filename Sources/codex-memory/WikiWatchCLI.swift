import Foundation
import MemoryStore
import WikiIngest

/// `codex-memory wiki-watch <verb>` — register and schedule watched sources
/// (§14.6). The cadence/backoff/due math is the deterministic WatchScheduler; this
/// CLI is the registration + inspection surface.
///
///   add <handle> [--cadence hot|warm|cold] [--kind k]   register / re-arm a source
///   list [--json]                                        show all watched sources
///   pause <handle> / resume <handle> / remove <handle>   manage one source
///   run-due [--json]                                     show sources currently due
///
/// The actual polling loop (fetch → change-gate → ingest) is the network-bearing
/// step and is reported here as "due"; wiring it to the scheduled Cron round is the
/// remaining watch milestone.
enum CodexMemoryWikiWatch {
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        guard let verb = args.first else { throw CLIError(message: "wiki-watch needs a verb: add|list|pause|resume|remove|run-due") }
        let rest = Array(args.dropFirst())
        let bundle = try await CodexMemoryRun.assemble()
        let now = Int64(Date().timeIntervalSince1970)
        let store = bundle.store

        switch verb {
        case "add":
            let (handle, opts) = try parseAdd(rest)
            let kind = opts.kind ?? WikiAdapterRegistry.detectKind(handle).rawValue
            let vol = opts.cadence ?? defaultCadence(forKind: kind)
            try await store.addWatch(id: handle, kind: kind, volatility: vol, now: now)
            return ("watching \(handle)  [kind=\(kind) cadence=\(vol.rawValue)] — due now\n", true)

        case "remove":
            let handle = try oneArg(rest, verb: "remove")
            try await store.removeWatch(id: handle)
            return ("removed \(handle)\n", true)

        case "pause", "resume":
            let handle = try oneArg(rest, verb: verb)
            try await store.setWatchStatus(id: handle, status: verb == "pause" ? .paused : .active)
            return ("\(verb)d \(handle)\n", true)

        case "list":
            let sources = try await store.watchSources()
            return (formatList(sources, now: now, json: rest.contains("--json")), true)

        case "run-due":
            let due = try await store.dueWatchSources(now: now)
            return (formatDue(due, json: rest.contains("--json")), true)

        default:
            throw CLIError(message: "unknown wiki-watch verb '\(verb)'")
        }
    }

    // MARK: format

    static func formatList(_ s: [WatchSource], now: Int64, json: Bool) -> String {
        if json {
            let arr = s.map { w -> [String: Any] in
                ["id": w.id, "cadence": w.volatility.rawValue, "status": w.status.rawValue,
                 "nextDueAt": NSNumber(value: w.nextDueAt), "errorCount": w.errorCount,
                 "due": WatchScheduler.isDue(w, now: now)]
            }
            return jsonLine(["watched": arr, "count": s.count])
        }
        if s.isEmpty { return "no watched sources\n" }
        var out = "\(s.count) watched source(s):\n"
        for w in s {
            let due = WatchScheduler.isDue(w, now: now) ? "DUE" : "in \((w.nextDueAt - now) / 3600)h"
            out += "  \(w.status.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(w.volatility.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(due.padding(toLength: 8, withPad: " ", startingAt: 0)) \(w.id)\n"
        }
        return out
    }

    static func formatDue(_ s: [WatchSource], json: Bool) -> String {
        if json { return jsonLine(["due": s.map(\.id), "count": s.count]) }
        if s.isEmpty { return "nothing due\n" }
        var out = "\(s.count) source(s) due to poll:\n"
        for w in s { out += "  \(w.id)\n" }
        out += "(polling is the network-bearing step — wiring to the scheduled round is in progress)\n"
        return out
    }

    static func jsonLine(_ obj: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    // MARK: parse

    struct AddOptions { var cadence: Volatility?; var kind: String? }

    static func parseAdd(_ args: [String]) throws -> (String, AddOptions) {
        var handle = ""; var o = AddOptions(); var i = 0
        while i < args.count {
            switch args[i] {
            case "--cadence":
                i += 1; guard i < args.count, let v = Volatility(rawValue: args[i].lowercased())
                else { throw CLIError(message: "--cadence must be hot|warm|cold") }
                o.cadence = v
            case "--kind":
                i += 1; guard i < args.count else { throw CLIError(message: "--kind requires a value") }
                o.kind = args[i]
            default:
                if args[i].hasPrefix("-") { throw CLIError(message: "unknown flag \(args[i])") }
                handle = args[i]
            }
            i += 1
        }
        guard !handle.isEmpty else { throw CLIError(message: "wiki-watch add needs a handle (URL/owner/feed)") }
        return (handle, o)
    }

    static func oneArg(_ args: [String], verb: String) throws -> String {
        guard let h = args.first(where: { !$0.hasPrefix("-") }) else {
            throw CLIError(message: "wiki-watch \(verb) needs a handle")
        }
        return h
    }

    /// Fast-moving kinds default to a tighter cadence.
    static func defaultCadence(forKind kind: String) -> Volatility {
        switch kind {
        case "github-owner", "feed": return .hot
        case "arxiv":                return .warm
        default:                     return .cold
        }
    }
}
