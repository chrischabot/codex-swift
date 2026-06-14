import XCTest
@testable import Mem0Core

/// Pure-logic tests for the store-backend selector (Phase 0). These need no
/// Postgres runtime, so they run in normal CI (unlike the tag-gated
/// Mem0PgStoreTests integration suite).
final class Mem0StoreBackendResolutionTests: XCTestCase {

    func testParseDefaultsToSqliteVec() {
        XCTAssertEqual(Mem0StoreBackendRequest.parse(nil), .sqliteVec)
        XCTAssertEqual(Mem0StoreBackendRequest.parse(""), .sqliteVec)
        XCTAssertEqual(Mem0StoreBackendRequest.parse("   "), .sqliteVec)
        XCTAssertEqual(Mem0StoreBackendRequest.parse("garbage"), .sqliteVec)
    }

    func testParseAliases() {
        for s in ["postgres", "postgresql", "pg", "pgvector", "PostGres", " PG "] {
            XCTAssertEqual(Mem0StoreBackendRequest.parse(s), .postgres, "‘\(s)’ → postgres")
        }
        for s in ["sqlite", "sqlite-vec", "sqlitevec", "vec", "default"] {
            XCTAssertEqual(Mem0StoreBackendRequest.parse(s), .sqliteVec, "‘\(s)’ → sqliteVec")
        }
        XCTAssertEqual(Mem0StoreBackendRequest.parse("container"), .postgresContainer)
        XCTAssertEqual(Mem0StoreBackendRequest.parse("auto"), .auto)
    }

    func testResolveFallsBackWhenUnavailable() {
        // postgres requested but unavailable → sqlite-vec
        XCTAssertEqual(Mem0StoreBackendResolver.resolve(.postgres, postgresAvailable: false), .sqliteVec)
        XCTAssertEqual(Mem0StoreBackendResolver.resolve(.postgres, postgresAvailable: true), .postgres)
        // container requested but unavailable → sqlite-vec
        XCTAssertEqual(Mem0StoreBackendResolver.resolve(.postgresContainer, postgresAvailable: true,
                                                        containerAvailable: false), .sqliteVec)
        // auto and sqliteVec always resolve to the safe default
        XCTAssertEqual(Mem0StoreBackendResolver.resolve(.auto, postgresAvailable: true), .sqliteVec)
        XCTAssertEqual(Mem0StoreBackendResolver.resolve(.sqliteVec, postgresAvailable: true), .sqliteVec)
    }

    func testDidFallBackFlag() {
        XCTAssertTrue(Mem0StoreBackendResolver.didFallBack(.postgres, .sqliteVec))
        XCTAssertFalse(Mem0StoreBackendResolver.didFallBack(.postgres, .postgres))
        XCTAssertFalse(Mem0StoreBackendResolver.didFallBack(.sqliteVec, .sqliteVec))
        XCTAssertFalse(Mem0StoreBackendResolver.didFallBack(.auto, .sqliteVec))
    }
}
