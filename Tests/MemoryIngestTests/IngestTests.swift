import XCTest
import Foundation
@testable import MemoryIngest
@testable import MemoryStore
import InfraPrimitives

final class IngestTests: XCTestCase {
    func testNormaliserStripsTagsAndDecodesEntities() {
        let html = """
        <html><head><title>x</title><script>alert('no')</script></head>
        <body><p>Hello&nbsp;<b>world</b> &amp; goodbye</p></body></html>
        """
        let text = Normaliser.plainText(from: html)
        XCTAssertFalse(text.contains("<"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("world"))
        XCTAssertTrue(text.contains("&"))
    }

    func testContentSHAIsStableAcrossWhitespace() {
        let a = Normaliser.contentSHA(Normaliser.plainText(from: "<p>Hi</p>"))
        let b = Normaliser.contentSHA(Normaliser.plainText(from: "<p>Hi</p>  "))
        XCTAssertEqual(a, b)
    }

    func testChunkRingBackpressuresAndDrains() async throws {
        let ring = ChunkRing(capacity: 2)
        let doc = IngestedDocument(
            sourceName: "x", sourceKind: .rss, sourceURI: "u",
            title: nil, publishedAt: nil, fetchedAt: 0,
            canonicalText: "", rawBytes: 0, contentSHA: Data())
        try await ring.enqueue(doc)
        try await ring.enqueue(doc)
        let dq = await ring.dequeue()
        XCTAssertNotNil(dq)
    }

    func testClaudeSourceIsImportOnlyAndMapsToStoreSource() async throws {
        let spec = SourceSpec(name: "claude", kind: .claude,
                              uri: "claude://conversation/1")
        XCTAssertEqual(spec.storeSource, .claude)
        let outcome = await CurlFetcher().fetch(
            spec, state: SourceState(), deadline: .fromNow(.seconds(2)))
        guard case .failed(let message) = outcome else {
            return XCTFail("expected claude source fetch to fail explicitly")
        }
        XCTAssertTrue(message.contains("import-only"))
    }

    func testSchedulerSkipsDueWhenCursorAhead() async throws {
        let path = NSTemporaryDirectory() + "ingest-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let ring = ChunkRing()
        let scheduler = SourceScheduler(
            store: store, ring: ring,
            fetcher: StubFetcher(),
            config: .init(clock: { 100 }))
        await scheduler.register(SourceSpec(
            name: "future", kind: .manual, uri: "stub://", minIntervalSeconds: 60))
        try await store.upsertCursor(SourceCursorRow(
            source: "future", nextEligibleAt: 1_000_000))
        let stats = try await scheduler.tick()
        XCTAssertEqual(stats.attempted, 0)
    }
}

struct StubFetcher: Fetcher {
    func fetch(_ spec: SourceSpec, state: SourceState, deadline: Deadline) async -> FetchOutcome {
        .fresh(body: Data("hello".utf8), etag: nil, lastModified: nil)
    }
}
