import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A minimal, dependency-free HTTP/1.1 server (POSIX sockets) that serves the
/// mem0 REST API through `Mem0RestHandler`. One request per connection
/// (`Connection: close`). This keeps the `codex-mem0` server self-contained
/// (no web-framework dependency) and unit-testable end-to-end.
///
/// `@unchecked Sendable`: the listen fd is guarded by a lock; the engine is a
/// Sendable value captured into connection handlers.
public final class Mem0HTTPServer: @unchecked Sendable {
    static let maxRequestBodyBytes = 2 * 1024 * 1024

    let engine: Mem0Engine
    private let acceptQueue = DispatchQueue(label: "mem0.http.accept")
    private let lock = NSLock()
    private var listenFD: Int32 = -1

    public init(engine: Mem0Engine) { self.engine = engine }

    /// Bind + listen on `host:port` (port 0 → an ephemeral port) and start the
    /// accept loop on a background queue. Returns the actual bound port.
    @discardableResult
    public func start(host: String = "127.0.0.1", port: UInt16 = 8080) throws -> UInt16 {
        signal(SIGPIPE, SIG_IGN)
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw Mem0Error.network("socket() failed") }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        }
        let bindRC = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else { close(fd); throw Mem0Error.network("bind() failed on \(host):\(port)") }
        guard listen(fd, 64) == 0 else { close(fd); throw Mem0Error.network("listen() failed") }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        let actualPort = UInt16(bigEndian: bound.sin_port)

        lock.lock(); listenFD = fd; lock.unlock()
        let engine = self.engine
        acceptQueue.async { [weak self] in
            while true {
                let cfd = accept(fd, nil, nil)
                if cfd < 0 {
                    if errno == EINTR { continue }
                    break  // listen socket closed by stop()
                }
                guard self != nil else { close(cfd); break }
                DispatchQueue.global().async {
                    Mem0HTTPServer.handle(cfd, engine: engine)
                }
            }
        }
        return actualPort
    }

    /// Stop accepting connections (closes the listen socket).
    public func stop() {
        lock.lock(); let fd = listenFD; listenFD = -1; lock.unlock()
        if fd >= 0 { close(fd) }
    }

    deinit { stop() }

    // MARK: - connection handling

    private final class ResultBox<T>: @unchecked Sendable {
        private var value: T?
        private let lock = NSLock()
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Run an async operation to completion from a synchronous (socket) thread.
    private static func runBlocking<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task { box.set(await op()); sem.signal() }
        sem.wait()
        return box.get()!
    }

    private typealias ParsedRequest = (method: String, path: String, query: [String: String], body: Data?)

    private enum RequestReadResult {
        case request(ParsedRequest)
        case badRequest
        case payloadTooLarge
    }

    private static func handle(_ cfd: Int32, engine: Mem0Engine) {
        defer { close(cfd) }
        let parsed: ParsedRequest
        switch readRequest(cfd) {
        case .request(let request):
            parsed = request
        case .payloadTooLarge:
            writeResponse(cfd, status: 413, body: Data(#"{"error":"payload too large"}"#.utf8))
            return
        case .badRequest:
            writeResponse(cfd, status: 400, body: Data(#"{"error":"bad request"}"#.utf8))
            return
        }
        let resp = runBlocking {
            await Mem0RestHandler.handle(method: parsed.method, path: parsed.path,
                                         query: parsed.query, body: parsed.body, engine: engine)
        }
        writeResponse(cfd, status: resp.status, body: resp.body)
    }

    private static func urlDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    private static func readRequest(_ fd: Int32) -> RequestReadResult {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Int? = nil
        while headerEnd == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return .badRequest }
            buffer.append(contentsOf: chunk[0..<n])
            if let r = buffer.range(of: sep) { headerEnd = r.lowerBound }
            if buffer.count > (1 << 20) { return .badRequest }
        }
        let headerData = buffer.subdata(in: 0..<headerEnd!)
        let bodyStart = headerEnd! + 4
        var body = bodyStart <= buffer.count ? buffer.subdata(in: bodyStart..<buffer.count) : Data()
        if body.count > maxRequestBodyBytes { return .payloadTooLarge }
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return .badRequest }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .badRequest }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .badRequest }
        let method = String(parts[0])
        let rawTarget = String(parts[1])

        var path = rawTarget
        var query: [String: String] = [:]
        if let q = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<q])
            let qs = String(rawTarget[rawTarget.index(after: q)...])
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = urlDecode(String(kv[0]))
                let v = kv.count > 1 ? urlDecode(String(kv[1])) : ""
                if !k.isEmpty { query[k] = v }
            }
        }

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        if contentLength > maxRequestBodyBytes { return .payloadTooLarge }
        while body.count < contentLength {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
            if body.count > maxRequestBodyBytes { return .payloadTooLarge }
        }
        if body.count < contentLength { return .badRequest }
        return .request((method, path, query, body.isEmpty ? nil : body))
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }

    private static func writeResponse(_ fd: Int32, status: Int, body: Data) {
        let head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < out.count {
                let n = send(fd, base + sent, out.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
