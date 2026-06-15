import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Coverage for wiki-collect: the scale gate, parse/build/format helpers, and the
/// WikiCollectDownloader safety branches (non-https skip, no-url skip, MIME allowlist
/// with temp cleanup, content-addressed placement under output/assets/, truncated
/// status, path-traversal-safe catalog component). The downloader is driven by a mock
/// fetcher — no network.
final class WikiCollectCLITests: XCTestCase {
    private typealias C = CodexMemoryWikiCollect

    // A mock that returns a pre-staged temp file (so place() can move it).
    private final class MockFetcher: CollectMediaFetcher, @unchecked Sendable {
        let result: Result<CollectMedia, CollectError>
        private(set) var fetched: [String] = []
        private let lock = NSLock()
        init(_ result: Result<CollectMedia, CollectError>) { self.result = result }
        func fetch(_ url: URL) async -> Result<CollectMedia, CollectError> {
            lock.withLock { fetched.append(url.absoluteString) }
            return result
        }
    }

    // Stages a FRESH temp file on each fetch (place() moves it), with a fixed sha/mime —
    // models PinnedFetcher's per-download 0600 staging.
    private final class StagingMockFetcher: CollectMediaFetcher, @unchecked Sendable {
        let sha: String; let mime: String
        init(sha: String, mime: String = "image/png") { self.sha = sha; self.mime = mime }
        func fetch(_ url: URL) async -> Result<CollectMedia, CollectError> {
            let p = NSTemporaryDirectory() + "stage-\(UUID().uuidString)"
            try? "PNGBYTES".write(toFile: p, atomically: true, encoding: .utf8)
            return .success(CollectMedia(tempPath: p, byteSize: 8, sha256: sha, mime: mime, truncated: false))
        }
    }

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "wc-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private func tempVault() throws -> String {
        let v = NSTemporaryDirectory() + "wcvault-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: v, withIntermediateDirectories: true)
        return v
    }

    func testRunDownloadCanonicalKeyedPersistsNotStuckPending() async throws {
        let store = try makeStore(); let vault = try tempVault()
        defer { try? FileManager.default.removeItem(atPath: vault) }
        _ = try await store.upsertCollectItem(CollectItemRow(
            catalogSlug: "c", rowNumber: 1, title: "x", canonicalURL: "https://ex.com/a.png",
            downloadStatus: "pending", createdAt: 1))
        let (out, ok) = try await C.runDownload(["c"], store: store, now: 2,
                                                fetcher: StagingMockFetcher(sha: "aa11"), vaultRoot: vault)
        XCTAssertTrue(ok); XCTAssertTrue(out.contains("1 downloaded"))
        let items = try await store.collectItems(catalogSlug: "c")
        XCTAssertEqual(items.count, 1, "no duplicate row created")
        XCTAssertEqual(items.first?.downloadStatus, "downloaded", "row is persisted as downloaded, NOT stuck pending")
        XCTAssertEqual(items.first?.sha256, "aa11")
        XCTAssertNotNil(items.first?.localMediaPath)
    }

    func testRunDownloadMediaOnlyDoesNotDuplicate() async throws {
        let store = try makeStore(); let vault = try tempVault()
        defer { try? FileManager.default.removeItem(atPath: vault) }
        // media-only item: all dedupe keys NULL at add time (the regression that
        // previously INSERTed a duplicate once sha was set).
        _ = try await store.upsertCollectItem(CollectItemRow(
            catalogSlug: "c", rowNumber: 1, title: "x", mediaURL: "https://ex.com/m.png",
            downloadStatus: "pending", createdAt: 1))
        _ = try await C.runDownload(["c"], store: store, now: 2,
                                    fetcher: StagingMockFetcher(sha: "bb22"), vaultRoot: vault)
        let items = try await store.collectItems(catalogSlug: "c")
        XCTAssertEqual(items.count, 1, "media-only item is updated in place, not duplicated")
        XCTAssertEqual(items.first?.downloadStatus, "downloaded")
        XCTAssertEqual(items.first?.sha256, "bb22")
    }

    func testRunDownloadIsIdempotent() async throws {
        let store = try makeStore(); let vault = try tempVault()
        defer { try? FileManager.default.removeItem(atPath: vault) }
        _ = try await store.upsertCollectItem(CollectItemRow(
            catalogSlug: "c", rowNumber: 1, title: "x", canonicalURL: "https://ex.com/a.png",
            downloadStatus: "pending", createdAt: 1))
        let f = StagingMockFetcher(sha: "cc33")
        _ = try await C.runDownload(["c"], store: store, now: 2, fetcher: f, vaultRoot: vault)
        // second run: the item is already "downloaded" → skipped, no re-fetch, still 1 row.
        let (out2, _) = try await C.runDownload(["c"], store: store, now: 3, fetcher: f, vaultRoot: vault)
        XCTAssertTrue(out2.contains("of 0 attempted"), "already-downloaded item is not re-fetched")
        let after = try await store.collectItems(catalogSlug: "c")
        XCTAssertEqual(after.count, 1)
    }

    private func stagedTemp(_ bytes: String = "data") throws -> String {
        let p = NSTemporaryDirectory() + "collect-src-\(UUID().uuidString)"
        try bytes.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func testScaleGate() {
        XCTAssertEqual(WikiCollectScale.classify(1), .ok)
        XCTAssertEqual(WikiCollectScale.classify(100), .ok)
        XCTAssertEqual(WikiCollectScale.classify(101), .large)
        XCTAssertEqual(WikiCollectScale.classify(500), .large)
        XCTAssertEqual(WikiCollectScale.classify(501), .huge)
        XCTAssertEqual(WikiCollectScale.classify(10_000), .huge)
    }

    func testParseAddValidatesKind() throws {
        let o = try C.parseAdd(["memes", "--title", "Doge", "--kind", "meme", "--canonical-url", "https://ex.com/d"])
        XCTAssertEqual(o.catalog, "memes"); XCTAssertEqual(o.kind, "meme")
        let row = C.item(from: o, rowNumber: 5, now: 100)
        XCTAssertEqual(row.rowNumber, 5); XCTAssertEqual(row.downloadStatus, "pending")
        XCTAssertThrowsError(try C.parseAdd(["c", "--title", "T", "--kind", "bogus"]))   // bad kind
        XCTAssertThrowsError(try C.parseAdd(["--title", "T"]))                           // missing catalog
        XCTAssertThrowsError(try C.parseAdd(["c"]))                                      // missing title
    }

    func testDownloaderRejectsNonHTTPS() async throws {
        let item = CollectItemRow(catalogSlug: "c", rowNumber: 1, title: "x", canonicalURL: "http://ex.com/a.png", createdAt: 1)
        let fetcher = MockFetcher(.success(CollectMedia(tempPath: "/x", byteSize: 1, sha256: "s", mime: "image/png", truncated: false)))
        let out = await WikiCollectDownloader.place(item: item, catalog: "c", vaultRoot: NSTemporaryDirectory(), fetcher: fetcher, now: 2)
        XCTAssertEqual(out.downloadStatus, "skipped-non-https")
        XCTAssertTrue(fetcher.fetched.isEmpty, "non-https URL is never fetched")
    }

    func testDownloaderNoURLSkips() async throws {
        let item = CollectItemRow(catalogSlug: "c", rowNumber: 1, title: "x", createdAt: 1)
        let fetcher = MockFetcher(.failure(CollectError("unused")))
        let out = await WikiCollectDownloader.place(item: item, catalog: "c", vaultRoot: NSTemporaryDirectory(), fetcher: fetcher, now: 2)
        XCTAssertEqual(out.downloadStatus, "skipped-no-url")
    }

    func testDownloaderRejectsDisallowedMIMEAndCleansTemp() async throws {
        let temp = try stagedTemp("<html>evil</html>")
        let item = CollectItemRow(catalogSlug: "c", rowNumber: 1, title: "x", mediaURL: "https://ex.com/a", createdAt: 1)
        let fetcher = MockFetcher(.success(CollectMedia(tempPath: temp, byteSize: 9, sha256: "abc", mime: "text/html", truncated: false)))
        let out = await WikiCollectDownloader.place(item: item, catalog: "c", vaultRoot: NSTemporaryDirectory(), fetcher: fetcher, now: 2)
        XCTAssertEqual(out.downloadStatus, "rejected-mime")
        XCTAssertEqual(out.nextAction, "text/html")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp), "the staged temp file is removed on MIME rejection")
        XCTAssertNil(out.localMediaPath)
    }

    func testDownloaderSuccessPlacesContentAddressedAssetUnderOutput() async throws {
        let vault = NSTemporaryDirectory() + "collectvault-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: vault) }
        let temp = try stagedTemp("PNGDATA")
        let item = CollectItemRow(catalogSlug: "art", rowNumber: 1, title: "ml", mediaURL: "https://ex.com/ml.png", createdAt: 1)
        let fetcher = MockFetcher(.success(CollectMedia(tempPath: temp, byteSize: 7, sha256: "deadbeefcafef00d1234", mime: "image/png", truncated: false)))
        let out = await WikiCollectDownloader.place(item: item, catalog: "art", vaultRoot: vault, fetcher: fetcher, now: 42)
        XCTAssertEqual(out.downloadStatus, "downloaded")
        XCTAssertEqual(out.sha256, "deadbeefcafef00d1234")
        XCTAssertEqual(out.mediaBytes, 7)
        XCTAssertEqual(out.downloadedAt, 42)
        let dest = try XCTUnwrap(out.localMediaPath)
        XCTAssertTrue(dest.contains("/output/assets/collect-art/"), "asset under output/assets/collect-<catalog>/, never raw/")
        XCTAssertTrue(dest.hasSuffix("deadbeefcafef00d.png"), "content-addressed filename (sha prefix + ext)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp), "temp moved, not left behind")
    }

    func testDownloaderTruncatedStatus() async throws {
        let vault = NSTemporaryDirectory() + "collectvault-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: vault) }
        let temp = try stagedTemp("partial")
        let item = CollectItemRow(catalogSlug: "c", rowNumber: 1, title: "x", mediaURL: "https://ex.com/big.mp4", createdAt: 1)
        let fetcher = MockFetcher(.success(CollectMedia(tempPath: temp, byteSize: 7, sha256: "f00d", mime: "video/mp4", truncated: true)))
        let out = await WikiCollectDownloader.place(item: item, catalog: "c", vaultRoot: vault, fetcher: fetcher, now: 2)
        XCTAssertEqual(out.downloadStatus, "downloaded-truncated")
    }

    func testDownloaderFetchFailure() async throws {
        let item = CollectItemRow(catalogSlug: "c", rowNumber: 1, title: "x", mediaURL: "https://ex.com/a.png", createdAt: 1)
        let fetcher = MockFetcher(.failure(CollectError("egressDenied(reason: blocked)")))
        let out = await WikiCollectDownloader.place(item: item, catalog: "c", vaultRoot: NSTemporaryDirectory(), fetcher: fetcher, now: 2)
        XCTAssertEqual(out.downloadStatus, "failed")
        XCTAssertTrue(out.nextAction?.contains("egressDenied") ?? false)
    }

    func testCatalogSanitizeBlocksTraversal() {
        XCTAssertEqual(WikiCollectDownloader.sanitize("../../etc"), "------etc")
        XCTAssertEqual(WikiCollectDownloader.sanitize("a/b\\c"), "a-b-c")
        XCTAssertEqual(WikiCollectDownloader.sanitize("ok-name_1"), "ok-name_1")
        XCTAssertFalse(WikiCollectDownloader.sanitize("../x").contains("/"), "no path separators survive")
    }

    func testFormatList() throws {
        let items = [CollectItemRow(catalogSlug: "c", rowNumber: 1, title: "A", collectKind: "meme",
                                    canonicalURL: "https://ex.com/a", downloadStatus: "downloaded", createdAt: 1)]
        let json = C.formatList(items, json: true)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["count"] as? Int, 1)
        XCTAssertEqual((obj["items"] as? [[String: Any]])?.first?["downloadStatus"] as? String, "downloaded")
    }
}
