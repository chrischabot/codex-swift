import Foundation
import MemoryRetrieve

/// `codex-memory wiki-query "<question>" [flags]` — query the knowledge in the wiki
/// from the terminal. Runs the production hybrid retrieval (FTS5 BM25 + vector
/// cosine → RRF fuse → optional rerank) over the store and prints the ranked hits
/// with their provenance (which source) and a why-breakdown (bm25 / vec / rerank).
enum CodexMemoryWikiQuery {
    struct Options { var query = ""; var k = 10; var rerank = true; var json = false }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let opt = try parse(args)
        guard !opt.query.isEmpty else { throw CLIError(message: "wiki-query requires a query string") }
        let bundle = try await CodexMemoryRun.assemble()
        let hits = try await bundle.retriever.search(opt.query, k: opt.k, rerank: opt.rerank)
        return (format(opt.query, hits, json: opt.json), true)
    }

    static func format(_ query: String, _ hits: [RetrievedHit], json: Bool) -> String {
        if json {
            let arr = hits.map { h -> [String: Any] in
                [
                    "documentURI": h.documentURI, "documentID": NSNumber(value: h.documentId),
                    "score": (h.score * 1e6).rounded() / 1e6,
                    "bm25": (h.why.bm25 * 1e6).rounded() / 1e6,
                    "vec": (h.why.vec * 1e6).rounded() / 1e6,
                    "rerank": (h.why.rerank * 1e6).rounded() / 1e6,
                    "snippet": h.snippet,
                ]
            }
            let obj: [String: Any] = ["query": query, "hits": arr]
            let data = (try? JSONSerialization.data(withJSONObject: obj,
                        options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        var out = "wiki-query: \"\(query)\"  (\(hits.count) hit\(hits.count == 1 ? "" : "s"))\n"
        for (i, h) in hits.enumerated() {
            out += String(format: "  %2d. [%.3f] %@\n", i + 1, h.score, h.documentURI)
            let snip = h.snippet.replacingOccurrences(of: "\n", with: " ")
            out += "      \(snip.prefix(200))\n"
        }
        if hits.isEmpty { out += "  (no matches)\n" }
        return out
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options(); var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--k":
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else { throw CLIError(message: "--k must be a positive integer") }
                o.k = n
            case "--no-rerank": o.rerank = false
            case "--json": o.json = true
            default:
                if a.hasPrefix("-") { throw CLIError(message: "unknown flag \(a)") }
                o.query = o.query.isEmpty ? a : o.query + " " + a   // allow unquoted multi-word
            }
            i += 1
        }
        return o
    }
}
