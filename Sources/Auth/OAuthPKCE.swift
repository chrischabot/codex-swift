import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// OAuth client configuration. Public-client PKCE (no secret). Defaults mirror
/// the Codex ChatGPT login surface; all fields are configurable so the flow
/// works against any conformant issuer and is testable offline.
public struct OAuthConfig: Sendable, Equatable {
    public var issuer: String          // e.g. https://auth.openai.com
    public var clientId: String
    public var redirectURI: String
    public var scopes: [String]
    /// Upstream `originator()` value (login/src/auth/default_client.rs:36),
    /// sent as the `originator` authorize param and the `originator` header.
    public var originator: String
    public init(issuer: String = "https://auth.openai.com",
                // Upstream production CLIENT_ID (login/src/auth/manager.rs:928).
                clientId: String = "app_EMoamEEZ73f0CkXaXp7hrann",
                redirectURI: String = "http://localhost:1455/auth/callback",
                // Upstream hardcoded scope set (login/src/server.rs:495-498).
                scopes: [String] = ["openid", "profile", "email", "offline_access",
                                    "api.connectors.read", "api.connectors.invoke"],
                originator: String = "codex_cli_rs") {
        self.issuer = issuer
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.originator = originator
    }
    public var authorizeEndpoint: String { issuer + "/oauth/authorize" }
    public var tokenEndpoint: String { issuer + "/oauth/token" }
}

/// Stored credential set (Codex `auth.json` analog).
public struct AuthTokens: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var tokenType: String
    public var expiresAtUnix: Int64
    public var accountId: String?
    public init(accessToken: String, refreshToken: String? = nil,
                idToken: String? = nil, tokenType: String = "Bearer",
                expiresAtUnix: Int64, accountId: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.tokenType = tokenType
        self.expiresAtUnix = expiresAtUnix
        self.accountId = accountId
    }
    public func isExpiring(skewSeconds: Int64 = 60, now: Int64) -> Bool {
        now + skewSeconds >= expiresAtUnix
    }
}

public enum AuthError: Error, Sendable, Equatable, CustomStringConvertible {
    case transport(String)
    case server(String)
    case invalidState
    case notAuthenticated
    case malformed(String)
    /// Refresh request was rejected by the issuer (HTTP 401 / equivalent
    /// permanent-failure signal). `reason` is the classified cause;
    /// `underlying` preserves the raw body for diagnostics. Mirrors upstream
    /// `RefreshTokenError::Permanent` + `RefreshTokenFailedError`
    /// (codex-rs/login/src/auth/manager.rs:843).
    case refreshFailed(reason: RefreshTokenFailedReason, underlying: String)
    /// The device-code start endpoint returned HTTP 404, meaning device-code
    /// login is not enabled for this Codex server. Mirrors the upstream
    /// `io::ErrorKind::NotFound` condition raised in
    /// `login/src/device_code_auth.rs:82-86`; the app-server maps this to a
    /// JSON-RPC `invalid_request` (account_processor.rs:344-351). The associated
    /// `message` is the verbatim upstream user-facing string so callers can
    /// surface it via `description`.
    case deviceCodeNotEnabled(String)
    public var description: String {
        switch self {
        case .transport(let s): return "auth transport: \(s)"
        case .server(let s): return "auth server: \(s)"
        case .invalidState: return "auth: state mismatch (possible CSRF)"
        case .notAuthenticated: return "auth: not authenticated"
        case .malformed(let s): return "auth: malformed (\(s))"
        case .refreshFailed(let r, _): return r.userFacingMessage
        case .deviceCodeNotEnabled(let s): return s
        }
    }
}

/// RFC 7636 PKCE pair. `verifier` is a high-entropy URL-safe string; the
/// `challenge` is base64url(SHA256(verifier)).
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Data(SHA256.hash(verifier)).base64URLEncodedString()
    }
    /// Generate a fresh pair (96 random bytes → base64url, 43–128 chars).
    public static func generate(
        rng: @Sendable (Int) -> [UInt8] = PKCE.secureRandomBytes) -> PKCE {
        let v = Data(rng(96)).base64URLEncodedString()
        return PKCE(verifier: String(v.prefix(128)))
    }
    public static func secureRandomBytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }
}

/// Builds the RFC 6749 / 7636 authorization-request URL.
public enum AuthorizeURL {
    public static func build(_ cfg: OAuthConfig, challenge: String,
                             state: String,
                             forcedWorkspaceIds: [String] = []) -> String {
        func enc(_ s: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        // Param set + order mirror upstream `build_authorize_url`
        // (login/src/server.rs:491-518): the two ChatGPT flow flags precede
        // `state`, and `originator` follows it. `allowed_workspace_id` is
        // appended only when forced workspace ids are configured.
        var q = [
            "response_type=code",
            "client_id=\(enc(cfg.clientId))",
            "redirect_uri=\(enc(cfg.redirectURI))",
            "scope=\(enc(cfg.scopes.joined(separator: " ")))",
            "code_challenge=\(enc(challenge))",
            "code_challenge_method=S256",
            "id_token_add_organizations=true",
            "codex_cli_simplified_flow=true",
            "state=\(enc(state))",
            "originator=\(enc(cfg.originator))",
        ]
        if !forcedWorkspaceIds.isEmpty {
            q.append("allowed_workspace_id=\(enc(forcedWorkspaceIds.joined(separator: ",")))")
        }
        return cfg.authorizeEndpoint + "?" + q.joined(separator: "&")
    }
}

/// The network seam. Default impl is a portable curl-backed POST so the Auth
/// module needs no URLSession (works on Linux); tests inject a mock.
public protocol TokenExchanger: Sendable {
    func exchange(code: String, verifier: String,
                  cfg: OAuthConfig) async -> Result<AuthTokens, AuthError>
    func refresh(refreshToken: String,
                 cfg: OAuthConfig) async -> Result<AuthTokens, AuthError>
}

public struct DeviceCodeChallenge: Sendable, Equatable {
    public var verificationURL: String
    public var userCode: String
    public var deviceAuthId: String
    public var intervalSeconds: UInt64
    public init(verificationURL: String, userCode: String, deviceAuthId: String,
                intervalSeconds: UInt64) {
        self.verificationURL = verificationURL
        self.userCode = userCode
        self.deviceAuthId = deviceAuthId
        self.intervalSeconds = intervalSeconds
    }
}

public protocol DeviceCodeClient: Sendable {
    func request(config: OAuthConfig) async -> Result<DeviceCodeChallenge, AuthError>
    func complete(config: OAuthConfig,
                  challenge: DeviceCodeChallenge) async -> Result<AuthTokens, AuthError>
}

/// `@unchecked Sendable` Process box (same pattern as the model client).
private final class ProcBox2: @unchecked Sendable { let p = Process() }

public struct CurlTokenExchanger: TokenExchanger {
    public init() {}

    /// Outcome of a token-endpoint POST. We carry the HTTP status so refresh
    /// callers can classify 401s as permanent failures (mirrors upstream's
    /// `RefreshTokenError::{Permanent,Transient}` split at manager.rs:843).
    struct TokenEndpointResult {
        var status: Int
        var body: String
        var json: [String: Any]?
    }

    private func post(_ url: String, form: [String: String])
    async -> Result<TokenEndpointResult, AuthError> {
        let body = form.map { k, v in
            let enc = { (s: String) in
                s.addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics) ?? s
            }
            return "\(enc(k))=\(enc(v))"
        }.joined(separator: "&")
        return await postRaw(
            url, body: body,
            contentType: "application/x-www-form-urlencoded")
    }

    /// Posts a JSON body to the token endpoint. Used by the ChatGPT OAuth
    /// refresh path, which upstream sends as `application/json`
    /// (`{"client_id":..,"grant_type":"refresh_token","refresh_token":..}`),
    /// distinct from the authorization_code exchange (form-encoded).
    /// (codex-rs/login/src/auth/manager.rs:815-834)
    private func postJSON(_ url: String, fields: [String: String])
    async -> Result<TokenEndpointResult, AuthError> {
        let bodyData = (try? JSONSerialization.data(
            withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
        return await postRaw(
            url, body: String(decoding: bodyData, as: UTF8.self),
            contentType: "application/json")
    }

    private func postRaw(_ url: String, body: String, contentType: String)
    async -> Result<TokenEndpointResult, AuthError> {
        let box = ProcBox2()
        let p = box.p
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["curl", "-sS", "-X", "POST", url,
                       "-H", "Content-Type: \(contentType)",
                       "-H", "Accept: application/json",
                       "-w", "\n%{http_code}",
                       "--data-binary", "@-"]
        let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() }
        catch { return .failure(.transport("spawn curl: \(error)")) }
        inPipe.fileHandleForWriting.write(Data(body.utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = errPipe.fileHandleForReading.readDataToEndOfFile()
            return .failure(.transport("curl exit \(p.terminationStatus): "
                + String(decoding: e.prefix(300), as: UTF8.self)))
        }
        let raw = String(decoding: out, as: UTF8.self)
        let parts = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let statusText = parts.last, let status = Int(statusText) else {
            return .failure(.malformed("missing HTTP status"))
        }
        let bodyText = parts.dropLast().joined(separator: "\n")
        let bodyData = bodyText.data(using: .utf8) ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: bodyData))
            as? [String: Any]
        return .success(TokenEndpointResult(
            status: status, body: bodyText, json: json))
    }

    public func tokensFromPublicObject(_ obj: [String: Any]) -> Result<AuthTokens, AuthError> {
        guard let access = obj["access_token"] as? String else {
            return .failure(.malformed("missing access_token"))
        }
        let expiresIn = (obj["expires_in"] as? Int)
            ?? Int((obj["expires_in"] as? Double) ?? 3600)
        let now = Int64(Date().timeIntervalSince1970)
        let idToken = obj["id_token"] as? String
        let claims = JWTClaims.decode(idToken)
        return .success(AuthTokens(
            accessToken: access,
            refreshToken: obj["refresh_token"] as? String,
            idToken: idToken,
            tokenType: (obj["token_type"] as? String) ?? "Bearer",
            expiresAtUnix: now + Int64(expiresIn),
            accountId: (obj["account_id"] as? String) ?? claims.accountId))
    }

    public func exchange(code: String, verifier: String,
                         cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
        switch await post(cfg.tokenEndpoint, form: [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": cfg.redirectURI, "client_id": cfg.clientId,
            "code_verifier": verifier,
        ]) {
        case .success(let r):
            if (200..<300).contains(r.status), let obj = r.json {
                return tokensFromPublicObject(obj)
            }
            if let obj = r.json, let err = obj["error"] {
                let desc = (obj["error_description"] as? String) ?? "\(err)"
                return .failure(.server(desc))
            }
            return .failure(.server(
                "token endpoint status \(r.status): "
                + String(r.body.prefix(300))))
        case .failure(let e): return .failure(e)
        }
    }

    /// Resolve the refresh-token POST endpoint. Mirrors upstream
    /// `refresh_token_endpoint()` (codex-rs/login/src/auth/manager.rs:930-933):
    /// honor `CODEX_REFRESH_TOKEN_URL_OVERRIDE` when set (independent of the
    /// configured issuer), otherwise fall back to the issuer-derived
    /// `<issuer>/oauth/token`. Upstream's non-override constant is the fixed
    /// `https://auth.openai.com/oauth/token`, which is the default
    /// `cfg.tokenEndpoint`.
    static func refreshTokenEndpoint(cfg: OAuthConfig) -> String {
        if let override = ProcessInfo.processInfo.environment[
            "CODEX_REFRESH_TOKEN_URL_OVERRIDE"], !override.isEmpty {
            return override
        }
        return cfg.tokenEndpoint
    }

    public func refresh(refreshToken: String,
                        cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
        switch await postJSON(Self.refreshTokenEndpoint(cfg: cfg), fields: [
            "client_id": cfg.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]) {
        case .success(let r):
            if (200..<300).contains(r.status), let obj = r.json {
                // Some issuers omit a rotated refresh_token; keep the old one.
                switch tokensFromPublicObject(obj) {
                case .success(var t):
                    if t.refreshToken == nil { t.refreshToken = refreshToken }
                    return .success(t)
                case .failure(let e): return .failure(e)
                }
            }
            // 401 → typed permanent failure with a user-facing message.
            // Mirrors upstream `classify_refresh_token_failure`
            // (codex-rs/login/src/auth/manager.rs:858).
            if r.status == 401 {
                let reason = RefreshFailureClassifier.classify(body: r.body)
                return .failure(.refreshFailed(
                    reason: reason, underlying: r.body))
            }
            if let obj = r.json, let err = obj["error"] {
                let desc = (obj["error_description"] as? String) ?? "\(err)"
                return .failure(.server(desc))
            }
            return .failure(.server(
                "token endpoint status \(r.status): "
                + String(r.body.prefix(300))))
        case .failure(let e): return .failure(e)
        }
    }
}

private struct JWTClaims {
    var accountId: String?
    var planType: String?

    static func decode(_ token: String?) -> JWTClaims {
        guard let token else { return JWTClaims() }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return JWTClaims() }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return JWTClaims()
        }
        // Real ChatGPT id_tokens nest account/plan claims under the
        // `https://api.openai.com/auth` object (upstream
        // `codex_login::token_data::AuthClaims`). Read those first, then fall
        // back to legacy flat keys for resilience.
        // The raw plan claim is canonicalized via the two-stage
        // `PlanType::from_raw_value` -> account `PlanType` mapping
        // (`AccountPlanType.normalize`): aliases like `hc` -> `enterprise`,
        // `education` -> `edu`, and any unrecognized value -> `unknown`
        // (never leaked verbatim).
        let auth = object["https://api.openai.com/auth"] as? [String: Any]
        let rawPlan = (auth?["chatgpt_plan_type"] as? String)
            ?? (object["https://api.openai.com/plan_type"] as? String)
            ?? (object["plan_type"] as? String)
        return JWTClaims(
            accountId: auth?["chatgpt_account_id"] as? String
                ?? object["chatgpt_account_id"] as? String
                ?? object["account_id"] as? String
                ?? object["workspace_id"] as? String,
            planType: rawPlan.map { AccountPlanType.normalize(rawValue: $0).wireValue })
    }
}

public struct CurlDeviceCodeClient: DeviceCodeClient {
    public init() {}

    private func postJSON(_ url: String, object: [String: String],
                          deviceCodeStart: Bool = false)
    async -> Result<[String: Any], AuthError> {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let body = String(data: data, encoding: .utf8) else {
            return .failure(.malformed("device code JSON encode failed"))
        }
        return await curl(url, contentType: "application/json", body: body,
                          deviceCodeStart: deviceCodeStart)
    }

    private func postForm(_ url: String, form: [String: String])
    async -> Result<[String: Any], AuthError> {
        func enc(_ s: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        let body = form.map { "\(enc($0.key))=\(enc($0.value))" }
            .joined(separator: "&")
        return await curl(url, contentType: "application/x-www-form-urlencoded", body: body,
                          deviceCodeStart: false)
    }

    private func curl(_ url: String, contentType: String, body: String,
                      deviceCodeStart: Bool)
    async -> Result<[String: Any], AuthError> {
        let box = ProcBox2()
        let p = box.p
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["curl", "-sS", "-X", "POST", url,
                       "-H", "Content-Type: \(contentType)",
                       "-H", "Accept: application/json",
                       "-w", "\n%{http_code}",
                       "--data-binary", "@-"]
        let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return .failure(.transport("spawn curl: \(error)")) }
        inPipe.fileHandleForWriting.write(Data(body.utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = errPipe.fileHandleForReading.readDataToEndOfFile()
            return .failure(.transport("curl exit \(p.terminationStatus): "
                + String(decoding: e.prefix(300), as: UTF8.self)))
        }
        let raw = String(decoding: out, as: UTF8.self)
        let parts = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let statusText = parts.last, let status = Int(statusText) else {
            return .failure(.malformed("missing HTTP status"))
        }
        let bodyText = parts.dropLast().joined(separator: "\n")
        if !(200..<300).contains(status) {
            if status == 404 && deviceCodeStart {
                // HTTP 404 on the device-code start endpoint maps to upstream's
                // `io::ErrorKind::NotFound` (device_code_auth.rs:82-86), which the
                // app-server reports as `invalid_request` rather than the
                // `internal_error` used for transient device-code failures.
                return .failure(.deviceCodeNotEnabled("device code login is not enabled for this Codex server. Use the browser login or verify the server URL."))
            }
            return .failure(.server("device auth failed with status \(status)"))
        }
        guard let data = bodyText.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.malformed("non-JSON device code response"))
        }
        return .success(obj)
    }

    public func request(config: OAuthConfig) async -> Result<DeviceCodeChallenge, AuthError> {
        let issuer = config.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch await postJSON("\(issuer)/api/accounts/deviceauth/usercode",
                              object: ["client_id": config.clientId],
                              deviceCodeStart: true) {
        case .success(let obj):
            guard let deviceAuthId = obj["device_auth_id"] as? String,
                  let userCode = (obj["user_code"] as? String) ?? (obj["usercode"] as? String) else {
                return .failure(.malformed("missing device code fields"))
            }
            let intervalText = (obj["interval"] as? String)
                ?? (obj["interval"] as? NSNumber).map { $0.stringValue }
                ?? "5"
            return .success(DeviceCodeChallenge(
                verificationURL: "\(issuer)/codex/device",
                userCode: userCode,
                deviceAuthId: deviceAuthId,
                intervalSeconds: UInt64(intervalText) ?? 5))
        case .failure(let e):
            return .failure(e)
        }
    }

    public func complete(config: OAuthConfig,
                         challenge: DeviceCodeChallenge) async -> Result<AuthTokens, AuthError> {
        let issuer = config.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let deadline = Date().addingTimeInterval(15 * 60)
        while true {
            if Task.isCancelled {
                return .failure(.server("Login was not completed"))
            }
            switch await postJSON("\(issuer)/api/accounts/deviceauth/token",
                                  object: ["device_auth_id": challenge.deviceAuthId,
                                           "user_code": challenge.userCode]) {
            case .success(let obj):
                guard let code = obj["authorization_code"] as? String,
                      let verifier = obj["code_verifier"] as? String else {
                    return .failure(.malformed("missing device auth token fields"))
                }
                return await exchangeDeviceCode(issuer: issuer, clientId: config.clientId,
                                                code: code, verifier: verifier)
            case .failure(.server(let message))
                where (message.contains("status 403") || message.contains("status 404"))
                    && Date() < deadline:
                try? await Task.sleep(for: .seconds(Int64(challenge.intervalSeconds)))
                continue
            case .failure(let e):
                return .failure(e)
            }
        }
    }

    private func exchangeDeviceCode(issuer: String, clientId: String,
                                    code: String, verifier: String)
    async -> Result<AuthTokens, AuthError> {
        switch await postForm("\(issuer)/oauth/token", form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "\(issuer)/deviceauth/callback",
            "client_id": clientId,
            "code_verifier": verifier,
        ]) {
        case .success(let obj):
            return CurlTokenExchanger().tokensFromPublicObject(obj)
        case .failure(let e):
            return .failure(e)
        }
    }
}
