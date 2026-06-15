import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore
@testable import MemoryProcess
@testable import MemoryInfer
import MemoryIngest
import InfraPrimitives

private actor FailingMarkdownInferenceProvider: LocalInferenceProvider {
    nonisolated let embeddingDimension: Int = 8

    func extract(_ batch: ChunkBatch, schema: ExtractionSchema,
                 deadline: InfraPrimitives.Deadline) async throws -> ExtractionResult {
        throw InferenceError.providerUnavailable("intentional test failure")
    }

    func contextualize(_ chunk: Chunk, in document: DocumentDigest,
                       deadline: InfraPrimitives.Deadline) async throws -> String {
        ""
    }

    func embed(_ texts: [String], deadline: InfraPrimitives.Deadline) async throws -> [MemoryInfer.Embedding] {
        throw InferenceError.providerUnavailable("intentional test failure")
    }

    func rerank(_ query: String, candidates: [String],
                deadline: InfraPrimitives.Deadline) async throws -> [Float] {
        []
    }

    func logprob(_ text: String, given: String?,
                 deadline: InfraPrimitives.Deadline) async throws -> Double {
        0
    }
}

final class ImportMarkdownTests: XCTestCase {
    private func tempDir(_ prefix: String = "import-markdown") throws -> String {
        let path = NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func stack(dim: Int = 8) throws -> (String, MemoryStore, MemoryProcessor) {
        let db = NSTemporaryDirectory() + "import-markdown-\(UUID().uuidString).db"
        let store = try MemoryStore(MemoryStoreConfig(path: db, embeddingDimension: dim))
        let processor = MemoryProcessor(
            store: store, inference: MockInferenceProvider(embeddingDimension: dim))
        return (db, store, processor)
    }

    private func options(stateRoot: String? = nil,
                         dryRun: Bool = false,
                         maxBytes: Int64 = 10 * 1024 * 1024) -> MarkdownImportOptions {
        var options = MarkdownImportOptions()
        options.dryRun = dryRun
        options.stateRoot = stateRoot
        options.maxBytes = maxBytes
        options.clock = { 1_800_000_000 }
        return options
    }

    /// The load-bearing data-integrity fix: progress JSON must expose `succeeded`
    /// (imported+unchanged) DISTINCT from `processed` (which includes failures), so the
    /// resilient import driver gates COMPLETE on success — not on a count that an
    /// all-failed clean-checkout run would still drive to discovered (stamping a degraded
    /// corpus authoritative).
    func testProgressJSONSeparatesSucceededFromFailedProcessed() throws {
        let path = try tempDir() + "/progress.json"
        let report = MarkdownImportReport(jobID: "j", roots: [], discovered: 6,
                                          imported: 2, unchanged: 1, failed: 3)
        writeProgress(report, to: path)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        XCTAssertEqual(json["succeeded"] as? Int, 3, "succeeded = imported+unchanged ONLY (excludes failures)")
        XCTAssertEqual(json["processed"] as? Int, 6, "processed still counts attempts incl. failures (display/stuck)")
        XCTAssertEqual(json["failed"] as? Int, 3)
        XCTAssertEqual(json["discovered"] as? Int, 6)
        // An all-failed run: succeeded stays 0 < discovered → the script's COMPLETE gate
        // (succeeded>=discovered) never fires, so it retries/aborts instead of declaring done.
        let allFailed = MarkdownImportReport(jobID: "j", roots: [], discovered: 5, failed: 5)
        writeProgress(allFailed, to: path)
        let j2 = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        XCTAssertEqual(j2["succeeded"] as? Int, 0, "an all-failed run reports zero success → never COMPLETE")
        XCTAssertEqual(j2["processed"] as? Int, 5)
    }

    func testDryRunManifestIsDeterministicAndSkipsUnsafeFiles() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = try tempDir("outside"); defer { try? FileManager.default.removeItem(atPath: outside) }
        let (_, store, processor) = try stack()
        try "# Alpha\nBody".write(toFile: root + "/a.md", atomically: true, encoding: .utf8)
        try "---\ntitle: Bee\n---\nBody".write(toFile: root + "/b.markdown", atomically: true, encoding: .utf8)
        try "not markdown".write(toFile: root + "/note.txt", atomically: true, encoding: .utf8)
        try Data([0xff, 0xfe, 0xfd]).write(to: URL(fileURLWithPath: root + "/bad.md"))
        try String(repeating: "x", count: 64).write(toFile: root + "/big.md", atomically: true, encoding: .utf8)
        try "# Outside".write(toFile: outside + "/outside.md", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/escape.md",
                                                   withDestinationPath: outside + "/outside.md")

        let report1 = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: options(dryRun: true, maxBytes: 32),
            store: store, processor: processor)
        let report2 = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: options(dryRun: true, maxBytes: 32),
            store: store, processor: processor)

        XCTAssertEqual(report1.discovered, 2)
        XCTAssertEqual(report1.skipped, 3)
        XCTAssertEqual(report1.manifest, report2.manifest)
        XCTAssertEqual(report1.manifest.filter { $0.skipReason == nil }
            .compactMap(\.title).sorted(),
                       ["Alpha", "Bee"])
        XCTAssertTrue(report1.manifest.contains { $0.relativeID == "bad.md" && $0.skipReason == "not utf-8" })
        XCTAssertTrue(report1.manifest.contains { $0.relativeID == "big.md" && $0.skipReason == "oversized" })
        XCTAssertTrue(report1.manifest.contains { $0.relativeID == "escape.md" && $0.skipReason != nil })
    }

    func testImportTwiceIsIdempotentAndChangedMarkdownClearsStaleFTS() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let state = try tempDir("state"); defer { try? FileManager.default.removeItem(atPath: state) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        let file = root + "/note.md"
        try "# Note\nalpha-only-term".write(toFile: file, atomically: true, encoding: .utf8)

        let first = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: options(stateRoot: state), store: store, processor: processor)
        let chunksAfterFirst = try await store.chunkCount()
        XCTAssertEqual(first.imported, 1)
        XCTAssertGreaterThan(chunksAfterFirst, 0)
        let alphaHits = try await store.searchLexical("alpha-only-term", k: 10)
        XCTAssertFalse(alphaHits.isEmpty)

        let second = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: options(stateRoot: state), store: store, processor: processor)
        let chunksAfterSecond = try await store.chunkCount()
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.unchanged, 1)
        XCTAssertEqual(chunksAfterSecond, chunksAfterFirst)

        try "# Note\nbeta-only-term".write(toFile: file, atomically: true, encoding: .utf8)
        let changed = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: options(stateRoot: state), store: store, processor: processor)
        let docCount = try await store.documentCount()
        let staleHits = try await store.searchLexical("alpha-only-term", k: 10)
        let freshHits = try await store.searchLexical("beta-only-term", k: 10)
        XCTAssertEqual(changed.imported, 1)
        XCTAssertEqual(docCount, 1)
        XCTAssertTrue(staleHits.isEmpty)
        XCTAssertFalse(freshHits.isEmpty)
    }

    func testChangedImportFailurePreservesPreviousDocument() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let state = try tempDir("state"); defer { try? FileManager.default.removeItem(atPath: state) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        let file = root + "/note.md"
        try "# Note\nold-good-term".write(toFile: file, atomically: true, encoding: .utf8)
        let first = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: options(stateRoot: state), store: store, processor: processor)
        XCTAssertEqual(first.imported, 1)
        let oldHits = try await store.searchLexical("old-good-term", k: 10)
        XCTAssertFalse(oldHits.isEmpty)

        try "# Note\nnew-failing-term".write(toFile: file, atomically: true, encoding: .utf8)
        let failingProcessor = MemoryProcessor(
            store: store, inference: FailingMarkdownInferenceProvider())
        let failed = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: options(stateRoot: state), store: store,
            processor: failingProcessor)
        let oldStillThere = try await store.searchLexical("old-good-term", k: 10)
        let newNotIndexed = try await store.searchLexical("new-failing-term", k: 10)
        XCTAssertEqual(failed.failed, 1)
        XCTAssertFalse(oldStillThere.isEmpty)
        XCTAssertTrue(newNotIndexed.isEmpty)
    }

    func testSameSHAPartialDocumentIsRepaired() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let state = try tempDir("state"); defer { try? FileManager.default.removeItem(atPath: state) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        let file = root + "/partial.md"
        let text = "# Partial\nrepair me"
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        let sourceURI = URL(fileURLWithPath: URL(fileURLWithPath: file)
            .resolvingSymlinksInPath().path).absoluteString
        let sha = Normaliser.contentSHA(text)
        _ = try await store.upsertDocument(DocumentRow(
            source: .manual,
            sourceURI: sourceURI,
            title: "Partial",
            bodyPath: "inline:\(sourceURI)",
            fetchedAt: 1,
            contentSHA: sha,
            rawBytes: Int64(text.utf8.count)))
        let chunksBeforeRepair = try await store.chunkCount()
        XCTAssertEqual(chunksBeforeRepair, 0)

        let report = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: options(stateRoot: state), store: store, processor: processor)
        let chunksAfterRepair = try await store.chunkCount()
        XCTAssertEqual(report.imported, 1)
        XCTAssertGreaterThan(chunksAfterRepair, 0)
    }

    func testResumeDoesNotSkipWhenStateExistsButStoreIsMissingDocument() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let state = try tempDir("state"); defer { try? FileManager.default.removeItem(atPath: state) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        let file = root + "/resume.md"
        try "# Resume\nstate is advisory".write(toFile: file, atomically: true, encoding: .utf8)
        var firstOptions = options(stateRoot: state)
        firstOptions.jobID = "resume-test"
        let first = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: firstOptions, store: store, processor: processor)
        XCTAssertEqual(first.imported, 1)
        guard let doc = try await store.document(byURI: first.manifest[0].sourceURI) else {
            return XCTFail("document should exist after first import")
        }
        try await store.deleteDocument(id: doc.id)
        let countAfterDelete = try await store.documentCount()
        XCTAssertEqual(countAfterDelete, 0)

        var resumeOptions = firstOptions
        resumeOptions.resume = true
        let resumed = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: resumeOptions, store: store, processor: processor)
        let countAfterResume = try await store.documentCount()
        XCTAssertEqual(resumed.imported, 1)
        XCTAssertEqual(resumed.unchanged, 0)
        XCTAssertEqual(countAfterResume, 1)
    }

    /// CLAIM (crash/restart proof): if an import is interrupted after some files
    /// land (simulated here by importing a subset first), a `--resume` re-run over
    /// the full corpus COMPLETES the remaining files WITHOUT re-importing the ones
    /// already done — and a later content change to a done file IS re-imported.
    func testResumeCompletesPartialImportWithoutRedoingDoneFiles() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let state = try tempDir("state"); defer { try? FileManager.default.removeItem(atPath: state) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }

        // "Before the crash": only file A exists and gets imported. Pin the jobID
        // so the resume run reads the SAME state file across a corpus change.
        let fileA = root + "/a.md"
        try "# A\nalpha body".write(toFile: fileA, atomically: true, encoding: .utf8)
        var opts = options(stateRoot: state)
        opts.jobID = "crash-test"
        opts.resume = true
        let first = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: opts, store: store, processor: processor)
        XCTAssertEqual(first.imported, 1)

        // "After restart": file B has appeared; resume over [A, B]. A is unchanged
        // (store still holds it, same SHA) and is NOT re-imported; B is new.
        try "# B\nbeta body".write(toFile: root + "/b.md", atomically: true, encoding: .utf8)
        let resumed = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: opts, store: store, processor: processor)
        let countAfterResume = try await store.documentCount()
        XCTAssertEqual(resumed.imported, 1, "only the not-yet-done file is imported")
        XCTAssertEqual(resumed.unchanged, 1, "the already-done file is skipped, not redone")
        XCTAssertEqual(countAfterResume, 2, "no duplicates; both pages present")

        // Editing a done file changes its SHA → it IS re-imported on the next resume.
        try "# A\nalpha body EDITED".write(toFile: fileA, atomically: true, encoding: .utf8)
        let afterEdit = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: opts, store: store, processor: processor)
        let countAfterEdit = try await store.documentCount()
        XCTAssertEqual(afterEdit.imported, 1, "the changed file is re-imported")
        XCTAssertEqual(afterEdit.unchanged, 1, "the unchanged file stays skipped")
        XCTAssertEqual(countAfterEdit, 2, "still no duplicates")
    }

    /// CLAIM: `--resume` with no prior state file (a fresh run that opts into
    /// resume) degrades gracefully to a normal import — no crash, everything
    /// imported.
    func testResumeWithNoPriorStateImportsEverything() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let state = try tempDir("state"); defer { try? FileManager.default.removeItem(atPath: state) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        try "# Fresh\nbody".write(toFile: root + "/fresh.md", atomically: true, encoding: .utf8)
        var opts = options(stateRoot: state)
        opts.resume = true // resume requested but no state exists yet
        let report = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: opts, store: store, processor: processor)
        let count = try await store.documentCount()
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(count, 1)
    }

    func testExtractModeRerunReplacesWithoutDuplicatingUntilCompletionMarkerExists() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let state = try tempDir("state"); defer { try? FileManager.default.removeItem(atPath: state) }
        let (db, store, processor) = try stack(); defer { try? FileManager.default.removeItem(atPath: db) }
        try "# Extract\nAlice met Bob".write(toFile: root + "/extract.md", atomically: true, encoding: .utf8)
        var extractOptions = options(stateRoot: state)
        extractOptions.extractMode = true

        let first = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: extractOptions, store: store, processor: processor)
        let chunksAfterFirst = try await store.chunkCount()
        let second = try await CodexMemoryMarkdownImport.importRoots(
            [root], options: extractOptions, store: store, processor: processor)
        let chunksAfterSecond = try await store.chunkCount()
        let documentCount = try await store.documentCount()
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(second.imported, 1)
        XCTAssertEqual(chunksAfterSecond, chunksAfterFirst)
        XCTAssertEqual(documentCount, 1)
    }

    func testUnsafeJobIDIsRejected() async throws {
        do {
            _ = try await CodexMemoryMarkdownImport.runDetailed(
                args: ["--dry-run", "--job-id", "../escape", "/tmp"])
            XCTFail("unsafe job id should be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("job id"))
        }
    }

    func testCLIDryRunUsesFactoredImportPath() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "# CLI\nhello".write(toFile: root + "/cli.md", atomically: true, encoding: .utf8)

        let output = try await CodexMemoryMarkdownImport.run(args: ["--dry-run", root])
        XCTAssertTrue(output.contains("import-markdown summary"))
        XCTAssertTrue(output.contains("discovered=1"))
        XCTAssertTrue(output.contains("failed=0"))
    }

    func testDocumentedSeedCorpusDryRunCountsWhenPresent() async throws {
        let roots = [
            ("/Users/chabotc/Projects/agentwiki/data/agentwiki/markdown", 4_865),
            ("/Users/chabotc/Projects/devrel-almanac/devrel", 102),
        ]
        let (_, store, processor) = try stack()
        for (root, expected) in roots {
            guard FileManager.default.fileExists(atPath: root) else {
                throw XCTSkip("seed corpus absent: \(root)")
            }
            let report = try await CodexMemoryMarkdownImport.importRoots(
                [root], options: options(dryRun: true),
                store: store, processor: processor)
            XCTAssertEqual(report.discovered, expected, root)
        }
    }
}
