#if canImport(CryptoKit) && os(macOS)
import XCTest
import Foundation
import Security
@testable import Auth

/// Production-path validation for P5a: exercises the REAL Keychain key provider
/// (`KeychainSecretsKeyProvider`) end-to-end — a 256-bit key generated and stored
/// in the actual macOS Keychain encrypts/decrypts the on-disk secrets file. This
/// is the live production crypto path (no injected key). Uses a unique CODEX_HOME
/// so its Keychain account is distinct, and deletes the Keychain item afterward.
final class EncryptedSecretsKeychainLiveTests: XCTestCase {

    func testRealKeychainKeyRoundTrip() throws {
        let home = NSTemporaryDirectory() + "enc-kc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let account = KeychainTokenStore.storeKey(codexHome: home)
        defer {
            try? FileManager.default.removeItem(atPath: home)
            // Remove the per-test Keychain key item.
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainSecretsKeyProvider.service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }

        let store = EncryptedSecretsTokenStore(codexHome: home)   // real Keychain provider
        let tokens = AuthTokens(accessToken: "live-kc-tok", refreshToken: "rt",
                                expiresAtUnix: 9_999_999_999, accountId: "acct")
        try store.save(tokens)

        // A FRESH store instance must decrypt using the SAME key fetched from the
        // real Keychain (proving the key persisted + the AES-GCM file round-trips).
        let reopened = EncryptedSecretsTokenStore(codexHome: home)
        XCTAssertEqual(reopened.load()?.accessToken, "live-kc-tok",
                       "real-Keychain key must decrypt the on-disk secrets file")

        // The token is encrypted at rest.
        let raw = try Data(contentsOf: URL(
            fileURLWithPath: home + "/secrets/codex-auth.secrets.json.enc"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("live-kc-tok"))

        try store.clear()
        XCTAssertNil(EncryptedSecretsTokenStore(codexHome: home).load())
    }
}
#endif
