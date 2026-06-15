#if canImport(CryptoKit)
import XCTest
import Foundation
import CryptoKit
@testable import MCP
@testable import Auth

/// P5a MCP-OAuth integration (#27541): MCP OAuth tokens persisted in the
/// encrypted secrets file (`mcpOAuth` namespace) instead of plaintext per-server
/// JSON.
final class McpOAuthEncryptedTests: XCTestCase {
    private func tmpHome() -> String {
        let p = NSTemporaryDirectory() + "mcp-oauth-enc-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testEncryptedRoundTripAndAtRest() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let backend = LocalSecretsBackend(codexHome: home, namespace: .mcpOAuth,
                                          keyProvider: InMemorySecretsKeyProvider())
        let store = McpOAuthStore(codexHome: home, secrets: backend)

        let tokens = StoredOAuthTokens(accessToken: "mcp-tok-SECRET", refreshToken: "rt",
                                       tokenType: "Bearer", expiresAtEpoch: 9_999_999_999)
        try store.save(tokens, server: "https://mcp.example.com/sse")
        let loaded = store.load(server: "https://mcp.example.com/sse")
        XCTAssertEqual(loaded?.accessToken, "mcp-tok-SECRET")
        XCTAssertEqual(loaded?.refreshToken, "rt")

        // Persisted in the mcpOAuth secrets file, encrypted; NOT as plaintext JSON.
        let encPath = home + "/secrets/mcp-oauth.secrets.json.enc"
        XCTAssertTrue(FileManager.default.fileExists(atPath: encPath))
        let raw = try Data(contentsOf: URL(fileURLWithPath: encPath))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("mcp-tok-SECRET"))
        // The legacy plaintext per-server file must NOT exist.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home + "/.mcp-oauth/https___mcp.example.com_sse.json"))

        // Per-server isolation + delete.
        try store.save(StoredOAuthTokens(accessToken: "other"), server: "srv2")
        XCTAssertEqual(store.load(server: "srv2")?.accessToken, "other")
        store.delete(server: "https://mcp.example.com/sse")
        XCTAssertNil(store.load(server: "https://mcp.example.com/sse"))
        XCTAssertEqual(store.load(server: "srv2")?.accessToken, "other", "delete is per-server")
    }

    func testPlaintextDefaultUnchanged() throws {
        // Without an injected secrets backend, the store keeps the legacy plaintext
        // path (no behavior change for existing callers).
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = McpOAuthStore(codexHome: home)
        try store.save(StoredOAuthTokens(accessToken: "plain"), server: "srv")
        XCTAssertEqual(store.load(server: "srv")?.accessToken, "plain")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.mcp-oauth/srv.json"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home + "/secrets/mcp-oauth.secrets.json.enc"))
    }
}
#endif
