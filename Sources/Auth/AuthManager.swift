import Foundation
import Broker

public struct LoginStart: Sendable, Equatable {
    public let authorizeURL: String
    public let state: String
}

public struct AccountInfo: Sendable, Equatable {
    public let accountId: String?
    public let authenticated: Bool
    public let expiresAtUnix: Int64?
}

/// Owns the OAuth PKCE login lifecycle and the refreshing token accessor.
/// All network egress goes through the injected `TokenExchanger`; concurrent
/// refreshes collapse via `AuthRefreshBroker` (single-flight). Portable and
/// deterministically testable with a mock exchanger.
public actor AuthManager {
    public typealias ExternalTokenRefresh = @Sendable (_ previousAccountId: String?) async -> AuthTokens?

    private let cfg: OAuthConfig
    private let store: any TokenStore
    private let exchanger: any TokenExchanger
    private let deviceCodeClient: any DeviceCodeClient
    private let refreshBroker: AuthRefreshBroker
    private let nowProvider: @Sendable () -> Int64
    private let externalTokenRefresh: ExternalTokenRefresh?

    private var pending: (pkce: PKCE, state: String, redirectURI: String)?
    private var refreshFailures = Set<String>()

    public init(config: OAuthConfig = OAuthConfig(),
                store: any TokenStore,
                exchanger: any TokenExchanger = CurlTokenExchanger(),
                deviceCodeClient: any DeviceCodeClient = CurlDeviceCodeClient(),
                refreshBroker: AuthRefreshBroker = AuthRefreshBroker(),
                externalTokenRefresh: ExternalTokenRefresh? = nil,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970)
                }) {
        self.cfg = config
        self.store = store
        self.exchanger = exchanger
        self.deviceCodeClient = deviceCodeClient
        self.refreshBroker = refreshBroker
        self.externalTokenRefresh = externalTokenRefresh
        self.nowProvider = now
    }

    /// Begin a login: returns the authorize URL + opaque state, stashing the
    /// PKCE verifier for the matching `loginFinish`.
    public func loginStart(
        rng: @Sendable (Int) -> [UInt8] = PKCE.secureRandomBytes,
        redirectURI: String? = nil) -> LoginStart {
        let pkce = PKCE.generate(rng: rng)
        let state = Data(rng(24)).base64URLEncodedString()
        let redirectURI = redirectURI ?? cfg.redirectURI
        pending = (pkce, state, redirectURI)
        let loginConfig = OAuthConfig(issuer: cfg.issuer,
                                      clientId: cfg.clientId,
                                      redirectURI: redirectURI,
                                      scopes: cfg.scopes)
        return LoginStart(
            authorizeURL: AuthorizeURL.build(loginConfig, challenge: pkce.challenge,
                                             state: state),
            state: state)
    }

    public func loginCancel() { pending = nil }

    public func deviceCodeStart() async -> Result<DeviceCodeChallenge, AuthError> {
        pending = nil
        return await deviceCodeClient.request(config: cfg)
    }

    public func deviceCodeComplete(_ challenge: DeviceCodeChallenge)
    async -> Result<AccountInfo, AuthError> {
        switch await deviceCodeClient.complete(config: cfg, challenge: challenge) {
        case .success(let t):
            do { try store.save(t) } catch {
                return .failure(.transport("persist: \(error)"))
            }
            return .success(AccountInfo(accountId: t.accountId,
                                        authenticated: true,
                                        expiresAtUnix: t.expiresAtUnix))
        case .failure(let e):
            return .failure(e)
        }
    }

    public func loginWithAPIKey(_ apiKey: String) throws {
        pending = nil
        refreshFailures.removeAll()
        try store.save(AuthTokens(accessToken: apiKey,
                                  refreshToken: nil,
                                  tokenType: "APIKey",
                                  expiresAtUnix: 4_102_444_800,
                                  accountId: nil))
    }

    public func loginWithExternalChatGPTTokens(accessToken: String,
                                               accountId: String) throws {
        pending = nil
        refreshFailures.removeAll()
        try store.save(AuthTokens(accessToken: accessToken,
                                  refreshToken: nil,
                                  tokenType: "BearerExternal",
                                  expiresAtUnix: 4_102_444_800,
                                  accountId: accountId))
    }

    /// Complete a login by exchanging the redirect `code`. `state` must match
    /// the value from `loginStart` (CSRF defense).
    public func loginFinish(code: String, state: String)
    async -> Result<AccountInfo, AuthError> {
        guard let p = pending else { return .failure(.notAuthenticated) }
        guard p.state == state else { return .failure(.invalidState) }
        let loginConfig = OAuthConfig(issuer: cfg.issuer,
                                      clientId: cfg.clientId,
                                      redirectURI: p.redirectURI,
                                      scopes: cfg.scopes)
        switch await exchanger.exchange(code: code, verifier: p.pkce.verifier,
                                        cfg: loginConfig) {
        case .success(let t):
            do { try store.save(t) } catch {
                return .failure(.transport("persist: \(error)"))
            }
            refreshFailures.removeAll()
            pending = nil
            return .success(AccountInfo(accountId: t.accountId,
                                        authenticated: true,
                                        expiresAtUnix: t.expiresAtUnix))
        case .failure(let e):
            return .failure(e)
        }
    }

    public func logout() throws {
        pending = nil
        refreshFailures.removeAll()
        try store.clear()
    }

    public func account() -> AccountInfo {
        guard let t = store.load() else {
            return AccountInfo(accountId: nil, authenticated: false,
                               expiresAtUnix: nil)
        }
        return AccountInfo(accountId: t.accountId,
                           authenticated: true,
                           expiresAtUnix: t.expiresAtUnix)
    }

    public func storedTokens() -> AuthTokens? { store.load() }

    public func hasRefreshFailure(for tokens: AuthTokens) -> Bool {
        refreshFailures.contains(refreshFailureKey(tokens))
    }

    public func isAuthenticated() -> Bool { store.load() != nil }

    /// A currently-valid access token, refreshing through the single-flight
    /// broker when expiring. Returns nil when not authenticated / unrefreshable.
    public func validAccessToken() async -> String? {
        guard let t = store.load() else { return nil }
        if !t.isExpiring(now: nowProvider()) { return t.accessToken }
        return await refreshAccessTokenFrom(t, fallbackToStored: true)
    }

    /// Force-refresh the access token after an upstream 401. Unlike
    /// `validAccessToken`, this does not return the old cached token when the
    /// refresh fails; retrying a known-rejected bearer would mask the real
    /// authentication failure.
    public func refreshAccessToken() async -> String? {
        guard let t = store.load() else { return nil }
        return await refreshAccessTokenFrom(t, fallbackToStored: false)
    }

    private func refreshAccessTokenFrom(_ t: AuthTokens,
                                        fallbackToStored: Bool) async -> String? {
        guard let rt = t.refreshToken else {
            guard t.tokenType == "BearerExternal",
                  let externalTokenRefresh else {
                return nil
            }
            guard let refreshed = await externalTokenRefresh(t.accountId) else {
                return nil
            }
            try? store.save(refreshed)
            return refreshed.accessToken
        }
        let cfg = self.cfg
        let exchanger = self.exchanger
        let store = self.store
        let account = t.accountId ?? "default"
        let refreshed = try? await refreshBroker.token(account: account) {
            switch await exchanger.refresh(refreshToken: rt, cfg: cfg) {
            case .success(let nt):
                try? store.save(nt)
                return nt.accessToken
            case .failure(let e):
                throw e
            }
        }
        if let refreshed {
            refreshFailures.remove(refreshFailureKey(t))
            return refreshed
        }
        if !fallbackToStored {
            refreshFailures.insert(refreshFailureKey(t))
        }
        return fallbackToStored ? store.load()?.accessToken : nil
    }

    private func refreshFailureKey(_ tokens: AuthTokens) -> String {
        "\(tokens.accountId ?? "default")|\(tokens.refreshToken ?? "")"
    }
}
