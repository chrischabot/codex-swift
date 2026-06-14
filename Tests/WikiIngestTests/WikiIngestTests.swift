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
        // forced wins
        XCTAssertEqual(WikiAdapterRegistry.detectKind("/notes/todo.md", forced: .pdf), .pdf)
        XCTAssertEqual(WikiAdapterRegistry.detectKind("https://example.com", forced: .feed), .feed)
    }

    func testNotImplementedAdapterYieldsError() async throws {
        let reg = WikiAdapterRegistry(fetcher: publicFetcher(HTMLTransport(html: "")))
        let adapter = reg.resolve("https://github.com/openai")   // github-owner not implemented in M5a
        do { _ = try await collect(adapter.enumerate(IngestRequest(input: "x", fetchedAt: 1))); XCTFail("expected error") }
        catch WikiIngestError.notImplemented(let k) { XCTAssertEqual(k, .githubOwner) }
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
        // Changed content under the SAME canonical URI → a NEW immutable revision.
        cand.bodyMarkdown = "completely different replacement content with other distinct words"
        let r2 = try await writer.write(cand, extract: false)
        XCTAssertFalse(r2.skipped)
        XCTAssertNotEqual(r2.documentID, r1.documentID)
        let twoDocs = try await store.documentCount()
        XCTAssertEqual(twoDocs, 2)   // both revisions present (old not clobbered)
        // Re-ingesting the same changed content → revision dedupe (no duplicate).
        let r3 = try await writer.write(cand, extract: false)
        XCTAssertTrue(r3.skipped)
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
