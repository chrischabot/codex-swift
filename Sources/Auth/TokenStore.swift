import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if os(macOS)
import Security
#endif

public protocol TokenStore: Sendable {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens) throws
    func clear() throws
}

/// `$CODEX_HOME/auth.json`, mode 0600. Crash-safe atomic write. This is the
/// portable default outside macOS and the explicit development/test fallback
/// on macOS when `CODEXKIT_AUTH_STORE=file` is set.
public struct FileTokenStore: TokenStore {
    public let path: String
    public init(codexHome: String) {
        self.path = codexHome + "/auth.json"
        try? FileManager.default.createDirectory(
            atPath: codexHome, withIntermediateDirectories: true)
    }

    public func load() -> AuthTokens? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // Primary: the interoperable upstream `auth.json` schema
        // (OPENAI_API_KEY / tokens{id_token,access_token,refresh_token,
        // account_id} / last_refresh). Bearer expiry is derived from the
        // id_token JWT `exp` claim (matching upstream). Fallback: the legacy
        // flat `AuthTokens` shape older codex-swift builds wrote.
        if let dj = try? AuthDotJson.decode(data), let t = AuthTokens.fromAuthDotJson(dj) {
            return t
        }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    public func save(_ tokens: AuthTokens) throws {
        // Write the interoperable upstream `AuthDotJson` schema so the file is
        // readable by the real codex CLI. Expiry is intentionally not persisted
        // (upstream re-derives it from the id_token JWT on load).
        let data = try tokens.toAuthDotJson().encode()
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        // Tighten perms to owner-only (credentials at rest).
        chmod(path, 0o600)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}

/// Where Codex stores CLI auth credentials. Mirrors upstream
/// `AuthCredentialsStoreMode` (config/src/types.rs:86-98), including its
/// `serde(rename_all = "lowercase")` wire spellings and `#[default] File`.
public enum AuthCredentialsStoreMode: String, Sendable, CaseIterable {
    /// Persist credentials in `CODEX_HOME/auth.json`.
    case file
    /// Persist credentials in the keyring (Keychain on macOS). Fail if
    /// unavailable.
    case keyring
    /// Use the keyring when available; otherwise fall back to a file in
    /// `CODEX_HOME`.
    case auto
    /// Store credentials in memory only for the current process.
    case ephemeral

    /// Upstream's `#[default]` is `File` (config/src/types.rs:89).
    public static let `default`: AuthCredentialsStoreMode = .file

    /// Parse the `cli_auth_credentials_store` config value. Unknown/absent
    /// values fall back to the upstream default (`File`), matching
    /// `cfg.cli_auth_credentials_store.unwrap_or_default()`
    /// (core/src/config/mod.rs:3308).
    public static func parse(_ raw: String?) -> AuthCredentialsStoreMode {
        guard let raw, let mode = AuthCredentialsStoreMode(rawValue: raw.lowercased()) else {
            return .default
        }
        return mode
    }
}

/// `Auto` storage: keyring-primary with a file fallback. Mirrors upstream
/// `AutoAuthStorage` (login/src/auth/storage.rs:265-291): reads prefer the
/// keyring and fall back to the file; writes prefer the keyring and fall back
/// to the file on failure. Crucially, a successful keyring write does NOT
/// delete the file — upstream only deletes on `delete()`, never silently after
/// a keyring save.
public struct AutoTokenStore: TokenStore {
    public let keyring: any TokenStore
    public let file: any TokenStore

    public init(keyring: any TokenStore, file: any TokenStore) {
        self.keyring = keyring
        self.file = file
    }

    public func load() -> AuthTokens? {
        if let tokens = keyring.load() { return tokens }
        return file.load()
    }

    public func save(_ tokens: AuthTokens) throws {
        do {
            try keyring.save(tokens)
        } catch {
            // Keyring unavailable: fall back to file storage.
            try file.save(tokens)
        }
    }

    public func clear() throws {
        // Delete from both backends (upstream's keyring delete also clears the
        // disk copy; we clear both explicitly for the same end state).
        var firstError: (any Error)?
        do { try keyring.clear() } catch { firstError = error }
        do { try file.clear() } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }
}

/// In-memory token store: credentials live only for the current process and are
/// never written to disk or the keyring. Mirrors upstream
/// `EphemeralAuthStorage` (login/src/auth/storage.rs:294-339).
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?

    public init() {}

    public func load() -> AuthTokens? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: AuthTokens) throws {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}

/// Wraps a production token store with a one-time migration from a legacy
/// fallback store. Legacy tokens are never used silently: if migration to the
/// primary store fails, `load` returns nil so production auth fails closed.
///
/// Used only when a deliberate, one-shot migration is requested (e.g. the
/// `CODEXKIT_AUTH_STORE=keyring-migrate` dev escape hatch). The default
/// production path no longer migrates+deletes `auth.json`, because that broke
/// credential interop with the official codex CLI (which defaults to File mode)
/// on a shared `CODEX_HOME`.
public struct MigratingTokenStore: TokenStore {
    public let primary: any TokenStore
    public let legacy: any TokenStore

    public init(primary: any TokenStore, legacy: any TokenStore) {
        self.primary = primary
        self.legacy = legacy
    }

    public func load() -> AuthTokens? {
        if let tokens = primary.load() { return tokens }
        guard let legacyTokens = legacy.load() else { return nil }
        do {
            try primary.save(legacyTokens)
            try legacy.clear()
            return primary.load() ?? legacyTokens
        } catch {
            return nil
        }
    }

    public func save(_ tokens: AuthTokens) throws {
        try primary.save(tokens)
        try legacy.clear()
    }

    public func clear() throws {
        var firstError: (any Error)?
        do { try primary.clear() } catch { firstError = error }
        do { try legacy.clear() } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }
}

#if os(macOS)
/// macOS Keychain-backed store. Production macOS builds use this instead of
/// `FileTokenStore`; the file store remains the portable/test fallback.
///
/// Interoperable with the official Codex CLI keyring
/// (`login/src/auth/storage.rs`): the keychain entry uses the service name
/// `"Codex Auth"` (`KEYRING_SERVICE`), keys each credential per `codexHome`
/// via `cli|<first16 hex of sha256(canonical codexHome)>`
/// (`compute_store_key`), and serializes the full `AuthDotJson` JSON
/// (`serde_json::to_string(auth)`) rather than the flat runtime `AuthTokens`.
/// Credentials written by the real CLI keyring on the same machine are
/// therefore readable here and vice versa.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String

    /// Upstream `KEYRING_SERVICE`.
    public static let defaultService = "Codex Auth"

    /// Mirrors `compute_store_key` (storage.rs:163-174): canonicalize the
    /// codex_home path (falling back to the raw path when it can't be
    /// resolved), SHA-256 the UTF-8 bytes, lowercase-hex it, and take the
    /// first 16 hex chars prefixed with `cli|`.
    public static func storeKey(codexHome: String) -> String {
        // `canonicalize().unwrap_or(path)`: resolve symlinks when possible,
        // otherwise hash the path as given.
        let canonical = URL(fileURLWithPath: codexHome)
            .resolvingSymlinksInPath().path
        let hex = SHA256.hexDigest(canonical)
        let truncated = String(hex.prefix(16))
        return "cli|\(truncated)"
    }

    public init(service: String = KeychainTokenStore.defaultService,
                account: String? = nil, codexHome: String) {
        self.service = service
        self.account = account ?? KeychainTokenStore.storeKey(codexHome: codexHome)
    }

    public func load() -> AuthTokens? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        // Upstream stores the serialized AuthDotJson; project it back into the
        // flat runtime AuthTokens. Tolerate a legacy flat-AuthTokens payload
        // (older codex-swift builds) so existing keychain entries still load.
        if let dotJson = try? AuthDotJson.decode(data),
           let tokens = AuthTokens.fromAuthDotJson(dotJson) {
            return tokens
        }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    public func save(_ tokens: AuthTokens) throws {
        // Serialize the full AuthDotJson (matching upstream
        // `serde_json::to_string(auth)`), not the flat AuthTokens.
        let data = try tokens.toAuthDotJson().encode()

        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updated = SecItemUpdate(baseQuery() as CFDictionary,
                                        update as CFDictionary)
            if updated == errSecSuccess { return }
            throw AuthError.transport("keychain update failed: \(updated)")
        }
        throw AuthError.transport("keychain save failed: \(status)")
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw AuthError.transport("keychain clear failed: \(status)")
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
#endif

public enum TokenStoreFactory {
    /// Build the production token store for a given credential store mode.
    ///
    /// Mirrors upstream `create_auth_storage` (login/src/auth/storage.rs:336-357):
    ///   - `.file`      → `auth.json` only (the upstream default; this is what
    ///                    the official codex CLI reads by default, so it keeps
    ///                    credential interop intact on a shared `CODEX_HOME`).
    ///   - `.keyring`   → Keychain only (fails closed if the keychain is
    ///                    unavailable).
    ///   - `.auto`      → keyring-primary with a file fallback that does NOT
    ///                    delete `auth.json` on a keyring success.
    ///   - `.ephemeral` → in-memory only.
    ///
    /// `mode` defaults to `.file` (upstream `#[default]`). Callers that have a
    /// loaded config should pass the resolved
    /// `cli_auth_credentials_store` value; callers without a config (e.g.
    /// codex-broker) get the upstream default.
    ///
    /// On non-macOS platforms there is no Keychain, so `.keyring`/`.auto`
    /// degrade to the file store (the only durable backend available).
    public static func production(
        codexHome: String,
        mode: AuthCredentialsStoreMode = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainService: String = KeychainTokenStore.defaultService,
        keychainAccount: String? = nil) -> any TokenStore {
        // Dev/test escape hatches. `=file` forces the on-disk store regardless
        // of configured mode; `=keyring-migrate` opts into the legacy
        // one-shot migrate-and-delete behaviour for tooling that explicitly
        // wants it.
        let envOverride = environment["CODEXKIT_AUTH_STORE"]
        if envOverride == "file" {
            return FileTokenStore(codexHome: codexHome)
        }

        #if os(macOS)
        let fileStore = FileTokenStore(codexHome: codexHome)
        func keychain() -> KeychainTokenStore {
            KeychainTokenStore(service: keychainService,
                               account: keychainAccount,
                               codexHome: codexHome)
        }
        if envOverride == "keyring-migrate" {
            return MigratingTokenStore(primary: keychain(), legacy: fileStore)
        }
        switch mode {
        case .file:
            return fileStore
        case .keyring:
            return keychain()
        case .auto:
            return AutoTokenStore(keyring: keychain(), file: fileStore)
        case .ephemeral:
            return InMemoryTokenStore()
        }
        #else
        switch mode {
        case .ephemeral:
            return InMemoryTokenStore()
        case .file, .keyring, .auto:
            // No keychain off macOS; the file store is the only durable backend.
            return FileTokenStore(codexHome: codexHome)
        }
        #endif
    }
}
