import XCTest
import Mem0Core
@testable import Mem0Store

/// Severe coverage for store-level tenant-scope enforcement (gbrain.md Wave 0.6):
/// a scope-less read must fail CLOSED (return nothing), never leak cross-tenant
/// records. Defense-in-depth — the engine already requires a scope, but a future
/// filter-construction bug must not silently expose another user's memories.
final class Mem0TenantScopeTests: XCTestCase {
    private func rec(_ id: String, _ vector: [Float], _ user: String) -> VectorRecord {
        var p: JSONObject = [:]
        p["data"] = .string("memory \(id)")
        p["user_id"] = .string(user)
        p["created_at"] = .string("2026-01-01T00:00:00Z")
        return VectorRecord(id: id, vector: vector, payload: p)
    }

    // MARK: - pure scope detection

    func testHasTenantScope() {
        XCTAssertTrue(Mem0SQLiteStore.hasTenantScope(["user_id": .string("u1")]))
        XCTAssertTrue(Mem0SQLiteStore.hasTenantScope(["agent_id": .string("a1")]))
        XCTAssertTrue(Mem0SQLiteStore.hasTenantScope(["run_id": .string("r1")]))
        XCTAssertFalse(Mem0SQLiteStore.hasTenantScope([:]), "empty filter is unscoped")
        XCTAssertFalse(Mem0SQLiteStore.hasTenantScope(["category": .string("x")]), "non-scope key is unscoped")
        XCTAssertFalse(Mem0SQLiteStore.hasTenantScope(["user_id": .null]), "null scope value is unscoped")
    }

    func testHasTenantScopeOrBranches() {
        // Every $or branch scoped → scoped.
        XCTAssertTrue(Mem0SQLiteStore.hasTenantScope(["$or": .array([
            .object(["user_id": .string("u1")]), .object(["agent_id": .string("a1")]),
        ])]))
        // A bare $or branch leaks if any branch is unscoped → unscoped.
        XCTAssertFalse(Mem0SQLiteStore.hasTenantScope(["$or": .array([
            .object(["user_id": .string("u1")]), .object(["category": .string("x")]),
        ])]))
    }

    // MARK: - the leak, closed

    func testEmptyFilterFailsClosed() async throws {
        let store = try Mem0SQLiteStore(path: ":memory:")
        try await store.insert([rec("a", [1, 0], "alice"), rec("b", [0, 1], "bob")])
        // The cross-tenant leak: an empty (scope-dropped) filter previously matched
        // EVERY record. Now it returns nothing.
        let leaked = try await store.search("", [1, 0], topK: 10, filters: [:])
        XCTAssertEqual(leaked.count, 0, "scope-less search must NOT return cross-tenant records")
        let listed = try await store.list([:], limit: nil)
        XCTAssertEqual(listed.count, 0, "scope-less list must NOT return cross-tenant records")
    }

    func testScopedFilterStillWorks() async throws {
        let store = try Mem0SQLiteStore(path: ":memory:")
        try await store.insert([rec("a", [1, 0], "alice"), rec("b", [1, 0], "bob")])
        let hits = try await store.search("", [1, 0], topK: 10, filters: ["user_id": .string("alice")])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, "a", "alice sees only her own record")
    }

    func testUnscopedOptOutRestoresGlobalRead() async throws {
        let store = try Mem0SQLiteStore(path: ":memory:")
        await store.setEnforceTenantScope(false)   // admin/global mode
        try await store.insert([rec("a", [1, 0], "alice"), rec("b", [0, 1], "bob")])
        let all = try await store.list([:], limit: nil)
        XCTAssertEqual(all.count, 2, "opt-out (admin) restores the global read")
    }
}
