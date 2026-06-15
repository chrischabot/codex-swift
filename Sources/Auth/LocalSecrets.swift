#if canImport(CryptoKit)
import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// Port of upstream's encrypted local secrets store (`codex-rs/secrets`,
/// #27535/#27539/#27541): secrets are held in a namespaced JSON file encrypted
/// at rest with a high-entropy symmetric key kept in the OS keyring (macOS
/// Keychain). CLI auth and MCP OAuth tokens move out of plaintext into this
/// store.
///
/// **Documented divergence (matches the existing keychain-interop divergence,
/// audit-v10):** upstream encrypts the file with `age` (passphrase mode); the
/// port uses CryptoKit `AES.GCM` with a 256-bit Keychain-held key. The file is
/// **port-private** (never shared with the upstream CLI, exactly like the port's
/// keychain auth entry), so byte-format interop is a non-goal — the security
/// property (encrypted-at-rest, key in the OS keyring, AEAD tamper detection) is
/// preserved. macOS-native (`#if canImport(CryptoKit)`), consistent with the
/// port's other OS-gated surfaces.
public enum SecretsNamespace: String, Sendable, CaseIterable {
    case managed, codexAuth, mcpOAuth
    var filename: String {
        switch self {
        case .managed:  return "secrets.json.enc"
        case .codexAuth: return "codex-auth.secrets.json.enc"
        case .mcpOAuth: return "mcp-oauth.secrets.json.enc"
        }
    }
}

/// Scope a secret is filed under. Mirrors upstream `SecretScope`
/// (global vs per-environment).
public enum SecretScope: Sendable, Equatable, Hashable {
    case global
    case environment(String)

    // Unit-separator (U+001F) — cannot appear in a normal name/id — delimits the
    // canonical key so parsing is unambiguous.
    private static let sep = "\u{1f}"

    public func canonicalKey(_ name: String) -> String {
        switch self {
        case .global:           return "global" + Self.sep + name
        case .environment(let id): return "env" + Self.sep + id + Self.sep + name
        }
    }
    static func parse(_ key: String) -> (scope: SecretScope, name: String)? {
        let parts = key.components(separatedBy: sep)
        switch parts.first {
        case "global" where parts.count == 2: return (.global, parts[1])
        case "env" where parts.count == 3:     return (.environment(parts[1]), parts[2])
        default: return nil
        }
    }
}

public struct SecretListEntry: Sendable, Equatable {
    public let scope: SecretScope
    public let name: String
    public init(scope: SecretScope, name: String) { self.scope = scope; self.name = name }
}

public enum SecretsError: Error, Equatable {
    case keygen
    case seal
    case versionTooNew(Int)
    case invalidName(String)
    case lock
}

/// Supplies the 256-bit symmetric key, persisting it on first use. Injectable so
/// tests run without touching the real Keychain.
public protocol SecretsKeyProvider: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

#if DEBUG
/// In-memory key provider for tests ONLY (deterministic, no Keychain). Gated to
/// DEBUG so it cannot be wired into a release production code path, which would
/// defeat the "key in the OS keyring" at-rest guarantee.
public final class InMemorySecretsKeyProvider: SecretsKeyProvider, @unchecked Sendable {
    private let key: SymmetricKey
    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) { self.key = key }
    public func loadOrCreateKey() throws -> SymmetricKey { key }
}
#endif

#if canImport(Security)
/// Keychain-backed key provider. The 256-bit key lives in the macOS Keychain
/// under a dedicated service, keyed per `CODEX_HOME` (reusing the auth store's
/// `cli|<sha256-prefix>` account derivation).
public struct KeychainSecretsKeyProvider: SecretsKeyProvider {
    public static let service = "Codex Secrets"
    let account: String
    public init(codexHome: String) {
        self.account = KeychainTokenStore.storeKey(codexHome: codexHome)
    }
    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }
    public func loadOrCreateKey() throws -> SymmetricKey {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        // Generate a fresh 256-bit key and persist it.
        var bytes = Data(count: 32)
        let rc = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard rc == errSecSuccess else { throw SecretsError.keygen }
        // Zero the transient key buffer after the SymmetricKey copy + Keychain
        // write, narrowing the memory-scrape / core-dump exposure window.
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        var add = baseQuery()
        add[kSecValueData as String] = bytes
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Lost a race — load the now-present key.
            return try loadOrCreateKey()
        }
        guard addStatus == errSecSuccess else { throw SecretsError.keygen }
        return SymmetricKey(data: bytes)
    }
}
#endif

/// Local encrypted secrets backend for one namespace. Mirrors upstream
/// `LocalSecretsBackend` (set/get/delete/list over `SecretScope`).
public struct LocalSecretsBackend: Sendable {
    static let version = 1
    let codexHome: String
    let namespace: SecretsNamespace
    let keyProvider: any SecretsKeyProvider

    public init(codexHome: String, namespace: SecretsNamespace,
                keyProvider: any SecretsKeyProvider) {
        self.codexHome = codexHome
        self.namespace = namespace
        self.keyProvider = keyProvider
    }

    private struct SecretsFile: Codable {
        var version: Int
        var secrets: [String: String]
    }

    private func secretsDir() -> String { codexHome + "/secrets" }
    private func secretsPath() -> String { secretsDir() + "/" + namespace.filename }

    private func loadFile() throws -> SecretsFile {
        let p = secretsPath()
        guard FileManager.default.fileExists(atPath: p) else {
            return SecretsFile(version: Self.version, secrets: [:])
        }
        let cipher = try Data(contentsOf: URL(fileURLWithPath: p))
        let key = try keyProvider.loadOrCreateKey()
        let box = try AES.GCM.SealedBox(combined: cipher)
        let plain = try AES.GCM.open(box, using: key)   // throws on tamper/wrong key
        var f = try JSONDecoder().decode(SecretsFile.self, from: plain)
        if f.version == 0 { f.version = Self.version }
        guard f.version <= Self.version else { throw SecretsError.versionTooNew(f.version) }
        return f
    }

    private func saveFile(_ f: SecretsFile) throws {
        let dir = secretsDir()
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Authoritative: tighten the dir even when it pre-existed with a looser umask.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let key = try keyProvider.loadOrCreateKey()
        let plain = try JSONEncoder().encode(f)
        let sealed = try AES.GCM.seal(plain, using: key)   // fresh random nonce per seal
        guard let combined = sealed.combined else { throw SecretsError.seal }
        try writeAtomically(secretsPath(), combined)
    }

    private func writeAtomically(_ path: String, _ data: Data) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/." + (path as NSString).lastPathComponent
            + ".tmp-\(ProcessInfo.processInfo.processIdentifier)-\(UInt64(bitPattern: Int64(Date().timeIntervalSince1970 * 1e6)))"
        // Create the temp with mode 0600 ATOMICALLY (O_EXCL) — no window where it
        // exists with the umask default, and collision-safe against the name.
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw SecretsError.seal }
        var ok = false
        defer { if !ok { unlink(tmp) } }
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n < 0 { close(fd); throw SecretsError.seal }
                off += n
            }
        }
        close(fd)
        // Replace destination atomically.
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        } else {
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
        }
        ok = true
        // Authoritative final-file perms — replaceItemAt may derive perms from the
        // umask, so this must succeed, not be best-effort.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public func set(_ scope: SecretScope, _ name: String, _ value: String) throws {
        try validate(scope, name)
        // Exclusive advisory lock over the whole read-modify-write so two
        // backends (CLI auth + daemon MCP refresh) on the same file cannot
        // lost-update each other's credentials.
        try withExclusiveLock {
            var f = try loadFile()
            f.secrets[scope.canonicalKey(name)] = value
            try saveFile(f)
        }
    }
    public func get(_ scope: SecretScope, _ name: String) throws -> String? {
        try validate(scope, name)
        // Reads need no lock: writeAtomically swaps the inode via rename, so a
        // reader always sees a complete old-or-new file.
        return try loadFile().secrets[scope.canonicalKey(name)]
    }
    @discardableResult
    public func delete(_ scope: SecretScope, _ name: String) throws -> Bool {
        try validate(scope, name)
        return try withExclusiveLock {
            var f = try loadFile()
            let removed = f.secrets.removeValue(forKey: scope.canonicalKey(name)) != nil
            if removed { try saveFile(f) }
            return removed
        }
    }
    public func list(_ filter: SecretScope? = nil) throws -> [SecretListEntry] {
        try loadFile().secrets.keys.compactMap { SecretScope.parse($0) }.compactMap { parsed in
            if let filter, filter != parsed.scope { return nil }
            return SecretListEntry(scope: parsed.scope, name: parsed.name)
        }
    }

    /// Every component concatenated into a canonical key (the scope id AND the
    /// name) must be a valid component — non-empty, no control chars, and no
    /// unit-separator delimiter — so a crafted environment id cannot inject the
    /// delimiter to collide / shadow / orphan another scope's key. Upstream
    /// `SecretName::new` enforces the same at the name boundary; the port also
    /// guards the environment id.
    private func validate(_ scope: SecretScope, _ name: String) throws {
        if case .environment(let id) = scope, !isValidComponent(id) {
            throw SecretsError.invalidName(id)
        }
        guard isValidComponent(name) else { throw SecretsError.invalidName(name) }
    }
    private func isValidComponent(_ s: String) -> Bool {
        !s.isEmpty && !s.unicodeScalars.contains { $0.value < 0x20 || $0 == "\u{1f}" }
    }

    /// Exclusive advisory file lock (flock) over a per-namespace lock file,
    /// serializing the read-modify-write across processes (the port's idiom for
    /// cross-process file safety).
    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let dir = secretsDir()
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // createDirectory only chmods dirs it CREATES; tighten a pre-existing one.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let lockPath = dir + "/." + namespace.filename + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw SecretsError.lock }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SecretsError.lock }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Build the production CLI-auth backend (Keychain-held key, `codexAuth`
    /// namespace). Used by `EncryptedSecretsTokenStore`.
    public static func codexAuth(codexHome: String) -> LocalSecretsBackend {
        production(codexHome: codexHome, namespace: .codexAuth)
    }
    /// Build the production MCP-OAuth backend (`mcpOAuth` namespace, #27541).
    public static func mcpOAuth(codexHome: String) -> LocalSecretsBackend {
        production(codexHome: codexHome, namespace: .mcpOAuth)
    }
    private static func production(codexHome: String, namespace: SecretsNamespace) -> LocalSecretsBackend {
        #if canImport(Security)
        return LocalSecretsBackend(codexHome: codexHome, namespace: namespace,
                                   keyProvider: KeychainSecretsKeyProvider(codexHome: codexHome))
        #else
        fatalError("LocalSecretsBackend requires the Keychain (macOS)")
        #endif
    }
}

/// `TokenStore` that persists the serialized `AuthDotJson` payload into the
/// encrypted local secrets file (`codexAuth` namespace) instead of the OS
/// keyring directly. Port of upstream's `AuthKeyringBackendKind::Secrets`
/// (#27504/#27539): the auth payload lives in the AES-GCM file, the file key in
/// the Keychain. Compose with `MigratingTokenStore` to read-fall-back from a
/// legacy direct-keychain entry.
public struct EncryptedSecretsTokenStore: TokenStore {
    static let scope: SecretScope = .global
    static let name = "auth"
    let backend: LocalSecretsBackend

    public init(codexHome: String) {
        self.backend = LocalSecretsBackend.codexAuth(codexHome: codexHome)
    }
    /// Test seam: inject a backend (e.g. an in-memory-keyed one).
    public init(backend: LocalSecretsBackend) { self.backend = backend }

    public func load() -> AuthTokens? {
        guard let json = try? backend.get(Self.scope, Self.name),
              let dj = try? AuthDotJson.decode(Data(json.utf8)) else { return nil }
        return AuthTokens.fromAuthDotJson(dj)
    }
    public func save(_ tokens: AuthTokens) throws {
        let data = try tokens.toAuthDotJson().encode()
        try backend.set(Self.scope, Self.name, String(decoding: data, as: UTF8.self))
    }
    public func clear() throws {
        _ = try backend.delete(Self.scope, Self.name)
    }
}
#endif
