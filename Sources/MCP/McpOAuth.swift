import Foundation

public struct StoredOAuthTokens: Sendable, Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String
    public var expiresAtEpoch: Double?

    public init(accessToken: String, refreshToken: String? = nil,
                tokenType: String = "Bearer", expiresAtEpoch: Double? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAtEpoch = expiresAtEpoch
    }

    public var isExpired: Bool {
        if let e = expiresAtEpoch { return Date().timeIntervalSince1970 >= e }
        return false
    }
}

public struct McpOAuthStore: Sendable {
    public let codexHome: String
    public init(codexHome: String) { self.codexHome = codexHome }

    private var dir: String { codexHome + "/.mcp-oauth" }

    private func path(_ server: String) -> String {
        let safe = String(server.map { c -> Character in
            if c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" { return c }
            return "_"
        })
        return dir + "/" + safe + ".json"
    }

    public func save(_ t: StoredOAuthTokens, server: String) throws {
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(t)
        let p = path(server)
        let tmp = p + ".tmp"
        if FileManager.default.fileExists(atPath: tmp) {
            try? FileManager.default.removeItem(atPath: tmp)
        }
        FileManager.default.createFile(atPath: tmp, contents: data,
                                       attributes: [.posixPermissions: 0o600])
        if FileManager.default.fileExists(atPath: p) {
            try? FileManager.default.removeItem(atPath: p)
        }
        try FileManager.default.moveItem(atPath: tmp, toPath: p)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: p)
    }

    public func load(server: String) -> StoredOAuthTokens? {
        guard let data = FileManager.default.contents(atPath: path(server)) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredOAuthTokens.self, from: data)
    }

    public func delete(server: String) {
        try? FileManager.default.removeItem(atPath: path(server))
    }
}

public struct OAuthMetadata: Sendable, Equatable {
    public var authorizationEndpoint: String?
    public var tokenEndpoint: String?
    public var issuer: String?

    public init(authorizationEndpoint: String? = nil,
                tokenEndpoint: String? = nil,
                issuer: String? = nil) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.issuer = issuer
    }
}

public enum McpOAuth {
    /// INTENTIONAL PORT DIVERGENCE (audit "mcp" Finding 6, minor):
    ///
    /// Upstream (`rmcp-client/src/perform_oauth_login.rs`) binds an *ephemeral*
    /// loopback port and appends a per-server callback-id (SHA256 of the
    /// normalized server URL, base64url) to the redirect path, and sources
    /// `client_id` from dynamic registration / `oauth.client_id` config. This
    /// Swift implementation is a *simplified, CLI-only* `codex mcp login` flow
    /// (out of band from the JSON-RPC protocol surface): it uses a fixed
    /// loopback port + static path and a literal `client_id=Codex` in the token
    /// exchange. Because this is not part of the wire protocol that real MCP
    /// servers exercise during a session, the fidelity impact is low; it is
    /// retained as a documented divergence rather than reproducing the
    /// ephemeral-port + callback-id machinery for a local CLI helper. If full
    /// OAuth login parity is later required, see the finding's
    /// `fixRecommendation` for the exact derivation.
    public static let redirectURI = "http://127.0.0.1:1455/mcp/oauth/callback"

    public static func discoverMetadata(serverURL: String,
                                        timeout: Double = 10) -> OAuthMetadata? {
        guard let comps = URLComponents(string: serverURL),
              let scheme = comps.scheme, let host = comps.host else { return nil }
        var origin = scheme + "://" + host
        if let port = comps.port { origin += ":\(port)" }
        var candidates: [String] = []
        let scopedPath = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !scopedPath.isEmpty {
            candidates.append(origin + "/.well-known/oauth-authorization-server/" + scopedPath)
        }
        candidates.append(origin + "/.well-known/oauth-authorization-server")
        let secs = String(Int(Swift.max(1, timeout)))
        for metaURL in candidates {
            guard let body = runCurlCapture(
                args: ["curl", "-sS", "--max-time", secs, metaURL]),
                  let data = body.data(using: .utf8),
                  let v = try? JSONLite.parse(data),
                  case .object(let o) = v else { continue }
            func str(_ k: String) -> String? {
                if case .string(let s)? = o[k] { return s }
                return nil
            }
            let m = OAuthMetadata(authorizationEndpoint: str("authorization_endpoint"),
                                  tokenEndpoint: str("token_endpoint"),
                                  issuer: str("issuer"))
            if m.authorizationEndpoint != nil || m.tokenEndpoint != nil || m.issuer != nil {
                return m
            }
        }
        return nil
    }

    public static func supportsOAuthLogin(serverURL: String) -> Bool {
        discoverMetadata(serverURL: serverURL) != nil
    }

    public static func exchangeAuthorizationCode(tokenEndpoint: String,
                                                 code: String,
                                                 verifier: String,
                                                 redirectURI: String = redirectURI,
                                                 timeout: Double = 10) throws
        -> StoredOAuthTokens {
        let secs = String(Int(Swift.max(1, timeout)))
        let body = try runCurlCaptureThrowing(args: [
            "curl", "-sS", "--max-time", secs,
            "-X", "POST", tokenEndpoint,
            "-H", "Content-Type: application/x-www-form-urlencoded",
            "--data-urlencode", "grant_type=authorization_code",
            "--data-urlencode", "client_id=Codex",
            "--data-urlencode", "code=\(code)",
            "--data-urlencode", "code_verifier=\(verifier)",
            "--data-urlencode", "redirect_uri=\(redirectURI)",
        ])
        guard let data = body.data(using: .utf8),
              let v = try? JSONLite.parse(data),
              case .object(let o) = v else {
            throw McpError.transport("OAuth token response was not JSON")
        }
        if let err = string(o["error"]) {
            let desc = string(o["error_description"])
            throw McpError.server(desc.map { "\(err): \($0)" } ?? err)
        }
        guard let access = string(o["access_token"]), !access.isEmpty else {
            throw McpError.transport("OAuth token response missing access_token")
        }
        let tokenType = string(o["token_type"]) ?? "Bearer"
        let refresh = string(o["refresh_token"])
        let expiresAt: Double?
        if let expiresIn = number(o["expires_in"]) {
            expiresAt = Date().timeIntervalSince1970 + expiresIn
        } else {
            expiresAt = nil
        }
        return StoredOAuthTokens(accessToken: access,
                                 refreshToken: refresh,
                                 tokenType: tokenType,
                                 expiresAtEpoch: expiresAt)
    }

    private static func string(_ value: JSONLite?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private static func number(_ value: JSONLite?) -> Double? {
        if case .number(let n)? = value { return n }
        return nil
    }
}

/// Synchronous small-document curl capture (metadata docs are tiny).
private func runCurlCapture(args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 { return nil }
    return String(data: data, encoding: .utf8)
}

private func runCurlCaptureThrowing(args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { throw McpError.spawn("\(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let message = String(data: errData, encoding: .utf8) ?? "curl failed"
        throw McpError.transport(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return String(data: data, encoding: .utf8) ?? ""
}
