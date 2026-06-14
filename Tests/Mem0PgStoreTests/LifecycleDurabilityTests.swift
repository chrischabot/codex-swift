import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import Mem0Core
import EmbeddedPG
@testable import Mem0PgStore

/// Lifecycle, durability, and concurrency: the FIFO gate must not lose writes
/// under concurrent callers; the postmaster must restart idempotently and recover
/// committed rows after a `kill -9`; and an APFS cold-clone must be a readable
/// cluster.
///
/// `CODEX_MEM0_PG_TEST=1 swift test --filter Mem0PgStoreTests`
final class LifecycleDurabilityTests: XCTestCase {

    private func postmasterPID(_ paths: PGPaths) -> Int32? {
        guard let s = try? String(contentsOfFile: paths.dataDir + "/postmaster.pid", encoding: .utf8),
              let line = s.split(separator: "\n").first else { return nil }
        return Int32(line.trimmingCharacters(in: .whitespaces))
    }

    /// 64 concurrent inserts + concurrent searches on one store actor: every write
    /// must land (no transaction interleaving corruption), proving the FIFO gate
    /// serializes the shared connection correctly.
    func testConcurrentInsertsNoLostWrites() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, _, _ in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<64 {
                    group.addTask {
                        try await store.insert([VectorRecord(id: "c\(i)", vector: .oneHot(i % 4, 4),
                                                             payload: ["user_id": .string("u")])])
                    }
                }
                for _ in 0..<16 {
                    group.addTask {
                        _ = try await store.search("", [1, 0, 0, 0], topK: 10, filters: ["user_id": .string("u")])
                    }
                }
                try await group.waitForAll()  // rethrows if any op hit a tx-state error
            }
            let all = try await store.list(["user_id": .string("u")], limit: nil)
            XCTAssertEqual(all.count, 64, "all concurrent writes must land — no lost writes")
            XCTAssertEqual(Set(all.map(\.id)).count, 64, "no duplicates/overwrites")
        }
    }

    /// `ensureStarted` is idempotent (no double-spawn), and a committed row
    /// survives a `kill -9` of the postmaster followed by a fresh start (WAL
    /// recovery) — which must NOT hang on the stale `postmaster.pid`.
    func testIdempotentStartAndKill9Recovery() async throws {
        try XCTSkipUnless(PGTestHarness.enabled, "set CODEX_MEM0_PG_TEST=1")
        let paths = try PGTestHarness.makePaths()
        let clusterRoot = (paths.dataDir as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: clusterRoot) }

        let lifecycle = PostgresLifecycle(paths: paths)
        try await lifecycle.ensureStarted()
        let pid1 = postmasterPID(paths)
        try await lifecycle.ensureStarted()                  // second call
        XCTAssertEqual(pid1, postmasterPID(paths), "ensureStarted must not double-spawn")

        let store = try await Mem0PgVectorStore.open(paths: paths, dims: 4)  // already running
        try await store.insert([VectorRecord(id: "survivor", vector: [1, 0, 0, 0],
                                             payload: ["user_id": .string("u")])])
        await store.shutdown()

        // Crash: SIGKILL the postmaster, then wait for it to actually die.
        guard let pid = pid1 else { return XCTFail("no postmaster pid") }
        #if canImport(Darwin)
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        for _ in 0..<100 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(50)) }
        #endif

        // Fresh lifecycle must clean the stale pid, recover from WAL, and find the row.
        let lifecycle2 = PostgresLifecycle(paths: paths)
        try await lifecycle2.ensureStarted()
        let store2 = try await Mem0PgVectorStore.open(paths: paths, dims: 4)
        let got = try await store2.get("survivor")
        XCTAssertNotNil(got, "a committed row must survive kill -9 (WAL recovery)")
        await store2.shutdown()
        try? await lifecycle2.stop()
    }

    /// A cold APFS clone (stop → clonefile → start) is an independent, readable
    /// cluster containing the committed data.
    func testColdSnapshotCloneIsReadable() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, lifecycle, paths in
            try XCTSkipUnless(PGSnapshot.supportsCloning(at: paths.dataDir),
                              "volume does not support file cloning")
            try await store.insert([VectorRecord(id: "snap", vector: [1, 0, 0, 0],
                                                 payload: ["user_id": .string("u")])])
            // Cold snapshot: stop the source, then clone PGDATA.
            await store.shutdown()
            try? await lifecycle.stop()
            let cloneRoot = NSTemporaryDirectory() + "codexmem0-clone-" + UUID().uuidString.prefix(8)
            defer { try? FileManager.default.removeItem(atPath: cloneRoot) }
            let cloneData = cloneRoot + "/pgdata"
            try PGSnapshot.cloneQuiesced(from: paths.dataDir, to: cloneData)
            try? FileManager.default.removeItem(atPath: cloneData + "/postmaster.pid")

            let clonePaths = PGPaths(serverBinDir: paths.serverBinDir, dataDir: cloneData,
                                     socketDir: cloneRoot + "/run", port: 5432,
                                     username: paths.username, database: paths.database)
            let cloneLifecycle = PostgresLifecycle(paths: clonePaths)
            let cloneStore = try await Mem0PgVectorStore.open(paths: clonePaths, dims: 4, lifecycle: cloneLifecycle)
            let got = try await cloneStore.get("snap")
            XCTAssertNotNil(got, "the APFS clone is a readable cluster with the committed row")
            await cloneStore.shutdown()
            try? await cloneLifecycle.stop()
        }
    }
}
