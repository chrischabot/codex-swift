import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - AuthDotJson — on-disk schema

/// On-disk auth.json shape (parity with upstream `codex-rs/login/src/auth/...`).
/// Two payloads:
///   * `openaiAPIKey` — set when the user logged in with an API key, or when
///     a successful ChatGPT login was followed by a token exchange that minted
///     one.
///   * `tokens` — set when the user logged in via the ChatGPT OAuth flow.
/// `lastRefresh` is an ISO-8601 timestamp updated on every successful refresh;
/// the guarded-reload codepath uses its presence to distinguish "sibling
/// already refreshed" from "stale fragment".
public struct AuthDotJson: Sendable, Equatable, Codable {
    public struct Tokens: Sendable, Equatable, Codable {
        public var accessToken: String
        public var refreshToken: String?
        public var idToken: String?
        public var accountId: String?

        public init(accessToken: String, refreshToken: String? = nil,
                    idToken: String? = nil, accountId: String? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.idToken = idToken
            self.accountId = accountId
        }

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case accountId = "account_id"
        }
    }

    public var openaiAPIKey: String?
    public var tokens: Tokens?
    public var lastRefresh: String?

    public init(openaiAPIKey: String? = nil,
                tokens: Tokens? = nil,
                lastRefresh: String? = nil) {
        self.openaiAPIKey = openaiAPIKey
        self.tokens = tokens
        self.lastRefresh = lastRefresh
    }

    private enum CodingKeys: String, CodingKey {
        case openaiAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    /// Decode auth.json bytes. Throws on JSON parse errors. Empty/whitespace
    /// payloads decode to an empty record so callers can distinguish "no
    /// file" (returned `nil` from the lock helper) from "file present but
    /// uninitialised".
    public static func decode(_ data: Data) throws -> AuthDotJson {
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AuthDotJson() }
        return try JSONDecoder().decode(AuthDotJson.self,
                                        from: Data(trimmed.utf8))
    }

    public func encode() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(self)
    }
}

// MARK: - AuthTokens bridging

extension AuthTokens {
    /// Far-future sentinel used when a credential doesn't carry an issuer
    /// expiry (API key, host-app-injected ChatGPT token).
    static let neverExpires: Int64 = 4_102_444_800

    /// Project the on-disk shape into the runtime `AuthTokens` projection.
    /// Precedence inside an `AuthDotJson` mirrors `load_auth` upstream:
    /// `OPENAI_API_KEY` beats `tokens.access_token` (because the minted API
    /// key is the long-lived credential; the OAuth tokens are the recovery
    /// path).
    public static func fromAuthDotJson(_ a: AuthDotJson) -> AuthTokens? {
        if let key = a.openaiAPIKey, !key.isEmpty {
            return AuthTokens(accessToken: key,
                              refreshToken: nil,
                              idToken: nil,
                              tokenType: "APIKey",
                              expiresAtUnix: AuthTokens.neverExpires,
                              accountId: a.tokens?.accountId)
        }
        guard let t = a.tokens else { return nil }
        return AuthTokens(accessToken: t.accessToken,
                          refreshToken: t.refreshToken,
                          idToken: t.idToken,
                          tokenType: "Bearer",
                          expiresAtUnix: AuthTokens.neverExpires,
                          accountId: t.accountId)
    }

    public func toAuthDotJson() -> AuthDotJson {
        if tokenType.lowercased() == "apikey" {
            // API-key auth has no OAuth tokens to record. Upstream's
            // auth.json keeps the `tokens` field unset (`null`) in this
            // mode rather than emitting a sentinel entry.
            return AuthDotJson(openaiAPIKey: accessToken,
                               tokens: nil,
                               lastRefresh: nil)
        }
        return AuthDotJson(
            openaiAPIKey: nil,
            tokens: AuthDotJson.Tokens(accessToken: accessToken,
                                       refreshToken: refreshToken,
                                       idToken: idToken,
                                       accountId: accountId),
            lastRefresh: nil)
    }
}

// MARK: - EphemeralTokenStore — in-memory, host-app-scoped

/// In-memory token store used when a host app injects ChatGPT tokens. Never
/// touches disk or the keychain. Lives and dies with the host-app process.
/// Sendable via an internal lock so `AuthManager` (an actor) can call it
/// synchronously without `await`.
public final class EphemeralTokenStore: @unchecked Sendable {
    private var current: AuthTokens?
    private let lock = NSLock()

    public init(_ initial: AuthTokens? = nil) {
        self.current = initial
    }

    public func load() -> AuthTokens? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func save(_ tokens: AuthTokens) throws {
        lock.lock(); defer { lock.unlock() }
        current = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        current = nil
    }
}

// MARK: - AuthFileLock — flock(LOCK_SH)-guarded reads

/// Reads `auth.json` under a *shared* advisory lock so concurrent siblings
/// can't observe a torn write while one of them is rotating tokens. The
/// matching writer path (when we add a write-locked save) takes `LOCK_EX`.
///
/// The lock is best-effort: if `open()` or `flock()` fails (read-only fs,
/// missing file, ENOTSUP filesystem) we degrade to "no contents available"
/// rather than refusing the operation. The `nil` return is the same signal
/// the caller would see if the file simply didn't exist.
public enum AuthFileLock {
    /// Open `path` read-only, take `LOCK_SH`, slurp contents, release, return.
    /// Returns `nil` on any error (missing file, permission denied, lock
    /// failure). Never throws — guarded reload must tolerate a missing or
    /// unlockable file.
    public static func readContentsLocked(path: String) -> Data? {
        let fd: Int32 = path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        if fd < 0 { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH) != 0 { return nil }
        defer { _ = flock(fd, LOCK_UN) }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { p -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, p.baseAddress, p.count)
                #else
                return Glibc.read(fd, p.baseAddress, p.count)
                #endif
            }
            if n == 0 { break }
            if n < 0 { return nil }
            out.append(buf, count: n)
        }
        return out
    }
}

// MARK: - EnvAuth — env-precedence overlay

/// Snapshot of the env-derived auth overlay. Precedence:
///   1. `CODEX_API_KEY`     — explicit Codex CLI override
///   2. `OPENAI_API_KEY`    — upstream-compatible API key
///   3. `CODEX_ACCESS_TOKEN` — pre-minted bearer (no refresh token)
///
/// Returning `nil` means no overlay is active and the caller should fall
/// through to the persistent / ephemeral store.
public enum EnvAuth {
    public static func loadFromEnv(env: [String: String]) -> AuthDotJson? {
        if let v = env["CODEX_API_KEY"], !v.isEmpty {
            return AuthDotJson(openaiAPIKey: v)
        }
        if let v = env["OPENAI_API_KEY"], !v.isEmpty {
            return AuthDotJson(openaiAPIKey: v)
        }
        if let v = env["CODEX_ACCESS_TOKEN"], !v.isEmpty {
            return AuthDotJson(
                openaiAPIKey: nil,
                tokens: AuthDotJson.Tokens(accessToken: v))
        }
        return nil
    }
}

// MARK: - LoginShadowedByEnvError

/// Thrown by `loginWithAPIKey` / `loginWithExternalChatGPTTokens` / `logout`
/// when an env overlay (`CODEX_API_KEY`, `OPENAI_API_KEY`, or
/// `CODEX_ACCESS_TOKEN`) is currently active. The persistent store *was*
/// updated; the caller is warned that the running process will still see the
/// env-overlay credential until the offending variable is unset.
public struct LoginShadowedByEnvError: Error, Sendable, Equatable,
    CustomStringConvertible {
    /// Operation that was attempted while the overlay was active.
    public enum Operation: String, Sendable {
        case loginWithAPIKey
        case loginWithExternalChatGPTTokens
        case logout
    }
    public let operation: Operation
    /// Which env var is shadowing. Diagnostic only.
    public let shadowingVar: String

    public init(operation: Operation, shadowingVar: String) {
        self.operation = operation
        self.shadowingVar = shadowingVar
    }

    public var description: String {
        "auth: \(operation.rawValue) succeeded but is shadowed by "
            + "\(shadowingVar); unset it for the change to take effect"
    }

    /// Probe which env var (if any) is currently shadowing. Matches the
    /// same precedence as `EnvAuth.loadFromEnv`.
    public static func shadowingVar(env: [String: String]) -> String? {
        if let v = env["CODEX_API_KEY"], !v.isEmpty { return "CODEX_API_KEY" }
        if let v = env["OPENAI_API_KEY"], !v.isEmpty { return "OPENAI_API_KEY" }
        if let v = env["CODEX_ACCESS_TOKEN"], !v.isEmpty {
            return "CODEX_ACCESS_TOKEN"
        }
        return nil
    }
}
