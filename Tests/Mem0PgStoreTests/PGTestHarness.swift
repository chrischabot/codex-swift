import XCTest
import Foundation
import Mem0Core
import Mem0Store
import EmbeddedPG
@testable import Mem0PgStore

/// Shared infrastructure for the (tag-gated) embedded-Postgres integration tests.
///
/// Run with:  `CODEX_MEM0_PG_TEST=1 swift test --filter Mem0PgStoreTests`
///
/// Every helper guarantees teardown (stop the postmaster + delete the temp
/// cluster) even on assertion failure, so the tests never leak postmasters or
/// disk — verified important after the first smoke run left a temp dir behind.
enum PGTestHarness {
    static var enabled: Bool { ProcessInfo.processInfo.environment["CODEX_MEM0_PG_TEST"] == "1" }

    /// Throwaway `PGPaths` under a unique temp dir.
    static func makePaths(database: String = "codexmem0test") throws -> PGPaths {
        guard let bin = PGPaths.discoverServerBinDir() else {
            throw XCTSkip("no postgres server binary found (install postgresql@NN)")
        }
        let tmp = NSTemporaryDirectory() + "codexmem0-test-" + UUID().uuidString.prefix(8)
        return PGPaths(serverBinDir: bin,
                       dataDir: tmp + "/pgdata",
                       socketDir: tmp + "/run",
                       port: 5432, username: "codex", database: database)
    }

    /// Open a fresh cluster + store, run `body`, then GUARANTEE teardown.
    static func withCluster(dims: Int = 8,
                            _ body: (Mem0PgVectorStore, PostgresLifecycle, PGPaths) async throws -> Void) async throws {
        try XCTSkipUnless(enabled, "set CODEX_MEM0_PG_TEST=1 to run")
        let paths = try makePaths()
        let lifecycle = PostgresLifecycle(paths: paths)
        let clusterRoot = (paths.dataDir as NSString).deletingLastPathComponent
        let store = try await Mem0PgVectorStore.open(paths: paths, dims: dims, lifecycle: lifecycle)
        do {
            try await body(store, lifecycle, paths)
        } catch {
            await store.shutdown()
            try? await lifecycle.stop()
            try? FileManager.default.removeItem(atPath: clusterRoot)
            throw error
        }
        await store.shutdown()
        try? await lifecycle.stop()
        try? FileManager.default.removeItem(atPath: clusterRoot)
    }

    /// Parity oracle: apply `ops` to BOTH a SQLite store and the PG store, then
    /// compare the id-sets returned by `query` against each. Returns (sqliteIDs,
    /// pgIDs) so the caller asserts equality.
    static func parityIDs(records: [VectorRecord],
                          query: (any Mem0VectorStore) async throws -> [SearchHit],
                          pg: Mem0PgVectorStore) async throws -> (sqlite: [String], pg: [String]) {
        let sqlite = try Mem0SQLiteStore(path: ":memory:")
        try await sqlite.insert(records)
        try await pg.reset()
        try await pg.insert(records)
        let s = try await query(sqlite).map(\.id)
        let p = try await query(pg).map(\.id)
        return (s, p)
    }

    /// Spin up a throwaway cluster (postmaster only — no Mem0 store), open a raw
    /// superuser PostgresNIO connection, run `body`, then GUARANTEE teardown.
    /// Use this for full-SQL / capability tests.
    static func withRawConnection(_ body: (PGRawConnection, PGPaths) async throws -> Void) async throws {
        try XCTSkipUnless(enabled, "set CODEX_MEM0_PG_TEST=1 to run")
        let paths = try makePaths()
        let lifecycle = PostgresLifecycle(paths: paths)
        let root = (paths.dataDir as NSString).deletingLastPathComponent
        try await lifecycle.ensureStarted()
        let raw = try await PGRawConnection.open(paths)
        let teardown: () async -> Void = {
            await raw.close()
            try? await lifecycle.stop()
            try? FileManager.default.removeItem(atPath: root)
        }
        do { try await body(raw, paths) } catch { await teardown(); throw error }
        await teardown()
    }

    // MARK: - raw psql access (for security/abuse tests)

    static func psqlPath(_ paths: PGPaths) -> String? {
        for c in [paths.serverBinDir + "/psql",
                  "/opt/homebrew/opt/libpq/bin/psql",
                  "/usr/local/opt/libpq/bin/psql",
                  "/usr/bin/psql"] where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    /// Run one SQL statement via `psql` as `user` against the cluster's socket.
    /// Returns (exitCode, stdout, stderr). Used to attempt privileged operations
    /// as the non-superuser data-plane role and assert they are denied.
    static func runSQL(_ paths: PGPaths, user: String, database: String? = nil,
                       host: String? = nil, sql: String) async throws -> (exit: Int32, out: String, err: String) {
        guard let psql = psqlPath(paths) else { throw XCTSkip("psql not found") }
        return try await runProc(psql, [
            "-h", host ?? paths.socketDir, "-p", "\(paths.port)",
            "-U", user, "-d", database ?? paths.database, "-v", "ON_ERROR_STOP=1", "-tAc", sql,
        ])
    }

    /// Strict-concurrency-clean async child-process runner (off the cooperative pool).
    static func runProc(_ launchPath: String, _ args: [String]) async throws -> (exit: Int32, out: String, err: String) {
        try await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            try p.run()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }.value
    }
}

/// Tiny test-vector helpers.
extension Array where Element == Float {
    /// A unit-ish vector with `1` at `i` (one-hot) of length `n`.
    static func oneHot(_ i: Int, _ n: Int) -> [Float] {
        var v = [Float](repeating: 0, count: n); if i < n { v[i] = 1 }; return v
    }
}
