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
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    public func save(_ tokens: AuthTokens) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(tokens)
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

/// Wraps a production token store with a one-time migration from a legacy
/// fallback store. Legacy tokens are never used silently: if migration to the
/// primary store fails, `load` returns nil so production auth fails closed.
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
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String
    public init(service: String = "ai.igent.codexkit",
                account: String = "default", codexHome: String) {
        self.service = service
        self.account = account
    }

    public func load() -> AuthTokens? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    public func save(_ tokens: AuthTokens) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(tokens)

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
    public static func production(
        codexHome: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainService: String = "ai.igent.codexkit",
        keychainAccount: String = "default") -> any TokenStore {
        #if os(macOS)
        let fileStore = FileTokenStore(codexHome: codexHome)
        if environment["CODEXKIT_AUTH_STORE"] == "file" {
            return fileStore
        }
        return MigratingTokenStore(
            primary: KeychainTokenStore(service: keychainService,
                                        account: keychainAccount,
                                        codexHome: codexHome),
            legacy: fileStore)
        #else
        return FileTokenStore(codexHome: codexHome)
        #endif
    }
}
