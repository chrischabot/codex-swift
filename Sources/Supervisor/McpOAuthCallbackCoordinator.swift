import Foundation
import InfraPrimitives
import MCP
import ProtocolModel

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private struct McpOAuthPendingLogin: Sendable {
    let name: String
    let tokenEndpoint: String
    let verifier: String
    let timeout: Double
    let store: McpOAuthStore
    let notify: @Sendable (Bool, String?) async -> Void
}

public actor McpOAuthCallbackCoordinator {
    public static let shared = McpOAuthCallbackCoordinator()

    private var pending: [String: McpOAuthPendingLogin] = [:]
    private var listener: McpOAuthCallbackListener?

    public func register(state: String,
                         name: String,
                         tokenEndpoint: String,
                         verifier: String,
                         timeout: Double,
                         store: McpOAuthStore,
                         notify: @escaping @Sendable (Bool, String?) async -> Void) throws {
        try ensureListener()
        pending[state] = McpOAuthPendingLogin(name: name,
                                              tokenEndpoint: tokenEndpoint,
                                              verifier: verifier,
                                              timeout: timeout,
                                              store: store,
                                              notify: notify)
    }

    private func ensureListener() throws {
        if listener != nil { return }
        let created = try McpOAuthCallbackListener(coordinator: self)
        created.start()
        listener = created
    }

    fileprivate func complete(state: String?, code: String?, error: String?) async
        -> (status: Int, message: String) {
        guard let state, !state.isEmpty else {
            return (400, "missing state")
        }
        guard let login = pending.removeValue(forKey: state) else {
            return (400, "unknown state")
        }
        if let error, !error.isEmpty {
            await login.notify(false, error)
            return (400, "OAuth failed: \(error)")
        }
        guard let code, !code.isEmpty else {
            await login.notify(false, "missing authorization code")
            return (400, "missing authorization code")
        }
        do {
            let tokens = try McpOAuth.exchangeAuthorizationCode(
                tokenEndpoint: login.tokenEndpoint,
                code: code,
                verifier: login.verifier,
                timeout: login.timeout)
            try login.store.save(tokens, server: login.name)
            await login.notify(true, nil)
            return (200, "MCP OAuth login completed")
        } catch {
            await login.notify(false, "\(error)")
            return (502, "OAuth token exchange failed")
        }
    }
}

private final class McpOAuthCallbackListener: @unchecked Sendable {
    private let fd: Int32
    private weak var coordinator: McpOAuthCallbackCoordinator?
    private var thread: Thread?

    init(coordinator: McpOAuthCallbackCoordinator) throws {
        self.fd = try PosixSocket.listenLoopback(port: 1455)
        self.coordinator = coordinator
    }

    deinit {
        close(fd)
    }

    func start() {
        let listenFd = fd
        let coordinator = self.coordinator
        let t = Thread {
            while true {
                let cfd = accept(listenFd, nil, nil)
                if cfd < 0 { break }
                McpOAuthCallbackListener.handle(cfd, coordinator: coordinator)
            }
        }
        t.stackSize = 1 << 20
        t.name = "ai.igent.codexkit.mcp-oauth-callback"
        t.start()
        thread = t
    }

    private static func handle(_ cfd: Int32,
                               coordinator: McpOAuthCallbackCoordinator?) {
        var acc = PosixSocket.readChunk(cfd)
        while SocketAcceptor.afterHeaderIndex(acc) == nil {
            if acc.count >= SocketAcceptor.maxHeaderBytes {
                writeHTTP(cfd, status: 431, body: "headers too large")
                return
            }
            let more = PosixSocket.readChunk(cfd)
            if more.isEmpty {
                writeHTTP(cfd, status: 400, body: "incomplete request")
                return
            }
            acc.append(contentsOf: more)
        }
        let hdrEnd = SocketAcceptor.afterHeaderIndex(acc)!
        let header = String(decoding: acc[0..<hdrEnd], as: UTF8.self)
        guard let target = SocketAcceptor.requestPath(header),
              target.hasPrefix("/mcp/oauth/callback") else {
            writeHTTP(cfd, status: 404, body: "not found")
            return
        }
        guard let coordinator else {
            writeHTTP(cfd, status: 503, body: "OAuth callback coordinator unavailable")
            return
        }
        let values = queryValues(target)
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var status = 500
            var message = "internal error"
        }
        let box = Box()
        Task {
            let result = await coordinator.complete(state: values["state"],
                                                    code: values["code"],
                                                    error: values["error"])
            box.status = result.status
            box.message = result.message
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            writeHTTP(cfd, status: 504, body: "OAuth callback timed out")
        } else {
            writeHTTP(cfd, status: box.status, body: box.message)
        }
    }

    private static func queryValues(_ target: String) -> [String: String] {
        guard let question = target.firstIndex(of: "?") else { return [:] }
        let query = target[target.index(after: question)...]
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            let key = percentDecode(parts.first.map(String.init) ?? "")
            let value = parts.count > 1 ? percentDecode(String(parts[1])) : ""
            out[key] = value
        }
        return out
    }

    private static func percentDecode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? value
    }

    private static func writeHTTP(_ fd: Int32, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 431: reason = "Request Header Fields Too Large"
        case 502: reason = "Bad Gateway"
        case 503: reason = "Service Unavailable"
        case 504: reason = "Gateway Timeout"
        default: reason = "Error"
        }
        let bytes = Array(body.utf8)
        let response = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Connection: close\r\n"
            + "Content-Length: \(bytes.count)\r\n\r\n"
        PosixSocket.writeAll(fd, Array(response.utf8) + bytes)
        close(fd)
    }
}
