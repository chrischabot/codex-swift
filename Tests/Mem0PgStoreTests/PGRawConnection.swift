import Foundation
import Logging
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import PostgresNIO
import EmbeddedPG
import XCTest

/// `XCTAssertEqual(expected, actual)` for SQL tests. PLAIN (non-autoclosure)
/// params so call sites can write `try await XCTAssertEqualAsync(42, db.int(sql))`
/// — the `try await` covers the async arg; the helper itself is synchronous
/// (XCTest's own autoclosure can't host `await`).
func XCTAssertEqualAsync<T: Equatable & Sendable>(
    _ expected: T?, _ actual: T?,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, message, file: file, line: line)
}

/// A raw PostgresNIO connection to a spawned test cluster — for exercising the
/// FULL SQL surface (DDL / DML / queries / types / transactions) beyond the Mem0
/// store API. Connects as the bootstrap superuser by default so tests can do
/// anything; pass a non-superuser role to test privilege boundaries.
///
/// Note: PostgresNIO uses the EXTENDED query protocol — one statement per
/// `query`. Multi-statement setup runs one `exec` per statement (or psql via
/// `PGTestHarness.runSQL`). A dollar-quoted `CREATE FUNCTION` body is a single
/// statement and works directly.
// @unchecked Sendable: the two-connection isolation tests run one connection per
// concurrent task (never the same connection from two tasks at once), so passing a
// PGRawConnection across an `async let` is race-free in practice.
final class PGRawConnection: @unchecked Sendable {
    let conn: PostgresConnection
    let logger = Logger(label: "pg.raw.test")
    private static let idCounter = NIOLockedValueBox<Int>(1000)

    private init(_ conn: PostgresConnection) { self.conn = conn }

    static func open(_ paths: PGPaths, database: String? = nil, username: String? = nil) async throws -> PGRawConnection {
        let cfg = PostgresConnection.Configuration(
            unixSocketPath: paths.unixSocketPath,
            username: username ?? paths.username, password: nil,
            database: database ?? paths.database)
        let id = Self.idCounter.withLockedValue { v -> Int in v += 1; return v }
        let conn = try await PostgresConnection.connect(
            on: MultiThreadedEventLoopGroup.singleton.any(),
            configuration: cfg, id: id, logger: Logger(label: "pg.raw.test")).get()
        return PGRawConnection(conn)
    }

    func close() async { try? await conn.close() }

    /// Run one statement, ignoring any result rows.
    func exec(_ sql: String) async throws { _ = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: logger) }

    /// Run a sequence of statements (each is a separate extended-protocol query).
    func execAll(_ statements: [String]) async throws { for s in statements { try await exec(s) } }

    func query(_ sql: String) async throws -> PostgresRowSequence {
        try await conn.query(PostgresQuery(unsafeSQL: sql), logger: logger)
    }
    func query(_ q: PostgresQuery) async throws -> PostgresRowSequence {
        try await conn.query(q, logger: logger)
    }

    /// First column of the first row decoded as `T` (nil if no rows).
    func scalar<T: PostgresDecodable & Sendable>(_ sql: String, as: T.Type = T.self) async throws -> T? {
        for try await v in (try await query(sql)).decode(T.self) { return v }
        return nil
    }
    func int(_ sql: String) async throws -> Int? { try await scalar(sql, as: Int.self) }
    func string(_ sql: String) async throws -> String? { try await scalar(sql, as: String.self) }
    func double(_ sql: String) async throws -> Double? { try await scalar(sql, as: Double.self) }
    func bool(_ sql: String) async throws -> Bool? { try await scalar(sql, as: Bool.self) }

    /// All rows' first (text) column joined by newline — handy for EXPLAIN plans.
    func text(_ sql: String) async throws -> String {
        var out: [String] = []
        for try await s in (try await query(sql)).decode(String.self) { out.append(s) }
        return out.joined(separator: "\n")
    }

    /// Number of rows a query returns.
    func rowCount(_ sql: String) async throws -> Int {
        var n = 0
        for try await _ in try await query(sql) { n += 1 }
        return n
    }

    /// Run SQL; return its SQLSTATE if it errors, or "" if it SUCCEEDS — without
    /// asserting either way (for cases where success is a valid outcome, e.g. the
    /// non-victim of a deadlock).
    func sqlstateOf(_ sql: String) async -> String {
        do { try await exec(sql); return "" }
        catch let e as PSQLError { return e.serverInfo?[.sqlState] ?? "?" }
        catch { return "?" }
    }

    /// Run SQL expecting it to FAIL; returns the SQLSTATE (e.g. "23505") or "" if
    /// the error carried none. Fails the test if the SQL unexpectedly succeeds.
    @discardableResult
    func expectError(_ sql: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async -> String {
        do {
            try await exec(sql)
            XCTFail("expected SQL to fail\(message.isEmpty ? "" : " (\(message))"): \(sql)", file: file, line: line)
            return ""
        } catch let e as PSQLError {
            return e.serverInfo?[.sqlState] ?? ""
        } catch {
            return ""
        }
    }
}
