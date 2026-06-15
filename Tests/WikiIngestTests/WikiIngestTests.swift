import XCTest
import Foundation
@testable import WikiIngest
import PinnedFetcher
import EgressGuard
import MediaDecode
import MemoryStore
import MemoryProcess
import MemoryInfer
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif

final class WikiIngestTests: XCTestCase {
    private func tmp(_ ext: String) -> String { NSTemporaryDirectory() + "wikiingest-\(UUID().uuidString).\(ext)" }

    private func collect(_ s: AsyncThrowingStream<WikiSourceCandidate, any Error>) async throws -> [WikiSourceCandidate] {
        var out: [WikiSourceCandidate] = []
        for try await c in s { out.append(c) }
        return out
    }

    private func publicFetcher(_ mock: any PinnedTransport) -> PinnedFetcher {
        PinnedFetcher(guard_: EgressGuard(EgressPolicy(allowedHosts: [], allowHTTP: true,
                                                       resolve: { _ in ["93.184.216.34"] })),
                      transport: mock)
    }

    private actor HTMLTransport: PinnedTransport {
        let bytes: Data
        init(html: String, contentType: String = "text/html") {
            bytes = Data("HTTP/1.1 200 OK\r\ncontent-type: \(contentType)\r\ncontent-length: \(html.utf8.count)\r\n\r\n\(html)".utf8)
        }
        func roundTrip(_ req: TransportRequest) async -> Result<TransportResponse, FetchError> {
            .success(TransportResponse(peerIP: "93.184.216.34", bytes: bytes, truncated: false))
        }
    }

    /// Routes a response by a substring match on the request's GET line.
    private actor RoutingTransport: PinnedTransport {
        let routes: [String: Data]
        init(routes: [String: Data]) { self.routes = routes }
        func roundTrip(_ req: TransportRequest) async -> Result<TransportResponse, FetchError> {
            let line = String(decoding: req.requestBytes, as: UTF8.self)
            for (k, v) in routes where line.contains(k) {
                return .success(TransportResponse(peerIP: "93.184.216.34", bytes: v, truncated: false))
            }
            return .failure(.statusError(404))
        }
    }

    // MARK: detectKind (pure)

    func testDetectKindExhaustive() {
        typealias K = WikiSourceKind
        func d(_ s: String) -> K { WikiAdapterRegistry.detectKind(s) }
        // URL shapes
        XCTAssertEqual(d("https://example.com/article"), .url)
        XCTAssertEqual(d("https://arxiv.org/abs/2402.17764"), .arxiv)
        XCTAssertEqual(d("https://export.arxiv.org/api/query?search_query=cat:cs.AI"), .arxiv)
        XCTAssertEqual(d("https://github.com/anthropics/buffa"), .git)
        XCTAssertEqual(d("https://github.com/anthropics"), .githubOwner)
        XCTAssertEqual(d("https://github.com/orgs/openai/repositories"), .githubOwner)
        XCTAssertEqual(d("https://github.com/simonw?tab=repositories"), .githubOwner)
        XCTAssertEqual(d("https://en.wikipedia.org/w/api.php?action=query"), .mediawikiAPI)
        XCTAssertEqual(d("https://dumps.wikimedia.org/enwiki-latest-pages.xml.bz2"), .mediawikiDump)
        XCTAssertEqual(d("https://web.archive.org/cdx/search/cdx?url=example.com"), .waybackCDX)
        XCTAssertEqual(d("https://simonwillison.net/atom/everything/"), .url)  // path doesn't end /atom
        XCTAssertEqual(d("https://news.smol.ai/feed"), .feed)
        XCTAssertEqual(d("https://lilianweng.github.io/index.xml"), .feed)
        XCTAssertEqual(d("https://blog.example.com/rss.xml"), .feed)
        // local paths
        XCTAssertEqual(d("/docs/paper.pdf"), .pdf)
        XCTAssertEqual(d("/data/messages.csv"), .messageArchive)
        XCTAssertEqual(d("/data/export.jsonl"), .messageArchive)
        XCTAssertEqual(d("/dumps/pages.xml"), .mediawikiDump)
        XCTAssertEqual(d("/notes/todo.md"), .file)
        // bare arXiv query/id is unambiguous → arxiv (documented bare forms work w/o --adapter)
        XCTAssertEqual(d("cat:cs.AI"), .arxiv)
        XCTAssertEqual(d("au:Karpathy"), .arxiv)
        XCTAssertEqual(d("ti:attention"), .arxiv)
        XCTAssertEqual(d("2402.17764"), .arxiv)
        XCTAssertEqual(d("2402.17764v2"), .arxiv)
        XCTAssertEqual(d("karpathy"), .file)        // a bare owner stays ambiguous → file
        XCTAssertEqual(d("notes/cat:thing"), .file) // a path with a colon is not an arXiv query
        // forced wins
        XCTAssertEqual(WikiAdapterRegistry.detectKind("/notes/todo.md", forced: .pdf), .pdf)
        XCTAssertEqual(WikiAdapterRegistry.detectKind("https://example.com", forced: .feed), .feed)
    }

    func testNotImplementedAdapterYieldsError() async throws {
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(HTMLTransport(html: "")))
        let adapter = reg.resolve("https://dumps.wikimedia.org/enwiki-latest-pages.xml.bz2")   // mediawiki-dump: not yet implemented
        do { _ = try await collect(adapter.enumerate(IngestRequest(input: "x", fetchedAt: 1))); XCTFail("expected error") }
        catch WikiIngestError.notImplemented(let k) { XCTAssertEqual(k, .mediawikiDump) }
    }

    // MARK: FileAdapter

    func testFileAdapterMarkdownFile() async throws {
        let p = tmp("md"); defer { try? FileManager.default.removeItem(atPath: p) }
        try Data("# Title\n\nbody text".utf8).write(to: URL(fileURLWithPath: p))
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(HTMLTransport(html: "")))
        let cands = try await collect(reg.resolve(p).enumerate(IngestRequest(input: p, fetchedAt: 42)))
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].contentFormat, .markdown)
        XCTAssertEqual(cands[0].rawType, .articles)
        XCTAssertTrue(cands[0].bodyMarkdown.contains("body text"))
        XCTAssertEqual(cands[0].sourceURI, "file://" + p)
        XCTAssertEqual(cands[0].fetched, 42)
    }

    func testFileAdapterUnreadable() async throws {
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(HTMLTransport(html: "")))
        do { _ = try await collect(reg.resolve("/no/such.md").enumerate(IngestRequest(input: "/no/such.md", fetchedAt: 1))); XCTFail("expected error") }
        catch WikiIngestError.unreadable { /* ok */ }
    }

    func testFileAdapterPDFThroughSandbox() async throws {
        #if canImport(PDFKit)
        let helper = FileManager.default.currentDirectoryPath + "/.build/debug/codex-mediadecode"
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
              FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("sandbox/helper unavailable") }
        let p = tmp("pdf"); defer { try? FileManager.default.removeItem(atPath: p) }
        try writeTextPDF(p, text: "INGESTPDFTEXT")
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(HTMLTransport(html: "")))
        let cands = try await collect(reg.resolve(p).enumerate(IngestRequest(input: p, fetchedAt: 7)))
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].contentFormat, .pdf)
        XCTAssertEqual(cands[0].rawType, .papers)
        XCTAssertTrue(cands[0].bodyMarkdown.contains("INGESTPDFTEXT"))
        XCTAssertEqual(cands[0].extractionStatus, "ok")
        #else
        throw XCTSkip("PDFKit unavailable")
        #endif
    }

    // MARK: URLAdapter

    func testURLAdapterHTMLToMarkdown() async throws {
        let html = "<html><head><title>Doc</title></head><body><h1>Heading</h1><p>para text</p></body></html>"
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(HTMLTransport(html: html)))
        let cands = try await collect(reg.resolve("https://example.com/x").enumerate(
            IngestRequest(input: "https://example.com/x", fetchedAt: 9)))
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].contentFormat, .html)
        XCTAssertEqual(cands[0].rawType, .articles)
        XCTAssertEqual(cands[0].title, "Doc")
        XCTAssertTrue(cands[0].bodyMarkdown.contains("# Heading"))
        XCTAssertEqual(cands[0].provenance.canonicalURL, "https://example.com/x")
    }

    // MARK: WikiIngestWriter (candidate → immutable raw doc + index + source_meta)

    func testWriterIngestsAndDedupes() async throws {
        let dbDir = NSTemporaryDirectory() + "wikiwriter-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dbDir) }
        let store = try MemoryStore(MemoryStoreConfig(path: dbDir + "/m.db", embeddingDimension: 8))
        let processor = MemoryProcessor(store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let writer = WikiIngestWriter(store: store, processor: processor)

        let cand = WikiSourceCandidate(
            sourceURI: "https://ex.com/a", rawType: .articles, title: "Doc A",
            bodyMarkdown: "hello world. this is a test document with enough text to chunk into pieces.",
            contentFormat: .html,
            provenance: CollectionProvenance(adapter: "url", canonicalURL: "https://ex.com/a", author: "Ada"),
            fetched: 100)

        let r1 = try await writer.write(cand, extract: false)
        XCTAssertGreaterThan(r1.documentID, 0)
        XCTAssertGreaterThan(r1.chunksWritten, 0)
        XCTAssertFalse(r1.skipped)

        // provenance overlay written
        let meta = try await store.sourceMeta(documentID: r1.documentID)
        XCTAssertEqual(meta?.sourceKind, "articles")     // raw bucket
        XCTAssertEqual(meta?.canonicalURL, "https://ex.com/a")
        XCTAssertEqual(meta?.author, "Ada")
        XCTAssertEqual(meta?.adapter, "url")

        // re-ingesting identical content (same source_uri + content) is a no-op
        let r2 = try await writer.write(cand, extract: false)
        XCTAssertEqual(r2.documentID, r1.documentID)
        XCTAssertTrue(r2.skipped)
        XCTAssertEqual(r2.chunksWritten, 0)
        let count = try await store.documentCount()
        XCTAssertEqual(count, 1)   // not duplicated
    }

    func testWriterRevisionsChangedContent() async throws {
        let dbDir = NSTemporaryDirectory() + "wikirev-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dbDir) }
        let store = try MemoryStore(MemoryStoreConfig(path: dbDir + "/m.db", embeddingDimension: 8))
        let writer = WikiIngestWriter(store: store,
            processor: MemoryProcessor(store: store, inference: MockInferenceProvider(embeddingDimension: 8)))
        var cand = WikiSourceCandidate(sourceURI: "https://ex.com/p", rawType: .articles, title: "P",
            bodyMarkdown: "original content here with several words to chunk", contentFormat: .html,
            provenance: CollectionProvenance(adapter: "url"), fetched: 1)
        let r1 = try await writer.write(cand, extract: false)
        XCTAssertFalse(r1.skipped)
        XCTAssertNil(r1.revisionOf, "first ingest is a CREATE — supersedes nothing")
        // Changed content under the SAME canonical URI → a NEW immutable revision (an UPDATE).
        cand.bodyMarkdown = "completely different replacement content with other distinct words"
        cand.fetched = 1_700_000_000   // 2023-11-14 UTC → deterministic change-marker date
        let r2 = try await writer.write(cand, extract: false)
        XCTAssertFalse(r2.skipped)
        XCTAssertNotEqual(r2.documentID, r1.documentID)
        XCTAssertEqual(r2.revisionOf, r1.documentID, "UPDATE records the superseded prior revision")
        // §14.6 "what changed" marker stamped on the new revision's source_meta.
        let meta = try await store.sourceMeta(documentID: r2.documentID)
        XCTAssertNotNil(meta?.frontmatter)
        XCTAssertTrue(meta?.frontmatter?.contains("\"changed_on\":\"2023-11-14\"") ?? false, meta?.frontmatter ?? "nil")
        XCTAssertTrue(meta?.frontmatter?.contains("\"supersedes_doc\":\(r1.documentID)") ?? false, meta?.frontmatter ?? "nil")
        // The original revision carries NO change marker (it superseded nothing).
        let meta1 = try await store.sourceMeta(documentID: r1.documentID)
        XCTAssertNil(meta1?.frontmatter)
        let twoDocs = try await store.documentCount()
        XCTAssertEqual(twoDocs, 2)   // both revisions present (old not clobbered)
        // Re-ingesting the same changed content → revision dedupe (no duplicate).
        let r3 = try await writer.write(cand, extract: false)
        XCTAssertTrue(r3.skipped)
        XCTAssertNil(r3.revisionOf, "a skipped no-op is not an update")
        XCTAssertEqual(r3.documentID, r2.documentID)
        let stillTwo = try await store.documentCount()
        XCTAssertEqual(stillTwo, 2)
    }

    // MARK: Feed parser (pure)

    func testFeedParserRSS() {
        let rss = """
        <rss version="2.0"><channel><title>My Blog</title>
        <item><title>Post One</title><link>https://b.com/1</link><guid>g1</guid><pubDate>Mon, 01 Jan 2026</pubDate></item>
        <item><title><![CDATA[Two & Three]]></title><link>https://b.com/2</link><guid>g2</guid></item>
        </channel></rss>
        """
        let p = FeedParser.parse(rss)
        XCTAssertEqual(p.title, "My Blog")              // feed title, not an item title
        XCTAssertEqual(p.entries.count, 2)
        XCTAssertEqual(p.entries[0].title, "Post One")
        XCTAssertEqual(p.entries[0].link, "https://b.com/1")
        XCTAssertEqual(p.entries[0].id, "g1")
        XCTAssertEqual(p.entries[1].title, "Two & Three")   // CDATA + entity
    }

    func testFeedParserAtom() {
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Lil'Log</title>
        <entry><title>Attention</title><id>tag:x,1</id>
        <link rel="self" href="https://x/self"/><link rel="alternate" href="https://x/post1"/>
        <published>2026-01-01T00:00:00Z</published></entry>
        </feed>
        """
        let p = FeedParser.parse(atom)
        XCTAssertEqual(p.title, "Lil'Log")
        XCTAssertEqual(p.entries.count, 1)
        XCTAssertEqual(p.entries[0].title, "Attention")
        XCTAssertEqual(p.entries[0].id, "tag:x,1")
        XCTAssertEqual(p.entries[0].link, "https://x/post1")   // prefers rel=alternate over self
    }

    func testFeedAdapterFetchesEntryArticles() async throws {
        func http(_ ct: String, _ body: String) -> Data {
            Data("HTTP/1.1 200 OK\r\ncontent-type: \(ct)\r\ncontent-length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        }
        let rss = "<rss><channel><title>F</title>" +
            "<item><title>A</title><link>https://example.com/a</link><guid>ga</guid></item>" +
            "<item><title>B</title><link>https://example.com/b</link><guid>gb</guid></item></channel></rss>"
        let routes = [
            "GET /feed":  http("application/rss+xml", rss),
            "GET /a ":    http("text/html", "<html><body><p>article A body</p></body></html>"),
            "GET /b ":    http("text/html", "<html><body><p>article B body</p></body></html>"),
        ]
        let mock = RoutingTransport(routes: routes)
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(mock))
        let cands = try await collect(reg.resolve("https://example.com/feed").enumerate(
            IngestRequest(input: "https://example.com/feed", fetchedAt: 5)))
        XCTAssertEqual(cands.count, 2)
        XCTAssertEqual(cands.map(\.title).compactMap { $0 }.sorted(), ["A", "B"])
        XCTAssertTrue(cands.allSatisfy { $0.provenance.adapter == "feed" })
        XCTAssertTrue(cands.contains { $0.bodyMarkdown.contains("article A body") })
    }

    // MARK: arXiv

    func testArxivAbsIDExtraction() {
        XCTAssertEqual(ArxivAdapter.absID(from: "2402.17764"), "2402.17764")
        XCTAssertEqual(ArxivAdapter.absID(from: "2402.17764v2"), "2402.17764v2")
        XCTAssertEqual(ArxivAdapter.absID(from: "https://arxiv.org/abs/2402.17764"), "2402.17764")
        XCTAssertEqual(ArxivAdapter.absID(from: "https://arxiv.org/pdf/2402.17764v1"), "2402.17764v1")
        XCTAssertNil(ArxivAdapter.absID(from: "cat:cs.AI"))           // a query, not an id
        XCTAssertNil(ArxivAdapter.absID(from: "au:Karpathy"))
    }

    func testArxivAPIURL() {
        let q = ArxivAdapter.apiURL(for: "cat:cs.AI", limit: 10)!.absoluteString
        XCTAssertTrue(q.contains("search_query=cat:cs.AI") || q.contains("search_query=cat%3Acs.AI"))
        XCTAssertTrue(q.contains("sortBy=submittedDate"))
        let byID = ArxivAdapter.apiURL(for: "https://arxiv.org/abs/2402.17764", limit: 10)!.absoluteString
        XCTAssertTrue(byID.contains("id_list=2402.17764"))
    }

    func testArxivAdapterParsesAbstracts() async throws {
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>ArXiv Query</title>
        <entry><id>http://arxiv.org/abs/2402.17764v1</id><title>The Era of 1-bit LLMs</title>
        <summary>We introduce BitNet b1.58, a 1-bit LLM variant.</summary>
        <published>2024-02-27T00:00:00Z</published>
        <link href="http://arxiv.org/abs/2402.17764v1" rel="alternate"/></entry></feed>
        """
        let mock = HTMLTransport(html: atom, contentType: "application/atom+xml")
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(mock))
        // A bare query (not an arxiv.org URL) is forced to the arxiv adapter by the caller.
        let cands = try await collect(reg.resolve("cat:cs.AI", forced: .arxiv).enumerate(
            IngestRequest(input: "cat:cs.AI", adapter: .arxiv, fetchedAt: 3)))
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].rawType, .papers)
        XCTAssertEqual(cands[0].sourceURI, "http://arxiv.org/abs/2402.17764v1")
        XCTAssertEqual(cands[0].title, "The Era of 1-bit LLMs")
        XCTAssertTrue(cands[0].bodyMarkdown.contains("BitNet b1.58"))      // abstract is the body
        XCTAssertTrue(cands[0].bodyMarkdown.contains("# The Era of 1-bit LLMs"))
        XCTAssertEqual(cands[0].provenance.adapter, "arxiv")
    }

    // A Sendable, lock-guarded recorder for the @Sendable ingest-progress closure.
    final class IngestEventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [WikiIngestOrchestrator.Progress] = []
        func append(_ e: WikiIngestOrchestrator.Progress) { lock.lock(); events.append(e); lock.unlock() }
        var all: [WikiIngestOrchestrator.Progress] { lock.lock(); defer { lock.unlock() }; return events }
    }

    // MARK: ingest ledger + orchestrator

    private func makeStore() throws -> (MemoryStore, String) {
        let dbDir = NSTemporaryDirectory() + "wikiorch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        let store = try MemoryStore(MemoryStoreConfig(path: dbDir + "/m.db", embeddingDimension: 8))
        return (store, dbDir)
    }

    func testIngestLedgerCountersAndItems() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try await store.ingestBegin(jobID: "J1", input: "https://ex.com/feed", adapter: "feed",
                                    rawType: "articles", corpus: nil, startedAt: 10)
        try await store.ingestRecordItem(jobID: "J1", seq: 1, sourceURI: "a", status: .written,
                                         documentID: 100, error: nil, recordedAt: 11)
        try await store.ingestRecordItem(jobID: "J1", seq: 2, sourceURI: "b", status: .deduped,
                                         documentID: 100, error: nil, recordedAt: 12)
        try await store.ingestRecordItem(jobID: "J1", seq: 3, sourceURI: "c", status: .failed,
                                         documentID: nil, error: "boom", recordedAt: 13)
        try await store.ingestFinish(jobID: "J1", status: "done", finishedAt: 20, cursor: "a", error: nil)

        let job = try await store.ingestJob("J1")
        XCTAssertEqual(job?.candidates, 3)
        XCTAssertEqual(job?.written, 1)
        XCTAssertEqual(job?.skipped, 1)   // deduped counts as skipped
        XCTAssertEqual(job?.failed, 1)
        XCTAssertEqual(job?.status, "done")
        XCTAssertEqual(job?.cursor, "a")
        XCTAssertEqual(job?.finishedAt, 20)
        let items = try await store.ingestItems(jobID: "J1")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[2].status, "failed")
        XCTAssertEqual(items[2].error, "boom")
        // recent-jobs listing + watch cursor
        let recent = try await store.ingestJobs()
        XCTAssertEqual(recent.first?.jobID, "J1")
        let cursor = try await store.ingestLastCursor(input: "https://ex.com/feed", adapter: "feed")
        XCTAssertEqual(cursor, "a")
    }

    func testIngestLedgerRerecordIsIdempotent() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try await store.ingestBegin(jobID: "R", input: "x", adapter: "feed", rawType: nil,
                                    corpus: nil, startedAt: 0)
        try await store.ingestRecordItem(jobID: "R", seq: 1, sourceURI: "a", status: .written,
                                         documentID: 1, error: nil, recordedAt: 1)
        // Re-record the SAME seq (a retry/resume) — counts must NOT double.
        try await store.ingestRecordItem(jobID: "R", seq: 1, sourceURI: "a", status: .written,
                                         documentID: 1, error: nil, recordedAt: 2)
        let j1 = try await store.ingestJob("R")
        XCTAssertEqual(j1?.candidates, 1)
        XCTAssertEqual(j1?.written, 1)
        // Re-record seq 1 with a DIFFERENT status — the bucket moves, total stays 1.
        try await store.ingestRecordItem(jobID: "R", seq: 1, sourceURI: "a", status: .failed,
                                         documentID: nil, error: "later failed", recordedAt: 3)
        let j2 = try await store.ingestJob("R")
        XCTAssertEqual(j2?.candidates, 1)
        XCTAssertEqual(j2?.written, 0)
        XCTAssertEqual(j2?.failed, 1)
        let items = try await store.ingestItems(jobID: "R")
        XCTAssertEqual(items.count, 1)            // still one row, not three
    }

    func testOrchestratorIngestsViaGitHubAdapterAndRecordsLedger() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let processor = MemoryProcessor(store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let writer = WikiIngestWriter(store: store, processor: processor)
        let json = """
        [{"name":"r1","full_name":"o/r1","description":"first repo with enough text to chunk nicely here",
          "html_url":"https://github.com/o/r1","language":"Swift","stargazers_count":3},
         {"name":"r2","full_name":"o/r2","description":"second repo also with enough descriptive body text",
          "html_url":"https://github.com/o/r2","language":"Go","stargazers_count":5}]
        """
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(HTMLTransport(html: json, contentType: "application/json")))
        let orch = WikiIngestOrchestrator(registry: reg, writer: writer, store: store, now: { 42 })

        let s = await orch.ingest(IngestRequest(input: "https://github.com/o", fetchedAt: 42), jobID: "JOB")
        XCTAssertEqual(s.status, "done")
        XCTAssertEqual(s.candidates, 2)
        XCTAssertEqual(s.written, 2)
        XCTAssertEqual(s.failed, 0)
        XCTAssertEqual(s.documentIDs.count, 2)
        XCTAssertEqual(s.cursor, "https://github.com/o/r1")     // first (newest) candidate

        // the ledger persisted the job + items, and the docs are actually in the store
        let job = try await store.ingestJob("JOB")
        XCTAssertEqual(job?.status, "done")
        XCTAssertEqual(job?.written, 2)
        let count1 = try await store.documentCount()
        XCTAssertEqual(count1, 2)

        // re-running is a clean no-op (dedup → all skipped, nothing duplicated)
        let s2 = await orch.ingest(IngestRequest(input: "https://github.com/o", fetchedAt: 42), jobID: "JOB2")
        XCTAssertEqual(s2.written, 0)
        XCTAssertEqual(s2.skipped, 2)
        let count2 = try await store.documentCount()
        XCTAssertEqual(count2, 2)
    }

    func testOrchestratorEmitsProgressEvents() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let processor = MemoryProcessor(store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let writer = WikiIngestWriter(store: store, processor: processor)
        let json = """
        [{"name":"r1","full_name":"o/r1","description":"first repo with enough text to chunk nicely here",
          "html_url":"https://github.com/o/r1","language":"Swift","stargazers_count":3},
         {"name":"r2","full_name":"o/r2","description":"second repo also with enough descriptive body text",
          "html_url":"https://github.com/o/r2","language":"Go","stargazers_count":5}]
        """
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(HTMLTransport(html: json, contentType: "application/json")))
        let orch = WikiIngestOrchestrator(registry: reg, writer: writer, store: store, now: { 42 })
        let log = IngestEventLog()
        _ = await orch.ingest(IngestRequest(input: "https://github.com/o", fetchedAt: 42), jobID: "JOB",
                              onProgress: { log.append($0) })
        let events = log.all
        // two candidate events (both written) + a finished event
        let candidates = events.filter { if case .candidate = $0 { return true }; return false }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(events.contains { if case .candidate(1, _, "written") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .finished(2, 0, 0) = $0 { return true }; return false })
        XCTAssertTrue({ if case .finished = events.last { return true }; return false }())
    }

    func testOrchestratorDryRunWritesNothing() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let processor = MemoryProcessor(store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let writer = WikiIngestWriter(store: store, processor: processor)
        let json = #"[{"name":"r1","full_name":"o/r1","html_url":"https://github.com/o/r1"}]"#
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(HTMLTransport(html: json, contentType: "application/json")))
        let orch = WikiIngestOrchestrator(registry: reg, writer: writer, store: store, now: { 7 })

        let s = await orch.ingest(IngestRequest(input: "https://github.com/o", dryRun: true, fetchedAt: 7), jobID: "DRY")
        XCTAssertEqual(s.candidates, 1)
        XCTAssertTrue(s.dryRun)
        XCTAssertEqual(s.written, 0)
        let dryCount = try await store.documentCount()
        XCTAssertEqual(dryCount, 0)                              // nothing written
        let dryJob = try await store.ingestJob("DRY")
        XCTAssertNil(dryJob)                                     // no ledger row for a dry-run
    }

    func testOrchestratorEnumerateFailureFailsJob() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let processor = MemoryProcessor(store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let writer = WikiIngestWriter(store: store, processor: processor)
        // A bare login that resolves to GitHub but the transport 404s every call.
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(RoutingTransport(routes: [:])))
        let orch = WikiIngestOrchestrator(registry: reg, writer: writer, store: store, now: { 1 })
        let s = await orch.ingest(IngestRequest(input: "https://github.com/ghost", fetchedAt: 1), jobID: "FAIL")
        XCTAssertEqual(s.status, "failed")
        XCTAssertNotNil(s.error)
        let failJob = try await store.ingestJob("FAIL")
        XCTAssertEqual(failJob?.status, "failed")
    }

    // MARK: GitHub owner

    func testGitHubOwnerParsing() {
        XCTAssertEqual(GitHubAdapter.owner(from: "https://github.com/openai"), "openai")
        XCTAssertEqual(GitHubAdapter.owner(from: "https://github.com/openai?tab=repositories"), "openai")
        XCTAssertEqual(GitHubAdapter.owner(from: "https://github.com/orgs/openai/repositories"), "openai")
        XCTAssertEqual(GitHubAdapter.owner(from: "karpathy"), "karpathy")
        XCTAssertNil(GitHubAdapter.owner(from: "not a login!"))
    }

    func testGitHubReposURL() {
        XCTAssertEqual(GitHubAdapter.reposURL(owner: "openai", org: false, perPage: 50)?.absoluteString,
                       "https://api.github.com/users/openai/repos?sort=pushed&per_page=50")
        XCTAssertEqual(GitHubAdapter.reposURL(owner: "openai", org: true, perPage: 200)?.absoluteString,
                       "https://api.github.com/orgs/openai/repos?sort=pushed&per_page=100")   // clamped to 100
    }

    func testGitHubRender() {
        let repo = GHRepo(name: "gpt-5", full_name: "openai/gpt-5", description: "The model",
                          html_url: "https://github.com/openai/gpt-5", language: "Python",
                          stargazers_count: 1000, forks_count: 7, pushed_at: "2026-06-01T00:00:00Z",
                          topics: ["llm", "ai"], fork: false, archived: false,
                          license: .init(spdx_id: "MIT"))
        let md = GitHubAdapter.render(repo)
        XCTAssertTrue(md.contains("# openai/gpt-5"))
        XCTAssertTrue(md.contains("The model"))
        XCTAssertTrue(md.contains("Language: Python"))
        XCTAssertTrue(md.contains("Stars: 1000"))
        XCTAssertTrue(md.contains("License: MIT"))
        XCTAssertTrue(md.contains("`llm`"))
    }

    func testGitHubAdapterEnumeratesExcludingArchivedAndForks() async throws {
        let json = """
        [{"name":"gpt-5","full_name":"openai/gpt-5","description":"The model",
          "html_url":"https://github.com/openai/gpt-5","language":"Python","stargazers_count":1000,
          "pushed_at":"2026-06-01T00:00:00Z","topics":["llm","ai"],"license":{"spdx_id":"MIT"}},
         {"name":"old","full_name":"openai/old","html_url":"https://github.com/openai/old","archived":true},
         {"name":"forked","full_name":"openai/forked","html_url":"https://github.com/openai/forked","fork":true}]
        """
        let mock = HTMLTransport(html: json, contentType: "application/json")
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(mock))
        let cands = try await collect(reg.resolve("https://github.com/openai").enumerate(
            IngestRequest(input: "https://github.com/openai", fetchedAt: 9)))
        XCTAssertEqual(cands.count, 1)                                  // archived + fork excluded
        XCTAssertEqual(cands[0].sourceURI, "https://github.com/openai/gpt-5")
        XCTAssertEqual(cands[0].rawType, .repos)
        XCTAssertEqual(cands[0].title, "openai/gpt-5")
        XCTAssertEqual(cands[0].provenance.adapter, "git")
        XCTAssertEqual(cands[0].provenance.collection, "openai")
        XCTAssertEqual(cands[0].provenance.upstreamID, "openai/gpt-5")
        XCTAssertTrue(cands[0].bodyMarkdown.contains("The model"))
    }

    // MARK: PDF helper

    private func writeTextPDF(_ path: String, text: String) throws {
        #if canImport(CoreGraphics) && canImport(CoreText)
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: path) as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw XCTSkip("CGContext PDF unavailable") }
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.beginPDFPage(nil); ctx.textPosition = CGPoint(x: 20, y: 150); CTLineDraw(line, ctx); ctx.endPDFPage()
        ctx.closePDF()
        #else
        throw XCTSkip("CoreGraphics/CoreText unavailable")
        #endif
    }
}
