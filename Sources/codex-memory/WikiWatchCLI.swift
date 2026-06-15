import Foundation
import MemoryStore
import WikiIngest
import PinnedFetcher
import EgressGuard

/// `codex-memory wiki-watch <verb>` — register and schedule watched sources
/// (§14.6). The cadence/backoff/due math is the deterministic WatchScheduler; this
/// CLI is the registration + inspection + round-runner surface.
///
///   add <handle> [--cadence hot|warm|cold] [--kind k]   register / re-arm a source
///   list [--json]                                        show all watched sources
///   pause <handle> / resume <handle> / remove <handle>   manage one source
///   run-due [--json]                                     show sources currently due
///   run-round [--limit N] [--json]                       POLL the due sources now:
///       fetch → content-SHA change-gate → ingest new items → advance the scheduler.
///   schedule [--interval S] [--rounds N] [--limit N]     LOOP run-round every S seconds
///       (default daily; per-source cadence still gates what's due). --rounds caps it
///       (omit = run until killed); for launchd/systemd-supervised periodic freshness.
enum CodexMemoryWikiWatch {
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        guard let verb = args.first else { throw CLIError(message: "wiki-watch needs a verb: add|list|pause|resume|remove|run-due|run-round|schedule") }
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

        case "run-round":
            let limit = try parseLimit(rest) ?? 50
            let fetcher = PinnedFetcher(guard_: EgressGuard(EgressPolicy(allowHTTP: true)))
            let poller = LiveWatchPoller(registry: WikiAdapterRegistry(fetcher: fetcher),
                                         writer: WikiIngestWriter(store: store, processor: bundle.processor),
                                         fetchedAt: now, maxPerSource: 20)
            let result = await WikiWatchOrchestrator.runRound(store: store, poller: poller, now: now, limit: limit)
            return (formatRound(result, json: rest.contains("--json")), true)

        case "schedule":
            let limit = try parseLimit(rest) ?? 50
            let interval = try parseIntOpt(rest, "--interval") ?? WikiWatchSchedule.defaultIntervalSeconds
            let maxRounds = try parseIntOpt(rest, "--rounds").map { Int($0) }   // nil = run forever
            let fetcher = PinnedFetcher(guard_: EgressGuard(EgressPolicy(allowHTTP: true)))
            // Each round re-stamps fetchedAt to the current time (a long-running loop
            // must not pin every revision to the start time).
            let writer = WikiIngestWriter(store: store, processor: bundle.processor)
            let registry = WikiAdapterRegistry(fetcher: fetcher)
            let json = rest.contains("--json")
            let tally = await WikiWatchSchedule.run(
                store: store,
                poller: SchedulePoller(registry: registry, writer: writer, maxPerSource: 20),
                intervalSeconds: interval, limit: limit, maxRounds: maxRounds,
                now: { Int64(Date().timeIntervalSince1970) },
                sleep: { secs in try? await Task.sleep(nanoseconds: UInt64(max(0, secs)) * 1_000_000_000) },
                emit: { line in if !json { FileHandle.standardError.write(Data((line + "\n").utf8)) } })
            return (formatSchedule(tally, json: json), true)

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
        out += "(run `wiki-watch run-round` to poll + ingest the due sources)\n"
        return out
    }

    static func formatRound(_ r: WikiWatchOrchestrator.RoundResult, json: Bool) -> String {
        if json {
            return jsonLine(["polled": r.polled, "changed": r.changed, "unchanged": r.unchanged,
                             "failed": r.failed, "itemsIngested": r.itemsIngested, "itemsUpdated": r.itemsUpdated])
        }
        let newItems = max(0, r.itemsIngested - r.itemsUpdated)
        return "wiki-watch round: polled \(r.polled) — \(r.changed) changed, \(r.unchanged) unchanged, "
            + "\(r.failed) failed; \(r.itemsIngested) item(s) ingested (\(newItems) new, \(r.itemsUpdated) updated)\n"
    }

    static func parseLimit(_ args: [String]) throws -> Int? {
        guard let i = args.firstIndex(of: "--limit") else { return nil }
        guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
            throw CLIError(message: "--limit must be a positive integer")
        }
        return n
    }

    /// Parse a positive Int64 option (e.g. `--interval`, `--rounds`); nil when absent.
    static func parseIntOpt(_ args: [String], _ flag: String) throws -> Int64? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count, let n = Int64(args[i + 1]), n > 0 else {
            throw CLIError(message: "\(flag) must be a positive integer")
        }
        return n
    }

    static func formatSchedule(_ t: WikiWatchSchedule.Tally, json: Bool) -> String {
        if json {
            return jsonLine(["rounds": t.rounds, "polled": t.polled, "changed": t.changed,
                             "unchanged": t.unchanged, "failed": t.failed,
                             "itemsIngested": t.itemsIngested, "itemsUpdated": t.itemsUpdated])
        }
        let newItems = max(0, t.itemsIngested - t.itemsUpdated)
        return "wiki-watch schedule: \(t.rounds) round(s) — polled \(t.polled), \(t.changed) changed; "
            + "\(newItems) new, \(t.itemsUpdated) updated, \(t.failed) failed\n"
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
