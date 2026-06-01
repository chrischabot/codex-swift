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

    // MARK: - Revoke endpoint resolution (revoke.rs:150-169)

    func testRevokeEndpointPrefersExplicitRevokeOverride() {
        setenv("CODEX_REVOKE_TOKEN_URL_OVERRIDE", "https://x.test/custom/revoke", 1)
        setenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE", "https://y.test/oauth/token?a=1", 1)
        defer {
            unsetenv("CODEX_REVOKE_TOKEN_URL_OVERRIDE")
            unsetenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE")
        }
        let cfg = OAuthConfig(issuer: "https://auth.example.com")
        XCTAssertEqual(CurlTokenRevoker.revokeEndpoint(cfg: cfg),
                       "https://x.test/custom/revoke")
    }

    func testRevokeEndpointDerivesFromRefreshOverrideWhenOnlyRefreshSet() {
        unsetenv("CODEX_REVOKE_TOKEN_URL_OVERRIDE")
        setenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE",
               "https://idp.local:8443/oauth/token?foo=bar", 1)
        defer { unsetenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE") }
        let cfg = OAuthConfig(issuer: "https://auth.example.com")
        // derive_revoke_token_endpoint: set_path("/oauth/revoke"), set_query(None)
        XCTAssertEqual(CurlTokenRevoker.revokeEndpoint(cfg: cfg),
                       "https://idp.local:8443/oauth/revoke")
    }

    func testRevokeEndpointFallsBackToIssuerWhenNoOverrides() {
        unsetenv("CODEX_REVOKE_TOKEN_URL_OVERRIDE")
        unsetenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE")
        let cfg = OAuthConfig(issuer: "https://auth.example.com/")
        XCTAssertEqual(CurlTokenRevoker.revokeEndpoint(cfg: cfg),
                       "https://auth.example.com/oauth/revoke")
    }

    func testDeriveRevokeEndpointRejectsNonURL() {
        XCTAssertNil(CurlTokenRevoker.deriveRevokeEndpoint(fromRefresh: "not a url"))
        XCTAssertNil(CurlTokenRevoker.deriveRevokeEndpoint(fromRefresh: "/relative/path"))
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

    /// Upstream default is File mode (config/src/types.rs:89): the production
    /// store must write/read `auth.json` and must NOT migrate to (or touch) the
    /// Keychain. This preserves credential interop with the official codex CLI
    /// on a shared CODEX_HOME.
    func testProductionTokenStoreDefaultsToFileMode() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let service = "ai.igent.codexkit.tests.\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let keychain = KeychainTokenStore(service: service, account: account, codexHome: home)
        defer { try? keychain.clear() }
        let tokens = AuthTokens(accessToken: "file-ak",
                                refreshToken: "file-rk",
                                expiresAtUnix: 67_890,
                                accountId: "acct_file")

        let production = TokenStoreFactory.production(
            codexHome: home,
            environment: [:],
            keychainService: service,
            keychainAccount: account)
        try production.save(tokens)
        XCTAssertEqual(FileTokenStore(codexHome: home).load(), tokens,
                       "default File mode writes auth.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/auth.json"))
        XCTAssertNil(keychain.load(),
                     "default File mode never writes the Keychain")
    }

    /// Keyring mode uses the Keychain only (and never auth.json).
    func testProductionTokenStoreKeyringMode() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let service = "ai.igent.codexkit.tests.\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let keychain = KeychainTokenStore(service: service, account: account, codexHome: home)
        defer { try? keychain.clear() }
        let tokens = AuthTokens(accessToken: "kr-ak", refreshToken: "kr-rk",
                                expiresAtUnix: 1, accountId: "acct_kr")

        let production = TokenStoreFactory.production(
            codexHome: home, mode: .keyring, environment: [:],
            keychainService: service, keychainAccount: account)
        try production.save(tokens)
        XCTAssertEqual(keychain.load(), tokens)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/auth.json"),
                       "Keyring mode does not write auth.json")
    }

    /// Auto mode reads keyring-then-file but a successful keyring write does NOT
    /// delete auth.json (mirrors upstream AutoAuthStorage, storage.rs:277-291).
    func testProductionTokenStoreAutoModeDoesNotDeleteFileOnKeyringSuccess() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let service = "ai.igent.codexkit.tests.\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let keychain = KeychainTokenStore(service: service, account: account, codexHome: home)
        defer { try? keychain.clear() }
        let file = FileTokenStore(codexHome: home)
        let fileTokens = AuthTokens(accessToken: "file-old", expiresAtUnix: 1,
                                    accountId: "acct_old")
        try file.save(fileTokens)

        let newTokens = AuthTokens(accessToken: "kr-new", expiresAtUnix: 2,
                                   accountId: "acct_new")
        let production = TokenStoreFactory.production(
            codexHome: home, mode: .auto, environment: [:],
            keychainService: service, keychainAccount: account)
        try production.save(newTokens)
        XCTAssertEqual(keychain.load(), newTokens, "Auto prefers the keyring")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "Auto must NOT delete auth.json after a keyring success")
        XCTAssertEqual(production.load(), newTokens,
                       "Auto reads the keyring first")
    }

    /// Ephemeral mode keeps credentials in memory only — nothing on disk.
    func testProductionTokenStoreEphemeralMode() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let tokens = AuthTokens(accessToken: "eph", expiresAtUnix: 1, accountId: "acct_eph")
        let production = TokenStoreFactory.production(
            codexHome: home, mode: .ephemeral, environment: [:])
        try production.save(tokens)
        XCTAssertEqual(production.load(), tokens)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/auth.json"),
                       "Ephemeral mode never touches disk")
    }

    /// `CODEXKIT_AUTH_STORE=file` forces the file store regardless of mode.
    func testProductionTokenStoreFileEnvOverride() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = TokenStoreFactory.production(
            codexHome: home, mode: .keyring,
            environment: ["CODEXKIT_AUTH_STORE": "file"])
        XCTAssertTrue(store is FileTokenStore)
    }

    /// `AuthCredentialsStoreMode.parse` mirrors serde lowercase spellings with a
    /// File default for unknown/absent values (core/src/config/mod.rs:3308).
    func testAuthCredentialsStoreModeParse() {
        XCTAssertEqual(AuthCredentialsStoreMode.parse(nil), .file)
        XCTAssertEqual(AuthCredentialsStoreMode.parse("file"), .file)
        XCTAssertEqual(AuthCredentialsStoreMode.parse("Keyring"), .keyring)
        XCTAssertEqual(AuthCredentialsStoreMode.parse("AUTO"), .auto)
        XCTAssertEqual(AuthCredentialsStoreMode.parse("ephemeral"), .ephemeral)
        XCTAssertEqual(AuthCredentialsStoreMode.parse("bogus"), .file)
        XCTAssertEqual(AuthCredentialsStoreMode.default, .file)
    }

    /// Keychain interop with the official CLI keyring
    /// (storage.rs:160-174): service "Codex Auth", and a per-codex_home key
    /// `cli|<first16 hex of sha256(canonical codex_home)>`.
    func testKeychainStoreKeyMatchesUpstreamComputeStoreKey() {
        // Stable, deterministic key prefix + length for a fixed path.
        let key = KeychainTokenStore.storeKey(codexHome: "/tmp/fixed-home")
        XCTAssertTrue(key.hasPrefix("cli|"), "key uses upstream cli| prefix")
        let hex = String(key.dropFirst(4))
        XCTAssertEqual(hex.count, 16, "truncated to first 16 hex chars")
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) },
                      "lowercase hex digest")
        // Independent recomputation of the upstream algorithm over the
        // symlink-resolved path.
        let canonical = URL(fileURLWithPath: "/tmp/fixed-home")
            .resolvingSymlinksInPath().path
        let expected = "cli|" + String(SHA256.hexDigest(canonical).prefix(16))
        XCTAssertEqual(key, expected)
        // Distinct codex_home paths yield distinct keys.
        XCTAssertNotEqual(KeychainTokenStore.storeKey(codexHome: "/tmp/a"),
                          KeychainTokenStore.storeKey(codexHome: "/tmp/b"))
        // Default service matches upstream KEYRING_SERVICE.
        XCTAssertEqual(KeychainTokenStore.defaultService, "Codex Auth")
    }

    /// The keychain payload is the serialized AuthDotJson (upstream
    /// `serde_json::to_string(auth)`), so an entry written by the real CLI is
    /// readable here: a CLI-style AuthDotJson JSON projects into the runtime
    /// AuthTokens.
    func testKeychainPayloadInteropProjectsAuthDotJson() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = KeychainTokenStore(
            service: "ai.igent.codexkit.tests.\(UUID().uuidString)",
            codexHome: home)
        defer { try? store.clear() }
        let tokens = AuthTokens(accessToken: "ak", refreshToken: "rk",
                                idToken: "ik", expiresAtUnix: 12_345,
                                accountId: "acct_interop")
        try store.save(tokens)
        // Round-trips through the AuthDotJson serialization the CLI shares.
        XCTAssertEqual(store.load(), tokens)
        // And the on-keychain payload IS an AuthDotJson the CLI could read.
        let dot = tokens.toAuthDotJson()
        XCTAssertEqual(dot.tokens?.accessToken, "ak")
        XCTAssertEqual(dot.tokens?.refreshToken, "rk")
        XCTAssertEqual(dot.tokens?.idToken, "ik")
        XCTAssertEqual(dot.tokens?.accountId, "acct_interop")
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

    // MARK: - A1: loginFinish mints OPENAI_API_KEY from id_token

    func testLoginFinishMintsAPIKeyFromIdTokenWhenExchangerWired() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        let ex = MockExchanger(
            exchange: { _, _ in .success(AuthTokens(
                accessToken: "AT", refreshToken: "RT",
                idToken: "header.payload.sig",
                expiresAtUnix: 9_999_999_999,
                accountId: "acct_42")) },
            refresh: { _ in .failure(.server("unused")) })
        let key = MockAPIKeyExchanger(result: .success("sk-minted-from-id-token"))
        let mgr = AuthManager(store: store, exchanger: ex,
                              apiKeyExchanger: key, now: { 1000 })
        let start = await mgr.loginStart(rng: { n in (0..<n).map { UInt8($0 % 256) } })
        let r = await mgr.loginFinish(code: "abc", state: start.state)
        guard case .success = r else { return XCTFail("login failed: \(r)") }
        let count = await key.count
        XCTAssertEqual(count, 1,
                       "loginFinish must invoke exchangeForAPIKey when id_token present")
        let lastID = await key.lastIDToken
        XCTAssertEqual(lastID, "header.payload.sig")
    }

    func testLoginFinishSkipsAPIKeyExchangeWhenNoIdToken() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let ex = MockExchanger(
            exchange: { _, _ in .success(AuthTokens(
                accessToken: "AT", refreshToken: "RT", idToken: nil,
                expiresAtUnix: 9_999_999_999, accountId: "acct_42")) },
            refresh: { _ in .failure(.server("unused")) })
        let key = MockAPIKeyExchanger(result: .success("sk-should-not-fire"))
        let mgr = AuthManager(store: FileTokenStore(codexHome: home),
                              exchanger: ex, apiKeyExchanger: key)
        let start = await mgr.loginStart()
        _ = await mgr.loginFinish(code: "abc", state: start.state)
        let count = await key.count
        XCTAssertEqual(count, 0,
                       "no id_token → no token-exchange call")
    }

    func testLoginFinishTreatsAPIKeyExchangeFailureAsNonFatal() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        let ex = MockExchanger(
            exchange: { _, _ in .success(AuthTokens(
                accessToken: "AT", refreshToken: "RT", idToken: "id.tok.en",
                expiresAtUnix: 9_999_999_999, accountId: "acct_42")) },
            refresh: { _ in .failure(.server("unused")) })
        let key = MockAPIKeyExchanger(result: .failure(.server("plan tier lacks API access")))
        let mgr = AuthManager(store: store, exchanger: ex, apiKeyExchanger: key)
        let start = await mgr.loginStart()
        let r = await mgr.loginFinish(code: "abc", state: start.state)
        guard case .success(let info) = r else {
            return XCTFail("ChatGPT login must still succeed when API-key mint fails: \(r)")
        }
        XCTAssertTrue(info.authenticated)
        XCTAssertEqual(store.load()?.accessToken, "AT",
                       "ChatGPT bearer is still persisted")
    }

    // MARK: - A2: revoke on logout / re-login

    func testLogoutRevokesPreviousRefreshTokenWhenWired() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(AuthTokens(accessToken: "ax", refreshToken: "rx",
                                  expiresAtUnix: 9_999_999_999,
                                  accountId: "acct"))
        let rev = MockRevoker()
        let mgr = AuthManager(store: store, revoker: rev)
        try await mgr.logout()
        let calls = await rev.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.token, "rx")
        XCTAssertEqual(calls.first?.hint, .refreshToken)
        XCTAssertNil(store.load(), "local clear still happens after revoke")
    }

    func testLogoutWithNoRevokerWiredIsSilent() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(AuthTokens(accessToken: "ax", refreshToken: "rx",
                                  expiresAtUnix: 9_999_999_999,
                                  accountId: "acct"))
        let mgr = AuthManager(store: store, revoker: nil)
        try await mgr.logout()
        XCTAssertNil(store.load())
    }

    func testReloginRevokesSupersededCredential() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(AuthTokens(accessToken: "OLD", refreshToken: "OLD-RT",
                                  expiresAtUnix: 9_999_999_999,
                                  accountId: "acct"))
        let rev = MockRevoker()
        let mgr = AuthManager(store: store, revoker: rev)
        try await mgr.loginWithAPIKey("sk-replacement")
        let calls = await rev.calls
        XCTAssertEqual(calls.count, 1, "old refresh token revoked")
        XCTAssertEqual(calls.first?.token, "OLD-RT")
        XCTAssertEqual(store.load()?.accessToken, "sk-replacement")
    }

    func testRevocationFailureDoesNotBreakLogout() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(AuthTokens(accessToken: "a", refreshToken: "r",
                                  expiresAtUnix: 9_999_999_999, accountId: "x"))
        let rev = MockRevoker(throwing: AuthError.transport("network down"))
        let mgr = AuthManager(store: store, revoker: rev)
        try await mgr.logout()  // must not throw
        XCTAssertNil(store.load(),
                     "logout proceeds with local clear even if revoke fails")
    }

    // MARK: - A3 / A4: refresh failure classification + always-mark

    func testValidAccessTokenRecordsClassifiedReasonOn401() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        let stored = AuthTokens(accessToken: "OLD", refreshToken: "RT0",
                                expiresAtUnix: 1000, accountId: "acct_x")
        try store.save(stored)
        let ex = MockExchanger(
            exchange: { _, _ in .failure(.server("unused")) },
            refresh: { _ in .failure(.refreshFailed(
                reason: .expired,
                underlying: #"{"error":{"code":"refresh_token_expired"}}"#)) })
        let mgr = AuthManager(store: store, exchanger: ex, now: { 2000 })
        let tok = await mgr.validAccessToken()
        XCTAssertEqual(tok, "OLD",
                       "validAccessToken falls back to stored on transient/permanent failure")
        let reason = await mgr.refreshFailureReason(for: stored)
        XCTAssertEqual(reason, .expired,
                       "permanent failure reason is recorded for supervisor surface")
        let marked = await mgr.hasRefreshFailure(for: stored)
        XCTAssertTrue(marked,
                      "validAccessToken must mark refresh failures so a follow-up call short-circuits")
    }

    func testSecondValidAccessTokenCallShortCircuitsAfterPermanentFailure() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(AuthTokens(accessToken: "OLD", refreshToken: "RT0",
                                  expiresAtUnix: 1000, accountId: "acct_x"))
        let ex = MockExchanger(
            exchange: { _, _ in .failure(.server("unused")) },
            refresh: { _ in .failure(.refreshFailed(
                reason: .exhausted, underlying: "{}")) })
        let mgr = AuthManager(store: store, exchanger: ex, now: { 2000 })
        _ = await mgr.validAccessToken()
        _ = await mgr.validAccessToken()
        let rc = await ex.refreshCount()
        // The single-flight broker collapses concurrent calls, but
        // sequential calls past a recorded refresh failure should NOT
        // burn additional refresh attempts.
        XCTAssertEqual(rc, 1,
                       "known-rejected refresh tokens must not be retried")
    }

    func testTransientFailureDoesNotPoisonReasonButMarksOnForceRefresh() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        let stored = AuthTokens(accessToken: "OLD", refreshToken: "RT0",
                                expiresAtUnix: 9_999_999_999,
                                accountId: "acct_x")
        try store.save(stored)
        let ex = MockExchanger(
            exchange: { _, _ in .failure(.server("unused")) },
            refresh: { _ in .failure(.transport("DNS error")) })
        let mgr = AuthManager(store: store, exchanger: ex, now: { 1000 })
        _ = await mgr.refreshAccessToken()
        let reason = await mgr.refreshFailureReason(for: stored)
        XCTAssertNil(reason, "transient failure must NOT be classified")
        let marked = await mgr.hasRefreshFailure(for: stored)
        XCTAssertTrue(marked,
                      "force-refresh marks the failure so the caller stops retrying")
    }

    // MARK: - A5: env-overlay shadowing

    func testLoginWithAPIKeyThrowsShadowedByEnvWhenOverlayActive() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        // CODEX_API_KEY only shadows when enableCodexApiKeyEnv is set (the
        // app-server passes false). Pass true here to exercise the overlay.
        let mgr = AuthManager(store: store,
                              env: ["CODEX_API_KEY": "env-key"],
                              enableCodexApiKeyEnv: true)
        do {
            try await mgr.loginWithAPIKey("sk-user")
            XCTFail("expected LoginShadowedByEnvError")
        } catch let e as LoginShadowedByEnvError {
            XCTAssertEqual(e.operation, .loginWithAPIKey)
            XCTAssertEqual(e.shadowingVar, "CODEX_API_KEY")
        }
        XCTAssertEqual(store.load()?.accessToken, "sk-user",
                       "persistent store still updated; shadow is a warning, not a refusal")
        let visible = await mgr.storedTokens()?.accessToken
        XCTAssertEqual(visible, "env-key",
                       "but the running process keeps reading the env overlay")
    }

    func testLogoutThrowsShadowedByEnvWhenOverlayActive() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(AuthTokens(accessToken: "ax", expiresAtUnix: 9_999_999_999,
                                  accountId: "acct"))
        // OPENAI_API_KEY is NOT an auth-overlay source upstream; only
        // CODEX_ACCESS_TOKEN (agent identity) shadows logout here.
        let mgr = AuthManager(store: store,
                              env: ["CODEX_ACCESS_TOKEN": "env-bearer"])
        do {
            try await mgr.logout()
            XCTFail("expected LoginShadowedByEnvError")
        } catch let e as LoginShadowedByEnvError {
            XCTAssertEqual(e.operation, .logout)
            XCTAssertEqual(e.shadowingVar, "CODEX_ACCESS_TOKEN")
        }
        XCTAssertNil(store.load(), "local clear still completed before the throw")
    }

    func testNoShadowingErrorWhenEnvUnset() async throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let mgr = AuthManager(store: FileTokenStore(codexHome: home),
                              env: [:])
        // Must not throw.
        try await mgr.loginWithAPIKey("sk")
        try await mgr.logout()
    }

    // MARK: - AuthSupport spot checks

    func testEnvAuthCodexAPIKeyGatedWinsWhenEnabled() {
        // With the gate enabled, CODEX_API_KEY beats CODEX_ACCESS_TOKEN and
        // OPENAI_API_KEY is never consulted (mirrors load_auth, manager.rs:731).
        let a = EnvAuth.loadFromEnv(env: [
            "CODEX_API_KEY": "codex",
            "OPENAI_API_KEY": "openai",
            "CODEX_ACCESS_TOKEN": "bearer",
        ], enableCodexApiKeyEnv: true)
        XCTAssertEqual(a?.openaiAPIKey, "codex")
        XCTAssertNil(a?.tokens, "API key path doesn't populate tokens section")
    }

    func testEnvAuthCodexAPIKeyIgnoredWhenGateDisabled() {
        // Default gate (false, matching the app-server): CODEX_API_KEY is NOT
        // an overlay source, so the CODEX_ACCESS_TOKEN agent identity wins.
        let a = EnvAuth.loadFromEnv(env: [
            "CODEX_API_KEY": "codex",
            "CODEX_ACCESS_TOKEN": "bearer",
        ])
        XCTAssertNil(a?.openaiAPIKey)
        XCTAssertEqual(a?.tokens?.accessToken, "bearer")
    }

    func testEnvAuthOpenAIKeyIsNeverAnOverlaySource() {
        // OPENAI_API_KEY is read only by the model client at request time;
        // it must never produce an auth overlay (manager.rs:469).
        XCTAssertNil(EnvAuth.loadFromEnv(env: ["OPENAI_API_KEY": "openai"]))
        XCTAssertNil(EnvAuth.loadFromEnv(env: ["OPENAI_API_KEY": "openai"],
                                         enableCodexApiKeyEnv: true))
    }

    func testEnvAuthCodexAccessTokenPopulatesTokensSection() {
        let a = EnvAuth.loadFromEnv(env: ["CODEX_ACCESS_TOKEN": "bearer"])
        XCTAssertNil(a?.openaiAPIKey)
        XCTAssertEqual(a?.tokens?.accessToken, "bearer")
    }

    func testEnvAuthEmptyStringIsTreatedAsUnset() {
        let a = EnvAuth.loadFromEnv(env: ["CODEX_API_KEY": ""],
                                    enableCodexApiKeyEnv: true)
        XCTAssertNil(a, "empty env values must not produce an overlay")
    }

    // MARK: - Finding #2: ephemeral external ChatGPT beats CODEX_ACCESS_TOKEN

    func testEphemeralExternalChatGPTTokensBeatCodexAccessTokenEnv() async {
        // Upstream load_auth checks the ephemeral store BEFORE reading
        // CODEX_ACCESS_TOKEN (manager.rs:742-768). With both present, the
        // external ChatGPT token must win.
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let ephemeral = EphemeralTokenStore(
            AuthTokens(accessToken: "external-chatgpt",
                       tokenType: "BearerExternal",
                       expiresAtUnix: AuthTokens.neverExpires,
                       accountId: "acct_ext"))
        let mgr = AuthManager(store: FileTokenStore(codexHome: home),
                              ephemeralStore: ephemeral,
                              env: ["CODEX_ACCESS_TOKEN": "agent-bearer"])
        let visible = await mgr.storedTokens()
        XCTAssertEqual(visible?.accessToken, "external-chatgpt",
                       "ephemeral external ChatGPT tokens take precedence over CODEX_ACCESS_TOKEN")
        XCTAssertEqual(visible?.accountId, "acct_ext")
    }

    func testCodexAccessTokenEnvUsedWhenNoEphemeral() async {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let mgr = AuthManager(store: FileTokenStore(codexHome: home),
                              env: ["CODEX_ACCESS_TOKEN": "agent-bearer"])
        let visible = await mgr.storedTokens()
        XCTAssertEqual(visible?.accessToken, "agent-bearer")
    }

    func testCodexAPIKeyGatedBeatsEphemeralWhenEnabled() async {
        // Step 1 of precedence: gated CODEX_API_KEY beats even the ephemeral
        // store (manager.rs:737-740 returns before the ephemeral check).
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let ephemeral = EphemeralTokenStore(
            AuthTokens(accessToken: "external-chatgpt",
                       tokenType: "BearerExternal",
                       expiresAtUnix: AuthTokens.neverExpires))
        let mgr = AuthManager(store: FileTokenStore(codexHome: home),
                              ephemeralStore: ephemeral,
                              env: ["CODEX_API_KEY": "codex-key"],
                              enableCodexApiKeyEnv: true)
        let visible = await mgr.storedTokens()
        XCTAssertEqual(visible?.accessToken, "codex-key")
    }

    func testCodexAPIKeyOverlayInertWhenGateDisabled() async {
        // With the default gate (false), CODEX_API_KEY does not shadow the
        // persisted login; OPENAI_API_KEY likewise has no effect.
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try? store.save(AuthTokens(accessToken: "persisted-bearer",
                                   refreshToken: "rt",
                                   idToken: "id",
                                   expiresAtUnix: 9_999_999_999,
                                   accountId: "acct"))
        let mgr = AuthManager(store: store,
                              env: ["CODEX_API_KEY": "codex-key",
                                    "OPENAI_API_KEY": "openai-key"])
        let visible = await mgr.storedTokens()
        XCTAssertEqual(visible?.accessToken, "persisted-bearer",
                       "ungated CODEX_API_KEY / OPENAI_API_KEY must not shadow a real login")
    }

    // MARK: - Finding #4: refresh endpoint honors override

    func testRefreshTokenEndpointHonorsOverride() {
        let cfg = OAuthConfig(issuer: "https://auth.openai.com")
        setenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE",
               "https://staging.example.com/oauth/token", 1)
        defer { unsetenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE") }
        XCTAssertEqual(CurlTokenExchanger.refreshTokenEndpoint(cfg: cfg),
                       "https://staging.example.com/oauth/token")
    }

    func testRefreshTokenEndpointFallsBackToIssuerWhenNoOverride() {
        unsetenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE")
        let cfg = OAuthConfig(issuer: "https://auth.openai.com")
        XCTAssertEqual(CurlTokenExchanger.refreshTokenEndpoint(cfg: cfg),
                       "https://auth.openai.com/oauth/token")
    }

    func testRefreshTokenEndpointIgnoresEmptyOverride() {
        setenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE", "", 1)
        defer { unsetenv("CODEX_REFRESH_TOKEN_URL_OVERRIDE") }
        let cfg = OAuthConfig(issuer: "https://issuer.test")
        XCTAssertEqual(CurlTokenExchanger.refreshTokenEndpoint(cfg: cfg),
                       "https://issuer.test/oauth/token")
    }

    func testAuthDotJsonRoundTripsViaAuthTokensProjection() throws {
        let original = AuthTokens(accessToken: "AT", refreshToken: "RT",
                                  idToken: "ID", tokenType: "Bearer",
                                  expiresAtUnix: AuthTokens.neverExpires,
                                  accountId: "acct_x")
        let dotJson = original.toAuthDotJson()
        let back = AuthTokens.fromAuthDotJson(dotJson)
        XCTAssertEqual(back?.accessToken, "AT")
        XCTAssertEqual(back?.refreshToken, "RT")
        XCTAssertEqual(back?.idToken, "ID")
        XCTAssertEqual(back?.accountId, "acct_x")
    }

    func testAuthDotJsonDecodeAcceptsUpstreamSnakeCase() throws {
        let payload = #"""
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "AT",
            "refresh_token": "RT",
            "id_token": "IDT",
            "account_id": "acct_42"
          },
          "last_refresh": "2026-01-01T00:00:00Z"
        }
        """#
        let a = try AuthDotJson.decode(Data(payload.utf8))
        XCTAssertEqual(a.tokens?.accessToken, "AT")
        XCTAssertEqual(a.tokens?.refreshToken, "RT")
        XCTAssertEqual(a.tokens?.idToken, "IDT")
        XCTAssertEqual(a.tokens?.accountId, "acct_42")
        XCTAssertEqual(a.lastRefresh, "2026-01-01T00:00:00Z")
    }

    /// The on-disk auth.json must be interoperable with the real codex CLI:
    /// canonical `OPENAI_API_KEY` / `tokens.{access_token,refresh_token,
    /// id_token,account_id}` keys present. And when a file written by UPSTREAM
    /// (no Swift `expires_at`) carries a JWT id_token, expiry is derived from
    /// its `exp` claim (matching upstream token_data.rs).
    func testFileTokenStoreWritesInteroperableSchemaAndDerivesJWTExp() throws {
        let home = atTmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = FileTokenStore(codexHome: home)
        try store.save(AuthTokens(accessToken: "AT", refreshToken: "RT",
                                  idToken: "ix", expiresAtUnix: 12_345,
                                  accountId: "acct_1"))
        let raw = try String(contentsOfFile: store.path, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"access_token\""), "canonical snake_case tokens key")
        XCTAssertTrue(raw.contains("\"id_token\""))
        XCTAssertTrue(raw.contains("\"account_id\""))
        XCTAssertFalse(raw.contains("\"accessToken\""), "must not emit the legacy flat camelCase shape")

        // Upstream-written file: canonical tokens with a real JWT id_token
        // (exp=4000000000), NO Swift expires_at. Expiry must come from the JWT.
        let exp: Int64 = 4_000_000_000
        let payloadB64 = Data("{\"exp\":\(exp)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "h.\(payloadB64).s"
        let upstreamFile = #"{"OPENAI_API_KEY":null,"tokens":{"access_token":"AT","id_token":"\#(jwt)"}}"#
        try upstreamFile.write(toFile: store.path, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load()?.expiresAtUnix, exp,
                       "Bearer expiry is derived from the id_token JWT exp claim")
    }

    func testAuthFileLockReadsExistingFileAndReturnsNilForMissing() throws {
        let dir = atTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/auth.json"
        let payload = #"{"OPENAI_API_KEY":"sk"}"#
        try payload.write(toFile: path, atomically: true, encoding: .utf8)
        let data = AuthFileLock.readContentsLocked(path: path)
        XCTAssertEqual(data, Data(payload.utf8))
        XCTAssertNil(AuthFileLock.readContentsLocked(path: dir + "/missing.json"))
    }
}

// MARK: - Test doubles for severe-testing coverage

private actor MockAPIKeyExchanger: APIKeyExchanger {
    private(set) var count = 0
    private(set) var lastIDToken: String?
    private let result: Result<String, AuthError>
    init(result: Result<String, AuthError>) { self.result = result }
    func exchangeForAPIKey(idToken: String, cfg: OAuthConfig) async throws -> String {
        count += 1
        lastIDToken = idToken
        switch result {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

private actor MockRevoker: TokenRevoker {
    struct Call: Sendable, Equatable {
        let token: String
        let hint: TokenTypeHint
    }
    private(set) var calls: [Call] = []
    private let throwing: AuthError?
    init(throwing: AuthError? = nil) { self.throwing = throwing }
    func revoke(token: String, tokenTypeHint: TokenTypeHint,
                cfg: OAuthConfig) async throws {
        calls.append(Call(token: token, hint: tokenTypeHint))
        if let throwing { throw throwing }
    }
}
