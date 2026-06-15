import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore
import MemoryProcess
import MemoryInfer
import PinnedFetcher
import EgressGuard
import WikiIngest
import WikiResearch

/// Enforcement coverage for the write gate in the research compiler (Codex-review
/// fix): in STRICT mode an ungrounded synthesis (zero linked claims) must be
/// REFUSED before the page is written — not written-then-flagged. In LINT mode the
/// same page is logged but still written.
final class ResearchCompilerGateTests: XCTestCase {
    private actor HTMLTransport: PinnedTransport {
        let bytes: Data
        init(html: String) {
            bytes = Data("HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: \(html.utf8.count)\r\n\r\n\(html)".utf8)
        }
        func roundTrip(_ req: TransportRequest) async -> Result<TransportResponse, FetchError> {
            .success(TransportResponse(peerIP: "93.184.216.34", bytes: bytes, truncated: false))
        }
    }

    private func makeCompiler(mode: String, store: MemoryStore, vault: String) async throws -> LiveResearchCompiler {
        try await store.setMetaValue("wiki.lint_on_write", mode)
        let processor = MemoryProcessor(store: store, inference: MockInferenceProvider(embeddingDimension: 8))
        let writer = WikiIngestWriter(store: store, processor: processor)
        let fetcher = PinnedFetcher(
            guard_: EgressGuard(EgressPolicy(allowedHosts: [], allowHTTP: true,
                                             resolve: { _ in ["93.184.216.34"] })),
            transport: HTMLTransport(html: "<html><body><h1>T</h1><p>readable body text here</p></body></html>"))
        // claimExtractor nil → zero claims linked → the synthesis page is ungrounded.
        return LiveResearchCompiler(writer: writer, store: store, fetcher: fetcher,
                                    fetchedAt: 100, vaultRoot: vault, claimExtractor: nil)
    }

    private func makeStore() throws -> (MemoryStore, String) {
        let dir = NSTemporaryDirectory() + "rcgate-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (try MemoryStore(MemoryStoreConfig(path: dir + "/m.db", embeddingDimension: 8)), dir)
    }

    func testStrictModeRefusesUngroundedPage() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let compiler = try await makeCompiler(mode: "strict", store: store, vault: dir)
        let src = RankedSource(url: "https://ex.com/a", title: "A", credibility: 3, agentQuality: 4)
        _ = try await compiler.compile(topic: "graph neural nets", sources: [src], round: 1)
        let slug = "research-" + LiveResearchCompiler.slugify("graph neural nets") + "-r1"
        let page = try await store.synthesis(slug: slug)
        XCTAssertNil(page, "strict mode must REFUSE the ungrounded page (gate before write)")
    }

    func testLintModeWritesUngroundedPage() async throws {
        let (store, dir) = try makeStore(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let compiler = try await makeCompiler(mode: "lint", store: store, vault: dir)
        let src = RankedSource(url: "https://ex.com/a", title: "A", credibility: 3, agentQuality: 4)
        _ = try await compiler.compile(topic: "graph neural nets", sources: [src], round: 1)
        let slug = "research-" + LiveResearchCompiler.slugify("graph neural nets") + "-r1"
        let page = try await store.synthesis(slug: slug)
        XCTAssertNotNil(page, "lint mode logs but never blocks → the page is still written")
    }

    // MARK: link-graph lint is now LIVE on the write path (was a structural no-op via body:"")

    func testRenderSynthesisBodyEmitsSeeAlsoLinks() {
        let withPrior = LiveResearchCompiler.renderSynthesisBody(
            topic: "Graph Nets", round: 2, sources: ["https://e/a"], seeAlso: ["research-graph-nets-r1"])
        XCTAssertTrue(withPrior.contains("## See Also"))
        XCTAssertTrue(withPrior.contains("[[research-graph-nets-r1]]"), "prior-round edge emitted")
        XCTAssertTrue(withPrior.contains("- https://e/a"), "external sources stay plain citations, not [[links]]")
        // No prior rounds → no See-Also section (round 1 has nothing real to link).
        let bare = LiveResearchCompiler.renderSynthesisBody(topic: "X", round: 1, sources: [], seeAlso: [])
        XCTAssertFalse(bare.contains("## See Also"))
    }

    func testStrictBlocksBrokenSeeAlsoLink() {
        // THE adversarial proof the linter now ITERATES: a [[link]] to a non-existent
        // slug must trip brokenLink in strict mode. With the old body:"" this could never
        // fire (links(in:"") == []), so the link-graph check named this axis was dead.
        let body = LiveResearchCompiler.renderSynthesisBody(
            topic: "T", round: 2, sources: ["https://e/a"], seeAlso: ["research-t-r1"])
        let gate = WikiWriteGate(mode: .strict, vaultRoot: NSTemporaryDirectory())
        let v = gate.validate(WikiLintPage(slug: "research-t-r2", body: body, category: "synthesis",
                                           claimLinkCount: 1),               // grounded → isolate the brokenLink
                              validSlugs: ["research-t-r2"])                 // r1 NOT present → broken
        XCTAssertTrue(v.block, "a broken See-Also link blocks in strict mode (linter now iterates)")
        XCTAssertTrue(v.issues.contains { $0.kind == .brokenLink && $0.target == "research-t-r1" })
    }

    func testStrictAcceptsValidSeeAlsoLink() {
        let body = LiveResearchCompiler.renderSynthesisBody(
            topic: "T", round: 2, sources: ["https://e/a"], seeAlso: ["research-t-r1"])
        let gate = WikiWriteGate(mode: .strict, vaultRoot: NSTemporaryDirectory())
        let v = gate.validate(WikiLintPage(slug: "research-t-r2", body: body, category: "synthesis",
                                           claimLinkCount: 1),
                              validSlugs: ["research-t-r2", "research-t-r1"])  // resolves
        XCTAssertFalse(v.block, "a valid prior-round See-Also link must NOT false-block the research write-path")
    }

    func testLintModeCLIFlagParsesAndValidates() throws {
        let opt = try CodexMemoryWikiResearch.parse(["graph nets", "--lint-mode", "strict"])
        XCTAssertEqual(opt.lintMode, "strict")
        XCTAssertThrowsError(try CodexMemoryWikiResearch.parse(["t", "--lint-mode", "bogus"]))
    }
}
