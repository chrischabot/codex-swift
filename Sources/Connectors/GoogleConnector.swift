import Foundation

// The high-level Google connector: token storage + transparent refresh + revoke.
// This is the API the Workspace suite (#4) and Gmail channel (#5) call —
// `accessToken()` always returns a valid bearer, refreshing under the hood.

/// Where the connector persists its tokens.
public protocol TokenStore: Sendable {
    func load() async -> OAuthTokens?
    func save(_ tokens: OAuthTokens) async
    func clear() async
}

/// JSON-on-disk token store, written 0600 (a refresh token is a long-lived
/// secret). Under `$CODEX_HOME` in production. (A Keychain-backed store is the
/// hardened production option; the file store keeps the flow dependency-free and
/// testable.)
public actor FileTokenStore: TokenStore {
    private let path: String
    public init(path: String) { self.path = path }

    public func load() -> OAuthTokens? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public func save(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public func clear() { try? FileManager.default.removeItem(atPath: path) }
}

/// In-memory token store (tests / ephemeral sessions).
public actor MemoryTokenStore: TokenStore {
    private var tokens: OAuthTokens?
    public init(_ initial: OAuthTokens? = nil) { self.tokens = initial }
    public func load() -> OAuthTokens? { tokens }
    public func save(_ t: OAuthTokens) { tokens = t }
    public func clear() { tokens = nil }
}

public actor GoogleConnector {
    private let client: GoogleOAuthClient
    private let store: any TokenStore
    private let now: @Sendable () -> Int64

    public init(client: GoogleOAuthClient,
                store: any TokenStore,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.client = client
        self.store = store
        self.now = now
    }

    public func isAuthorized() async -> Bool { await store.load() != nil }

    /// Persist tokens obtained from a fresh authorization-code exchange.
    public func saveExchanged(_ tokens: OAuthTokens) async { await store.save(tokens) }

    /// A valid (non-expired) access token, refreshing transparently if needed.
    /// `.noRefreshToken` when not authorized or the refresh fails with no token.
    public func accessToken() async -> Result<String, OAuthError> {
        guard let tokens = await store.load() else { return .failure(.noRefreshToken) }
        if !tokens.isExpired(now: now()) { return .success(tokens.accessToken) }
        guard let refresh = tokens.refreshToken else { return .failure(.noRefreshToken) }
        switch await client.refresh(refreshToken: refresh) {
        case .success(let fresh):
            await store.save(fresh)
            return .success(fresh.accessToken)
        case .failure(let e):
            return .failure(e)
        }
    }

    /// Revoke the grant at Google (revoking the refresh token kills the whole
    /// grant) and clear local tokens. Returns whether the remote revoke
    /// succeeded; local tokens are cleared regardless.
    @discardableResult
    public func revokeAndClear() async -> Bool {
        guard let tokens = await store.load() else { return true }
        let toRevoke = tokens.refreshToken ?? tokens.accessToken
        let result = await client.revoke(token: toRevoke)
        await store.clear()
        if case .success = result { return true }
        return false
    }
}
