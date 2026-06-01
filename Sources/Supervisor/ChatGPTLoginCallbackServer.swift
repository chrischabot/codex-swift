import Foundation
import Auth

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct ChatGPTLoginCallbackResponse: Sendable {
    var status: Int
    var body: String

    static let success = ChatGPTLoginCallbackResponse(
        status: 200,
        body: "Sign-in complete. You can return to Codex.")

    /// Mirrors upstream `login/src/server.rs` `compose_success_url` +
    /// `/success` page selection: the post-callback success page reflects the
    /// `codex_streamlined_login` flag. Upstream redirects the browser to
    /// `/success?...&codex_streamlined_login=true` and serves the streamlined
    /// `success.html` body, versus the legacy `success_legacy.html` body when
    /// the flag is absent/false. The Swift callback server collapses the
    /// redirect into a single response, so the flag selects the body here.
    static func success(streamlined: Bool) -> ChatGPTLoginCallbackResponse {
        guard streamlined else { return .success }
        return ChatGPTLoginCallbackResponse(
            status: 200,
            body: "Signed in to Codex. You can return to Codex.")
    }

    static func failure(_ message: String, status: Int = 400) -> ChatGPTLoginCallbackResponse {
        ChatGPTLoginCallbackResponse(status: status, body: message)
    }
}

final class ChatGPTLoginCallbackServer: @unchecked Sendable {
    typealias Handler = @Sendable ([String: String]) async -> ChatGPTLoginCallbackResponse

    let port: UInt16
    /// When true, the post-callback success page uses the streamlined variant,
    /// mirroring upstream `codex_streamlined_login` (login/src/server.rs:887-889,
    /// 407-410). Threaded from `account/login/start` `codexStreamlinedLogin`.
    let codexStreamlinedLogin: Bool
    private let fd: Int32
    private let handler: Handler
    private var acceptThread: Thread?
    private let stopped = WriteGate()
    private var isStopped = false

    init(preferredPort: UInt16 = 1455, fallbackPort: UInt16 = 1457,
         codexStreamlinedLogin: Bool = false,
         handler: @escaping Handler) throws {
        do {
            self.fd = try PosixSocket.listenLoopback(port: preferredPort)
        } catch SocketError.bind where preferredPort != fallbackPort {
            self.fd = try PosixSocket.listenLoopback(port: fallbackPort)
        }
        self.port = PosixSocket.boundPort(fd)
        self.codexStreamlinedLogin = codexStreamlinedLogin
        self.handler = handler
        start()
    }

    deinit { stop() }

    func stop() {
        stopped.withLock {
            guard !isStopped else { return }
            isStopped = true
            close(fd)
        }
    }

    private func start() {
        let listenFd = fd
        let callback = handler
        let thread = Thread {
            while true {
                let cfd = accept(listenFd, nil, nil)
                if cfd < 0 { break }
                PosixSocket.disableSigpipe(cfd)
                Thread.detachNewThread {
                    Self.handle(cfd, callback: callback)
                }
            }
        }
        thread.name = "ai.igent.codexkit.chatgpt-login-callback"
        thread.start()
        acceptThread = thread
    }

    private static func handle(_ cfd: Int32, callback: @escaping Handler) {
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
        let headerEnd = SocketAcceptor.afterHeaderIndex(acc)!
        let header = String(decoding: acc[..<headerEnd], as: UTF8.self)
        guard let target = SocketAcceptor.requestPath(header),
              target.hasPrefix("/auth/callback") else {
            writeHTTP(cfd, status: 404, body: "not found")
            return
        }

        let values = queryValues(target)
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var response = ChatGPTLoginCallbackResponse.failure("internal error", status: 500)
        }
        let box = Box()
        Task {
            box.response = await callback(values)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            writeHTTP(cfd, status: 504, body: "OAuth callback timed out")
        } else {
            writeHTTP(cfd, status: box.response.status, body: box.response.body)
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
        case 500: reason = "Internal Server Error"
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
