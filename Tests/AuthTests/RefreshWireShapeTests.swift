import XCTest
import Foundation
@testable import Auth

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Finding 2: ChatGPT OAuth token refresh must be sent as a JSON request body
/// (`Content-Type: application/json`,
/// `{"client_id":..,"grant_type":"refresh_token","refresh_token":..}`),
/// mirroring upstream `request_chatgpt_token_refresh`
/// (codex-rs/login/src/auth/manager.rs:815-834). The authorization_code
/// exchange stays form-encoded.
final class RefreshWireShapeTests: XCTestCase {

    /// Minimal single-shot loopback HTTP server. Captures the first request's
    /// raw bytes and replies with a fixed token JSON, then closes.
    private final class CaptureServer: @unchecked Sendable {
        let port: UInt16
        private let listenFd: Int32
        private let captured = NSMutableData()
        private let lock = NSLock()
        private var done = false

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw NSError(domain: "sock", code: 1) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                       socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0  // ephemeral
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    #if canImport(Darwin)
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    #else
                    Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    #endif
                }
            }
            guard bound == 0, listen(fd, 1) == 0 else {
                close(fd); throw NSError(domain: "bind", code: 2)
            }
            var name = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &name) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            self.port = UInt16(bigEndian: name.sin_port)
            self.listenFd = fd
            start()
        }

        private func start() {
            let fd = listenFd
            Thread.detachNewThread { [weak self] in
                let cfd = accept(fd, nil, nil)
                guard cfd >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = read(cfd, &buf, buf.count)
                if n > 0 {
                    self?.lock.lock()
                    self?.captured.append(buf, length: n)
                    self?.done = true
                    self?.lock.unlock()
                }
                let body = "{\"access_token\":\"new-access\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                _ = resp.withCString { write(cfd, $0, strlen($0)) }
                close(cfd)
                close(fd)
            }
        }

        func capturedRequest(timeout: TimeInterval = 5) -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                lock.lock(); let d = done; lock.unlock()
                if d { break }
                usleep(20_000)
            }
            lock.lock(); defer { lock.unlock() }
            guard done else { return nil }
            return String(decoding: captured as Data, as: UTF8.self)
        }
    }

    func testRefreshSendsJSONBody() async throws {
        let server = try CaptureServer()
        let cfg = OAuthConfig(issuer: "http://127.0.0.1:\(server.port)",
                              clientId: "test-client")
        let exchanger = CurlTokenExchanger()
        let result = await exchanger.refresh(refreshToken: "rt-123", cfg: cfg)

        guard let raw = server.capturedRequest() else {
            return XCTFail("server did not capture the refresh request")
        }

        // Request line + headers.
        XCTAssertTrue(raw.hasPrefix("POST /oauth/token "),
                      "expected POST to /oauth/token, got:\n\(raw)")
        XCTAssertTrue(
            raw.range(of: "content-type: application/json",
                      options: .caseInsensitive) != nil,
            "expected application/json Content-Type, got:\n\(raw)")
        XCTAssertNil(
            raw.range(of: "x-www-form-urlencoded", options: .caseInsensitive),
            "refresh must not be form-encoded:\n\(raw)")

        // Body is JSON with the upstream field set.
        let bodyStart = raw.range(of: "\r\n\r\n")
        let body = bodyStart.map { String(raw[$0.upperBound...]) } ?? ""
        let data = Data(body.utf8)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "refresh body must be valid JSON, got: \(body)")
        XCTAssertEqual(obj["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(obj["refresh_token"] as? String, "rt-123")
        XCTAssertEqual(obj["client_id"] as? String, "test-client")

        // The exchanger should have parsed the 200 token response.
        switch result {
        case .success(let tokens):
            XCTAssertEqual(tokens.accessToken, "new-access")
            // Issuer omitted the rotated refresh token → old one is kept.
            XCTAssertEqual(tokens.refreshToken, "rt-123")
        case .failure(let err):
            XCTFail("refresh should succeed, got \(err)")
        }
    }
}
