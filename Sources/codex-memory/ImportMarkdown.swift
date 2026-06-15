import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import MemoryIngest
import MemoryInfer
import MemoryProcess
import MemoryStore

struct MarkdownImportOptions: Sendable {
    var dryRun: Bool = false
    var json: Bool = false
    var extractMode: Bool = false
    var force: Bool = false
    var resume: Bool = false
    var restart: Bool = false
    var jobID: String?
    var batchSize: Int = 64
    var maxBytes: Int64 = 10 * 1024 * 1024
    var stateRoot: String?
    /// Number of documents processed concurrently. >1 overlaps the per-document
    /// LLM calls (contextualise/extract) — a big win for the network-bound
    /// remote backend. The store/processor are actors, so writes still
    /// serialise; only the LLM awaits run in parallel. Local MLX gets little
    /// benefit (single GPU). Default 1 = the original serial behaviour.
    var concurrency: Int = 1
    /// When set, a small JSON progress snapshot is rewritten after every file
    /// so an external monitor can poll live counts (imported / failed / total).
    var progressPath: String?
    var clock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
}

struct MarkdownImportReport: Sendable, Equatable {
    var jobID: String
    var roots: [String]
    var discovered: Int = 0
    var imported: Int = 0
    var unchanged: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var chunks: Int = 0
    var claims: Int = 0
    var entities: Int = 0
    var manifest: [MarkdownManifestEntry] = []
    var errors: [String] = []

    var summaryLine: String {
        "import-markdown summary: discovered=\(discovered) imported=\(imported) "
            + "unchanged=\(unchanged) skipped=\(skipped) failed=\(failed) "
            + "chunks=\(chunks) claims=\(claims) entities=\(entities) job_id=\(jobID)"
    }

    func jsonObject(includeManifest: Bool = true) -> [String: Any] {
        var out: [String: Any] = [
            "job_id": jobID,
            "roots": roots,
            "discovered": discovered,
            "imported": imported,
            "unchanged": unchanged,
            "skipped": skipped,
            "failed": failed,
            "chunks": chunks,
            "claims": claims,
            "entities": entities,
            "errors": errors,
        ]
        if includeManifest {
            out["manifest"] = manifest.map { $0.jsonObject() }
        }
        return out
    }
}

struct MarkdownManifestEntry: Sendable, Equatable {
    var root: String
    var absolutePath: String
    var relativeID: String
    var sourceURI: String
    var title: String?
    var bytes: Int64
    var mtime: Int64
    var sha256: String?
    var skipReason: String?

    func jsonObject() -> [String: Any] {
        [
            "root": root,
            "absolute_path": absolutePath,
            "relative_id": relativeID,
            "source_uri": sourceURI,
            "title": title as Any,
            "bytes": bytes,
            "mtime": mtime,
            "sha256": sha256 as Any,
            "skip_reason": skipReason as Any,
        ].compactMapValues { value in
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                return mirror.children.first?.value ?? NSNull()
            }
            return value
        }
    }
}

/// Result of processing one document, merged serially into the report.
enum EntryOutcome: Sendable {
    case skipped
    case unchanged(uri: String, sha: String, expectedChunks: Int)
    case imported(uri: String, sha: String, expectedChunks: Int, chunks: Int, entities: Int)
    case failed(relativeID: String, error: String)
}

private struct MarkdownImportState: Codable {
    var jobID: String
    var manifestDigest: String
    var extractMode: Bool
    var completed: [CompletedMarkdownImport]
    var updatedAt: Int64
}

private struct CompletedMarkdownImport: Codable, Equatable {
    var sourceURI: String
    var sha256: String
    var expectedChunks: Int
}

public enum CodexMemoryMarkdownImport {
    public static func run(args: [String]) async throws -> String {
        let result = try await runDetailed(args: args)
        return result.output
    }

    static func runDetailed(args: [String]) async throws -> (report: MarkdownImportReport, output: String) {
        let parsed = try parseArgs(args)
        guard !parsed.roots.isEmpty else {
            throw argumentError("import-markdown requires at least one markdown root")
        }
        if parsed.options.dryRun {
            let tempDB = NSTemporaryDirectory() + "import-markdown-dry-run-\(UUID().uuidString).db"
            defer { try? FileManager.default.removeItem(atPath: tempDB) }
            let store = try MemoryStore(MemoryStoreConfig(path: tempDB, embeddingDimension: 8))
            let processor = MemoryProcessor(
                store: store,
                inference: MockInferenceProvider(embeddingDimension: 8))
            let report = try await importRoots(parsed.roots,
                                               options: parsed.options,
                                               store: store,
                                               processor: processor)
            return (report, format(report, json: parsed.options.json))
        }
        let bundle = try await CodexMemoryRun.assemble()
        let processor: MemoryProcessor
        if parsed.options.batchSize == 64 {
            processor = bundle.processor
        } else {
            processor = MemoryProcessor(
                store: bundle.store,
                inference: bundle.inference,
                archive: bundle.archive,
                config: MemoryProcessor.Config(embedBatchSize: parsed.options.batchSize))
        }
        let report = try await importRoots(parsed.roots,
                                           options: parsed.options,
                                           store: bundle.store,
                                           processor: processor)
        return (report, format(report, json: parsed.options.json))
    }

    static func importRoots(_ roots: [String],
                            options: MarkdownImportOptions,
                            store: MemoryStore,
                            processor: MemoryProcessor) async throws -> MarkdownImportReport {
        let canonicalRoots = try roots.map { root -> String in
            guard let path = realPath(root) else {
                throw NSError(domain: "CodexMemoryMarkdownImport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "root not found: \(root)"])
            }
            return path
        }
        var entries = discover(roots: canonicalRoots, options: options)
        entries.sort {
            if $0.sourceURI == $1.sourceURI { return $0.relativeID < $1.relativeID }
            return $0.sourceURI < $1.sourceURI
        }

        let discovered = entries.filter { $0.skipReason == nil }.count
        let skipped = entries.filter { $0.skipReason != nil }.count
        let jobID = try validateJobID(options.jobID ?? deterministicJobID(
            roots: canonicalRoots, entries: entries, extractMode: options.extractMode))
        let manifestDigest = deterministicJobID(roots: canonicalRoots,
                                                entries: entries,
                                                extractMode: options.extractMode)
        var report = MarkdownImportReport(jobID: jobID, roots: canonicalRoots,
                                          discovered: discovered,
                                          skipped: skipped,
                                          manifest: entries)
        if options.dryRun { return report }

        let stateURL = try stateFileURL(jobID: jobID, options: options)
        if options.restart {
            try? FileManager.default.removeItem(at: stateURL)
        }
        let loadedState = options.resume ? loadState(stateURL) : nil
        let completedEntries = loadedState?.jobID == jobID
            && loadedState?.manifestDigest == manifestDigest
            && loadedState?.extractMode == options.extractMode
            ? loadedState?.completed ?? []
            : []
        var completedByURI = Dictionary(uniqueKeysWithValues:
            completedEntries.map { ($0.sourceURI, $0) })

        writeProgress(report, to: options.progressPath)
        let work = entries.filter { $0.skipReason == nil }
        let concurrency = max(1, options.concurrency)

        // Per-document work (independent; only touches the store/processor
        // actors). Runs on the task group; the shared report/state merge below
        // is serial, so no data races on the counters or the resume state.
        @Sendable func processOne(_ entry: MarkdownManifestEntry) async -> EntryOutcome {
            do {
                guard let raw = try readMarkdown(entry: entry, maxBytes: options.maxBytes) else {
                    return .skipped
                }
                let canonical = normalizeMarkdown(raw)
                let sha = Normaliser.contentSHA(canonical)
                let shaHex = hex(sha)
                let expectedChunks = MemoryProcessor.Config().splitter.split(canonical).count
                if !options.force,
                   try await isCompleteDocument(store: store, sourceURI: entry.sourceURI,
                                                sha: sha, expectedChunks: expectedChunks,
                                                extractMode: options.extractMode) {
                    return .unchanged(uri: entry.sourceURI, sha: shaHex, expectedChunks: expectedChunks)
                }
                let stagedURI = "codex-memory://import-markdown/staging/\(jobID)/\(shaHex)/\(entry.relativeID)"
                let doc = IngestedDocument(
                    sourceName: "markdown",
                    sourceKind: .manual,
                    sourceURI: stagedURI,
                    title: entry.title,
                    publishedAt: nil,
                    fetchedAt: entry.mtime > 0 ? entry.mtime : options.clock(),
                    canonicalText: canonical,
                    rawBytes: Int64(canonical.utf8.count),
                    contentSHA: sha)
                if let staleStage = try await store.document(byURI: stagedURI) {
                    try await store.deleteDocument(id: staleStage.id)
                }
                let processed = try await processor.process(doc, extract: options.extractMode)
                let staged = try await store.document(id: processed.documentId)
                let finalBodyPath = staged?.bodyPath.hasPrefix("inline:") == true
                    ? "inline:\(entry.sourceURI)"
                    : (staged?.bodyPath ?? "inline:\(entry.sourceURI)")
                try await store.promoteStagedDocument(
                    stagedId: processed.documentId,
                    sourceURI: entry.sourceURI,
                    bodyPath: finalBodyPath,
                    title: entry.title)
                return .imported(uri: entry.sourceURI, sha: shaHex, expectedChunks: expectedChunks,
                                 chunks: processed.chunksWritten, entities: processed.entitiesUpserted)
            } catch {
                return .failed(relativeID: entry.relativeID, error: "\(error)")
            }
        }

        func merge(_ outcome: EntryOutcome) {
            switch outcome {
            case .skipped:
                report.skipped += 1
            case let .unchanged(uri, sha, expectedChunks):
                report.unchanged += 1
                completedByURI[uri] = CompletedMarkdownImport(
                    sourceURI: uri, sha256: sha, expectedChunks: expectedChunks)
            case let .imported(uri, sha, expectedChunks, chunks, entities):
                report.imported += 1
                report.chunks += chunks
                report.entities += entities
                completedByURI[uri] = CompletedMarkdownImport(
                    sourceURI: uri, sha256: sha, expectedChunks: expectedChunks)
            case let .failed(relativeID, error):
                report.failed += 1
                report.errors.append("\(relativeID): \(error)")
            }
            try? saveState(jobID: jobID, manifestDigest: manifestDigest,
                           extractMode: options.extractMode,
                           completed: Array(completedByURI.values),
                           updatedAt: options.clock(), to: stateURL)
            writeProgress(report, to: options.progressPath)
        }

        await withTaskGroup(of: EntryOutcome.self) { group in
            var next = 0
            // Seed up to `concurrency` documents in flight.
            while next < work.count && next < concurrency {
                let entry = work[next]; next += 1
                group.addTask { await processOne(entry) }
            }
            // Drain: merge each completed outcome (serially), then top up.
            while let outcome = await group.next() {
                merge(outcome)
                if next < work.count {
                    let entry = work[next]; next += 1
                    group.addTask { await processOne(entry) }
                }
            }
        }
        return report
    }

    static func format(_ report: MarkdownImportReport, json: Bool) -> String {
        if json {
            let obj = report.jsonObject()
            let data = (try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        var lines = [report.summaryLine]
        for error in report.errors {
            lines.append("FAIL \(error)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private func isCompleteDocument(store: MemoryStore, sourceURI: String,
                                sha: Data, expectedChunks: Int,
                                extractMode: Bool) async throws -> Bool {
    if extractMode {
        // Until MemoryProcess writes a durable per-document completion marker,
        // chunk count alone cannot prove entity/edge extraction finished.
        return false
    }
    guard let existing = try await store.document(byURI: sourceURI),
          existing.contentSHA == sha else {
        return false
    }
    return try await store.chunkCount(documentId: existing.id) == expectedChunks
}

func discover(roots: [String], options: MarkdownImportOptions) -> [MarkdownManifestEntry] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey,
    ]
    let skippedDirs: Set<String> = [
        ".git", ".hg", ".svn", ".build", "node_modules", ".venv", "venv",
        "dist", "build", ".cache",
    ]
    var entries: [MarkdownManifestEntry] = []
    for (rootIndex, root) in roots.enumerated() {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = fm.enumerator(at: rootURL,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else {
            continue
        }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = (try? url.resourceValues(forKeys: Set(keys)))
            if values?.isDirectory == true {
                if skippedDirs.contains(name) || values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let ext = url.pathExtension.lowercased()
            let isMarkdown = ext == "md" || ext == "markdown"
            guard let canonical = realPath(url.path) else {
                if isMarkdown {
                    entries.append(entry(root: root, rootIndex: rootIndex,
                                         rootsCount: roots.count, path: url.path,
                                         canonicalPath: url.path, bytes: 0, mtime: 0,
                                         title: nil, sha: nil,
                                         skip: "unresolvable"))
                }
                continue
            }
            guard canonical == root || canonical.hasPrefix(root + "/") else {
                if isMarkdown {
                    entries.append(entry(root: root, rootIndex: rootIndex,
                                         rootsCount: roots.count, path: url.path,
                                         canonicalPath: url.path, bytes: 0, mtime: 0,
                                         title: nil, sha: nil,
                                         skip: "path escapes root"))
                }
                continue
            }
            let bytes = Int64(values?.fileSize ?? 0)
            let mtime = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            if values?.isSymbolicLink == true {
                if isMarkdown {
                    entries.append(entry(root: root, rootIndex: rootIndex,
                                         rootsCount: roots.count, path: url.path,
                                         canonicalPath: canonical, bytes: bytes,
                                         mtime: mtime, title: nil, sha: nil,
                                         skip: "symlink"))
                }
                continue
            }
            guard values?.isRegularFile == true else {
                if isMarkdown {
                    entries.append(entry(root: root, rootIndex: rootIndex,
                                         rootsCount: roots.count, path: url.path,
                                         canonicalPath: canonical, bytes: bytes,
                                         mtime: mtime, title: nil, sha: nil,
                                         skip: "not a regular file"))
                }
                continue
            }
            guard isMarkdown else { continue }
            guard bytes <= options.maxBytes else {
                entries.append(entry(root: root, rootIndex: rootIndex,
                                     rootsCount: roots.count, path: url.path,
                                     canonicalPath: canonical, bytes: bytes,
                                     mtime: mtime, title: nil, sha: nil,
                                     skip: "oversized"))
                continue
            }
            guard let raw = try? readMarkdown(canonical, maxBytes: options.maxBytes) else {
                entries.append(entry(root: root, rootIndex: rootIndex,
                                     rootsCount: roots.count, path: url.path,
                                     canonicalPath: canonical, bytes: bytes,
                                     mtime: mtime, title: nil, sha: nil,
                                     skip: "not utf-8"))
                continue
            }
            let canonicalText = normalizeMarkdown(raw)
            let sha = hex(Normaliser.contentSHA(canonicalText))
            entries.append(entry(root: root, rootIndex: rootIndex,
                                 rootsCount: roots.count, path: url.path,
                                 canonicalPath: canonical, bytes: bytes, mtime: mtime,
                                 title: markdownTitle(canonicalText, fallback: name),
                                 sha: sha, skip: nil))
        }
    }
    return entries
}

func entry(root: String, rootIndex: Int, rootsCount: Int, path: String,
           canonicalPath: String, bytes: Int64, mtime: Int64,
           title: String?, sha: String?, skip: String?) -> MarkdownManifestEntry {
    let relative = relativePath(canonicalPath, root: root)
    let relativeID = rootsCount > 1
        ? "\(URL(fileURLWithPath: root).lastPathComponent)/\(relative)"
        : relative
    return MarkdownManifestEntry(
        root: root,
        absolutePath: canonicalPath,
        relativeID: relativeID.isEmpty ? "\(rootIndex)" : relativeID,
        sourceURI: URL(fileURLWithPath: canonicalPath).absoluteString,
        title: title,
        bytes: bytes,
        mtime: mtime,
        sha256: sha,
        skipReason: skip)
}

func readMarkdown(entry: MarkdownManifestEntry, maxBytes: Int64) throws -> String? {
    guard let current = realPath(entry.absolutePath),
          current == entry.absolutePath,
          current == entry.sourceURIFilePath else {
        return nil
    }
    return try readMarkdown(current, maxBytes: maxBytes)
}

func readMarkdown(_ path: String, maxBytes: Int64) throws -> String? {
    let fd: Int32 = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var st = stat()
    guard fstat(fd, &st) == 0 else { return nil }
    let kind = st.st_mode & mode_t(S_IFMT)
    guard kind == mode_t(S_IFREG), st.st_size <= maxBytes else { return nil }

    var data = Data()
    data.reserveCapacity(Int(min(Int64(st.st_size), maxBytes)))
    var remaining = maxBytes + 1
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while remaining > 0 {
        let count = min(buffer.count, Int(remaining))
        let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
            #if canImport(Darwin)
            return Darwin.read(fd, raw.baseAddress, count)
            #else
            return Glibc.read(fd, raw.baseAddress, count)
            #endif
        }
        if readCount == 0 { break }
        guard readCount > 0 else { return nil }
        data.append(contentsOf: buffer.prefix(readCount))
        remaining -= Int64(readCount)
        if Int64(data.count) > maxBytes { return nil }
    }
    return String(data: data, encoding: .utf8)
}

func normalizeMarkdown(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func markdownTitle(_ text: String, fallback: String) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            if trimmed.lowercased().hasPrefix("title:") {
                let raw = trimmed.dropFirst("title:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !raw.isEmpty { return raw }
            }
        }
    }
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("# ") {
            let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
    }
    return (fallback as NSString).deletingPathExtension
}

func relativePath(_ path: String, root: String) -> String {
    if path == root { return "" }
    if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
    return path
}

func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func deterministicJobID(roots: [String], entries: [MarkdownManifestEntry],
                        extractMode: Bool) -> String {
    let body = (roots.sorted() + entries.map {
        "\($0.sourceURI)|\($0.sha256 ?? "")|\($0.skipReason ?? "")"
    } + ["extract=\(extractMode)"]).joined(separator: "\n")
    return String(hex(Normaliser.contentSHA(body)).prefix(16))
}

extension MarkdownManifestEntry {
    var sourceURIFilePath: String? {
        URL(string: sourceURI)?.path
    }
}

func validateJobID(_ raw: String) throws -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    guard !raw.isEmpty,
          raw.count <= 128,
          raw.rangeOfCharacter(from: allowed.inverted) == nil,
          !raw.contains(".."),
          raw != "." else {
        throw argumentError("job id must use only letters, numbers, '.', '_' or '-' and must not contain '..'")
    }
    return raw
}

private func stateFileURL(jobID: String, options: MarkdownImportOptions) throws -> URL {
    let safeJobID = try validateJobID(jobID)
    let root = options.stateRoot
        ?? ((ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex"))
            + "/memory/imports/markdown")
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let rootPath = (realPath(root) ?? root).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let statePath = rootPath + "/" + safeJobID + ".state.json"
    guard statePath.hasPrefix(rootPath + "/") else {
        throw argumentError("job id escapes import state directory")
    }
    return URL(fileURLWithPath: "/" + statePath)
}

private func loadState(_ url: URL) -> MarkdownImportState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(MarkdownImportState.self, from: data)
}

private func saveState(jobID: String, manifestDigest: String, extractMode: Bool,
                       completed: [CompletedMarkdownImport], updatedAt: Int64,
                       to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let state = MarkdownImportState(jobID: jobID,
                                    manifestDigest: manifestDigest,
                                    extractMode: extractMode,
                                    completed: completed.sorted { $0.sourceURI < $1.sourceURI },
                                    updatedAt: updatedAt)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(state)
    try data.write(to: url, options: .atomic)
}

private func parseArgs(_ args: [String]) throws -> (options: MarkdownImportOptions, roots: [String]) {
    var options = MarkdownImportOptions()
    var roots: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--dry-run": options.dryRun = true
        case "--json": options.json = true
        case "--extract": options.extractMode = true
        case "--force": options.force = true
        case "--resume": options.resume = true
        case "--restart": options.restart = true
        case "--job-id":
            i += 1
            guard i < args.count else { throw argumentError("--job-id requires a value") }
            options.jobID = try validateJobID(args[i])
        case let s where s.hasPrefix("--job-id="):
            options.jobID = try validateJobID(String(s.dropFirst("--job-id=".count)))
        case "--batch-size":
            i += 1
            guard i < args.count, let n = Int(args[i]), n > 0 else {
                throw argumentError("--batch-size requires a positive integer")
            }
            options.batchSize = n
        case let s where s.hasPrefix("--batch-size="):
            guard let n = Int(s.dropFirst("--batch-size=".count)), n > 0 else {
                throw argumentError("--batch-size requires a positive integer")
            }
            options.batchSize = n
        case "--progress-file":
            i += 1
            guard i < args.count else { throw argumentError("--progress-file requires a value") }
            options.progressPath = args[i]
        case let s where s.hasPrefix("--progress-file="):
            options.progressPath = String(s.dropFirst("--progress-file=".count))
        case "--concurrency":
            i += 1
            guard i < args.count, let n = Int(args[i]), n > 0 else {
                throw argumentError("--concurrency requires a positive integer")
            }
            options.concurrency = n
        case let s where s.hasPrefix("--concurrency="):
            guard let n = Int(s.dropFirst("--concurrency=".count)), n > 0 else {
                throw argumentError("--concurrency requires a positive integer")
            }
            options.concurrency = n
        case "--max-bytes":
            i += 1
            guard i < args.count, let n = Int64(args[i]), n > 0 else {
                throw argumentError("--max-bytes requires a positive integer")
            }
            options.maxBytes = n
        case let s where s.hasPrefix("--max-bytes="):
            guard let n = Int64(s.dropFirst("--max-bytes=".count)), n > 0 else {
                throw argumentError("--max-bytes requires a positive integer")
            }
            options.maxBytes = n
        default:
            if arg.hasPrefix("--") { throw argumentError("unknown option \(arg)") }
            roots.append(arg)
        }
        i += 1
    }
    return (options, roots)
}

private func argumentError(_ message: String) -> NSError {
    NSError(domain: "CodexMemoryMarkdownImport", code: 2,
            userInfo: [NSLocalizedDescriptionKey: message])
}

/// Rewrite a tiny JSON progress snapshot (atomically) so an external monitor
/// can poll live counts. No-op when no progress path was requested.
func writeProgress(_ report: MarkdownImportReport, to path: String?) {
    guard let path else { return }
    // `succeeded` = imported + unchanged ONLY (NOT failed). The resilient import driver
    // gates COMPLETE on this, never on `processed` (which includes failures) — else a
    // clean-checkout run where MLX throws providerUnavailable on every doc would reach
    // processed==discovered and be declared "complete", stamping an empty/degraded corpus
    // authoritative. `processed` stays for display + the stuck-detector.
    let succeeded = report.imported + report.unchanged
    let processed = succeeded + report.failed
    let obj: [String: Any] = [
        "discovered": report.discovered,
        "processed": processed,
        "succeeded": succeeded,
        "imported": report.imported,
        "unchanged": report.unchanged,
        "skipped": report.skipped,
        "failed": report.failed,
        "chunks": report.chunks,
        "entities": report.entities,
        "updated_at": Int(Date().timeIntervalSince1970),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}
