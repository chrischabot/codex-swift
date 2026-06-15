import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import MemoryInfer
import MemoryIngest
import MemoryProcess
import MemoryStore

struct WikiCompileOptions: Sendable {
    var vaultPath: String?
    var dbPath: String?
    var json: Bool = false
    var dryRun: Bool = false
    var indexCompiledPages: Bool = false
    var limit: Int = 10_000
    var clock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
}

struct WikiCompileReport: Sendable, Equatable {
    var vaultPath: String
    var sourcePages: Int = 0
    var entityPages: Int = 0
    var claimPages: Int = 0
    var digestFiles: Int = 0
    var indexed: Int = 0
    var indexUnchanged: Int = 0
    var failed: Int = 0
    var outputs: [String] = []
    var errors: [String] = []

    var summaryLine: String {
        "wiki-compile summary: sources=\(sourcePages) entities=\(entityPages) "
            + "claims=\(claimPages) digests=\(digestFiles) indexed=\(indexed) "
            + "index_unchanged=\(indexUnchanged) failed=\(failed) vault=\(vaultPath)"
    }

    func jsonObject() -> [String: Any] {
        [
            "vault": vaultPath,
            "source_pages": sourcePages,
            "entity_pages": entityPages,
            "claim_pages": claimPages,
            "digest_files": digestFiles,
            "indexed": indexed,
            "index_unchanged": indexUnchanged,
            "failed": failed,
            "outputs": outputs,
            "errors": errors,
        ]
    }
}

enum WikiLintSeverity: String, Sendable, Codable {
    case error
    case warning
    case info
}

struct WikiLintIssue: Sendable, Equatable, Codable {
    var severity: WikiLintSeverity
    var code: String
    var message: String
    var path: String?
    var sourceURI: String?
}

struct WikiLintOptions: Sendable {
    var vaultPath: String?
    var dbPath: String?
    var json: Bool = false
    var maxBytes: Int64 = 10 * 1024 * 1024
    var limit: Int = 10_000
    var apply: Bool = false   // auto-fix the safe, mechanical issues (idempotent)
}

struct WikiLintReport: Sendable, Equatable {
    var roots: [String]
    var vaultPath: String?
    var checkedFiles: Int = 0
    var checkedDocuments: Int = 0
    var issues: [WikiLintIssue] = []
    var storeHealth: MemoryStoreIndexHealth?
    var appliedFixes: [String] = []   // human-readable record of --apply repairs

    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }

    var summaryLine: String {
        "wiki-lint summary: errors=\(errorCount) warnings=\(warningCount) "
            + "files=\(checkedFiles) documents=\(checkedDocuments)"
            + (appliedFixes.isEmpty ? "" : " fixed=\(appliedFixes.count)")
    }

    func jsonObject() -> [String: Any] {
        var out: [String: Any] = [
            "roots": roots,
            "vault": vaultPath as Any,
            "checked_files": checkedFiles,
            "checked_documents": checkedDocuments,
            "errors": errorCount,
            "warnings": warningCount,
            "issues": issues.map { issue in
                [
                    "severity": issue.severity.rawValue,
                    "code": issue.code,
                    "message": issue.message,
                    "path": issue.path as Any,
                    "source_uri": issue.sourceURI as Any,
                ].compactMapValues { unwrapOptional($0) }
            },
        ]
        if let health = storeHealth {
            out["store_health"] = [
                "documents": health.documentCount,
                "chunks": health.chunkCount,
                "entities": health.entityCount,
                "edges": health.edgeCount,
                "zero_chunk_document_ids": health.zeroChunkDocumentIds,
                "orphan_chunk_ids": health.orphanChunkIds,
                "chunks_missing_vector": health.chunksMissingVector,
                "stale_vector_row_ids": health.staleVectorRowIds,
                "fts_integrity_ok": health.ftsIntegrityOK,
                "fts_integrity_error": health.ftsIntegrityError as Any,
            ].compactMapValues { unwrapOptional($0) }
        }
        if !appliedFixes.isEmpty { out["applied_fixes"] = appliedFixes }
        return out.compactMapValues { unwrapOptional($0) }
    }
}

public enum CodexMemoryWikiCompile {
    static func runDetailed(args: [String]) async throws -> (report: WikiCompileReport, output: String) {
        let options = try parseCompileArgs(args)
        guard let vaultPath = options.vaultPath else {
            throw wikiArgumentError("wiki-compile requires --vault PATH")
        }
        let report: WikiCompileReport
        if options.indexCompiledPages {
            if options.dbPath != nil {
                throw wikiArgumentError("--index uses the assembled default memory store; omit --db")
            }
            let bundle = try await CodexMemoryRun.assemble()
            report = try await compile(store: bundle.store,
                                       processor: bundle.processor,
                                       options: options)
        } else {
            let store = try MemoryStore(MemoryStoreConfig(
                path: options.dbPath ?? MemoryStoreConfig.defaultPath()))
            report = try await compile(store: store, processor: nil, options: options)
        }
        _ = vaultPath
        return (report, format(report, json: options.json))
    }

    static func compile(store: MemoryStore,
                        processor: MemoryProcessor?,
                        options: WikiCompileOptions) async throws -> WikiCompileReport {
        guard let vaultPath = options.vaultPath else {
            throw wikiArgumentError("wiki-compile requires --vault PATH")
        }
        let vault = try WikiVault(path: vaultPath, dryRun: options.dryRun)
        let documents = try await store.documentChunkSummaries(limit: options.limit)
            .filter { !isCompiledURI($0.document.sourceURI) }
        let entities = try await store.entities(limit: options.limit)
        let edges = try await store.edges(limit: options.limit)
        let entityByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })

        var pages: [WikiCompiledPage] = []
        pages.reserveCapacity(documents.count + entities.count + edges.count)
        for summary in documents {
            let relative = sourcePagePath(summary.document)
            pages.append(renderSourcePage(summary, human: vault.humanBlock(relativePath: relative)))
        }
        for entity in entities {
            let related = edges.filter { $0.src == entity.id || $0.dst == entity.id }
            let relative = entityPagePath(entity)
            pages.append(renderEntityPage(entity, edges: related, entityByID: entityByID,
                                          human: vault.humanBlock(relativePath: relative)))
        }
        for edge in edges {
            let src = entityByID[edge.src]?.canonical ?? "\(edge.src)"
            let dst = entityByID[edge.dst]?.canonical ?? "\(edge.dst)"
            let relative = claimPagePath(edge: edge, src: src, dst: dst)
            pages.append(try await renderClaimPage(edge, entityByID: entityByID,
                                                   store: store,
                                                   human: vault.humanBlock(relativePath: relative)))
        }
        pages.sort { $0.relativePath < $1.relativePath }

        var report = WikiCompileReport(vaultPath: vault.rootPath)
        for page in pages {
            switch page.kind {
            case .source: report.sourcePages += 1
            case .entity: report.entityPages += 1
            case .claim: report.claimPages += 1
            case .digest: report.digestFiles += 1
            }
            if !options.dryRun {
                do {
                    try vault.write(relativePath: page.relativePath, content: page.content)
                } catch {
                    report.failed += 1
                    report.errors.append("\(page.relativePath): \(error)")
                    continue
                }
            }
            report.outputs.append(page.relativePath)
        }

        let digest = try makeAgentDigest(pages: pages,
                                         documents: documents,
                                         entities: entities,
                                         edges: edges)
        let manifest = try makeCompileManifest(pages: pages, digest: digest)
        let digestPath = "_digests/agent-digest.json"
        let manifestPath = "_digests/compile-manifest.json"
        if !options.dryRun {
            try vault.write(relativePath: digestPath, content: digest)
            try vault.write(relativePath: manifestPath, content: manifest)
        }
        report.digestFiles = 2
        report.outputs.append(contentsOf: [digestPath, manifestPath])

        if options.indexCompiledPages, let processor {
            for page in pages + [
                WikiCompiledPage(kind: .digest, relativePath: digestPath,
                                 title: "Agent Digest", sourceURI: "wiki://compiled/\(digestPath)",
                                 content: digest),
            ] {
                do {
                    let result = try await indexCompiledPage(page, store: store,
                                                            processor: processor,
                                                            clock: options.clock)
                    if result { report.indexed += 1 } else { report.indexUnchanged += 1 }
                } catch {
                    report.failed += 1
                    report.errors.append("index \(page.relativePath): \(error)")
                }
            }
        }

        report.outputs.sort()
        report.errors.sort()
        return report
    }

    static func format(_ report: WikiCompileReport, json: Bool) -> String {
        if json { return jsonString(report.jsonObject()) + "\n" }
        var lines = [report.summaryLine]
        for error in report.errors { lines.append("FAIL \(error)") }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum CodexMemoryWikiLint {
    static func runDetailed(args: [String]) async throws -> (report: WikiLintReport, output: String) {
        let parsed = try parseLintArgs(args)
        let store = try MemoryStore(MemoryStoreConfig(
            path: parsed.options.dbPath ?? MemoryStoreConfig.defaultPath()))
        let report = try await lint(roots: parsed.roots,
                                    store: store,
                                    options: parsed.options)
        return (report, format(report, json: parsed.options.json))
    }

    static func lint(roots: [String],
                     store: MemoryStore,
                     options: WikiLintOptions) async throws -> WikiLintReport {
        var canonicalRoots: [String] = []
        for root in roots {
            guard let path = realPath(root) else {
                throw wikiArgumentError("root not found: \(root)")
            }
            canonicalRoots.append(path)
        }
        var report = WikiLintReport(roots: canonicalRoots, vaultPath: options.vaultPath)
        let importOptions = MarkdownImportOptions(dryRun: true, maxBytes: options.maxBytes)
        let entries = discover(roots: canonicalRoots, options: importOptions)
            .sorted { $0.absolutePath < $1.absolutePath }
        report.checkedFiles = entries.filter { $0.skipReason == nil }.count
        lintMarkdownEntries(entries, into: &report, maxBytes: options.maxBytes)

        let health = try await store.indexHealth()
        report.storeHealth = health
        report.checkedDocuments = health.documentCount
        appendStoreHealthIssues(health, into: &report)

        let docs = try await store.documentChunkSummaries(limit: options.limit)
            .filter { !isCompiledURI($0.document.sourceURI) }
        let entities = try await store.entities(limit: options.limit)
        if let vaultPath = options.vaultPath {
            try lintVault(path: vaultPath, documents: docs,
                          health: health, into: &report)
        }
        for entity in entities where entity.degree == 0 {
            let mentioning = try await store.chunksMentioning(entity.id, limit: 1)
            if mentioning.isEmpty {
                report.issues.append(WikiLintIssue(
                    severity: .warning,
                    code: "orphan_entity",
                    message: "entity has no edges and no chunk mentions: \(entity.kind.rawValue)/\(entity.canonical)",
                    path: nil,
                    sourceURI: nil))
            }
        }
        report.issues.sort {
            ($0.severity.rawValue, $0.code, $0.path ?? "", $0.message)
                < ($1.severity.rawValue, $1.code, $1.path ?? "", $1.message)
        }
        // --apply: repair the safe, mechanical issues idempotently (currently the
        // store-derived digest counts). Runs after detection so it can resolve the
        // issues it fixes.
        if options.apply {
            applyDigestFixes(report: &report, vaultPath: options.vaultPath,
                             documentCount: docs.count, health: health)
        }
        return report
    }

    /// `--apply` fixer for the agent-digest projection. Regenerates the digest's
    /// store-derived counts (the `stale_digest`/`missing_digest` drift signal) from the
    /// store — the source of truth — preserving any existing per-page lists, and creating
    /// a minimal digest if absent. Idempotent: once the counts match, a re-lint reports
    /// no stale/missing digest. Does NOT rebuild the per-page lists (a full `wiki-compile`
    /// does that), never creates absent OPTIONAL trees, and never mutates knowledge.
    static func applyDigestFixes(report: inout WikiLintReport, vaultPath: String?,
                                 documentCount: Int, health: MemoryStoreIndexHealth) {
        guard let vaultPath else { return }
        guard report.issues.contains(where: { $0.code == "stale_digest" || $0.code == "missing_digest" }) else { return }
        let digestRel = "_digests/agent-digest.json"
        let digestURL = URL(fileURLWithPath: vaultPath).appendingPathComponent(digestRel)
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: digestURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing   // preserve page lists + other fields
        } else {
            object["version"] = 1
            object["source_pages"] = []; object["entity_pages"] = []; object["claim_pages"] = []
        }
        object["documents"] = documentCount   // must match lint's filtered doc count
        object["chunks"] = health.chunkCount
        object["entities"] = health.entityCount
        object["edges"] = health.edgeCount
        // Write THROUGH WikiVault so the digest path gets the same protections as every
        // other vault write: refuses to overwrite a symlink, refuses paths that escape
        // the canonicalized root, writes atomically, and matches wiki-compile's compact
        // serialization (so the manifest sha doesn't needlessly drift).
        do {
            let vault = try WikiVault(path: vaultPath, dryRun: false)
            try vault.write(relativePath: digestRel, content: jsonString(object) + "\n")
        } catch {
            report.appliedFixes.append("FAILED to write \(digestRel): \(error)")
            return
        }
        report.appliedFixes.append("regenerated \(digestRel) counts "
            + "(documents=\(documentCount), chunks=\(health.chunkCount), "
            + "entities=\(health.entityCount), edges=\(health.edgeCount))")
        report.issues.removeAll { $0.code == "stale_digest" || $0.code == "missing_digest" }
    }

    static func format(_ report: WikiLintReport, json: Bool) -> String {
        if json { return jsonString(report.jsonObject()) + "\n" }
        var lines = [report.summaryLine]
        for issue in report.issues {
            let location = issue.path ?? issue.sourceURI ?? "-"
            lines.append("\(issue.severity.rawValue.uppercased()) \(issue.code) \(location): \(issue.message)")
        }
        for fix in report.appliedFixes { lines.append("FIXED \(fix)") }
        return lines.joined(separator: "\n") + "\n"
    }
}

private enum WikiPageKind: String {
    case source
    case entity
    case claim
    case digest
}

private struct WikiCompiledPage: Equatable {
    var kind: WikiPageKind
    var relativePath: String
    var title: String
    var sourceURI: String
    var content: String
}

private struct WikiVault {
    var rootPath: String
    var dryRun: Bool

    init(path: String, dryRun: Bool) throws {
        if !dryRun {
            try FileManager.default.createDirectory(atPath: path,
                                                    withIntermediateDirectories: true)
        }
        let canonical = realPath(path) ?? URL(fileURLWithPath: path).standardizedFileURL.path
        self.rootPath = canonical
        self.dryRun = dryRun
    }

    func write(relativePath: String, content: String) throws {
        guard !dryRun else { return }
        guard isSafeRelativePath(relativePath) else {
            throw wikiArgumentError("unsafe vault path: \(relativePath)")
        }
        let url = URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let parentReal = realPath(parent.path),
              parentReal == rootPath || parentReal.hasPrefix(rootPath + "/") else {
            throw wikiArgumentError("vault write escapes root: \(relativePath)")
        }
        var statBuf = stat()
        if lstat(url.path, &statBuf) == 0 {
            let kind = statBuf.st_mode & mode_t(S_IFMT)
            guard kind != mode_t(S_IFLNK) else {
                throw wikiArgumentError("refusing to overwrite symlink: \(relativePath)")
            }
        }
        guard let data = content.data(using: .utf8) else {
            throw wikiArgumentError("content is not utf-8 encodable: \(relativePath)")
        }
        try data.write(to: url, options: .atomic)
    }

    func readIfPresent(relativePath: String) -> String? {
        guard isSafeRelativePath(relativePath) else { return nil }
        let url = URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func humanBlock(relativePath: String) -> String {
        guard let existing = readIfPresent(relativePath: relativePath) else { return "" }
        return extractHumanBlock(existing) ?? ""
    }
}

private func renderSourcePage(_ summary: DocumentChunkSummary, human: String) -> WikiCompiledPage {
    let doc = summary.document
    let title = doc.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty ?? URL(string: doc.sourceURI)?.lastPathComponent.nilIfEmpty
        ?? doc.sourceURI
    let relative = sourcePagePath(doc)
    let content = """
    ---
    wiki_type: source
    source_uri: \(quoted(doc.sourceURI))
    title: \(quoted(title))
    source: \(quoted(doc.source.rawValue))
    content_sha: \(quoted(hex(doc.contentSHA)))
    fetched_at: \(doc.fetchedAt)
    chunks: \(summary.chunkCount)
    ---
    # \(title)

    ## Source
    - URI: \(doc.sourceURI)
    - Kind: \(doc.source.rawValue)
    - Chunks: \(summary.chunkCount)
    - SHA-256: \(hex(doc.contentSHA))

    ## Human Notes
    <!-- codex-wiki:human:start -->
    \(human)
    <!-- codex-wiki:human:end -->
    """
    return WikiCompiledPage(kind: .source, relativePath: relative, title: title,
                            sourceURI: "wiki://compiled/\(relative)", content: content + "\n")
}

private func renderEntityPage(_ entity: EntityRow,
                              edges: [EdgeRow],
                              entityByID: [Int64: EntityRow],
                              human: String) -> WikiCompiledPage {
    let title = entity.canonical
    let relative = entityPagePath(entity)
    let edgeLines = edges.sorted { ($0.relation, $0.src, $0.dst) < ($1.relation, $1.src, $1.dst) }
        .map { edge -> String in
            let src = entityByID[edge.src]?.canonical ?? "\(edge.src)"
            let dst = entityByID[edge.dst]?.canonical ?? "\(edge.dst)"
            return "- \(src) --\(edge.relation)--> \(dst) (weight \(formatDouble(edge.weight)))"
        }
    let aliases = entity.aliases.sorted().joined(separator: ", ")
    let content = """
    ---
    wiki_type: entity
    entity_kind: \(quoted(entity.kind.rawValue))
    canonical: \(quoted(entity.canonical))
    degree: \(entity.degree)
    ---
    # \(title)

    ## Profile
    - Kind: \(entity.kind.rawValue)
    - Aliases: \(aliases.isEmpty ? "None" : aliases)
    - Degree: \(entity.degree)

    ## Backlinks
    \(edgeLines.isEmpty ? "No graph links yet." : edgeLines.joined(separator: "\n"))

    ## Human Notes
    <!-- codex-wiki:human:start -->
    \(human)
    <!-- codex-wiki:human:end -->
    """
    return WikiCompiledPage(kind: .entity, relativePath: relative, title: title,
                            sourceURI: "wiki://compiled/\(relative)", content: content + "\n")
}

private func renderClaimPage(_ edge: EdgeRow,
                             entityByID: [Int64: EntityRow],
                             store: MemoryStore,
                             human: String) async throws -> WikiCompiledPage {
    let src = entityByID[edge.src]?.canonical ?? "\(edge.src)"
    let dst = entityByID[edge.dst]?.canonical ?? "\(edge.dst)"
    let title = "\(src) \(edge.relation) \(dst)"
    let relative = claimPagePath(edge: edge, src: src, dst: dst)
    let evidence: ChunkEvidenceRow?
    if let evidenceChunkId = edge.evidenceChunkId {
        evidence = try await store.chunkEvidence(id: evidenceChunkId)
    } else {
        evidence = nil
    }
    let evidenceURI = evidence?.document?.sourceURI ?? "missing"
    let snippet = evidence?.chunk.text.prefix(800).replacingOccurrences(of: "\n", with: " ") ?? ""
    let status = evidence == nil ? "weak_evidence" : "active"
    let content = """
    ---
    wiki_type: claim
    status: \(quoted(status))
    relation: \(quoted(edge.relation))
    source_entity: \(quoted(src))
    target_entity: \(quoted(dst))
    evidence_uri: \(quoted(evidenceURI))
    ---
    # \(title)

    ## Claim
    \(src) \(edge.relation) \(dst).

    ## Evidence
    - Source: \(evidenceURI)
    - Chunk: \(edge.evidenceChunkId.map(String.init) ?? "missing")
    - Snippet: \(snippet.isEmpty ? "No evidence chunk is attached." : String(snippet))

    ## Human Notes
    <!-- codex-wiki:human:start -->
    \(human)
    <!-- codex-wiki:human:end -->
    """
    return WikiCompiledPage(kind: .claim, relativePath: relative, title: title,
                            sourceURI: "wiki://compiled/\(relative)", content: content + "\n")
}

private func sourcePagePath(_ doc: DocumentRow) -> String {
    let title = URL(string: doc.sourceURI)?.lastPathComponent.nilIfEmpty ?? doc.sourceURI
    let id = String(hex(Normaliser.contentSHA(doc.sourceURI)).prefix(12))
    return "sources/\(slug(title))-\(id).md"
}

private func entityPagePath(_ entity: EntityRow) -> String {
    let id = String(hex(Normaliser.contentSHA("\(entity.kind.rawValue):\(entity.canonical)")).prefix(12))
    return "entities/\(entity.kind.rawValue)/\(slug(entity.canonical))-\(id).md"
}

private func claimPagePath(edge: EdgeRow, src: String, dst: String) -> String {
    let key = "\(src)|\(edge.relation)|\(dst)"
    let id = String(hex(Normaliser.contentSHA(key)).prefix(12))
    return "claims/\(slug(src + "-" + edge.relation + "-" + dst))-\(id).md"
}

private func makeAgentDigest(pages: [WikiCompiledPage],
                             documents: [DocumentChunkSummary],
                             entities: [EntityRow],
                             edges: [EdgeRow]) throws -> String {
    let sourcePages = pages.filter { $0.kind == .source }.map {
        ["path": $0.relativePath, "title": $0.title, "sha256": hex(Normaliser.contentSHA($0.content))]
    }
    let entityPages = pages.filter { $0.kind == .entity }.map {
        ["path": $0.relativePath, "title": $0.title, "sha256": hex(Normaliser.contentSHA($0.content))]
    }
    let claimPages = pages.filter { $0.kind == .claim }.map {
        ["path": $0.relativePath, "title": $0.title, "sha256": hex(Normaliser.contentSHA($0.content))]
    }
    let object: [String: Any] = [
        "version": 1,
        "documents": documents.count,
        "chunks": documents.reduce(0) { $0 + $1.chunkCount },
        "entities": entities.count,
        "edges": edges.count,
        "source_pages": sourcePages,
        "entity_pages": entityPages,
        "claim_pages": claimPages,
        "limitations": [
            "per-page lists reflect the last full wiki-compile; counts are refreshed by wiki-lint --apply",
        ],
    ]
    return jsonString(object) + "\n"
}

private func makeCompileManifest(pages: [WikiCompiledPage], digest: String) throws -> String {
    let files = pages.map {
        [
            "path": $0.relativePath,
            "kind": $0.kind.rawValue,
            "sha256": hex(Normaliser.contentSHA($0.content)),
        ]
    } + [[
        "path": "_digests/agent-digest.json",
        "kind": "digest",
        "sha256": hex(Normaliser.contentSHA(digest)),
    ]]
    return jsonString(["version": 1, "files": files.sorted { $0["path"]! < $1["path"]! }]) + "\n"
}

private func indexCompiledPage(_ page: WikiCompiledPage,
                               store: MemoryStore,
                               processor: MemoryProcessor,
                               clock: @Sendable () -> Int64) async throws -> Bool {
    let canonical = normalizeMarkdown(page.content)
    let sha = Normaliser.contentSHA(canonical)
    let expectedChunks = MemoryProcessor.Config().splitter.split(canonical).count
    if let existing = try await store.document(byURI: page.sourceURI),
       existing.contentSHA == sha,
       try await store.chunkCount(documentId: existing.id) == expectedChunks {
        return false
    }
    let stagedURI = "wiki://compiled/staging/\(hex(sha))/\(page.relativePath)"
    if let stale = try await store.document(byURI: stagedURI) {
        try await store.deleteDocument(id: stale.id)
    }
    let doc = IngestedDocument(
        sourceName: "wiki-compiled",
        sourceKind: .manual,
        sourceURI: stagedURI,
        title: page.title,
        publishedAt: nil,
        fetchedAt: clock(),
        canonicalText: canonical,
        rawBytes: Int64(canonical.utf8.count),
        contentSHA: sha)
    let processed = try await processor.process(doc, extract: false)
    try await store.promoteStagedDocument(
        stagedId: processed.documentId,
        sourceURI: page.sourceURI,
        bodyPath: "inline:\(page.sourceURI)",
        title: page.title)
    return true
}

private func lintMarkdownEntries(_ entries: [MarkdownManifestEntry],
                                 into report: inout WikiLintReport,
                                 maxBytes: Int64) {
    var byTitle: [String: [MarkdownManifestEntry]] = [:]
    var bySHA: [String: [MarkdownManifestEntry]] = [:]
    let validPaths = Set(entries.filter { $0.skipReason == nil }.map(\.absolutePath))
    for entry in entries {
        if let reason = entry.skipReason {
            report.issues.append(WikiLintIssue(
                severity: .warning,
                code: "markdown_skipped",
                message: reason,
                path: entry.absolutePath,
                sourceURI: entry.sourceURI))
            continue
        }
        if let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            byTitle[title.lowercased(), default: []].append(entry)
        }
        if let sha = entry.sha256 { bySHA[sha, default: []].append(entry) }
        guard let raw = try? readMarkdown(entry: entry, maxBytes: maxBytes) else { continue }
        if !hasExplicitTitle(raw) {
            report.issues.append(WikiLintIssue(
                severity: .warning,
                code: "missing_explicit_title",
                message: "markdown has no front-matter title or H1",
                path: entry.absolutePath,
                sourceURI: entry.sourceURI))
        }
        if hasUnclosedFrontMatter(raw) {
            report.issues.append(WikiLintIssue(
                severity: .error,
                code: "bad_front_matter",
                message: "front matter starts with --- but has no closing ---",
                path: entry.absolutePath,
                sourceURI: entry.sourceURI))
        }
        for broken in brokenMarkdownLinks(raw, entry: entry, validPaths: validPaths) {
            report.issues.append(WikiLintIssue(
                severity: .warning,
                code: "broken_link",
                message: "link target not found: \(broken)",
                path: entry.absolutePath,
                sourceURI: entry.sourceURI))
        }
    }
    for (_, group) in byTitle where group.count > 1 {
        for entry in group {
            report.issues.append(WikiLintIssue(
                severity: .warning,
                code: "duplicate_title",
                message: "title is shared by \(group.count) files",
                path: entry.absolutePath,
                sourceURI: entry.sourceURI))
        }
    }
    for (_, group) in bySHA where group.count > 1 {
        for entry in group {
            report.issues.append(WikiLintIssue(
                severity: .info,
                code: "duplicate_content_sha",
                message: "content hash is shared by \(group.count) files",
                path: entry.absolutePath,
                sourceURI: entry.sourceURI))
        }
    }
}

private func appendStoreHealthIssues(_ health: MemoryStoreIndexHealth,
                                     into report: inout WikiLintReport) {
    for id in health.zeroChunkDocumentIds {
        report.issues.append(WikiLintIssue(
            severity: .error,
            code: "zero_chunk_document",
            message: "document has no chunks",
            path: nil,
            sourceURI: "document:\(id)"))
    }
    for id in health.orphanChunkIds {
        report.issues.append(WikiLintIssue(
            severity: .error,
            code: "orphan_chunk",
            message: "chunk has no owning document",
            path: nil,
            sourceURI: "chunk:\(id)"))
    }
    for id in health.chunksMissingVector {
        report.issues.append(WikiLintIssue(
            severity: .error,
            code: "missing_vector",
            message: "chunk is missing a vector row",
            path: nil,
            sourceURI: "chunk:\(id)"))
    }
    for id in health.staleVectorRowIds {
        report.issues.append(WikiLintIssue(
            severity: .error,
            code: "stale_vector",
            message: "vector row has no chunk",
            path: nil,
            sourceURI: "chunk:\(id)"))
    }
    if !health.ftsIntegrityOK {
        report.issues.append(WikiLintIssue(
            severity: .error,
            code: "fts_integrity",
            message: health.ftsIntegrityError ?? "FTS integrity check failed",
            path: nil,
            sourceURI: nil))
    }
}

private func lintVault(path: String,
                       documents: [DocumentChunkSummary],
                       health: MemoryStoreIndexHealth,
                       into report: inout WikiLintReport) throws {
    let vault = try WikiVault(path: path, dryRun: true)
    for summary in documents {
        let relative = sourcePagePath(summary.document)
        let full = URL(fileURLWithPath: vault.rootPath)
            .appendingPathComponent(relative).path
        if !FileManager.default.fileExists(atPath: full) {
            report.issues.append(WikiLintIssue(
                severity: .warning,
                code: "uncompiled_source",
                message: "imported source has no compiled source page",
                path: relative,
                sourceURI: summary.document.sourceURI))
        }
    }
    let digestPath = URL(fileURLWithPath: vault.rootPath)
        .appendingPathComponent("_digests/agent-digest.json").path
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: digestPath)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        // Gate on the SAME filtered set the digest tracks (non-compiled `documents`),
        // not the raw store count, so missing-detection and the count written by
        // --apply share one definition.
        if !documents.isEmpty {
            report.issues.append(WikiLintIssue(
                severity: .warning,
                code: "missing_digest",
                message: "agent-digest.json is missing or unreadable",
                path: "_digests/agent-digest.json",
                sourceURI: nil))
        }
        return
    }
    if let docs = object["documents"] as? Int, docs != documents.count {
        report.issues.append(WikiLintIssue(
            severity: .warning,
            code: "stale_digest",
            message: "digest documents=\(docs) but store documents=\(documents.count)",
            path: "_digests/agent-digest.json",
            sourceURI: nil))
    }
    if let chunks = object["chunks"] as? Int, chunks != health.chunkCount {
        report.issues.append(WikiLintIssue(
            severity: .warning,
            code: "stale_digest",
            message: "digest chunks=\(chunks) but store chunks=\(health.chunkCount)",
            path: "_digests/agent-digest.json",
            sourceURI: nil))
    }
}

private func parseCompileArgs(_ args: [String]) throws -> WikiCompileOptions {
    var options = WikiCompileOptions()
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--vault":
            i += 1
            guard i < args.count else { throw wikiArgumentError("--vault requires a path") }
            options.vaultPath = args[i]
        case let s where s.hasPrefix("--vault="):
            options.vaultPath = String(s.dropFirst("--vault=".count))
        case "--db":
            i += 1
            guard i < args.count else { throw wikiArgumentError("--db requires a path") }
            options.dbPath = args[i]
        case let s where s.hasPrefix("--db="):
            options.dbPath = String(s.dropFirst("--db=".count))
        case "--json": options.json = true
        case "--dry-run": options.dryRun = true
        case "--index": options.indexCompiledPages = true
        case "--limit":
            i += 1
            guard i < args.count, let n = Int(args[i]), n > 0 else {
                throw wikiArgumentError("--limit requires a positive integer")
            }
            options.limit = n
        case let s where s.hasPrefix("--limit="):
            guard let n = Int(s.dropFirst("--limit=".count)), n > 0 else {
                throw wikiArgumentError("--limit requires a positive integer")
            }
            options.limit = n
        default:
            throw wikiArgumentError("unknown wiki-compile option \(arg)")
        }
        i += 1
    }
    return options
}

private func parseLintArgs(_ args: [String]) throws -> (options: WikiLintOptions, roots: [String]) {
    var options = WikiLintOptions()
    var roots: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--vault":
            i += 1
            guard i < args.count else { throw wikiArgumentError("--vault requires a path") }
            options.vaultPath = args[i]
        case let s where s.hasPrefix("--vault="):
            options.vaultPath = String(s.dropFirst("--vault=".count))
        case "--db":
            i += 1
            guard i < args.count else { throw wikiArgumentError("--db requires a path") }
            options.dbPath = args[i]
        case let s where s.hasPrefix("--db="):
            options.dbPath = String(s.dropFirst("--db=".count))
        case "--json": options.json = true
        case "--apply": options.apply = true
        case "--max-bytes":
            i += 1
            guard i < args.count, let n = Int64(args[i]), n > 0 else {
                throw wikiArgumentError("--max-bytes requires a positive integer")
            }
            options.maxBytes = n
        case let s where s.hasPrefix("--max-bytes="):
            guard let n = Int64(s.dropFirst("--max-bytes=".count)), n > 0 else {
                throw wikiArgumentError("--max-bytes requires a positive integer")
            }
            options.maxBytes = n
        case "--limit":
            i += 1
            guard i < args.count, let n = Int(args[i]), n > 0 else {
                throw wikiArgumentError("--limit requires a positive integer")
            }
            options.limit = n
        case let s where s.hasPrefix("--limit="):
            guard let n = Int(s.dropFirst("--limit=".count)), n > 0 else {
                throw wikiArgumentError("--limit requires a positive integer")
            }
            options.limit = n
        default:
            if arg.hasPrefix("--") { throw wikiArgumentError("unknown wiki-lint option \(arg)") }
            roots.append(arg)
        }
        i += 1
    }
    return (options, roots)
}

private func hasExplicitTitle(_ raw: String) -> Bool {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            if trimmed.lowercased().hasPrefix("title:") {
                return !trimmed.dropFirst("title:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }
    return lines.contains { line in
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# ")
    }
}

private func hasUnclosedFrontMatter(_ raw: String) -> Bool {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
        return false
    }
    return !lines.dropFirst().contains {
        $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }
}

private func brokenMarkdownLinks(_ raw: String,
                                 entry: MarkdownManifestEntry,
                                 validPaths: Set<String>) -> [String] {
    var broken: [String] = []
    let pattern = #"\[[^\]]+\]\(([^)]+)\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    for match in regex.matches(in: raw, range: range) {
        guard match.numberOfRanges >= 2,
              let linkRange = Range(match.range(at: 1), in: raw) else { continue }
        let target = String(raw[linkRange]).split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        guard !target.isEmpty,
              !target.hasPrefix("http://"),
              !target.hasPrefix("https://"),
              !target.hasPrefix("mailto:"),
              !target.hasPrefix("#") else { continue }
        let base = (entry.absolutePath as NSString).deletingLastPathComponent
        let candidate = URL(fileURLWithPath: base)
            .appendingPathComponent(target).standardizedFileURL.path
        if let real = realPath(candidate), validPaths.contains(real) {
            continue
        }
        broken.append(target)
    }
    return broken.sorted()
}

private func extractHumanBlock(_ text: String) -> String? {
    let start = "<!-- codex-wiki:human:start -->"
    let end = "<!-- codex-wiki:human:end -->"
    guard let startRange = text.range(of: start),
          let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
        return nil
    }
    let inner = text[startRange.upperBound..<endRange.lowerBound]
    return inner.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func slug(_ raw: String) -> String {
    var out = ""
    var lastWasDash = false
    for scalar in raw.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            out.unicodeScalars.append(scalar)
            lastWasDash = false
        } else if !lastWasDash {
            out.append("-")
            lastWasDash = true
        }
        if out.count >= 80 { break }
    }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "item" : trimmed
}

private func quoted(_ raw: String) -> String {
    let escaped = raw
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func isCompiledURI(_ uri: String) -> Bool {
    uri.hasPrefix("wiki://compiled/") || uri.hasPrefix("codex-memory://import-markdown/staging/")
}

private func isSafeRelativePath(_ path: String) -> Bool {
    !path.isEmpty
        && !path.hasPrefix("/")
        && !path.split(separator: "/").contains("..")
}

private func formatDouble(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func jsonString(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object,
                                             options: [.sortedKeys]))
        ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

private func unwrapOptional(_ value: Any) -> Any? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        return mirror.children.first?.value
    }
    return value
}

private func wikiArgumentError(_ message: String) -> NSError {
    NSError(domain: "CodexMemoryWiki", code: 2,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
