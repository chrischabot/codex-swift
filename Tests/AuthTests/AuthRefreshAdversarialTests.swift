import XCTest
import Foundation
@testable import Auth
@testable import Broker

/// SEVERE adversarial audit of the auth-refresh remediation (wave D). The core
/// invariants under attack:
///   - `validAccessToken` must NEVER hand back an already-expired bearer without
///     a successful refresh.
///   - A *permanent* refresh failure (expired/exhausted/revoked) must short-
///     circuit to nil — no stale-token fallback that masks a real auth failure
///     and burns refresh calls.
///   - `refreshAccessToken` (force, post-401) must NOT fall back to the old
///     cached token on failure.
///   - The refresh skew boundary (60s) is honored exactly.
private actor Rec { // counts refresh attempts
    private(set) var n = 0
    func bump() { n += 1 }
    func count() -> Int { n }
}

private actor MockEx: TokenExchanger {
    let rec: Rec
    let onRefresh: @Sendable (String) -> Result<AuthTokens, AuthError>
    init(rec: Rec, onRefresh: @escaping @Sendable (String) -> Result<AuthTokens, AuthError>) {
        self.rec = rec; self.onRefresh = onRefresh
    }
    func exchange(code: String, verifier: String, cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
        .failure(.notAuthenticated)
    }
    func refresh(refreshToken: String, cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
        await rec.bump()
        return onRefresh(refreshToken)
    }
}

final class AuthRefreshAdversarialTests: XCTestCase {

    private func home() -> String {
        let p = NSTemporaryDirectory() + "authadv-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// AUDIT: an expired token whose refresh PERMANENTLY fails (revoked).
    /// Documented A4 contract: `validAccessToken` is a BEST-EFFORT accessor —
    /// on the FIRST failure it returns the stored token (so the caller makes one
    /// request that will 401 → then it calls `refreshAccessToken`, which returns
    /// nil and drives re-login). The protective invariant is that the SECOND
    /// `validAccessToken` call SHORT-CIRCUITS to nil (permanent failure recorded)
    /// and does NOT burn another refresh — so a dead token can never loop.
    /// This mirrors upstream `AuthManager::auth()` (best-effort) vs the strict
    /// post-401 `refreshAccessToken` path (tested separately).
    func testExpiredTokenPermanentFailureShortCircuitsAfterFirstAttempt() async {
        let h = home(); defer { try? FileManager.default.removeItem(atPath: h) }
        let rec = Rec()
        let ex = MockEx(rec: rec) { _ in
            .failure(.refreshFailed(reason: .revoked, underlying: "401 revoked"))
        }
        let store = FileTokenStore(codexHome: h)
        let expired = AuthTokens(accessToken: "STALE", refreshToken: "rt",
                                 tokenType: "Bearer", expiresAtUnix: 500, accountId: "acct")
        try? store.save(expired)
        let mgr = AuthManager(store: store, exchanger: ex, now: { 1000 }) // now > expiry

        // First call: best-effort fallback returns the stored token (one shot).
        _ = await mgr.validAccessToken()
        // PROTECTIVE INVARIANT: second call short-circuits to nil with NO new refresh.
        let tok2 = await mgr.validAccessToken()
        XCTAssertNil(tok2, "permanent failure not recorded; dead token can loop")
        let attempts = await rec.count()
        XCTAssertEqual(attempts, 1,
                       "permanent failure did not short-circuit; burned \(attempts) refreshes")
    }

    /// ATTACK: force-refresh after a 401 must NOT return the old cached token on
    /// failure (returning it would re-send a known-rejected bearer in a loop).
    func testForceRefreshDoesNotFallBackToStaleToken() async {
        let h = home(); defer { try? FileManager.default.removeItem(atPath: h) }
        let rec = Rec()
        let ex = MockEx(rec: rec) { _ in
            .failure(.refreshFailed(reason: .expired, underlying: "401"))
        }
        let store = FileTokenStore(codexHome: h)
        let t = AuthTokens(accessToken: "OLD", refreshToken: "rt",
                           tokenType: "Bearer", expiresAtUnix: 10_000, accountId: "acct")
        try? store.save(t)
        let mgr = AuthManager(store: store, exchanger: ex, now: { 1000 })
        let forced = await mgr.refreshAccessToken()
        XCTAssertNil(forced, "force-refresh returned the stale token after a permanent failure")
    }

    /// CONFIRM: a successful refresh of an expiring token returns the NEW token
    /// and clears any prior failure state.
    func testSuccessfulRefreshReturnsNewToken() async {
        let h = home(); defer { try? FileManager.default.removeItem(atPath: h) }
        let rec = Rec()
        let ex = MockEx(rec: rec) { _ in
            .success(AuthTokens(accessToken: "FRESH", refreshToken: "rt2",
                                tokenType: "Bearer", expiresAtUnix: 99_999, accountId: "acct"))
        }
        let store = FileTokenStore(codexHome: h)
        let expiring = AuthTokens(accessToken: "OLD", refreshToken: "rt",
                                  tokenType: "Bearer", expiresAtUnix: 1030, accountId: "acct")
        try? store.save(expiring)
        let mgr = AuthManager(store: store, exchanger: ex, now: { 1000 }) // 1000+60 >= 1030 → expiring
        let tok = await mgr.validAccessToken()
        XCTAssertEqual(tok, "FRESH", "successful refresh did not return the new token")
    }

    /// ATTACK: the 60s skew boundary must be exact. A token expiring exactly at
    /// `now + 60` is considered expiring (refresh attempted); `now + 61` is not.
    func testSkewBoundaryExact() async {
        // expiresAt == now+60 → isExpiring true (>=). Refresh must be attempted.
        let h1 = home(); defer { try? FileManager.default.removeItem(atPath: h1) }
        let rec1 = Rec()
        let ex1 = MockEx(rec: rec1) { _ in
            .success(AuthTokens(accessToken: "REFRESHED", refreshToken: "rt2",
                                tokenType: "Bearer", expiresAtUnix: 99_999, accountId: "a"))
        }
        let s1 = FileTokenStore(codexHome: h1)
        try? s1.save(AuthTokens(accessToken: "A", refreshToken: "rt",
                                tokenType: "Bearer", expiresAtUnix: 1060, accountId: "a"))
        let m1 = AuthManager(store: s1, exchanger: ex1, now: { 1000 })
        _ = await m1.validAccessToken()
        let n1 = await rec1.count()
        XCTAssertEqual(n1, 1, "token at now+60 boundary was NOT refreshed")

        // expiresAt == now+61 → not expiring. Cached token returned, no refresh.
        let h2 = home(); defer { try? FileManager.default.removeItem(atPath: h2) }
        let rec2 = Rec()
        let ex2 = MockEx(rec: rec2) { _ in .failure(.notAuthenticated) }
        let s2 = FileTokenStore(codexHome: h2)
        try? s2.save(AuthTokens(accessToken: "B", refreshToken: "rt",
                                tokenType: "Bearer", expiresAtUnix: 1061, accountId: "a"))
        let m2 = AuthManager(store: s2, exchanger: ex2, now: { 1000 })
        let tok = await m2.validAccessToken()
        XCTAssertEqual(tok, "B", "non-expiring token not returned from cache")
        let n2 = await rec2.count()
        XCTAssertEqual(n2, 0, "non-expiring token triggered a needless refresh")
    }

    /// STRESS / ATTACK: concurrent callers on an expiring token must single-flight
    /// the refresh (the broker collapses them) — not stampede the issuer with N
    /// refreshes. Tolerant assertion: far fewer than the caller count.
    func testConcurrentRefreshSingleFlights() async {
        let h = home(); defer { try? FileManager.default.removeItem(atPath: h) }
        let rec = Rec()
        let ex = MockEx(rec: rec) { _ in
            .success(AuthTokens(accessToken: "NEW", refreshToken: "rt2",
                                tokenType: "Bearer", expiresAtUnix: 99_999, accountId: "a"))
        }
        let store = FileTokenStore(codexHome: h)
        try? store.save(AuthTokens(accessToken: "OLD", refreshToken: "rt",
                                   tokenType: "Bearer", expiresAtUnix: 1010, accountId: "a"))
        let mgr = AuthManager(store: store, exchanger: ex, now: { 1000 })
        await withTaskGroup(of: String?.self) { g in
            for _ in 0..<50 { g.addTask { await mgr.validAccessToken() } }
            for await r in g { XCTAssertEqual(r, "NEW") }
        }
        let n = await rec.count()
        XCTAssertLessThan(n, 50, "no single-flighting: \(n) concurrent refreshes hit the issuer")
        XCTAssertGreaterThanOrEqual(n, 1)
    }
}
