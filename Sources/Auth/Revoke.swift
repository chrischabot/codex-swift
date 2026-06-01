import Foundation

/// Best-effort OAuth token revocation. Mirrors upstream
/// `codex-rs/login/src/auth/revoke.rs`. Revoking the refresh token invalidates
/// any child access tokens at the issuer, so callers should revoke on logout
/// AND when an existing ChatGPT login is being superseded by a fresh login.
///
/// Failures are best-effort by contract: the public surface is
/// `Revocation.revokeIfPossible(...)` which never throws — it logs and
/// returns. Callers must not let revocation outcomes block their primary work
/// (logout still removes local state; re-login still persists fresh
/// credentials).
public protocol TokenRevoker: Sendable {
    /// POST `{token, token_type_hint, client_id?}` (JSON) to the revoke
    /// endpoint. Returns on success; throws on transport/server error so the
    /// caller can decide whether to log.
    func revoke(token: String,
                tokenTypeHint: TokenTypeHint,
                cfg: OAuthConfig) async throws
}

public enum TokenTypeHint: String, Sendable {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
}

/// Best-effort revocation entry points. The `revocableToken(...)` helper
/// picks the most-useful token from an `AuthTokens` (refresh > access) and
/// only returns a value for managed ChatGPT logins — API-key and external
/// modes are not revocable at this endpoint.
public enum Revocation {
    /// Mirrors upstream `revocable_token`. Returns `nil` for API-key and
    /// external/host-managed modes (both not revocable here).
    public static func revocableToken(_ t: AuthTokens?) -> (String, TokenTypeHint)? {
        guard let t else { return nil }
        // Only managed ChatGPT logins (Bearer) carry an issuer refresh token
        // we can revoke. API-key, external-bearer, and agent-identity tokens
        // are not OAuth-issued in the sense the revoke endpoint expects.
        switch t.tokenType.lowercased() {
        case "bearer":
            if let rt = t.refreshToken, !rt.isEmpty {
                return (rt, .refreshToken)
            }
            if !t.accessToken.isEmpty {
                return (t.accessToken, .accessToken)
            }
            return nil
        default:
            return nil
        }
    }

    /// Mirrors upstream `should_revoke_auth_tokens`: revoke the prior
    /// credential unless the replacement reuses the same token. Used on
    /// re-login to invalidate the previous session at the issuer.
    public static func shouldRevoke(previous: AuthTokens?,
                                    replacement: AuthTokens?) -> Bool {
        guard let (token, kind) = revocableToken(previous) else { return false }
        guard let r = replacement,
              r.tokenType.lowercased() == "bearer" else { return true }
        switch kind {
        case .accessToken: return r.accessToken != token
        case .refreshToken: return (r.refreshToken ?? "") != token
        }
    }

    /// Best-effort revoke. Logs failures via `onError` (default: stderr) and
    /// always returns. Use this from logout / re-login paths.
    public static func revokeIfPossible(
        _ tokens: AuthTokens?,
        cfg: OAuthConfig = OAuthConfig(),
        revoker: any TokenRevoker = CurlTokenRevoker(),
        onError: @Sendable (String) -> Void = Revocation.defaultLog
    ) async {
        guard let (token, kind) = revocableToken(tokens) else { return }
        do {
            try await revoker.revoke(token: token, tokenTypeHint: kind, cfg: cfg)
        } catch {
            onError("revoke \(kind.rawValue) failed: \(error)")
        }
    }

    public static func defaultLog(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}

/// `@unchecked Sendable` Process box for the curl-based revoke client.
private final class RevokeProcBox: @unchecked Sendable { let p = Process() }

/// Default revoker: posts JSON to `<issuer>/oauth/revoke` (matching upstream's
/// `REVOKE_TOKEN_URL`). 10s timeout via curl `--max-time` (mirrors upstream
/// `REVOKE_HTTP_TIMEOUT`).
public struct CurlTokenRevoker: TokenRevoker {
    public init() {}

    public func revoke(token: String,
                       tokenTypeHint: TokenTypeHint,
                       cfg: OAuthConfig) async throws {
        guard !token.isEmpty else { return }
        let endpoint = Self.revokeEndpoint(cfg: cfg)
        let body = RevokeRequestBody.jsonObject(
            token: token, tokenTypeHint: tokenTypeHint, cfg: cfg)
        let data = try JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys])
        try await post(endpoint, jsonBody: data)
    }

    /// Endpoint resolution mirrors upstream `revoke_token_endpoint`
    /// (login/src/auth/revoke.rs:150-169): first the explicit
    /// `CODEX_REVOKE_TOKEN_URL_OVERRIDE`; then, if only
    /// `CODEX_REFRESH_TOKEN_URL_OVERRIDE` is set, derive the revoke endpoint
    /// from it by replacing the path with `/oauth/revoke` and dropping any
    /// query (`derive_revoke_token_endpoint`); finally fall back to
    /// `<issuer>/oauth/revoke`.
    static func revokeEndpoint(cfg: OAuthConfig) -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CODEX_REVOKE_TOKEN_URL_OVERRIDE"],
           !override.isEmpty {
            return override
        }
        if let refreshOverride = env["CODEX_REFRESH_TOKEN_URL_OVERRIDE"],
           !refreshOverride.isEmpty,
           let derived = deriveRevokeEndpoint(fromRefresh: refreshOverride) {
            return derived
        }
        return cfg.issuer.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")) + "/oauth/revoke"
    }

    /// Mirrors upstream `derive_revoke_token_endpoint`: parse the refresh URL,
    /// set its path to `/oauth/revoke`, and clear the query string. Returns nil
    /// when the refresh override is not a parseable absolute URL.
    static func deriveRevokeEndpoint(fromRefresh refresh: String) -> String? {
        guard var comps = URLComponents(string: refresh),
              comps.scheme != nil, comps.host != nil else { return nil }
        comps.path = "/oauth/revoke"
        comps.query = nil
        comps.fragment = nil
        return comps.string
    }

    private func post(_ url: String, jsonBody: Data) async throws {
        let box = RevokeProcBox()
        let p = box.p
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["curl", "-sS", "-X", "POST", url,
                       "--max-time", "10",
                       "-H", "Content-Type: application/json",
                       "-H", "Accept: application/json",
                       "-w", "\n%{http_code}",
                       "--data-binary", "@-"]
        let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() }
        catch { throw AuthError.transport("spawn curl: \(error)") }
        inPipe.fileHandleForWriting.write(jsonBody)
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = errPipe.fileHandleForReading.readDataToEndOfFile()
            throw AuthError.transport("curl exit \(p.terminationStatus): "
                + String(decoding: e.prefix(300), as: UTF8.self))
        }
        let raw = String(decoding: out, as: UTF8.self)
        let parts = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let statusText = parts.last, let status = Int(statusText) else {
            throw AuthError.malformed("revoke: missing HTTP status")
        }
        if !(200..<300).contains(status) {
            let bodyText = parts.dropLast().joined(separator: "\n")
            throw AuthError.server("revoke failed: status \(status): "
                + String(bodyText.prefix(300)))
        }
    }
}

/// Helper exposed for testing the JSON body shape without networking. Order
/// of keys here is for diagnostics — actual on-wire JSON uses sorted keys
/// for determinism.
public enum RevokeRequestBody {
    public static func jsonObject(token: String,
                                  tokenTypeHint: TokenTypeHint,
                                  cfg: OAuthConfig) -> [String: String] {
        var d = [
            "token": token,
            "token_type_hint": tokenTypeHint.rawValue,
        ]
        // Upstream only includes client_id when revoking a refresh token
        // (`RevokeTokenKind::client_id`).
        if tokenTypeHint == .refreshToken { d["client_id"] = cfg.clientId }
        return d
    }
}
