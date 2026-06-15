#if canImport(CryptoKit)
import XCTest
import Foundation
import CryptoKit
@testable import Auth

/// P5a integration: CLI auth persisted in the encrypted secrets file
/// (`EncryptedSecretsTokenStore`), with legacy-keychain read-fallback/migration.
final class EncryptedSecretsTokenStoreTests: XCTestCase {
    private func tmpHome() -> String {
        let p = NSTemporaryDirectory() + "enc-auth-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private func store(_ home: String, key: SymmetricKey) -> EncryptedSecretsTokenStore {
        EncryptedSecretsTokenStore(backend: LocalSecretsBackend(
            codexHome: home, namespace: .codexAuth,
            keyProvider: InMemorySecretsKeyProvider(key: key)))
    }

    func testRoundTripThroughEncryptedFile() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let s = store(home, key: SymmetricKey(size: .bits256))
        let tokens = AuthTokens(accessToken: "tok-SECRET-123", refreshToken: "rt-9",
                                expiresAtUnix: 9_999_999_999, accountId: "acct-1")
        try s.save(tokens)
        let loaded = s.load()
        XCTAssertEqual(loaded?.accessToken, "tok-SECRET-123")
        XCTAssertEqual(loaded?.refreshToken, "rt-9")
        XCTAssertEqual(loaded?.accountId, "acct-1")
        // Stored in the codexAuth secrets file, encrypted (token not in plaintext).
        let path = home + "/secrets/codex-auth.secrets.json.enc"
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("tok-SECRET-123"),
                       "the access token must not appear in plaintext on disk")
        // clear removes it.
        try s.clear()
        XCTAssertNil(s.load())
    }

    func testMigratesFromLegacyKeychain() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let primary = store(home, key: SymmetricKey(size: .bits256))
        // Legacy store already holds credentials; encrypted store is empty.
        let legacy = InMemoryTokenStore()
        try legacy.save(AuthTokens(accessToken: "legacy-tok", refreshToken: "rt",
                                   expiresAtUnix: 9_999_999_999, accountId: "a"))
        let migrating = MigratingTokenStore(primary: primary, legacy: legacy)
        // First load migrates legacy → primary and clears legacy.
        XCTAssertEqual(migrating.load()?.accessToken, "legacy-tok")
        XCTAssertEqual(primary.load()?.accessToken, "legacy-tok", "migrated into the encrypted store")
        XCTAssertNil(legacy.load(), "legacy entry cleared after migration")
    }

    func testKeyringBackendKindResolution() {
        // env wins over config; config over default; default = .keyring.
        XCTAssertEqual(AuthKeyringBackendKind.resolve(
            config: "keyring", env: ["CODEXKIT_AUTH_KEYRING_BACKEND": "secrets"]), .secrets)
        XCTAssertEqual(AuthKeyringBackendKind.resolve(config: "secrets", env: [:]), .secrets)
        XCTAssertEqual(AuthKeyringBackendKind.resolve(config: nil, env: [:]), .keyring)
        XCTAssertEqual(AuthKeyringBackendKind.resolve(config: "bogus", env: [:]), .keyring)
    }
}
#endif
