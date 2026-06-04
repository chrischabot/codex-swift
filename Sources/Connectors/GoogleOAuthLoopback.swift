import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The ephemeral-port loopback redirect server for the installed-app PKCE flow.
// Binding 127.0.0.1:0 means there is no FIXED port another local process could
// squat to steal the auth code; the OS assigns a fresh port per flow. We accept
// exactly ONE connection (the browser redirect), validate the `state` (CSRF),
// and hand back the code.

public actor LoopbackRedirectServer {
    public let path = "/oauth2/callback"
    private var listenFD: Int32 = -1
    public private(set) var port: Int = 0

    public init() {}

    /// Bind 127.0.0.1:0 + listen; returns the redirect URI to register in the
    /// auth request (`http://127.0.0.1:<port>/oauth2/callback`).
    public func start() throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OAuthError.transport("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // loopback ONLY
        addr.sin_port = 0                                 // ephemeral port
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else { close(fd); throw OAuthError.transport("bind() failed") }
        guard listen(fd, 1) == 0 else { close(fd); throw OAuthError.transport("listen() failed") }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenFD = fd
        port = Int(UInt16(bigEndian: bound.sin_port))
        return "http://127.0.0.1:\(port)\(path)"
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    /// Wait (up to `timeoutMs`) for the browser to hit the callback; validate the
    /// state and return the code. Accepts on a detached thread so the actor (and
    /// concurrency pool) is never blocked on the syscall.
    public func awaitCallback(expectedState: String, timeoutMs: Int = 300_000) async -> Result<String, OAuthError> {
        let fd = listenFD
        let path = self.path
        guard fd >= 0 else { return .failure(.transport("server not started")) }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<String, OAuthError>, Never>) in
            let thread = Thread {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pr = poll(&pfd, 1, Int32(timeoutMs))
                if pr <= 0 { cont.resume(returning: .failure(.callbackError("timeout"))); return }
                let conn = accept(fd, nil, nil)
                if conn < 0 { cont.resume(returning: .failure(.transport("accept() failed"))); return }
                defer { close(conn) }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = read(conn, &buf, buf.count)
                let request = n > 0 ? String(decoding: buf[0..<Int(n)], as: UTF8.self) : ""
                let result = LoopbackRedirectServer.parseCallback(request, path: path, expectedState: expectedState)
                let ok = (try? result.get()) != nil
                let bodyText = ok
                    ? "Authorization complete — you may close this window and return to the terminal."
                    : "Authorization failed. Return to the terminal."
                let body = "<html><body>\(bodyText)</body></html>"
                let resp = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\n" +
                    "Content-Type: text/html; charset=utf-8\r\n" +
                    "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                let out = Array(resp.utf8)
                _ = out.withUnsafeBytes { write(conn, $0.baseAddress, out.count) }
                cont.resume(returning: result)
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// Pure callback parser (testable): extract the auth `code` from the HTTP
    /// request, after checking the path, an `error` param, and the CSRF `state`.
    static func parseCallback(_ request: String, path: String, expectedState: String) -> Result<String, OAuthError> {
        let firstLine = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return .failure(.callbackError("malformed request line")) }
        let target = String(parts[1])
        guard let comps = URLComponents(string: "http://127.0.0.1\(target)") else {
            return .failure(.callbackError("bad callback target"))
        }
        let items = comps.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let err = q("error") { return .failure(.callbackError(err)) }
        guard comps.path == path else { return .failure(.callbackError("unexpected path '\(comps.path)'")) }
        guard let state = q("state"), state == expectedState else { return .failure(.stateMismatch) }
        guard let code = q("code"), !code.isEmpty else { return .failure(.callbackError("no authorization code")) }
        return .success(code)
    }
}
