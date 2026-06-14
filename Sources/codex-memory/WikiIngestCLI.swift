import Foundation
import EgressGuard
import PinnedFetcher
import WikiIngest
import MemoryStore
import MemoryProcess
import MemoryInfer

/// `codex-memory wiki-ingest <input> [flags]` — drive the Memory-Wiki ingest
/// pipeline end-to-end against the production store. `<input>` is a URL, a local
/// path, or a bare arXiv query/id (`cat:cs.AI`, `2402.17764`); the adapter
/// auto-detects. A bare GitHub owner is ambiguous with a filename, so pass the
/// owner URL (`https://github.com/openai`) or force `--adapter github`. Override
/// detection any time with `--adapter`. Writes go through the same store assembly as
/// `import-markdown`, so ingested pages join the rest of the wiki and are
/// queryable immediately. Progress is recorded in the crash-safe ingest ledger.
enum CodexMemoryWikiIngest {
    struct Options {
        var input = ""
        var adapter: WikiSourceKind?
        var rawType: RawType?
        var limit: Int?
        var dryRun = false
        var extract = false
        var json = false
        var corpus: String?
        var jobID: String?
        var allowHTTP = true     // SSRF protection is the private-IP block, not the scheme
    }

    struct CLIError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Returns the formatted output plus an explicit success flag, so the dispatcher
    /// sets the exit code on the actual job status (not by parsing the text, which a
    /// `--json` body would defeat).
    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let opt = try parse(args)
        guard !opt.input.isEmpty else {
            throw CLIError(message: "wiki-ingest requires an input (URL, path, arXiv query, or GitHub owner)")
        }
        // A dry-run writes nothing, so it needs neither the production store nor an
        // embedding provider/API key — use a throwaway store so it runs anywhere.
        let store: MemoryStore
        let processor: MemoryProcessor
        if opt.dryRun {
            let tmp = NSTemporaryDirectory() + "wiki-ingest-dry-\(UUID().uuidString).db"
            store = try MemoryStore(MemoryStoreConfig(path: tmp, embeddingDimension: 8))
            processor = MemoryProcessor(store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        } else {
            let bundle = try await CodexMemoryRun.assemble()
            store = bundle.store
            processor = bundle.processor
        }
        let fetcher = PinnedFetcher(guard_: EgressGuard(EgressPolicy(allowHTTP: opt.allowHTTP)))
        let registry = WikiAdapterRegistry(fetcher: fetcher)
        let writer = WikiIngestWriter(store: store, processor: processor)
        let orch = WikiIngestOrchestrator(registry: registry, writer: writer, store: store,
                                          now: { Int64(Date().timeIntervalSince1970) })
        let now = Int64(Date().timeIntervalSince1970)
        let req = IngestRequest(input: opt.input, adapter: opt.adapter, rawType: opt.rawType,
                                limit: opt.limit, dryRun: opt.dryRun, fetchedAt: now)
        let jobID = opt.jobID ?? UUID().uuidString
        let summary = await orch.ingest(req, jobID: jobID, extract: opt.extract, corpus: opt.corpus)
        return (format(summary, json: opt.json), summary.status != "failed")
    }

    // MARK: format

    static func format(_ s: WikiIngestOrchestrator.Summary, json: Bool) -> String {
        if json {
            var obj: [String: Any] = [
                "jobID": s.jobID, "status": s.status, "candidates": s.candidates,
                "written": s.written, "skipped": s.skipped, "failed": s.failed,
                "documentIDs": s.documentIDs.map(NSNumber.init(value:)), "dryRun": s.dryRun,
            ]
            if let c = s.cursor { obj["cursor"] = c }
            if let e = s.error { obj["error"] = e }
            let data = (try? JSONSerialization.data(withJSONObject: obj,
                        options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        var out = "wiki-ingest [\(s.jobID)] status=\(s.status)\(s.dryRun ? " (dry-run)" : "")\n"
        out += "  candidates=\(s.candidates) written=\(s.written) skipped=\(s.skipped) failed=\(s.failed)\n"
        if let c = s.cursor { out += "  cursor=\(c)\n" }
        if let e = s.error { out += "  error: \(e)\n" }
        return out
    }

    // MARK: arg parsing

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw CLIError(message: "\(flag) requires a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--adapter":
                let v = try value(a)
                guard let k = adapterKind(v) else { throw CLIError(message: "unknown adapter '\(v)'") }
                o.adapter = k
            case "--raw-type":
                let v = try value(a)
                guard let r = RawType(rawValue: v.lowercased()) else { throw CLIError(message: "unknown raw-type '\(v)'") }
                o.rawType = r
            case "--limit":
                let v = try value(a)
                guard let n = Int(v), n > 0 else { throw CLIError(message: "--limit must be a positive integer") }
                o.limit = n
            case "--corpus":   o.corpus = try value(a)
            case "--job-id":   o.jobID = try value(a)
            case "--dry-run":  o.dryRun = true
            case "--extract":  o.extract = true
            case "--json":     o.json = true
            case "--allow-http": o.allowHTTP = true
            case "--https-only": o.allowHTTP = false
            default:
                if a.hasPrefix("-") { throw CLIError(message: "unknown flag \(a)") }
                o.input = a
            }
            i += 1
        }
        return o
    }

    /// Map a user-friendly adapter name (or a raw kind value) to a WikiSourceKind.
    static func adapterKind(_ s: String) -> WikiSourceKind? {
        switch s.lowercased() {
        case "github", "gh", "github-owner", "owner": return .githubOwner
        case "git", "repo":                            return .git
        case "rss", "atom", "feed":                    return .feed
        case "paper", "papers", "arxiv":               return .arxiv
        default:                                       return WikiSourceKind(rawValue: s.lowercased())
        }
    }
}
