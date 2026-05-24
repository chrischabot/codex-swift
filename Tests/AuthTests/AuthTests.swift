import XCTest
import Foundation
@testable import Auth
@testable import Broker

private func atTmp() -> String {
    let p = NSTemporaryDirectory() + "auth-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

private actor MockExchanger: TokenExchanger {
    private(set) var exchanges = 0
    private(set) var refreshes = 0
    private let onExchange: @Sendable (String, String) -> Result<AuthTokens, AuthError>
    private let onRefresh: @Sendable (String) -> Result<AuthTokens, AuthError>
    private let refreshDelayMs: Int
    init(refreshDelayMs: Int = 0,
         exchange: @escaping @Sendable (String, String) -> Result<AuthTokens, AuthError>,
         refresh: @escaping @Sendable (String) -> Result<AuthTokens, AuthError>) {
        self.refreshDelayMs = refreshDelayMs
        self.onExchange = exchange
        self.onRefresh = refresh
    }
    func exchange(code: String, verifier: String,
                  cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
        exchanges += 1
        return onExchange(code, verifier)
    }
    func refresh(refreshToken: String,
                 cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
        refreshes += 1
        if refreshDelayMs > 0 {
            try? await Task.sleep(for: .milliseconds(refreshDelayMs))
        }
        return onRefresh(refreshToken)
    }
    func exchangeCount() -> Int { exchanges }
    func refreshCount() -> Int { refreshes }
}

final class AuthTests: XCTestCase {

    // MARK: SHA-256 known-answer vectors

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hexDigest(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hexDigest("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            SHA256.hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // A >1 block message (exercises multi-block + length padding).
        XCTAssertEqual(SHA256.hexDigest(String(repeating: "a", count: 1000)),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    // MARK: PKCE — RFC 7636 Appendix B

    func testPKCES256RFC7636Vector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPKCEGenerateIsDeterministicWithInjectedRNG() {
        let bytes: @Sendable (Int) -> [UInt8] = { n in (0..<n).map { UInt8($0 % 256) } }
        let a = PKCE.generate(rng: bytes)
        let b = PKCE.generate(rng: bytes)
        XCTAssertEqual(a, b, "same entropy → same pair")
        XCTAssertGreaterThanOrEqual(a.verifier.count, 43)
        XCTAssertLessThanOrEqual(a.verifier.count, 128)
        XCTAssertEqual(a.challenge,
                       Data(SHA256.hash(a.verifier)).base64URLEncodedString())
        XCTAssertFalse(a.verifier.contains("="))
        XCTAssertFalse(a.verifier.contains("+"))
        XCTAssertFalse(a.verifier.contains("/"))
    }

    // MARK: Authorize URL

    func testAuthorizeURLComposition() {
        let cfg = OAuthConfig(issuer: "https://auth.example.com",
                              clientId: "cid",
                              redirectURI: "http://localhost:1455/cb",
                              scopes: ["openid", "offline_access"])
        let url = AuthorizeURL.build(cfg, challenge: "CHAL", state: "STATE")
        XCTAssertTrue(url.hasPrefix("https://auth.example.com/oauth/authorize?"))
        XCTAssertTrue(url.contains("response_type=code"))
        XCTAssertTrue(url.contains("client_id=cid"))
        XCTAssertTrue(url.contains("code_challenge=CHAL"))
        XCTAssertTrue(url.contains("code_challenge_method=S256"))
        XCTAssertTrue(url.contains("state=STATE"))
        XCTAssertTrue(url.contains("scope=openid%20offline_access"))
        XCTAssertTrue(url.contains("redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcb"))
    }

    // MARK: FileTokenStore

    func testFileTokenStoreRoundTripAnd0600() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        XCTAssertNil(store.load())
        let t = AuthTokens(accessToken: "ax", refreshToken: "rx",
                           idToken: "ix", expiresAtUnix: 12_345, accountId: "acct_1")
        try store.save(t)
        XCTAssertEqual(store.load(), t)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "credentials at rest are owner-only")
        try store.clear()
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    #if os(macOS)
    func testKeychainTokenStoreRoundTripAndClear() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = KeychainTokenStore(
            service: "ai.igent.codexkit.tests.\(UUID().uuidString)",
            account: "acct-\(UUID().uuidString)",
            codexHome: home)
        defer { try? store.clear() }
        XCTAssertNil(store.load())

        let first = AuthTokens(accessToken: "ak", refreshToken: "rk",
                               idToken: "ik", expiresAtUnix: 12_345,
                               accountId: "acct_keychain")
        try store.save(first)
        XCTAssertEqual(store.load(), first)

        let second = AuthTokens(accessToken: "ak2", refreshToken: nil,
                                expiresAtUnix: 67_890,
                                accountId: "acct_keychain_2")
        try store.save(second)
        XCTAssertEqual(store.load(), second,
                       "saving again updates the existing Keychain item")

        try store.clear()
        XCTAssertNil(store.load())
    }

    func testMigratingTokenStoreMovesLegacyFileTokenIntoKeychain() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let legacy = FileTokenStore(codexHome: home)
        let keychain = KeychainTokenStore(
            service: "ai.igent.codexkit.tests.\(UUID().uuidString)",
            account: "acct-\(UUID().uuidString)",
            codexHome: home)
        defer { try? keychain.clear() }

        let original = AuthTokens(accessToken: "legacy-ak",
                                  refreshToken: "legacy-rk",
                                  idToken: "legacy-ik",
                                  expiresAtUnix: 12_345,
                                  accountId: "acct_legacy")
        try legacy.save(original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))

        let migrating = MigratingTokenStore(primary: keychain, legacy: legacy)

        XCTAssertEqual(migrating.load(), original)
        XCTAssertEqual(keychain.load(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "legacy auth.json is removed after successful Keychain migration")
    }

    func testProductionTokenStoreMigratesFileFallbackUnlessExplicitlyOverridden() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let legacy = FileTokenStore(codexHome: home)
        let service = "ai.igent.codexkit.tests.\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let keychain = KeychainTokenStore(service: service,
                                          account: account,
                                          codexHome: home)
        defer { try? keychain.clear() }
        let tokens = AuthTokens(accessToken: "factory-ak",
                                refreshToken: "factory-rk",
                                expiresAtUnix: 67_890,
                                accountId: "acct_factory")
        try legacy.save(tokens)

        let production = TokenStoreFactory.production(
            codexHome: home,
            environment: [:],
            keychainService: service,
            keychainAccount: account)
        XCTAssertEqual(production.load(), tokens)
        XCTAssertEqual(keychain.load(), tokens)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        let fallbackHome = atTmp()
        defer { try? FileManager.default.removeItem(atPath: fallbackHome) }
        let fallback = TokenStoreFactory.production(
            codexHome: fallbackHome,
            environment: ["CODEXKIT_AUTH_STORE": "file"],
            keychainService: service,
            keychainAccount: "unused-\(UUID().uuidString)")
        try fallback.save(tokens)
        XCTAssertNotNil(FileTokenStore(codexHome: fallbackHome).load(),
                        "explicit file override remains available for tests/dev")
    }
    #endif

    // MARK: AuthManager login lifecycle

    private func tokens(_ access: String, refresh: String? = "r0",
                        exp: Int64) -> AuthTokens {
        AuthTokens(accessToken: access, refreshToken: refresh,
                   expiresAtUnix: exp, accountId: "acct_x")
    }

    func testLoginFinishSuccessPersistsAndAccount() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        let ex = MockExchanger(
            exchange: { code, _ in .success(AuthTokens(
                accessToken: "AT-\(code)", refreshToken: "RT",
                expiresAtUnix: 9_999_999_999, accountId: "acct_42")) },
            refresh: { _ in .failure(.server("unused")) })
        let mgr = AuthManager(store: store, exchanger: ex,
                              refreshBroker: AuthRefreshBroker(),
                              now: { 1000 })
        let start = await mgr.loginStart(rng: { n in (0..<n).map { UInt8($0 % 256) } })
        XCTAssertTrue(start.authorizeURL.contains("code_challenge_method=S256"))
        let pre = await mgr.account()
        XCTAssertFalse(pre.authenticated)
        let r = await mgr.loginFinish(code: "abc", state: start.state)
        guard case .success(let info) = r else { return XCTFail("login failed: \(r)") }
        XCTAssertEqual(info.accountId, "acct_42")
        XCTAssertTrue(info.authenticated)
        let post = await mgr.account()
        XCTAssertTrue(post.authenticated)
        XCTAssertEqual(post.accountId, "acct_42")
        XCTAssertEqual(store.load()?.accessToken, "AT-abc")
        let ec = await ex.exchangeCount()
        XCTAssertEqual(ec, 1)
    }

    func testLoginFinishStateMismatchAndNoPending() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let ex = MockExchanger(
            exchange: { _, _ in .success(AuthTokens(accessToken: "x",
                expiresAtUnix: 1)) },
            refresh: { _ in .failure(.server("x")) })
        let mgr = AuthManager(store: FileTokenStore(codexHome: home), exchanger: ex)
        let noPending = await mgr.loginFinish(code: "c", state: "s")
        XCTAssertEqual(noPending, .failure(.notAuthenticated))
        let start = await mgr.loginStart()
        let bad = await mgr.loginFinish(code: "c", state: start.state + "x")
        XCTAssertEqual(bad, .failure(.invalidState))
        let ec = await ex.exchangeCount()
        XCTAssertEqual(ec, 0, "no token exchange on a rejected state")
    }

    func testLogoutClears() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(tokens("a", exp: 9_999_999_999))
        let mgr = AuthManager(store: store)
        let acct = await mgr.account()
        XCTAssertTrue(acct.authenticated)
        try await mgr.logout()
        let after = await mgr.account()
        XCTAssertFalse(after.authenticated)
        XCTAssertNil(store.load())
    }

    func testValidAccessTokenRefreshesWhenExpiring() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(tokens("OLD", refresh: "RT0", exp: 1000))   // already expiring
        let ex = MockExchanger(
            exchange: { _, _ in .failure(.server("unused")) },
            refresh: { rt in .success(AuthTokens(
                accessToken: "NEW-\(rt)", refreshToken: "RT1",
                expiresAtUnix: 9_999_999_999, accountId: "acct_x")) })
        let mgr = AuthManager(store: store, exchanger: ex,
                              refreshBroker: AuthRefreshBroker(),
                              now: { 2000 })   // now > expiry → refresh
        let tok = await mgr.validAccessToken()
        XCTAssertEqual(tok, "NEW-RT0")
        XCTAssertEqual(store.load()?.accessToken, "NEW-RT0")
        XCTAssertEqual(store.load()?.refreshToken, "RT1")
        let rc = await ex.refreshCount()
        XCTAssertEqual(rc, 1)
    }

    func testValidAccessTokenNotExpiringSkipsRefresh() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(tokens("FRESH", exp: 9_999_999_999))
        let ex = MockExchanger(
            exchange: { _, _ in .failure(.server("x")) },
            refresh: { _ in .failure(.server("should not refresh")) })
        let mgr = AuthManager(store: store, exchanger: ex, now: { 1000 })
        let tok = await mgr.validAccessToken()
        XCTAssertEqual(tok, "FRESH")
        let rc = await ex.refreshCount()
        XCTAssertEqual(rc, 0)
    }

    func testRefreshAccessTokenForcesRefreshEvenWhenCachedTokenIsFresh() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(tokens("REJECTED_BUT_FRESH", refresh: "RT0", exp: 9_999_999_999))
        let ex = MockExchanger(
            exchange: { _, _ in .failure(.server("x")) },
            refresh: { rt in .success(AuthTokens(
                accessToken: "FORCED-\(rt)", refreshToken: "RT1",
                expiresAtUnix: 9_999_999_999, accountId: "acct_x")) })
        let mgr = AuthManager(store: store, exchanger: ex, now: { 1000 })

        let tok = await mgr.refreshAccessToken()

        XCTAssertEqual(tok, "FORCED-RT0")
        XCTAssertEqual(store.load()?.accessToken, "FORCED-RT0")
        let rc = await ex.refreshCount()
        XCTAssertEqual(rc, 1)
    }

    func testRefreshAccessTokenUsesExternalTokenRefreshForClientManagedChatGPTTokens() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        let mgr = AuthManager(
            store: store,
            externalTokenRefresh: { previousAccountId in
                XCTAssertEqual(previousAccountId, "acct_old")
                return AuthTokens(accessToken: "CLIENT-REFRESHED",
                                  refreshToken: nil,
                                  tokenType: "BearerExternal",
                                  expiresAtUnix: 9_999_999_999,
                                  accountId: "acct_new")
            },
            now: { 1000 })
        try await mgr.loginWithExternalChatGPTTokens(accessToken: "REJECTED",
                                                     accountId: "acct_old")

        let tok = await mgr.refreshAccessToken()

        XCTAssertEqual(tok, "CLIENT-REFRESHED")
        XCTAssertEqual(store.load()?.accessToken, "CLIENT-REFRESHED")
        XCTAssertEqual(store.load()?.accountId, "acct_new")
        XCTAssertEqual(store.load()?.tokenType, "BearerExternal")
    }

    func testRefreshAccessTokenDoesNotReturnOldTokenOnFailure() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(tokens("REJECTED", refresh: "RT0", exp: 9_999_999_999))
        let ex = MockExchanger(
            exchange: { _, _ in .failure(.server("x")) },
            refresh: { _ in .failure(.server("refresh failed")) })
        let mgr = AuthManager(store: store, exchanger: ex, now: { 1000 })

        let tok = await mgr.refreshAccessToken()

        XCTAssertNil(tok, "401 recovery must not retry with the known-rejected token")
        XCTAssertEqual(store.load()?.accessToken, "REJECTED")
    }

    func testConcurrentRefreshSingleFlight() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(tokens("OLD", refresh: "RT0", exp: 1000))
        let ex = MockExchanger(
            refreshDelayMs: 60,
            exchange: { _, _ in .failure(.server("x")) },
            refresh: { _ in .success(AuthTokens(
                accessToken: "NEW", refreshToken: "RT1",
                expiresAtUnix: 9_999_999_999, accountId: "acct_x")) })
        let broker = AuthRefreshBroker()
        let mgr = AuthManager(store: store, exchanger: ex,
                              refreshBroker: broker, now: { 2000 })
        async let a = mgr.validAccessToken()
        async let b = mgr.validAccessToken()
        async let c = mgr.validAccessToken()
        let results = await [a, b, c]
        XCTAssertEqual(results, ["NEW", "NEW", "NEW"])
        let rc = await ex.refreshCount()
        XCTAssertEqual(rc, 1, "concurrent refreshes collapse via the broker")
    }

    func testAuthErrorDescriptions() {
        XCTAssertEqual("\(AuthError.invalidState)",
                       "auth: state mismatch (possible CSRF)")
        XCTAssertEqual("\(AuthError.notAuthenticated)", "auth: not authenticated")
        XCTAssertTrue("\(AuthError.transport("x"))".contains("transport"))
    }
}
