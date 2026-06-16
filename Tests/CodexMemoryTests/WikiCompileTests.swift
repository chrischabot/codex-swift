import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore
@testable import MemoryProcess
@testable import MemoryInfer
import MemoryIngest

final class WikiCompileTests: XCTestCase {
    private func tempDir(_ prefix: String = "wiki-compile") throws -> String {
        let path = NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func stack(dim: Int = 8) throws -> (String, MemoryStore, MemoryProcessor) {
        let db = NSTemporaryDirectory() + "wiki-compile-\(UUID().uuidString).db"
        let store = try MemoryStore(MemoryStoreConfig(path: db, embeddingDimension: dim))
        let processor = MemoryProcessor(
            store: store,
            inference: MockInferenceProvider(embeddingDimension: dim),
            config: MemoryProcessor.Config(clock: { 1_800_000_000 }))
        return (db, store, processor)
    }

    @discardableResult
    private func seedDocument(store: MemoryStore,
                              uri: String = "file:///tmp/agent-memory.md",
                              title: String = "Agent Memory",
                              text: String = "retrieval chunk",
                              embedding: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]) async throws -> Int64 {
        let sha = Normaliser.contentSHA(title + "\n" + text)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual,
            sourceURI: uri,
            title: title,
            bodyPath: "inline:\(uri)",
            fetchedAt: 1,
            contentSHA: sha,
            rawBytes: Int64(text.utf8.count)))
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0,
                     text: text, rawText: text, tokenCount: 2, createdAt: 1),
            embeddingValues: embedding)
        return docId
    }

    func testCompileIsStableAndPreservesHumanBlocks() async throws {
        let vault = try tempDir(); defer { try? FileManager.default.removeItem(atPath: vault) }
        let (db, store, _) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        let docId = try await seedDocument(store: store)
        let alice = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Alice", firstSeen: 1, lastSeen: 1))
        let product = try await store.upsertEntity(EntityRow(
            kind: .product, canonical: "Codex Memory", firstSeen: 1, lastSeen: 1))
        let chunk = try await store.chunks(forDocument: docId).first
        _ = try await store.upsertEdge(EdgeRow(
            src: alice, dst: product, relation: "uses",
            firstSeen: 1, lastSeen: 1, evidenceChunkId: chunk?.id))

        var options = WikiCompileOptions()
        options.vaultPath = vault
        let first = try await CodexMemoryWikiCompile.compile(
            store: store, processor: nil, options: options)
        XCTAssertEqual(first.failed, 0)
        XCTAssertEqual(first.sourcePages, 1)
        XCTAssertEqual(first.entityPages, 2)
        XCTAssertEqual(first.claimPages, 1)
        guard let sourcePath = first.outputs.first(where: { $0.hasPrefix("sources/") }) else {
            return XCTFail("expected source page")
        }
        let sourceURL = URL(fileURLWithPath: vault).appendingPathComponent(sourcePath)
        var sourceText = try String(contentsOf: sourceURL, encoding: .utf8)
        sourceText = sourceText.replacingOccurrences(
            of: "<!-- codex-wiki:human:end -->",
            with: "keep this analyst note\n<!-- codex-wiki:human:end -->")
        try sourceText.write(to: sourceURL, atomically: true, encoding: .utf8)

        _ = try await CodexMemoryWikiCompile.compile(store: store, processor: nil, options: options)
        let afterPreserve = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(afterPreserve.contains("keep this analyst note"))

        _ = try await CodexMemoryWikiCompile.compile(store: store, processor: nil, options: options)
        let afterStableRerun = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertEqual(afterStableRerun, afterPreserve)
    }

    // Code-intelligence entities (.symbol/.module) are a SEPARATE index, not human wiki
    // content. They must NOT be compiled into entity/claim pages nor indexed into the
    // searchable compiled corpus — otherwise a code-indexed repo floods the wiki and its
    // symbol pages pollute hybrid/lexical recall.
    func testCodeIntelSymbolsAreNotCompiledOrIndexed() async throws {
        let vault = try tempDir(); defer { try? FileManager.default.removeItem(atPath: vault) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        _ = try await seedDocument(store: store)
        // One real memory entity (person) and one code symbol, joined by an edge.
        let alice = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Alice", firstSeen: 1, lastSeen: 1))
        let symbol = try await store.upsertEntity(EntityRow(
            kind: .symbol, canonical: "parseZxcvbnConfig", firstSeen: 1, lastSeen: 1))
        _ = try await store.upsertEdge(EdgeRow(
            src: alice, dst: symbol, relation: "authored", firstSeen: 1, lastSeen: 1))

        var options = WikiCompileOptions()
        options.vaultPath = vault
        options.indexCompiledPages = true
        options.clock = { 1_800_000_000 }
        let report = try await CodexMemoryWikiCompile.compile(
            store: store, processor: processor, options: options)

        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.entityPages, 1, "only the person entity is compiled, not the code symbol")
        XCTAssertEqual(report.claimPages, 0, "the edge touching a code symbol is dropped (no raw-id page)")
        XCTAssertFalse(report.outputs.contains { $0.contains("entities/symbol/") },
                       "no symbol page is written to the vault")

        // The symbol never entered the searchable compiled corpus: no indexed doc references it.
        let compiledSymbolDoc = try await store.document(byURI:
            "wiki://compiled/" + (report.outputs.first { $0.contains("entities/symbol/") } ?? "entities/symbol/none.md"))
        XCTAssertNil(compiledSymbolDoc, "no compiled symbol document exists")
        let hits = try await store.searchLexical("parseZxcvbnConfig", k: 20)
        XCTAssertTrue(hits.isEmpty, "the code symbol is not recallable from the compiled wiki search index")
    }

    // LIMIT-STARVATION regression: when symbol population exceeds the row limit, a
    // degree-ordered per-kind query truncates LOW-degree symbols, but their edges can still
    // fall inside the edges() slice. The earlier fix filtered edges against a separately-
    // limited code-intel id set, so a truncated symbol's edge survived → a compiled+indexed
    // claim page rendering the symbol's raw numeric id. Membership against the filtered
    // entityByID closes it regardless of limit.
    func testLowDegreeCodeSymbolDoesNotLeakUnderLimitStarvation() async throws {
        let vault = try tempDir(); defer { try? FileManager.default.removeItem(atPath: vault) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        _ = try await seedDocument(store: store)
        let alice = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Alice", firstSeen: 1, lastSeen: 1))
        // Two HIGH-degree symbols (self-loops → degree 2) that win the top-N by degree DESC.
        let hi1 = try await store.upsertEntity(EntityRow(kind: .symbol, canonical: "HighDegreeOne", firstSeen: 1, lastSeen: 1))
        let hi2 = try await store.upsertEntity(EntityRow(kind: .symbol, canonical: "HighDegreeTwo", firstSeen: 1, lastSeen: 1))
        _ = try await store.upsertEdge(EdgeRow(src: hi1, dst: hi1, relation: "self", firstSeen: 1, lastSeen: 1))
        _ = try await store.upsertEdge(EdgeRow(src: hi2, dst: hi2, relation: "self", firstSeen: 1, lastSeen: 1))
        // A LOW-degree symbol that a limit=2 per-kind query (ORDER BY degree DESC) truncates.
        let leak = try await store.upsertEntity(EntityRow(kind: .symbol, canonical: "leakingSymbolXyz", firstSeen: 1, lastSeen: 1))
        _ = try await store.upsertEdge(EdgeRow(src: alice, dst: leak, relation: "authored", firstSeen: 1, lastSeen: 1))

        var options = WikiCompileOptions()
        options.vaultPath = vault
        options.limit = 2                      // smaller than the symbol population → starvation
        options.indexCompiledPages = true
        options.clock = { 1_800_000_000 }
        let report = try await CodexMemoryWikiCompile.compile(store: store, processor: processor, options: options)

        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.claimPages, 0, "the Alice→leaked-symbol edge must be dropped, not rendered with a raw id")
        XCTAssertFalse(report.outputs.contains { $0.contains("/claims/") },
                       "no claim page leaks a code-symbol endpoint under limit starvation")
        let hits = try await store.searchLexical("\(leak)", k: 20)  // the raw numeric id
        XCTAssertTrue(hits.isEmpty, "the truncated symbol's numeric id is not recallable from a leaked page")
    }

    func testIndexedCompileIsIdempotentAndReplacesStaleSearchRows() async throws {
        let vault = try tempDir(); defer { try? FileManager.default.removeItem(atPath: vault) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        let uri = "file:///tmp/product-angle.md"
        _ = try await seedDocument(store: store, uri: uri, title: "OldOnlyTerm", text: "neutral source")
        var options = WikiCompileOptions()
        options.vaultPath = vault
        options.indexCompiledPages = true
        options.clock = { 1_800_000_000 }

        let first = try await CodexMemoryWikiCompile.compile(
            store: store, processor: processor, options: options)
        XCTAssertEqual(first.failed, 0)
        XCTAssertGreaterThan(first.indexed, 0)
        let docsAfterFirst = try await store.documentCount()
        let oldHits = try await store.searchLexical("OldOnlyTerm", k: 20)
        XCTAssertFalse(oldHits.isEmpty)

        let second = try await CodexMemoryWikiCompile.compile(
            store: store, processor: processor, options: options)
        let docsAfterSecond = try await store.documentCount()
        XCTAssertEqual(second.failed, 0)
        XCTAssertEqual(docsAfterSecond, docsAfterFirst)
        XCTAssertGreaterThan(second.indexUnchanged, 0)

        _ = try await store.upsertDocument(DocumentRow(
            source: .manual,
            sourceURI: uri,
            title: "NewOnlyTerm",
            bodyPath: "inline:\(uri)",
            fetchedAt: 2,
            contentSHA: Normaliser.contentSHA("NewOnlyTerm"),
            rawBytes: 11))
        let changed = try await CodexMemoryWikiCompile.compile(
            store: store, processor: processor, options: options)
        XCTAssertEqual(changed.failed, 0)
        let staleHits = try await store.searchLexical("OldOnlyTerm", k: 20)
        let freshHits = try await store.searchLexical("NewOnlyTerm", k: 20)
        XCTAssertTrue(staleHits.isEmpty)
        XCTAssertFalse(freshHits.isEmpty)
        let docsAfterChange = try await store.documentCount()
        XCTAssertEqual(docsAfterChange, docsAfterFirst)
    }

    func testLintFindsMarkdownAndIndexProblemsDeterministically() async throws {
        let root = try tempDir("wiki-lint-root"); defer { try? FileManager.default.removeItem(atPath: root) }
        try "body without heading".write(toFile: root + "/untitled.md", atomically: true, encoding: .utf8)
        try "---\ntitle: Broken\nbody".write(toFile: root + "/bad-frontmatter.md", atomically: true, encoding: .utf8)
        try "# Same\nalpha".write(toFile: root + "/dup-a.md", atomically: true, encoding: .utf8)
        try "# Same\nbeta".write(toFile: root + "/dup-b.md", atomically: true, encoding: .utf8)
        try "# Link\n[missing](missing.md)".write(toFile: root + "/link.md", atomically: true, encoding: .utf8)

        let (db, store, _) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        _ = try await store.upsertDocument(DocumentRow(
            source: .manual,
            sourceURI: "file:///tmp/zero.md",
            title: "Zero",
            bodyPath: "inline:file:///tmp/zero.md",
            fetchedAt: 1,
            contentSHA: Normaliser.contentSHA("zero"),
            rawBytes: 4))

        let options = WikiLintOptions()
        let first = try await CodexMemoryWikiLint.lint(
            roots: [root], store: store, options: options)
        let second = try await CodexMemoryWikiLint.lint(
            roots: [root], store: store, options: options)
        let codes = Set(first.issues.map(\.code))
        XCTAssertTrue(codes.contains("missing_explicit_title"))
        XCTAssertTrue(codes.contains("bad_front_matter"))
        XCTAssertTrue(codes.contains("duplicate_title"))
        XCTAssertTrue(codes.contains("broken_link"))
        XCTAssertTrue(codes.contains("zero_chunk_document"))
        XCTAssertEqual(first.issues, second.issues)
    }

    func testCompileRefusesVaultSymlinkOverwrite() async throws {
        let vault = try tempDir(); defer { try? FileManager.default.removeItem(atPath: vault) }
        let outside = try tempDir("wiki-outside"); defer { try? FileManager.default.removeItem(atPath: outside) }
        let (db, store, _) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        _ = try await seedDocument(store: store)
        var options = WikiCompileOptions()
        options.vaultPath = vault
        options.dryRun = true
        let planned = try await CodexMemoryWikiCompile.compile(
            store: store, processor: nil, options: options)
        guard let sourcePath = planned.outputs.first(where: { $0.hasPrefix("sources/") }) else {
            return XCTFail("expected source output")
        }
        let destination = URL(fileURLWithPath: vault).appendingPathComponent(sourcePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outsideFile = outside + "/outside.md"
        try "outside".write(toFile: outsideFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: destination.path,
                                                   withDestinationPath: outsideFile)

        options.dryRun = false
        let report = try await CodexMemoryWikiCompile.compile(
            store: store, processor: nil, options: options)
        XCTAssertGreaterThan(report.failed, 0)
        XCTAssertEqual(try String(contentsOfFile: outsideFile, encoding: .utf8), "outside")
    }

    func testWikiCompileCLIJSONUsesCorePath() async throws {
        let vault = try tempDir(); defer { try? FileManager.default.removeItem(atPath: vault) }
        let db = NSTemporaryDirectory() + "wiki-cli-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: db) }
        let store = try MemoryStore(MemoryStoreConfig(path: db))
        let uri = "file:///tmp/cli-source.md"
        _ = try await store.upsertDocument(DocumentRow(
            source: .manual,
            sourceURI: uri,
            title: "CLI Source",
            bodyPath: "inline:\(uri)",
            fetchedAt: 1,
            contentSHA: Normaliser.contentSHA("CLI Source"),
            rawBytes: 10))

        let result = try await CodexMemoryWikiCompile.runDetailed(
            args: ["--db", db, "--vault", vault, "--json"])
        XCTAssertEqual(result.report.failed, 0)
        XCTAssertTrue(result.output.contains("\"source_pages\":1"))
    }
}
