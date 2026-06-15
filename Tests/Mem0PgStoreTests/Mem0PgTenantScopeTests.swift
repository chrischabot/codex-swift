import XCTest
import Mem0Core
@testable import Mem0PgStore

/// Audit fix: the Postgres store failed OPEN on a scope-less filter (no WHERE → all
/// tenants), unlike the SQLite store's fail-CLOSED guard. These pin the ported
/// hasTenantScope detector (pure — no live postgres needed); the search/list/keywordSearch
/// integration is exercised under CODEX_MEM0_PG_TEST.
final class Mem0PgTenantScopeTests: XCTestCase {
    private typealias S = Mem0PgVectorStore

    func testDirectScopeKeysAreRecognized() {
        XCTAssertTrue(S.hasTenantScope(["user_id": .string("u1")]))
        XCTAssertTrue(S.hasTenantScope(["agent_id": .string("a1")]))
        XCTAssertTrue(S.hasTenantScope(["run_id": .string("r1")]))
    }

    func testScopelessFilterFailsTheGuard() {
        XCTAssertFalse(S.hasTenantScope([:]), "empty filter is scope-less → fail closed")
        XCTAssertFalse(S.hasTenantScope(["category": .string("x")]), "a non-scope key is not a scope")
        XCTAssertFalse(S.hasTenantScope(["user_id": .null]), "a null scope value does NOT scope")
    }

    func testOrBranchesMustAllBeScoped() {
        let allScoped: JSONObject = ["$or": .array([
            .object(["user_id": .string("u1")]), .object(["user_id": .string("u2")])])]
        XCTAssertTrue(S.hasTenantScope(allScoped), "every branch scoped → the $or is scoped")
        let oneUnscoped: JSONObject = ["$or": .array([
            .object(["user_id": .string("u1")]), .object(["category": .string("x")])])]
        XCTAssertFalse(S.hasTenantScope(oneUnscoped), "a single unscoped branch leaks → whole $or denied")
        XCTAssertFalse(S.hasTenantScope(["$or": .array([])]), "an empty $or is not a scope")
    }
}
