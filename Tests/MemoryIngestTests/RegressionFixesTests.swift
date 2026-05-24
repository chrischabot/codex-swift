import XCTest
import Foundation
@testable import MemoryIngest
@testable import MemoryStore
import InfraPrimitives

/// Regression coverage for the post-code-review fixes touching MemoryIngest.
final class IngestRegressionFixesTests: XCTestCase {
    // Fix #1: tryDequeue must return nil immediately when the ring is empty
    // (the daemon's main loop relies on this to avoid deadlocking between
    // ticks).
    func testTryDequeueReturnsNilWhenEmpty() async throws {
        let ring = ChunkRing(capacity: 4)
        let v = await ring.tryDequeue()
        XCTAssertNil(v)
        // After enqueue, tryDequeue should hand it back.
        let doc = IngestedDocument(
            sourceName: "s", sourceKind: .manual, sourceURI: "u",
            title: nil, publishedAt: nil, fetchedAt: 0,
            canonicalText: "", rawBytes: 0, contentSHA: Data())
        try await ring.enqueue(doc)
        let v2 = await ring.tryDequeue()
        XCTAssertNotNil(v2)
        let v3 = await ring.tryDequeue()
        XCTAssertNil(v3, "second tryDequeue must not park")
    }

    // Fix #6: splitHeaders walks past every redirect hop's header block to
    // report the FINAL hop's status/etag.
    func testSplitHeadersHonoursRedirectChain() throws {
        let fetcher = CurlFetcher()
        let combined =
            "HTTP/1.1 301 Moved Permanently\r\n" +
            "Location: https://example.com/v2\r\n\r\n" +
            "HTTP/1.1 200 OK\r\n" +
            "ETag: \"final\"\r\n\r\n" +
            "<html>real body</html>"
        let data = Data(combined.utf8)
        let split = fetcher.splitHeaders(data)
        XCTAssertNotNil(split)
        XCTAssertTrue(split?.headers.contains("200 OK") == true,
                      "final status should be 200, got: \(split?.headers ?? "")")
        XCTAssertTrue(split?.headers.contains("final") == true)
        let parsed = fetcher.parseHeaders(split!.headers)
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.etag, "\"final\"")
        XCTAssertEqual(String(data: split!.body, encoding: .utf8),
                       "<html>real body</html>")
    }

    // Fix #4: TwitterAPI watermark must flow into source_cursor.high_watermark_id
    // even when no etag is set. (We use the CompositeFetcher's stub path via
    // a synthetic FetchOutcome since hitting real TwitterAPI.io needs a key.)
    func testSchedulerStoresWatermarkFromFreshOutcome() async throws {
        let path = NSTemporaryDirectory() + "ingest-fix-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let ring = ChunkRing()
        let scheduler = SourceScheduler(
            store: store, ring: ring,
            fetcher: WatermarkStubFetcher(),
            config: .init(clock: { 100 }))
        await scheduler.register(SourceSpec(
            name: "x-test", kind: .x, uri: "user:nobody",
            minIntervalSeconds: 60))
        _ = try await scheduler.tick()
        let cursor = try await store.cursor(source: "x-test")
        XCTAssertEqual(cursor?.highWatermarkID, "tweet-id-999")
    }

    // Fix #12: consecutiveFailures counter escalates the backoff window.
    func testConsecutiveFailuresEscalate() async throws {
        let path = NSTemporaryDirectory() + "ingest-bf-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        let ring = ChunkRing()
        let scheduler = SourceScheduler(
            store: store, ring: ring,
            fetcher: AlwaysFailingFetcher(),
            config: .init(clock: { 100 }))
        await scheduler.register(SourceSpec(
            name: "bf", kind: .web, uri: "https://invalid", minIntervalSeconds: 1))
        _ = try await scheduler.tick()
        var cursor = try await store.cursor(source: "bf")
        XCTAssertEqual(cursor?.consecutiveFailures, 1)
        // Wind the clock so the source is eligible again; second tick should
        // bump the counter and use a wider backoff window.
        let scheduler2 = SourceScheduler(
            store: store, ring: ring,
            fetcher: AlwaysFailingFetcher(),
            config: .init(clock: { 999_999 }))
        await scheduler2.register(SourceSpec(
            name: "bf", kind: .web, uri: "https://invalid", minIntervalSeconds: 1))
        _ = try await scheduler2.tick()
        cursor = try await store.cursor(source: "bf")
        XCTAssertEqual(cursor?.consecutiveFailures, 2)
    }
}

struct WatermarkStubFetcher: Fetcher {
    func fetch(_ spec: SourceSpec, state: SourceState,
               deadline: Deadline) async -> FetchOutcome {
        .fresh(body: Data("hi".utf8), etag: nil, lastModified: nil,
               highWatermarkID: "tweet-id-999")
    }
}

struct AlwaysFailingFetcher: Fetcher {
    func fetch(_ spec: SourceSpec, state: SourceState,
               deadline: Deadline) async -> FetchOutcome {
        .failed("synthetic failure")
    }
}
