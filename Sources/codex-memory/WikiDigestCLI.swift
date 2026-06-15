import Foundation
import MemoryStore

/// `codex-memory wiki-digest [--days D | --since TS] [--now TS] [--file] [--json]` (§14.6)
/// — render a digest of the wiki pages created/updated in a window, grouped by category.
/// Pure render (no model, no network); with `--file` it's persisted as a durable
/// `synthesis` row (category=digest, output_type=digest) for delivery (Push) + the
/// Reports lane. The scheduled watch round emits one of these per run.
enum WikiDigest {
    struct Result: Sendable, Equatable {
        var pageCount: Int
        var markdown: String
        var slug: String
    }

    /// `yyyy-MM-dd` in UTC (deterministic — POSIX locale, no Date.now).
    static func isoDate(_ epoch: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// Render the digest from pages updated within `[since, now]`, grouped by category,
    /// newest-first within each group. Pure + deterministic given fixed timestamps.
    static func render(pages: [SynthesisRow], since: Int64, now: Int64) -> Result {
        let inWindow = pages.filter { $0.updatedAt >= since && $0.updatedAt <= now }
            .sorted { $0.updatedAt > $1.updatedAt }
        let slug = "digest-" + isoDate(now)
        var md = "# Wiki digest — \(isoDate(since)) → \(isoDate(now))\n\n"
        md += "\(inWindow.count) page(s) created/updated in this window.\n"
        let byCat = Dictionary(grouping: inWindow, by: { $0.category })
        for cat in byCat.keys.sorted() {
            let rows = byCat[cat]!.sorted { $0.updatedAt > $1.updatedAt }
            md += "\n## \(cat) (\(rows.count))\n"
            for r in rows { md += "- [[\(r.slug)]] \(r.title)\n" }
        }
        return Result(pageCount: inWindow.count, markdown: md, slug: slug)
    }
}

enum CodexMemoryWikiDigest {
    struct Options { var days = 7; var since: Int64?; var now: Int64?; var file = false; var json = false }
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        let o = try parse(args)
        let bundle = try await CodexMemoryRun.assemble()
        let now = o.now ?? Int64(Date().timeIntervalSince1970)
        let since = o.since ?? (now - Int64(o.days) * 86_400)
        let pages = try await bundle.store.syntheses(limit: 100_000)
        let result = WikiDigest.render(pages: pages, since: since, now: now)

        if o.file {
            let vaultRoot = (MemoryStoreConfig.defaultPath() as NSString).deletingLastPathComponent
            let dir = (vaultRoot as NSString).appendingPathComponent("wiki/digest")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = (dir as NSString).appendingPathComponent(result.slug + ".md")
            try result.markdown.write(toFile: path, atomically: true, encoding: .utf8)
            _ = try await bundle.store.upsertSynthesis(SynthesisRow(
                slug: result.slug, category: "digest", title: "Digest \(WikiDigest.isoDate(now))",
                bodyPath: path, createdAt: now, updatedAt: now, generatedAt: now, outputType: "digest"))
        }
        if o.json {
            let obj: [String: Any] = ["slug": result.slug, "pages": result.pageCount, "filed": o.file]
            let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return (String(decoding: d, as: UTF8.self) + "\n", true)
        }
        return (result.markdown, true)
    }

    static func parse(_ args: [String]) throws -> Options {
        var o = Options(); var i = 0
        func val(_ f: String) throws -> String { i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }; return args[i] }
        while i < args.count {
            switch args[i] {
            case "--days":
                guard let n = Int(try val("--days")), n > 0 else { throw CLIError(message: "--days must be a positive integer") }
                o.days = n
            case "--since":
                guard let n = Int64(try val("--since")), n > 0 else { throw CLIError(message: "--since must be a positive epoch second") }
                o.since = n
            case "--now":
                guard let n = Int64(try val("--now")), n > 0 else { throw CLIError(message: "--now must be a positive epoch second") }
                o.now = n
            case "--file": o.file = true
            case "--json": o.json = true
            default: throw CLIError(message: "unknown flag \(args[i])")
            }
            i += 1
        }
        return o
    }
}
