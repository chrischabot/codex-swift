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
    /// Optional ephemeral (in-memory, host-app-scoped) store. When set,
    /// `loginWithExternalChatGPTTokens` writes here instead of `store`
    /// so host-app-injected ChatGPT tokens never touch disk or the
    /// keychain. All other login modes continue to route through `store`.
    private let ephemeralStore: EphemeralTokenStore?
    private let exchanger: any TokenExchanger
    private let deviceCodeClient: any DeviceCodeClient
    private let refreshBroker: AuthRefreshBroker
    private let nowProvider: @Sendable () -> Int64
    private let externalTokenRefresh: ExternalTokenRefresh?
    /// OAuth 2.0 Token Exchange client used to mint an OpenAI API key from
    /// the id_token after a successful ChatGPT login (B1). Optional so
    /// tests / offline harnesses can disable the post-login exchange.
    private let apiKeyExchanger: (any APIKeyExchanger)?
    /// Revocation client used on logout / re-login. Best-effort; never
    /// blocks the surrounding operation. Optional so tests can disable.
    private let revoker: (any TokenRevoker)?

    private var pending: (pkce: PKCE, state: String, redirectURI: String)?
    private var refreshFailures = Set<String>()
    /// Most-recent classified refresh failure, keyed by `refreshFailureKey`.
    /// Mirrors upstream's `refresh_failure_for_auth` lookup
    /// (manager.rs:1398) so the supervisor can surface a re-login prompt
    /// without re-attempting the refresh.
    private var refreshFailureReasons: [String: RefreshTokenFailedReason] = [:]
    /// OpenAI API key minted from the ChatGPT id_token via OAuth 2.0 token
    /// exchange (B1). Held in memory so the same login can serve both
    /// API-key and ChatGPT-managed code paths. Mirrors the
    /// `OPENAI_API_KEY` field in upstream's auth.json.
    private var mintedAPIKey: String?
    /// D1: env-precedence overlay snapshotted at construction. Holds only the
    /// gated `CODEX_API_KEY` (when `enableCodexApiKeyEnv`) credential — the
    /// `CODEX_ACCESS_TOKEN` agent identity is applied separately, AFTER the
    /// ephemeral store, to mirror upstream `load_auth` ordering (manager.rs:
    /// 731-768). `OPENAI_API_KEY` is not an auth-overlay source.
    private let envOverlay: AuthDotJson?
    /// Snapshot of the env vars used to detect overlay shadow on writes and to
    /// resolve the `CODEX_ACCESS_TOKEN` agent identity after the ephemeral
    /// store. Held separately from `envOverlay` so we can report the specific
    /// shadowing var to callers.
    private let envSnapshot: [String: String]
    /// Gate for the `CODEX_API_KEY` env overlay. Defaults to `false` to match
    /// the app-server, which never enables it (lib.rs:470,685,775).
    private let enableCodexApiKeyEnv: Bool
    /// D2: optional auth.json path for guarded-reload codepath. nil =
    /// single-process mode (keychain etc.); reload is a no-op.
    private let authJsonPath: String?

    public init(config: OAuthConfig = OAuthConfig(),
                store: any TokenStore,
                ephemeralStore: EphemeralTokenStore? = nil,
                exchanger: any TokenExchanger = CurlTokenExchanger(),
                deviceCodeClient: any DeviceCodeClient = CurlDeviceCodeClient(),
                refreshBroker: AuthRefreshBroker = AuthRefreshBroker(),
                externalTokenRefresh: ExternalTokenRefresh? = nil,
                apiKeyExchanger: (any APIKeyExchanger)? = nil,
                revoker: (any TokenRevoker)? = nil,
                env: [String: String] = [:],
                enableCodexApiKeyEnv: Bool = false,
                authJsonPath: String? = nil,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970)
                }) {
        self.cfg = config
        self.store = store
        self.ephemeralStore = ephemeralStore
        self.exchanger = exchanger
        self.deviceCodeClient = deviceCodeClient
        self.refreshBroker = refreshBroker
        self.externalTokenRefresh = externalTokenRefresh
        self.apiKeyExchanger = apiKeyExchanger
        self.revoker = revoker
        self.nowProvider = now
        self.enableCodexApiKeyEnv = enableCodexApiKeyEnv
        // `envOverlay` holds ONLY the gated CODEX_API_KEY credential so it can
        // be resolved at the very top of `effectiveTokens()` precedence. The
        // CODEX_ACCESS_TOKEN agent identity is applied separately, AFTER the
        // ephemeral store, mirroring upstream `load_auth` ordering. Hence we do
        // NOT keep the CODEX_ACCESS_TOKEN fallback that `loadFromEnv` would
        // otherwise return.
        if enableCodexApiKeyEnv, let key = env["CODEX_API_KEY"], !key.isEmpty {
            self.envOverlay = AuthDotJson(openaiAPIKey: key)
        } else {
            self.envOverlay = nil
        }
        self.envSnapshot = env
        if let authJsonPath {
            self.authJsonPath = authJsonPath
        } else if let fs = store as? FileTokenStore {
            self.authJsonPath = fs.path
        } else if let mig = store as? MigratingTokenStore,
                  let fs = mig.primary as? FileTokenStore {
            self.authJsonPath = fs.path
        } else if let mig = store as? MigratingTokenStore,
                  let fs = mig.legacy as? FileTokenStore {
            self.authJsonPath = fs.path
        } else if let auto = store as? AutoTokenStore,
                  let fs = auto.file as? FileTokenStore {
            self.authJsonPath = fs.path
        } else {
            self.authJsonPath = nil
        }
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

    public func loginWithAPIKey(_ apiKey: String) async throws {
        pending = nil
        refreshFailures.removeAll()
        refreshFailureReasons.removeAll()
        let new = AuthTokens(accessToken: apiKey,
                             refreshToken: nil,
                             tokenType: "APIKey",
                             expiresAtUnix: AuthTokens.neverExpires,
                             accountId: nil)
        let prev = store.load()
        try store.save(new)
        await revokeIfNeeded(previous: prev, replacement: new)
        try throwIfEnvShadowed(.loginWithAPIKey)
    }

    public func loginWithExternalChatGPTTokens(accessToken: String,
                                               accountId: String) async throws {
        pending = nil
        refreshFailures.removeAll()
        refreshFailureReasons.removeAll()
        // Upstream `AuthDotJson::from_external_tokens` (manager.rs:936-958)
        // parses the ChatGPT JWT claims out of the supplied `access_token` and
        // stores them in the `id_token` slot of `TokenData` (which is what
        // `get_account_email` / `account_plan_type` later read). For external
        // tokens the access_token IS the claim-bearing JWT, so we mirror that
        // by populating `idToken` with it — keeping the account/read claim
        // source canonical (id_token only) per Finding #3.
        let tokens = AuthTokens(accessToken: accessToken,
                                refreshToken: nil,
                                idToken: accessToken,
                                tokenType: "BearerExternal",
                                expiresAtUnix: AuthTokens.neverExpires,
                                accountId: accountId)
        // Host-app-injected ChatGPT tokens are in-memory only. They
        // live and die with the host-app session, so we must never
        // persist them to disk or to the keychain. Upstream parity:
        // `EphemeralAuthStorage` (codex-rs/login/src/auth/storage.rs:293-334).
        if let ephemeralStore {
            let prev = ephemeralStore.load()
            try ephemeralStore.save(tokens)
            await revokeIfNeeded(previous: prev, replacement: tokens)
            try throwIfEnvShadowed(.loginWithExternalChatGPTTokens)
            return
        }
        let prev = store.load()
        try store.save(tokens)
        await revokeIfNeeded(previous: prev, replacement: tokens)
        try throwIfEnvShadowed(.loginWithExternalChatGPTTokens)
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
            // A1: best-effort OAuth 2.0 Token Exchange (RFC 8693) to mint
            // an OpenAI API key from the id_token. Mirrors upstream
            // `obtain_api_key`. Failure is non-fatal — the ChatGPT login
            // still succeeds; the user just doesn't get the API-key path.
            if let idToken = t.idToken, !idToken.isEmpty,
               let apiKeyExchanger {
                do {
                    let key = try await apiKeyExchanger.exchangeForAPIKey(
                        idToken: idToken, cfg: loginConfig)
                    mintedAPIKey = key
                } catch {
                    mintedAPIKey = nil
                }
            } else {
                mintedAPIKey = nil
            }
            let prev = store.load()
            do { try store.save(t) } catch {
                return .failure(.transport("persist: \(error)"))
            }
            refreshFailures.removeAll()
            refreshFailureReasons.removeAll()
            pending = nil
            // A2: revoke prior credential when superseded. Best-effort.
            await revokeIfNeeded(previous: prev, replacement: t)
            return .success(AccountInfo(accountId: t.accountId,
                                        authenticated: true,
                                        expiresAtUnix: t.expiresAtUnix))
        case .failure(let e):
            return .failure(e)
        }
    }

    public func logout() async throws {
        pending = nil
        refreshFailures.removeAll()
        refreshFailureReasons.removeAll()
        // A2: best-effort revoke previous credentials at the issuer
        // BEFORE we clear local state. If revocation fails we still
        // proceed with the local clear (best-effort by contract).
        let ephemeralPrev = ephemeralStore?.load()
        let persistedPrev = store.load()
        await revokeIfNeeded(previous: ephemeralPrev, replacement: nil)
        await revokeIfNeeded(previous: persistedPrev, replacement: nil)
        // Clear both ephemeral (host-app-injected) and persistent
        // (managed-CLI) credentials. Either side throwing does not
        // prevent the other from being attempted; the first error is
        // rethrown so callers learn something failed.
        var firstError: (any Error)?
        if let ephemeralStore {
            do { try ephemeralStore.clear() } catch { firstError = error }
        }
        do { try store.clear() } catch {
            if firstError == nil { firstError = error }
        }
        mintedAPIKey = nil
        if let firstError { throw firstError }
        // A5: even though local state was cleared, an env overlay still
        // wins on read. Surface that so the caller can warn the user.
        try throwIfEnvShadowed(.logout)
    }

    // MARK: - A2 / A5 helpers

    /// Best-effort revocation of `previous` when it differs from
    /// `replacement`. Never blocks the caller on error — failures are
    /// swallowed by `Revocation.revokeIfPossible`. Skipped when no
    /// `revoker` is wired (the default).
    private func revokeIfNeeded(previous: AuthTokens?,
                                replacement: AuthTokens?) async {
        guard let revoker else { return }
        guard Revocation.shouldRevoke(previous: previous,
                                      replacement: replacement) else { return }
        await Revocation.revokeIfPossible(previous, cfg: cfg, revoker: revoker)
    }

    /// Throws `LoginShadowedByEnvError` if any env-overlay variable is
    /// currently set. Used at the END of write-side operations so the
    /// persistent store update still happens — the throw is purely
    /// diagnostic ("your change won't be visible to this process").
    private func throwIfEnvShadowed(
        _ op: LoginShadowedByEnvError.Operation) throws {
        if let varname = LoginShadowedByEnvError.shadowingVar(
            env: envSnapshot, enableCodexApiKeyEnv: enableCodexApiKeyEnv) {
            throw LoginShadowedByEnvError(operation: op, shadowingVar: varname)
        }
    }

    public func account() -> AccountInfo {
        guard let t = effectiveTokens() else {
            return AccountInfo(accountId: nil, authenticated: false,
                               expiresAtUnix: nil)
        }
        return AccountInfo(accountId: t.accountId,
                           authenticated: true,
                           expiresAtUnix: t.expiresAtUnix)
    }

    public func storedTokens() -> AuthTokens? { effectiveTokens() }

    /// Effective tokens after applying overlays. Precedence mirrors upstream
    /// `load_auth` (manager.rs:731-768) EXACTLY:
    ///   1. CODEX_API_KEY env overlay (only when `enableCodexApiKeyEnv`)
    ///   2. ephemeral host-app-injected ChatGPT tokens
    ///   3. CODEX_ACCESS_TOKEN agent-identity env
    ///   4. persistent token store (file / keychain)
    /// External ChatGPT (ephemeral) tokens therefore take precedence over a
    /// CODEX_ACCESS_TOKEN when both are present, matching upstream.
    private func effectiveTokens() -> AuthTokens? {
        if let envOverlay,
           let tokens = AuthTokens.fromAuthDotJson(envOverlay) {
            return tokens
        }
        if let ephemeralStore, let t = ephemeralStore.load() { return t }
        if let accessToken = envSnapshot["CODEX_ACCESS_TOKEN"],
           !accessToken.isEmpty,
           let tokens = AuthTokens.fromAuthDotJson(
            AuthDotJson(openaiAPIKey: nil,
                        tokens: AuthDotJson.Tokens(accessToken: accessToken))) {
            return tokens
        }
        return store.load()
    }

    /// D1: return the effective on-disk auth record after applying env
    /// precedence. Used by callers that need the raw `AuthDotJson`
    /// shape (e.g. supervisor reads) rather than the runtime
    /// `AuthTokens` projection.
    public func effectiveAuthDotJson() -> AuthDotJson? {
        if let envOverlay { return envOverlay }
        if let ephemeralStore, let t = ephemeralStore.load() {
            return t.toAuthDotJson()
        }
        if let accessToken = envSnapshot["CODEX_ACCESS_TOKEN"],
           !accessToken.isEmpty {
            return AuthDotJson(
                openaiAPIKey: nil,
                tokens: AuthDotJson.Tokens(accessToken: accessToken))
        }
        if let path = authJsonPath,
           let data = AuthFileLock.readContentsLocked(path: path),
           let auth = try? AuthDotJson.decode(data) {
            return auth
        }
        if let t = store.load() { return t.toAuthDotJson() }
        return nil
    }

    // MARK: - D2: account-id-matched guarded reload

    /// Outcome of `reloadIfAccountIdMatches`. Mirrors upstream
    /// `ReloadOutcome` (manager.rs:~1430).
    public enum ReloadOutcome: Sendable, Equatable {
        /// On-disk account+token match in-memory; continue with refresh.
        case matched
        /// Sibling process refreshed; adopt the on-disk tokens and skip
        /// the network call.
        case adoptedOnDisk(AuthTokens)
        /// On-disk record is missing/empty/stale (continue with refresh).
        case staleOnDisk
        /// Store doesn't expose an auth.json path (single-process mode).
        case skipped
    }

    /// Before issuing a network refresh, re-read auth.json under a
    /// shared flock and compare account ids. If a sibling process has
    /// already refreshed the tokens out from under us, adopt those
    /// tokens and skip the network call (prevents two processes burning
    /// the same refresh_token in parallel). Mirrors upstream
    /// `reload_if_account_id_matches` (manager.rs:1434).
    public func reloadIfAccountIdMatches() -> ReloadOutcome {
        guard let path = authJsonPath else { return .skipped }
        guard let inMemory = store.load() else { return .skipped }
        guard let data = AuthFileLock.readContentsLocked(path: path) else {
            return .staleOnDisk
        }
        guard let onDisk = try? AuthDotJson.decode(data),
              let onDiskTokens = AuthTokens.fromAuthDotJson(onDisk) else {
            return .staleOnDisk
        }
        if inMemory.accountId == onDiskTokens.accountId
            && inMemory.accessToken == onDiskTokens.accessToken {
            return .matched
        }
        if onDisk.lastRefresh != nil {
            try? store.save(onDiskTokens)
            refreshFailures.remove(refreshFailureKey(inMemory))
            return .adoptedOnDisk(onDiskTokens)
        }
        return .staleOnDisk
    }

    public func hasRefreshFailure(for tokens: AuthTokens) -> Bool {
        refreshFailures.contains(refreshFailureKey(tokens))
    }

    /// Classified reason for the last refresh failure on `tokens`, or `nil`
    /// when no failure has been recorded. Surfaces upstream's
    /// `RefreshTokenFailedReason` (expired / reused / revoked / other) so
    /// the supervisor can decide between "show re-login prompt" and "retry
    /// transparently". Mirrors `refresh_failure_for_auth` (manager.rs:1398).
    public func refreshFailureReason(for tokens: AuthTokens)
        -> RefreshTokenFailedReason? {
        refreshFailureReasons[refreshFailureKey(tokens)]
    }

    public func isAuthenticated() -> Bool { effectiveTokens() != nil }

    /// A currently-valid access token, refreshing through the single-flight
    /// broker when expiring. Returns nil when not authenticated / unrefreshable.
    ///
    /// A4: if a *permanent* refresh failure (`expired` / `exhausted` /
    /// `revoked`) has already been recorded for `t`, we short-circuit and
    /// return nil rather than burning another refresh call on a known-
    /// rejected token. Transient failures still fall through to the
    /// refresh path so retries can recover.
    public func validAccessToken() async -> String? {
        guard let t = effectiveTokens() else { return nil }
        if !t.isExpiring(now: nowProvider()) { return t.accessToken }
        if let reason = refreshFailureReasons[refreshFailureKey(t)],
           reason.isPermanent {
            return nil
        }
        return await refreshAccessTokenFrom(t, fallbackToStored: true)
    }

    /// Force-refresh the access token after an upstream 401. Unlike
    /// `validAccessToken`, this does not return the old cached token when the
    /// refresh fails; retrying a known-rejected bearer would mask the real
    /// authentication failure.
    public func refreshAccessToken() async -> String? {
        guard let t = effectiveTokens() else { return nil }
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
        // Wrap the refresh in a typed-throwing closure so the broker
        // preserves the AuthError (in particular `.refreshFailed`) all
        // the way back here. The previous `try?` collapse was the
        // root cause of A3 — the classified reason was silently
        // discarded before we could record it.
        let key = refreshFailureKey(t)
        do {
            let refreshed = try await refreshBroker.token(account: account) {
                switch await exchanger.refresh(refreshToken: rt, cfg: cfg) {
                case .success(let nt):
                    try? store.save(nt)
                    return nt.accessToken
                case .failure(let e):
                    throw e
                }
            }
            refreshFailures.remove(key)
            refreshFailureReasons.removeValue(forKey: key)
            return refreshed
        } catch let AuthError.refreshFailed(reason, _) {
            // A3 + A4: record classified reason AND mark the failure on
            // both paths so subsequent `validAccessToken` callers don't
            // burn another refresh attempt on a known-rejected token.
            refreshFailures.insert(key)
            refreshFailureReasons[key] = reason
            return fallbackToStored ? store.load()?.accessToken : nil
        } catch {
            // Transient failures (timeouts, 5xx, parser errors). Mark the
            // failure on the force-refresh path so the next call short-
            // circuits, but don't classify a reason — a retry might
            // succeed. Mirrors upstream's transient/permanent split.
            if !fallbackToStored {
                refreshFailures.insert(key)
            }
            return fallbackToStored ? store.load()?.accessToken : nil
        }
    }

    private func refreshFailureKey(_ tokens: AuthTokens) -> String {
        "\(tokens.accountId ?? "default")|\(tokens.refreshToken ?? "")"
    }
}
