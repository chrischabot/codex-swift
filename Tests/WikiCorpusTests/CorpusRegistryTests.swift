import XCTest
import Foundation
@testable import WikiCorpus
import MemoryStore

/// Severe coverage for the corpus registry + LRU store cache: persistence,
/// `<HUB>`-relative portability across machines, resolution rules, archive
/// lifecycle, the single-embedder stamp enforced through the cache, and bounded
/// LRU eviction.
final class CorpusRegistryTests: XCTestCase {
    private func tmpDir() -> String {
        let d = NSTemporaryDirectory() + "wikicorpus-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func testRegisterListPersistAcrossReopen() async throws {
        let hub = tmpDir(); defer { try? FileManager.default.removeItem(atPath: hub) }
        let reg = CorpusRegistry(hubRoot: hub)
        _ = try await reg.register(CorpusRecord(name: "agents", dbPath: hub + "/topics/agents/wiki.db",
                                                embeddingProviderID: "nomic", embeddingDimension: 1536,
                                                description: "AI agents"))
        let active = await reg.list()
        XCTAssertEqual(active.map(\.name), ["agents"])
        // corpora.json persisted; a fresh registry at the same hub sees it.
        let reg2 = CorpusRegistry(hubRoot: hub)
        let got = await reg2.get("agents")
        XCTAssertEqual(got?.embeddingProviderID, "nomic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hub + "/corpora.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hub + "/corpora.json.tmp"))  // atomic, no temp left
    }

    func testHubRelativePathPortabilityAcrossMachines() async throws {
        let hubA = tmpDir(); defer { try? FileManager.default.removeItem(atPath: hubA) }
        let reg = CorpusRegistry(hubRoot: hubA)
        _ = try await reg.register(CorpusRecord(name: "foo", dbPath: hubA + "/topics/foo/wiki.db"))
        // Stored form must be <HUB>-relative, not the absolute /Users/... path.
        let json = String(data: FileManager.default.contents(atPath: hubA + "/corpora.json")!, encoding: .utf8)!
        XCTAssertTrue(json.contains("<HUB>/topics/foo/wiki.db"))
        XCTAssertFalse(json.contains(hubA + "/topics/foo/wiki.db"))

        // Simulate moving the shared hub to a different machine path.
        let hubB = tmpDir(); defer { try? FileManager.default.removeItem(atPath: hubB) }
        try FileManager.default.copyItem(atPath: hubA + "/corpora.json", toPath: hubB + "/corpora.json")
        let regB = CorpusRegistry(hubRoot: hubB)
        let rec = try await regB.resolve("foo")
        let abs = await regB.resolvedDBPath(rec)
        XCTAssertEqual(abs, hubB + "/topics/foo/wiki.db")   // re-rooted to the new hub
    }

    func testResolveLocalWikiAndDefaultAutoRegister() async throws {
        let hub = tmpDir(); defer { try? FileManager.default.removeItem(atPath: hub) }
        let reg = CorpusRegistry(hubRoot: hub)
        // --local
        let local = try await reg.resolve(nil, local: true, cwd: "/work/proj")
        XCTAssertEqual(local.dbPath, "/work/proj/.wiki/wiki.db")
        // default auto-registers once and is stable
        let d1 = try await reg.resolve(nil)
        let d2 = try await reg.resolve(nil)
        XCTAssertEqual(d1.name, "default")
        XCTAssertEqual(d1.dbPath, d2.dbPath)
        let listed = await reg.list()
        XCTAssertEqual(listed.filter { $0.name == "default" }.count, 1)  // registered exactly once
        // --wiki unknown throws
        await XCTAssertThrowsErrorAsync(try await reg.resolve("nope"))
    }

    func testArchiveRestoreVisibility() async throws {
        let hub = tmpDir(); defer { try? FileManager.default.removeItem(atPath: hub) }
        let reg = CorpusRegistry(hubRoot: hub)
        _ = try await reg.register(CorpusRecord(name: "old", dbPath: hub + "/topics/old/wiki.db"))
        try await reg.archive("old", reason: "stale")
        let hidden = await reg.list().count
        let withArchived = await reg.list(includeArchived: true).count
        let status = await reg.get("old")?.status
        XCTAssertEqual(hidden, 0)                 // hidden from default
        XCTAssertEqual(withArchived, 1)           // visible with flag
        XCTAssertEqual(status, .archived)
        try await reg.restore("old")
        let restored = await reg.list().count
        XCTAssertEqual(restored, 1)
    }

    func testRegisterDuplicateThrows() async throws {
        let hub = tmpDir(); defer { try? FileManager.default.removeItem(atPath: hub) }
        let reg = CorpusRegistry(hubRoot: hub)
        _ = try await reg.register(CorpusRecord(name: "a", dbPath: hub + "/a.db"))
        await XCTAssertThrowsErrorAsync(try await reg.register(CorpusRecord(name: "a", dbPath: hub + "/a2.db")))
    }

    // MARK: store cache

    func testStoreCacheReturnsSameInstanceAndValidatesStamp() async throws {
        let hub = tmpDir(); defer { try? FileManager.default.removeItem(atPath: hub) }
        let cache = WikiStoreCache(capacity: 4)
        let path = hub + "/s1.db"
        let s1 = try await cache.store(path: path, embeddingProviderID: "nomic", embeddingDimension: 8)
        let s2 = try await cache.store(path: path, embeddingProviderID: "nomic", embeddingDimension: 8)
        XCTAssertTrue(ObjectIdentifier(s1) == ObjectIdentifier(s2))  // cached identity, one open
        let count = await cache.count()
        XCTAssertEqual(count, 1)

        // Evict, then reopen with a DIFFERENT provider id → the stamp validation
        // at open must throw (the single-embedder invariant, enforced via cache).
        await cache.evictAll()
        await XCTAssertThrowsErrorAsync(
            try await cache.store(path: path, embeddingProviderID: "openai", embeddingDimension: 8))
    }

    func testStoreCacheLRUEviction() async throws {
        let hub = tmpDir(); defer { try? FileManager.default.removeItem(atPath: hub) }
        let cache = WikiStoreCache(capacity: 2)
        _ = try await cache.store(path: hub + "/a.db", embeddingProviderID: nil, embeddingDimension: 8)
        _ = try await cache.store(path: hub + "/b.db", embeddingProviderID: nil, embeddingDimension: 8)
        _ = try await cache.store(path: hub + "/c.db", embeddingProviderID: nil, embeddingDimension: 8)
        let count = await cache.count()
        XCTAssertEqual(count, 2)  // 'a' (LRU) evicted
        await cache.trim(to: 0)
        let zero = await cache.count()
        XCTAssertEqual(zero, 0)
    }
}

// Async throwing-assertion helper (XCTAssertThrowsError can't await the expression).
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) }
    catch { /* expected */ }
}
