import Foundation
import EgressGuard
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// ADDONS.md #3 — the native-Swift Google OAuth2 runtime (the `Connectors.swift`
// stub made real). A loopback PKCE flow (no client secret needed for an
// installed app), an ephemeral-port redirect (no fixed port to hijack), token
// storage + refresh, and a REAL Google revoke. The token endpoints are vetted
// through the #5 egress chokepoint. This is the auth substrate the Google
// Workspace suite (#4) and Gmail channel (#5) build on.

/// PKCE (RFC 7636) parameters for one authorization. `verifier` is the secret
/// kept locally; `challenge` is sent in the auth URL; the token exchange proves
/// possession of the verifier — so an intercepted auth code is useless without it.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    /// Generate a fresh verifier (high-entropy, URL-safe) + its S256 challenge.
    public static func generate() -> PKCE {
        let verifier = randomURLSafe(byteCount: 48)   // 64 base64url chars
        let challenge = s256Challenge(verifier)
        return PKCE(verifier: verifier, challenge: challenge)
    }

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    static func s256Challenge(_ verifier: String) -> String {
        let data = Data(verifier.utf8)
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return base64URL(Data(digest))
        #else
        return base64URL(data)   // dev fallback (non-Apple) — Apple is the target
        #endif
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Endpoints + client identity for a Google OAuth app. Defaults target Google;
/// overridable for testing against a stub server.
public struct GoogleOAuthConfig: Sendable, Equatable {
    public var clientId: String
    /// Installed-app PKCE flows usually omit the secret; included for "web"
    /// client types that require it. Never logged.
    public var clientSecret: String?
    public var scopes: [String]
    public var authEndpoint: String
    public var tokenEndpoint: String
    public var revokeEndpoint: String

    public init(clientId: String,
                clientSecret: String? = nil,
                scopes: [String],
                authEndpoint: String = "https://accounts.google.com/o/oauth2/v2/auth",
                tokenEndpoint: String = "https://oauth2.googleapis.com/token",
                revokeEndpoint: String = "https://oauth2.googleapis.com/revoke") {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.authEndpoint = authEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revokeEndpoint = revokeEndpoint
    }
}

/// Stored OAuth tokens. `expiresAt` is absolute (epoch seconds) so expiry is
/// checked without tracking when they were issued.
public struct OAuthTokens: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Int64
    public var scope: String
    public var tokenType: String

    public init(accessToken: String, refreshToken: String?, expiresAt: Int64,
                scope: String, tokenType: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    /// True when the access token is expired (or within `skew` seconds of it).
    public func isExpired(now: Int64, skew: Int64 = 60) -> Bool {
        now + skew >= expiresAt
    }
}

/// Typed OAuth failures.
public enum OAuthError: Error, Sendable, Equatable {
    case egressDenied(String)
    case http(status: Int, body: String)
    case transport(String)
    case malformedResponse(String)
    case noRefreshToken
    case stateMismatch
    case callbackError(String)
}

/// The token/revoke HTTP seam (form-encoded POST → JSON / status). Injectable so
/// the exchange/refresh/revoke logic is testable without the network.
public protocol OAuthHTTPClient: Sendable {
    func postForm(url: URL, fields: [String: String]) async -> Result<(status: Int, body: Data), OAuthError>
}

/// The OAuth client: builds auth URLs and runs the token exchange / refresh /
/// revoke calls, vetting every endpoint through EgressGuard first.
public struct GoogleOAuthClient: Sendable {
    public let config: GoogleOAuthConfig
    private let egress: EgressGuard
    private let http: any OAuthHTTPClient
    private let now: @Sendable () -> Int64

    public init(config: GoogleOAuthConfig,
                egress: EgressGuard,
                http: any OAuthHTTPClient,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.config = config
        self.egress = egress
        self.http = http
        self.now = now
    }

    /// Build the authorization URL the user opens in a browser. `redirectURI` is
    /// the loopback callback (`http://127.0.0.1:<port>/...`); `state` is an
    /// unguessable token echoed back to defeat CSRF.
    public func authorizationURL(redirectURI: String, state: String, pkce: PKCE) -> URL? {
        var comps = URLComponents(string: config.authEndpoint)
        comps?.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return comps?.url
    }

    /// Exchange an authorization `code` (+ the PKCE verifier) for tokens.
    public func exchange(code: String, verifier: String, redirectURI: String) async -> Result<OAuthTokens, OAuthError> {
        var fields = [
            "client_id": config.clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        return await tokenCall(endpoint: config.tokenEndpoint, fields: fields, existingRefresh: nil)
    }

    /// Refresh an access token using a stored refresh token.
    public func refresh(refreshToken: String) async -> Result<OAuthTokens, OAuthError> {
        var fields = [
            "client_id": config.clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = config.clientSecret { fields["client_secret"] = secret }
        // Google omits the refresh_token on refresh responses — carry the old one.
        return await tokenCall(endpoint: config.tokenEndpoint, fields: fields, existingRefresh: refreshToken)
    }

    /// Revoke an access OR refresh token at Google's revoke endpoint.
    public func revoke(token: String) async -> Result<Void, OAuthError> {
        guard let url = URL(string: config.revokeEndpoint) else {
            return .failure(.malformedResponse("bad revoke endpoint"))
        }
        if case .deny(let r) = egress.vet(url) { return .failure(.egressDenied(r)) }
        switch await http.postForm(url: url, fields: ["token": token]) {
        case .failure(let e): return .failure(e)
        case .success(let resp):
            return (200..<300).contains(resp.status)
                ? .success(())
                : .failure(.http(status: resp.status, body: String(data: resp.body, encoding: .utf8) ?? ""))
        }
    }

    private func tokenCall(endpoint: String, fields: [String: String],
                           existingRefresh: String?) async -> Result<OAuthTokens, OAuthError> {
        guard let url = URL(string: endpoint) else {
            return .failure(.malformedResponse("bad token endpoint"))
        }
        if case .deny(let r) = egress.vet(url) { return .failure(.egressDenied(r)) }
        switch await http.postForm(url: url, fields: fields) {
        case .failure(let e): return .failure(e)
        case .success(let resp):
            guard (200..<300).contains(resp.status) else {
                return .failure(.http(status: resp.status, body: String(data: resp.body, encoding: .utf8) ?? ""))
            }
            return parseTokens(resp.body, existingRefresh: existingRefresh)
        }
    }

    private func parseTokens(_ body: Data, existingRefresh: String?) -> Result<OAuthTokens, OAuthError> {
        struct Resp: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
            let scope: String?
            let token_type: String?
        }
        guard let r = try? JSONDecoder().decode(Resp.self, from: body) else {
            return .failure(.malformedResponse("token response not JSON / missing access_token"))
        }
        let expiresAt = now() + Int64(r.expires_in ?? 3600)
        return .success(OAuthTokens(
            accessToken: r.access_token,
            refreshToken: r.refresh_token ?? existingRefresh,
            expiresAt: expiresAt,
            scope: r.scope ?? "",
            tokenType: r.token_type ?? "Bearer"))
    }
}
