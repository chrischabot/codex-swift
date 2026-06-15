import Foundation
import MemoryStore
import PinnedFetcher
import EgressGuard

/// `codex-memory wiki-collect <verb> [flags]` — a bounded discovery catalog of
/// artifacts / media / entities with dedupe, provenance, hashes, and locally-staged
/// assets (§5.A). Downloads are HTTPS-only, IP-pinned (PinnedFetcher), size-capped, and
/// MIME-allowlisted; assets land under `output/assets/collect-<catalog>/`, NEVER in
/// `raw/`. The discovery `run` (web-search fan-out + per-candidate classification) is
/// model+network-heavy and reuses the research web-search/spend infra — tracked
/// separately; this CLI ships the deterministic, safety-critical core: catalog CRUD,
/// the scale gate, and the asset downloader.
///
/// Verbs: list <catalog> | add <catalog> ... | download <catalog> [--limit N]
enum CodexMemoryWikiCollect {
    struct CLIError: Error, CustomStringConvertible { let message: String; var description: String { message } }
    static let kinds: Set<String> = ["artifact", "media", "meme", "tool", "entity", "dataset", "person"]

    static func run(args: [String]) async throws -> (output: String, ok: Bool) {
        guard let verb = args.first, !verb.hasPrefix("-") else {
            throw CLIError(message: "wiki-collect requires a verb (list|add|download)")
        }
        let rest = Array(args.dropFirst())
        let bundle = try await CodexMemoryRun.assemble()
        let now = Int64(Date().timeIntervalSince1970)

        switch verb {
        case "list":
            guard let catalog = rest.first, !catalog.hasPrefix("-") else { throw CLIError(message: "list requires a <catalog>") }
            let items = try await bundle.store.collectItems(catalogSlug: catalog)
            return (formatList(items, json: rest.contains("--json")), true)

        case "add":
            let o = try parseAdd(rest)
            let existing = try await bundle.store.collectItems(catalogSlug: o.catalog)
            // Scale gate (§5.A): cap on catalog size — huge redirects to datasets/ingest-collection.
            switch scale(existing.count + 1) {
            case .huge:
                return ("wiki-collect: catalog '\(o.catalog)' would exceed \(WikiCollectScale.hugeFloor) items — "
                        + "use wiki-dataset / ingest-collection for bulk material instead\n", false)
            case .large where !o.confirm:
                return ("wiki-collect: catalog '\(o.catalog)' is large (\(existing.count) items) — re-run with --confirm\n", false)
            default: break
            }
            let row = item(from: o, rowNumber: Int64(existing.count + 1), now: now)
            let id = try await bundle.store.upsertCollectItem(row)
            return ("wiki-collect: added '\(o.title)' to \(o.catalog) (id \(id))\n", true)

        case "download":
            return try await runDownload(rest, store: bundle.store, now: now, fetcher: nil)

        default:
            throw CLIError(message: "unknown wiki-collect verb '\(verb)' (expected: list|add|download)")
        }
    }

    /// `fetcher == nil` builds the production PinnedFetcher (allowHTTP:false); tests
    /// inject a mock. `vaultRoot == nil` uses the production vault.
    static func runDownload(_ args: [String], store: MemoryStore, now: Int64,
                            fetcher injected: (any CollectMediaFetcher)?, vaultRoot vaultArg: String? = nil) async throws -> (String, Bool) {
        var catalog = ""; var limit = 25; var i = 0
        func val(_ f: String) throws -> String { i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }; return args[i] }
        while i < args.count {
            switch args[i] {
            case "--limit":
                guard let n = Int(try val("--limit")), n > 0 else { throw CLIError(message: "--limit must be a positive integer") }
                limit = n
            default:
                if args[i].hasPrefix("-") { throw CLIError(message: "unknown flag \(args[i])") }
                if catalog.isEmpty { catalog = args[i] } else { throw CLIError(message: "unexpected argument \(args[i])") }
            }
            i += 1
        }
        guard !catalog.isEmpty else { throw CLIError(message: "download requires a <catalog>") }
        let vaultRoot = vaultArg ?? (MemoryStoreConfig.defaultPath() as NSString).deletingLastPathComponent
        let fetcher = injected ?? PinnedCollectFetcher(fetcher: PinnedFetcher(guard_: EgressGuard(EgressPolicy(allowHTTP: false))))
        let items = try await store.collectItems(catalogSlug: catalog)
        let pending = items.filter { ($0.downloadStatus ?? "") != "downloaded" && ($0.mediaURL ?? $0.canonicalURL) != nil }.prefix(limit)
        var downloaded = 0, failed = 0
        for it in pending {
            let updated = await WikiCollectDownloader.place(item: it, catalog: catalog, vaultRoot: vaultRoot, fetcher: fetcher, now: now)
            let ok = updated.downloadStatus == "downloaded" || updated.downloadStatus == "downloaded-truncated"
            do {
                // Write back BY ID (updateCollectItem), not upsert — upsert is
                // insert-or-return-existing and would discard the result / duplicate the row.
                try await store.updateCollectItem(updated)
                if ok { downloaded += 1 } else { failed += 1 }
            } catch {
                // sha collided with another catalog row → identical content already owned.
                // Mark this row a duplicate (drop its sha to avoid the collision) + remove
                // the just-staged asset so we don't keep two copies.
                if let p = updated.localMediaPath { try? FileManager.default.removeItem(atPath: p) }
                var dup = updated; dup.sha256 = nil; dup.localMediaPath = nil; dup.downloadStatus = "duplicate"
                try? await store.updateCollectItem(dup)
                failed += 1
            }
        }
        return ("wiki-collect: \(catalog) — \(downloaded) downloaded, \(failed) skipped/failed (of \(pending.count) attempted)\n", true)
    }

    // MARK: - pure builders / formatters

    struct AddOptions {
        var catalog = "", title = ""
        var kind: String?, canonicalURL: String?, mediaURL: String?, sourceURL: String?
        var creator: String?, description: String?, confidence: String?, confirm = false
    }

    static func item(from o: AddOptions, rowNumber: Int64, now: Int64) -> CollectItemRow {
        CollectItemRow(catalogSlug: o.catalog, rowNumber: rowNumber, title: o.title, collectKind: o.kind,
                       canonicalURL: o.canonicalURL, mediaURL: o.mediaURL, sourceURL: o.sourceURL,
                       creator: o.creator, description: o.description, provenanceConfidence: o.confidence,
                       downloadStatus: "pending", createdAt: now)
    }

    static func formatList(_ items: [CollectItemRow], json: Bool) -> String {
        if json {
            let rows = items.map { it -> [String: Any] in
                var o: [String: Any] = ["title": it.title, "rowNumber": NSNumber(value: it.rowNumber)]
                if let k = it.collectKind { o["kind"] = k }
                if let u = it.canonicalURL { o["canonicalURL"] = u }
                if let s = it.downloadStatus { o["downloadStatus"] = s }
                if let p = it.localMediaPath { o["localMediaPath"] = p }
                return o
            }
            let d = (try? JSONSerialization.data(withJSONObject: ["count": items.count, "items": rows],
                        options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: d, as: UTF8.self) + "\n"
        }
        var out = "wiki-collect: \(items.count) item(s)\n"
        for it in items {
            out += "  #\(it.rowNumber) \(it.collectKind ?? "?")  \(String(it.title.prefix(48)))  [\(it.downloadStatus ?? "-")]\n"
        }
        return out
    }

    static func parseAdd(_ args: [String]) throws -> AddOptions {
        var o = AddOptions(); var i = 0
        func val(_ f: String) throws -> String { i += 1; guard i < args.count else { throw CLIError(message: "\(f) requires a value") }; return args[i] }
        while i < args.count {
            switch args[i] {
            case "--title": o.title = try val("--title")
            case "--kind": o.kind = try val("--kind")
            case "--canonical-url": o.canonicalURL = try val("--canonical-url")
            case "--media-url": o.mediaURL = try val("--media-url")
            case "--source-url": o.sourceURL = try val("--source-url")
            case "--creator": o.creator = try val("--creator")
            case "--description": o.description = try val("--description")
            case "--confidence": o.confidence = try val("--confidence")
            case "--confirm": o.confirm = true
            default:
                if args[i].hasPrefix("-") { throw CLIError(message: "unknown flag \(args[i])") }
                if o.catalog.isEmpty { o.catalog = args[i] } else { throw CLIError(message: "unexpected argument \(args[i])") }
            }
            i += 1
        }
        guard !o.catalog.isEmpty else { throw CLIError(message: "add requires a <catalog>") }
        guard !o.title.isEmpty else { throw CLIError(message: "add requires --title") }
        if let k = o.kind, !kinds.contains(k) { throw CLIError(message: "--kind must be one of: \(kinds.sorted().joined(separator: "|"))") }
        return o
    }

    static func scale(_ n: Int) -> WikiCollectScale { WikiCollectScale.classify(n) }
}

/// Catalog-size scale gate (§5.A): ≤large → ok; large → needs `--confirm`; ≥hugeFloor →
/// refuse and redirect to datasets / ingest-collection.
enum WikiCollectScale: Equatable {
    case ok, large, huge
    static let largeFloor = 101   // 101..500 → confirm
    static let hugeFloor = 501    // 501+   → redirect
    static func classify(_ n: Int) -> WikiCollectScale {
        if n >= hugeFloor { return .huge }
        if n >= largeFloor { return .large }
        return .ok
    }
}

/// The result of staging one media download.
struct CollectMedia: Sendable, Equatable {
    var tempPath: String
    var byteSize: Int
    var sha256: String
    var mime: String       // magic-byte-sniffed MIME (not the server header)
    var truncated: Bool
}

/// A download failure carrying a short human reason (String isn't `Error`).
struct CollectError: Error, Equatable { let message: String; init(_ m: String) { message = m } }

/// Media-download port (PinnedFetcher in prod, a mock in tests).
protocol CollectMediaFetcher: Sendable {
    func fetch(_ url: URL) async -> Result<CollectMedia, CollectError>
}

/// PinnedFetcher-backed fetcher: HTTPS-only enforced by the EgressPolicy (allowHTTP:false)
/// + IP-pinning + size cap + 0600 staging all live in PinnedFetcher.download.
struct PinnedCollectFetcher: CollectMediaFetcher {
    let fetcher: PinnedFetcher
    func fetch(_ url: URL) async -> Result<CollectMedia, CollectError> {
        switch await fetcher.download(url) {
        case .failure(let e): return .failure(CollectError(String(describing: e)))
        case .success(let b):
            return .success(CollectMedia(tempPath: b.path, byteSize: b.byteSize, sha256: b.sha256,
                                         mime: b.sniffedMIME, truncated: b.truncated))
        }
    }
}

/// Stages an item's media into `output/assets/collect-<catalog>/` and updates the row.
/// Safety: HTTPS-only, MIME-allowlisted (magic-byte sniff, not the server header), and
/// content-addressed filename. Returns the updated row (downloadStatus reflects the
/// outcome); on any rejection the temp file is removed.
enum WikiCollectDownloader {
    static let allowedMIME: [String: String] = [
        "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp",
        "image/svg+xml": "svg", "application/pdf": "pdf", "video/mp4": "mp4", "audio/mpeg": "mp3",
    ]

    static func place(item: CollectItemRow, catalog: String, vaultRoot: String,
                      fetcher: any CollectMediaFetcher, now: Int64) async -> CollectItemRow {
        var out = item
        guard let urlStr = item.mediaURL ?? item.canonicalURL, let url = URL(string: urlStr) else {
            out.downloadStatus = "skipped-no-url"; return out
        }
        guard url.scheme?.lowercased() == "https" else { out.downloadStatus = "skipped-non-https"; return out }

        switch await fetcher.fetch(url) {
        case .failure(let e):
            out.downloadStatus = "failed"; out.nextAction = String(e.message.prefix(120)); return out
        case .success(let media):
            guard let ext = allowedMIME[media.mime] else {
                try? FileManager.default.removeItem(atPath: media.tempPath)
                out.downloadStatus = "rejected-mime"; out.nextAction = media.mime; return out
            }
            // assets under output/assets/collect-<catalog>/ — NEVER raw/.
            let dir = (vaultRoot as NSString).appendingPathComponent("output/assets/collect-" + sanitize(catalog))
            let dest = (dir as NSString).appendingPathComponent(String(media.sha256.prefix(16)) + "." + ext)
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest) { try? FileManager.default.removeItem(atPath: dest) }
                try FileManager.default.moveItem(atPath: media.tempPath, toPath: dest)
            } catch {
                try? FileManager.default.removeItem(atPath: media.tempPath)
                out.downloadStatus = "failed"; out.nextAction = "stage: \(error)"; return out
            }
            out.localMediaPath = dest
            out.sha256 = media.sha256
            out.mediaBytes = Int64(media.byteSize)
            out.mediaFormat = media.mime
            out.downloadedAt = now
            out.downloadStatus = media.truncated ? "downloaded-truncated" : "downloaded"
            return out
        }
    }

    /// Keep the catalog component a safe single path segment (no traversal).
    static func sanitize(_ s: String) -> String {
        let safe = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "-" }
        return String(safe).isEmpty ? "catalog" : String(String(safe).prefix(64))
    }
}
