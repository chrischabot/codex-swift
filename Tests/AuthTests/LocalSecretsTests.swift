#if canImport(CryptoKit)
import XCTest
import Foundation
import CryptoKit
@testable import Auth

final class LocalSecretsTests: XCTestCase {
    private func tmpHome() -> String {
        let p = NSTemporaryDirectory() + "secrets-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private func backend(_ home: String, _ ns: SecretsNamespace,
                         key: SymmetricKey) -> LocalSecretsBackend {
        LocalSecretsBackend(codexHome: home, namespace: ns,
                            keyProvider: InMemorySecretsKeyProvider(key: key))
    }

    func testRoundTripSetGetDeleteList() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let b = backend(home, .codexAuth, key: SymmetricKey(size: .bits256))
        try b.set(.global, "OPENAI_API_KEY", "sk-abc123")
        XCTAssertEqual(try b.get(.global, "OPENAI_API_KEY"), "sk-abc123")
        try b.set(.environment("proj1"), "TOKEN", "t-1")
        XCTAssertEqual(try b.get(.environment("proj1"), "TOKEN"), "t-1")
        // list returns both, parsed back to scope+name.
        XCTAssertTrue(try b.list().contains { $0.scope == .global && $0.name == "OPENAI_API_KEY" })
        XCTAssertTrue(try b.list().contains { $0.scope == .environment("proj1") && $0.name == "TOKEN" })
        // delete
        XCTAssertTrue(try b.delete(.global, "OPENAI_API_KEY"))
        XCTAssertNil(try b.get(.global, "OPENAI_API_KEY"))
        XCTAssertFalse(try b.delete(.global, "OPENAI_API_KEY"), "second delete → false")
        // scoped list filter
        XCTAssertEqual(try b.list(.environment("proj1")).count, 1)
        XCTAssertEqual(try b.list(.global).count, 0)
    }

    func testFileIsEncryptedAtRest() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let b = backend(home, .codexAuth, key: SymmetricKey(size: .bits256))
        try b.set(.global, "SECRET", "PLAINTEXT_NEEDLE_42")
        let path = home + "/secrets/codex-auth.secrets.json.enc"
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("PLAINTEXT_NEEDLE_42"),
                       "the secret value must NOT appear in the on-disk ciphertext")
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("SECRET"),
                       "the canonical key must not be plaintext either")
        // 0600 perms.
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWrongKeyCannotDecrypt() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        try backend(home, .codexAuth, key: SymmetricKey(size: .bits256))
            .set(.global, "K", "v")
        // A backend with a DIFFERENT key cannot open the AES-GCM box.
        let other = backend(home, .codexAuth, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try other.get(.global, "K"),
                             "decryption with the wrong key must fail (AEAD)")
    }

    func testTamperedCiphertextIsRejected() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let key = SymmetricKey(size: .bits256)
        try backend(home, .codexAuth, key: key).set(.global, "K", "v")
        let path = home + "/secrets/codex-auth.secrets.json.enc"
        var raw = try Data(contentsOf: URL(fileURLWithPath: path))
        raw[raw.count - 1] ^= 0xFF   // flip a ciphertext/tag byte
        try raw.write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try backend(home, .codexAuth, key: key).get(.global, "K"),
                             "a tampered ciphertext must fail authentication")
    }

    func testNamespaceIsolation() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let key = SymmetricKey(size: .bits256)
        try backend(home, .codexAuth, key: key).set(.global, "K", "auth-val")
        try backend(home, .mcpOAuth, key: key).set(.global, "K", "mcp-val")
        XCTAssertEqual(try backend(home, .codexAuth, key: key).get(.global, "K"), "auth-val")
        XCTAssertEqual(try backend(home, .mcpOAuth, key: key).get(.global, "K"), "mcp-val")
        // Separate files on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/secrets/codex-auth.secrets.json.enc"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/secrets/mcp-oauth.secrets.json.enc"))
    }

    func testAtomicOverwriteLastWriteWins() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let key = SymmetricKey(size: .bits256)
        let b = backend(home, .codexAuth, key: key)
        try b.set(.global, "K", "v1")
        try b.set(.global, "K", "v2")
        XCTAssertEqual(try b.get(.global, "K"), "v2")
        XCTAssertEqual(try b.list().count, 1, "overwrite does not duplicate the key")
    }

    func testInvalidNameRejected() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let b = backend(home, .codexAuth, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try b.set(.global, "", "v"))
        XCTAssertThrowsError(try b.set(.global, "bad\u{1f}name", "v"))
        XCTAssertThrowsError(try b.set(.global, "ctrl\u{01}char", "v"))
    }

    func testEnvironmentIdDelimiterRejected() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let b = backend(home, .codexAuth, key: SymmetricKey(size: .bits256))
        // A crafted environment id cannot inject the canonical-key delimiter to
        // collide / shadow / orphan another scope's key.
        XCTAssertThrowsError(try b.set(.environment("bad\u{1f}id"), "n", "v"))
        XCTAssertThrowsError(try b.get(.environment("x\u{1f}y"), "n"))
        XCTAssertThrowsError(try b.delete(.environment(""), "n"))
        XCTAssertThrowsError(try b.set(.environment("ctrl\u{01}"), "n", "v"))
        // A clean id is fine.
        try b.set(.environment("prod"), "n", "v")
        XCTAssertEqual(try b.get(.environment("prod"), "n"), "v")
    }

    func testConcurrentSetsAllPersistNoLostUpdate() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let key = SymmetricKey(size: .bits256)
        // 20 concurrent backends each appending a distinct key to the SAME file.
        // The exclusive flock must serialize the read-modify-write so none are
        // lost (without it, concurrent writers clobber each other).
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<20 {
                g.addTask {
                    let b = LocalSecretsBackend(
                        codexHome: home, namespace: .codexAuth,
                        keyProvider: InMemorySecretsKeyProvider(key: key))
                    try? b.set(.global, "k\(i)", "v\(i)")
                }
            }
        }
        let b = backend(home, .codexAuth, key: key)
        XCTAssertEqual(try b.list().count, 20, "flock prevents lost updates under concurrency")
    }

    func testScopeCanonicalKeyRoundTrips() {
        XCTAssertEqual(SecretScope.parse(SecretScope.global.canonicalKey("n"))?.scope, .global)
        XCTAssertEqual(SecretScope.parse(SecretScope.environment("e").canonicalKey("n"))?.scope,
                       .environment("e"))
        XCTAssertEqual(SecretScope.parse(SecretScope.environment("e").canonicalKey("n"))?.name, "n")
    }
}
#endif
