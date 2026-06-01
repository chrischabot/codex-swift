import XCTest
import Foundation
@testable import Supervisor

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Covers the `codex_streamlined_login` flag threading (audit unit "auth").
///
/// Upstream: `app-server-protocol/src/protocol/v2/account.rs` carries
/// `codex_streamlined_login: bool`; `account_processor.rs:320-329` threads it
/// into the login server options; `login/src/server.rs:887-889` appends
/// `codex_streamlined_login=true` to the success redirect URL and
/// `server.rs:407-410` selects the streamlined success page body. The Swift
/// callback server collapses the redirect into a single response, so the flag
/// selects the success body it serves.
final class ChatGPTStreamlinedLoginTests: XCTestCase {
    func testSuccessResponseDefaultIsLegacyBody() {
        let legacy = ChatGPTLoginCallbackResponse.success(streamlined: false)
        XCTAssertEqual(legacy.status, 200)
        XCTAssertEqual(legacy.body, ChatGPTLoginCallbackResponse.success.body)
    }

    func testSuccessResponseStreamlinedBodyDiffers() {
        let streamlined = ChatGPTLoginCallbackResponse.success(streamlined: true)
        XCTAssertEqual(streamlined.status, 200)
        XCTAssertNotEqual(streamlined.body, ChatGPTLoginCallbackResponse.success.body)
        XCTAssertFalse(streamlined.body.isEmpty)
    }

    func testServerStoresStreamlinedFlagDefaultFalse() throws {
        let server = try ChatGPTLoginCallbackServer(
            preferredPort: 0, fallbackPort: 0
        ) { _ in .success }
        defer { server.stop() }
        XCTAssertFalse(server.codexStreamlinedLogin)
    }

    func testServerStoresStreamlinedFlagWhenTrue() throws {
        let server = try ChatGPTLoginCallbackServer(
            preferredPort: 0, fallbackPort: 0,
            codexStreamlinedLogin: true
        ) { _ in .success }
        defer { server.stop() }
        XCTAssertTrue(server.codexStreamlinedLogin)
    }

    /// End-to-end: a streamlined server, given a handler that composes its
    /// success response from the server's stored flag, serves the streamlined
    /// body over HTTP at `/auth/callback`.
    func testStreamlinedServerServesStreamlinedBody() throws {
        final class FlagBox: @unchecked Sendable { var streamlined = false }
        let box = FlagBox()
        // Capture the flag the handler should consult; in production this comes
        // from the PendingBrowserLogin's server instance.
        box.streamlined = true
        let server = try ChatGPTLoginCallbackServer(
            preferredPort: 0, fallbackPort: 0,
            codexStreamlinedLogin: true
        ) { _ in .success(streamlined: box.streamlined) }
        defer { server.stop() }

        let body = Self.fetch(port: server.port, path: "/auth/callback?code=abc&state=xyz")
        XCTAssertNotNil(body)
        XCTAssertEqual(body, ChatGPTLoginCallbackResponse.success(streamlined: true).body)
        XCTAssertNotEqual(body, ChatGPTLoginCallbackResponse.success.body)
    }

    // MARK: - Minimal HTTP fetch helper

    private static func fetch(port: UInt16, path: String) -> String? {
        let fd = socket(AF_INET, sockStreamType, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        let reqBytes = Array(request.utf8)
        _ = reqBytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var data = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "\r\n\r\n") else { return nil }
        return String(text[range.upperBound...])
    }

    #if canImport(Darwin)
    private static let sockStreamType = SOCK_STREAM
    #else
    private static let sockStreamType = Int32(SOCK_STREAM.rawValue)
    #endif
}
