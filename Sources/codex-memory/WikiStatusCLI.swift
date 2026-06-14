import Foundation
import MemoryStore

/// `codex-memory wiki-status [--json] [--limit N]` — a dashboard over the wiki: raw
/// document count, compiled-page count + how many are flagged stale, and the recent
/// ingest-job ledger (what was ingested, when, and what failed). This is the "view
/// logs / activity" surface for the CLI. All reads, no model.
enum CodexMemoryWikiStatus {
    struct Options { var json = false; var limit = 10 }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let opt = try parse(args)
        let bundle = try await CodexMemoryRun.assemble()
        let now = Int64(Date().timeIntervalSince1970)
        let docs = try await bundle.store.documentCount()
        let scores = try await bundle.store.librarianScan(now: now)
        let jobs = try await bundle.store.ingestJobs(limit: opt.limit)
        return (format(docs: docs, pages: scores.count, flagged: scores.filter(\.needsTier2).count,
                       jobs: jobs, opt: opt), true)
    }

    static func format(docs: Int, pages: Int, flagged: Int, jobs: [IngestJobRow], opt: Options) -> String {
        if opt.json {
            let jobObjs = jobs.map { j -> [String: Any] in
                var o: [String: Any] = [
                    "jobID": j.jobID, "input": j.input, "status": j.status,
                    "candidates": j.candidates, "written": j.written,
                    "skipped": j.skipped, "failed": j.failed, "startedAt": NSNumber(value: j.startedAt),
                ]
                if let a = j.adapter { o["adapter"] = a }
                if let e = j.error { o["error"] = e }
                return o
            }
            let obj: [String: Any] = [
                "documents": docs, "pages": pages, "flaggedStale": flagged, "recentJobs": jobObjs,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: obj,
                        options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        var out = "Memory Wiki status\n"
        out += "  raw documents : \(docs)\n"
        out += "  wiki pages    : \(pages)  (\(flagged) flagged stale for review)\n"
        out += "  recent ingest jobs:\n"
        if jobs.isEmpty {
            out += "    (none)\n"
        } else {
            for j in jobs {
                out += String(format: "    %@ %-8@ w%d/s%d/f%d  %@\n",
                              j.jobID.prefix(8).description, j.status as NSString,
                              j.written, j.skipped, j.failed, j.input)
            }
        }
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
