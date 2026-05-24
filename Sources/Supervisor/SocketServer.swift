import Foundation
import WireProtocol
import InfraPrimitives

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - SHA-1 (WebSocket accept key only)

/// Minimal SHA-1 (RFC 3174) — needed solely for the RFC 6455 handshake
/// `Sec-WebSocket-Accept`. Not used for anything security-sensitive.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
        var msg = message
        let ml = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((ml >> (UInt64(i) * 8)) & 0xff)) }
        func rol(_ x: UInt32, _ c: UInt32) -> UInt32 { (x << c) | (x >> (32 - c)) }
        var i = 0
        while i < msg.count {
            var w = [UInt32](repeating: 0, count: 80)
            for j in 0..<16 {
                let b = i + j * 4
                w[j] = (UInt32(msg[b]) << 24) | (UInt32(msg[b + 1]) << 16)
                    | (UInt32(msg[b + 2]) << 8) | UInt32(msg[b + 3])
            }
            for j in 16..<80 { w[j] = rol(w[j-3] ^ w[j-8] ^ w[j-14] ^ w[j-16], 1) }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for j in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch j {
                case 0..<20:  f = (b & c) | (~b & d);          k = 0x5A827999
                case 20..<40: f = b ^ c ^ d;                   k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default:      f = b ^ c ^ d;                   k = 0xCA62C1D6
                }
                let t = rol(a, 5) &+ f &+ e &+ k &+ w[j]
                e = d; d = c; c = rol(b, 30); b = a; a = t
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
            i += 64
        }
        var out = [UInt8]()
        for v in [h0, h1, h2, h3, h4] {
            out.append(UInt8((v >> 24) & 0xff)); out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 8) & 0xff));  out.append(UInt8(v & 0xff))
        }
        return out
    }
}

/// RFC 6455 §4.2.2 accept-key derivation.
public enum WebSocketHandshake {
    public static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    public static func acceptKey(for clientKey: String) -> String {
        Data(SHA1.hash(Array((clientKey + magicGUID).utf8))).base64EncodedString()
    }
}

/// pthread-mutex write gate. Unlike `NSLock`, this is callable from **both**
/// an `async` function and a synchronous `Thread` body (no Swift-6
/// async-context unavailability annotation); the critical section never
/// suspends so it is safe on the cooperative pool.
final class WriteGate: @unchecked Sendable {
    private let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    init() { pthread_mutex_init(m, nil) }
    deinit { pthread_mutex_destroy(m); m.deallocate() }
    func withLock(_ body: () -> Void) {
        pthread_mutex_lock(m); defer { pthread_mutex_unlock(m) }
        body()
    }
}

// MARK: - RFC 6455 frame codec (pure / testable)

public enum WSOpcode: UInt8, Sendable {
    case continuation = 0x0, text = 0x1, binary = 0x2
    case close = 0x8, ping = 0x9, pong = 0xA
}

public enum WSFrameCodec {
    /// Encode a server→client frame (never masked, single final frame).
    public static func encode(opcode: WSOpcode, payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x80 | opcode.rawValue]
        let n = payload.count
        if n < 126 {
            out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out.append(126)
            out.append(UInt8((n >> 8) & 0xff)); out.append(UInt8(n & 0xff))
        } else {
            out.append(127)
            for s in (0..<8).reversed() { out.append(UInt8((n >> (s * 8)) & 0xff)) }
        }
        out.append(contentsOf: payload)
        return out
    }

    public struct Frame: Sendable, Equatable {
        public let fin: Bool
        public let opcode: WSOpcode
        public let payload: [UInt8]
    }

    /// Decode result: a complete frame (+ bytes consumed), need-more-bytes,
    /// or a protocol error (unknown opcode / unmasked client frame) — the
    /// caller closes the connection deterministically on `.invalid`.
    public enum DecodeResult: Sendable, Equatable {
        case frame(Frame, Int)
        case incomplete
        case invalid
    }

    public static func decode(_ buf: [UInt8]) -> DecodeResult {
        guard buf.count >= 2 else { return .incomplete }
        let fin = (buf[0] & 0x80) != 0
        guard let op = WSOpcode(rawValue: buf[0] & 0x0F) else { return .invalid }
        let masked = (buf[1] & 0x80) != 0
        var len = Int(buf[1] & 0x7F)
        var off = 2
        if len == 126 {
            guard buf.count >= 4 else { return .incomplete }
            len = (Int(buf[2]) << 8) | Int(buf[3]); off = 4
        } else if len == 127 {
            guard buf.count >= 10 else { return .incomplete }
            len = 0
            for i in 0..<8 { len = (len << 8) | Int(buf[2 + i]) }
            off = 10
        }
        guard masked else { return .invalid }       // RFC 6455 §5.1: client must mask
        guard buf.count >= off + 4 + len else { return .incomplete }
        let mask = Array(buf[off..<off + 4]); off += 4
        var payload = [UInt8](repeating: 0, count: len)
        for i in 0..<len { payload[i] = buf[off + i] ^ mask[i % 4] }
        return .frame(Frame(fin: fin, opcode: op, payload: payload), off + len)
    }
}

// MARK: - low-level POSIX socket helpers

enum PosixSocket {
    static func disableSigpipe(_ fd: Int32) {
        #if canImport(Darwin)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func listenLoopback(port: UInt16) throws -> Int32 {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SocketError.create(errno) }
        disableSigpipe(fd)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian   // 127.0.0.1
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw SocketError.bind(errno) }
        guard listen(fd, 16) == 0 else { close(fd); throw SocketError.listen(errno) }
        return fd
    }

    static func listenUnix(path: String) throws -> Int32 {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard chmod(parent, 0o700) == 0 else { throw SocketError.chmod(errno) }
        } catch let error as SocketError {
            throw error
        } catch {
            throw SocketError.preparePath(path)
        }

        var st = stat()
        if lstat(path, &st) == 0 {
            let kind = st.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFSOCK) else { throw SocketError.pathExists(path) }
            guard unlink(path) == 0 else { throw SocketError.unlink(errno) }
        } else if errno != ENOENT {
            throw SocketError.stat(errno)
        }

        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SocketError.create(errno) }
        disableSigpipe(fd)

        do {
            try withUnixSockaddr(path: path) { sa, len in
                let oldMask = umask(0o177)
                let rc = bind(fd, sa, len)
                _ = umask(oldMask)
                guard rc == 0 else { close(fd); throw SocketError.bind(errno) }
            }
        } catch {
            close(fd)
            throw error
        }
        guard chmod(path, 0o600) == 0 else {
            close(fd)
            _ = unlink(path)
            throw SocketError.chmod(errno)
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            _ = unlink(path)
            throw SocketError.listen(errno)
        }
        return fd
    }

    static func connectUnix(path: String) throws -> Int32 {
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SocketError.create(errno) }
        disableSigpipe(fd)
        var tv = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        do {
            try withUnixSockaddr(path: path) { sa, len in
                guard connect(fd, sa, len) == 0 else {
                    close(fd)
                    throw SocketError.connect(errno)
                }
            }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    static func withUnixSockaddr<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var addr = sockaddr_un()
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count + 1 <= maxPath else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: pathBytes)
        }
        return try withUnsafePointer(to: &addr) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func boundPort(_ fd: Int32) -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    static func readChunk(_ fd: Int32, _ max: Int = 65536) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, max, 0) }
        if n <= 0 { return [] }
        return Array(buf[0..<n])
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var off = 0
        bytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while off < bytes.count {
                #if canImport(Glibc)
                let flags = Int32(MSG_NOSIGNAL)
                #else
                let flags = Int32(0)
                #endif
                let n = send(fd, base + off, bytes.count - off, flags)
                if n <= 0 { break }
                off += n
            }
        }
    }
}

public enum SocketError: Error, Sendable {
    case create(Int32), bind(Int32), listen(Int32), connect(Int32)
    case preparePath(String), pathTooLong(String), pathExists(String)
    case stat(Int32), unlink(Int32), chmod(Int32)
}

// MARK: - per-connection ClientConnection adapters

/// Newline-delimited JSON-RPC over a raw TCP socket (the portable analog of
/// Codex's plain `ws://` data path without WS framing).
final class RawSocketConnection: ClientConnection, @unchecked Sendable {
    private let fd: Int32
    private let codec: WireCodec
    private let inStream: AsyncStream<JSONRPCMessage>
    private let inCont: AsyncStream<JSONRPCMessage>.Continuation
    private let gate = WriteGate()

    init(fd: Int32, limits: Limits, prebuffered: [UInt8]) {
        self.fd = fd
        self.codec = WireCodec(limits: limits.clamped())
        (inStream, inCont) = AsyncStream<JSONRPCMessage>.makeStream()
        let codec = self.codec
        let cont = self.inCont
        let thread = Thread {
            var buffer = Data(prebuffered)
            func drainFrames() {
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if line.isEmpty { continue }
                    if let m = try? codec.decode(line) { cont.yield(m) }
                }
            }
            drainFrames()
            while true {
                let chunk = PosixSocket.readChunk(fd)
                if chunk.isEmpty { break }
                buffer.append(contentsOf: chunk)
                drainFrames()
            }
            cont.finish()
        }
        thread.stackSize = 1 << 20
        thread.name = "ai.igent.codexkit.tcpconn"
        thread.start()
    }

    func incoming() -> AsyncStream<JSONRPCMessage> { inStream }

    func send(_ message: JSONRPCMessage) async {
        guard var data = try? codec.encode(message) else { return }
        data.append(0x0A)
        let bytes = Array(data)
        gate.withLock { PosixSocket.writeAll(fd, bytes) }
    }
}

/// RFC 6455 WebSocket carrying one JSON-RPC message per text frame (Codex
/// `ws://` parity). Handshake is performed by `SocketListener`; this owns the
/// post-upgrade frame loop. A protocol-invalid client frame triggers a Close
/// and terminates the connection deterministically.
final class WebSocketConnection: ClientConnection, @unchecked Sendable {
    private let fd: Int32
    private let codec: WireCodec
    private let inStream: AsyncStream<JSONRPCMessage>
    private let inCont: AsyncStream<JSONRPCMessage>.Continuation
    private let gate = WriteGate()

    init(fd: Int32, limits: Limits, leftover: [UInt8]) {
        self.fd = fd
        self.codec = WireCodec(limits: limits.clamped())
        (inStream, inCont) = AsyncStream<JSONRPCMessage>.makeStream()
        let codec = self.codec
        let cont = self.inCont
        let wl = self.gate
        let thread = Thread {
            var buf = leftover
            var assembling: [UInt8] = []
            func handleText(_ payload: [UInt8]) {
                if let m = try? codec.decode(Data(payload)) { cont.yield(m) }
            }
            func closeAndEnd() {
                wl.withLock {
                    PosixSocket.writeAll(fd, WSFrameCodec.encode(opcode: .close, payload: []))
                }
            }
            loop: while true {
                inner: while true {
                    switch WSFrameCodec.decode(buf) {
                    case .frame(let frame, let used):
                        buf.removeFirst(used)
                        switch frame.opcode {
                        case .text, .binary, .continuation:
                            assembling.append(contentsOf: frame.payload)
                            if frame.fin {
                                handleText(assembling); assembling.removeAll()
                            }
                        case .ping:
                            wl.withLock {
                                PosixSocket.writeAll(fd, WSFrameCodec.encode(
                                    opcode: .pong, payload: frame.payload))
                            }
                        case .pong:
                            continue inner
                        case .close:
                            closeAndEnd(); break loop
                        }
                    case .incomplete:
                        break inner               // need more bytes
                    case .invalid:
                        closeAndEnd(); break loop  // deterministic protocol-error close
                    }
                }
                let chunk = PosixSocket.readChunk(fd)
                if chunk.isEmpty { break }
                buf.append(contentsOf: chunk)
            }
            cont.finish()
        }
        thread.stackSize = 1 << 20
        thread.name = "ai.igent.codexkit.wsconn"
        thread.start()
    }

    func incoming() -> AsyncStream<JSONRPCMessage> { inStream }

    func send(_ message: JSONRPCMessage) async {
        guard let data = try? codec.encode(message) else { return }
        let frame = WSFrameCodec.encode(opcode: .text, payload: Array(data))
        gate.withLock { PosixSocket.writeAll(fd, frame) }
    }
}

/// Loopback acceptor. Each accepted connection is sniffed: an HTTP request
/// (starts with a method token) is read in full up to the `CRLFCRLF`
/// terminator (bounded) and, if it carries `Upgrade: websocket`, gets the
/// RFC 6455 handshake then a `WebSocketConnection`; otherwise the bytes are
/// treated as newline-delimited JSON-RPC (`RawSocketConnection`). Binds
/// 127.0.0.1 only (no non-loopback exposure → no auth needed, the safe Codex
/// default).
public final class SocketListener: @unchecked Sendable {
    private let fd: Int32
    public let port: UInt16
    private let limits: Limits
    private var acceptThread: Thread?
    private static let maxHeaderBytes = 16 * 1024

    public init(port: UInt16 = 0, limits: Limits = Limits()) throws {
        self.fd = try PosixSocket.listenLoopback(port: port)
        self.port = PosixSocket.boundPort(fd)
        self.limits = limits
    }

    /// Begin accepting. `handler` is invoked once per connection with a
    /// ready `ClientConnection`.
    public func start(_ handler: @escaping @Sendable (any ClientConnection) -> Void) {
        let listenFd = fd
        let limits = self.limits
        let t = Thread {
            while true {
                let cfd = accept(listenFd, nil, nil)
                if cfd < 0 { break }
                PosixSocket.disableSigpipe(cfd)
                SocketAcceptor.spawnAccepted(cfd, limits, handler,
                                             name: "ai.igent.codexkit.client")
            }
        }
        t.stackSize = 1 << 20
        t.name = "ai.igent.codexkit.accept"
        t.start()
        acceptThread = t
    }

    /// Read the first bytes; if it looks like an HTTP request, accumulate
    /// until the header terminator (bounded) before deciding WS-vs-JSONL.
    public func stop() { close(fd) }

    /// Index just past `CRLFCRLF`, or nil if the terminator is not yet present.
    static func afterHeaderIndex(_ bytes: [UInt8]) -> Int? {
        SocketAcceptor.afterHeaderIndex(bytes)
    }

    static func headerValue(_ header: String, _ name: String) -> String? {
        SocketAcceptor.headerValue(header, name)
    }

    static func requestPath(_ header: String) -> String? {
        SocketAcceptor.requestPath(header)
    }
}

/// Unix-domain socket listener for local app control. It intentionally reuses
/// the same JSONL/WebSocket acceptor as the loopback TCP transport so protocol
/// behavior cannot drift between local transports.
public final class UnixSocketListener: @unchecked Sendable {
    private let fd: Int32
    public let path: String
    private let limits: Limits
    private var acceptThread: Thread?

    public init(path: String, limits: Limits = Limits()) throws {
        self.path = path
        self.fd = try PosixSocket.listenUnix(path: path)
        self.limits = limits
    }

    public func start(_ handler: @escaping @Sendable (any ClientConnection) -> Void) {
        let listenFd = fd
        let limits = self.limits
        let t = Thread {
            while true {
                let cfd = accept(listenFd, nil, nil)
                if cfd < 0 { break }
                PosixSocket.disableSigpipe(cfd)
                SocketAcceptor.spawnAccepted(cfd, limits, handler,
                                             name: "ai.igent.codexkit.udsclient")
            }
        }
        t.stackSize = 1 << 20
        t.name = "ai.igent.codexkit.udsaccept"
        t.start()
        acceptThread = t
    }

    public func stop() {
        close(fd)
        _ = unlink(path)
    }
}

enum SocketAcceptor {
    static let maxHeaderBytes = 16 * 1024

    static func spawnAccepted(
        _ cfd: Int32, _ limits: Limits,
        _ handler: @escaping @Sendable (any ClientConnection) -> Void,
        name: String) {
        let t = Thread {
            handleAccepted(cfd, limits, handler)
        }
        t.stackSize = 1 << 20
        t.name = name
        t.start()
    }

    static func handleAccepted(
        _ cfd: Int32, _ limits: Limits,
        _ handler: @escaping @Sendable (any ClientConnection) -> Void) {
        var acc = PosixSocket.readChunk(cfd)
        if acc.isEmpty { close(cfd); return }
        let looksHTTP = String(decoding: acc.prefix(8), as: UTF8.self)
            .uppercased().hasPrefix("GET ")
        if !looksHTTP {
            handler(RawSocketConnection(fd: cfd, limits: limits, prebuffered: acc))
            return
        }
        // Accumulate the full request header (CRLFCRLF), bounded.
        while afterHeaderIndex(acc) == nil {
            if acc.count >= maxHeaderBytes { close(cfd); return }
            let more = PosixSocket.readChunk(cfd)
            if more.isEmpty { close(cfd); return }
            acc.append(contentsOf: more)
            if acc.count >= maxHeaderBytes, afterHeaderIndex(acc) == nil {
                close(cfd); return
            }
        }
        let hdrEnd = afterHeaderIndex(acc)!
        let header = String(decoding: acc[0..<hdrEnd], as: UTF8.self)
        let leftover = Array(acc[hdrEnd...])
        let path = requestPath(header)
        if path == "/readyz" || path == "/healthz" {
            let body = #"{"status":"ok"}"#
            let resp = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + "Connection: close\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n"
                + body
            PosixSocket.writeAll(cfd, Array(resp.utf8))
            close(cfd)
            return
        }
        if headerValue(header, "origin") != nil {
            let resp = "HTTP/1.1 403 Forbidden\r\n"
                + "Connection: close\r\nContent-Length: 0\r\n\r\n"
            PosixSocket.writeAll(cfd, Array(resp.utf8))
            close(cfd)
            return
        }
        if header.lowercased().contains("upgrade: websocket"),
           let key = headerValue(header, "sec-websocket-key") {
            let accept = WebSocketHandshake.acceptKey(for: key)
            let resp = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            PosixSocket.writeAll(cfd, Array(resp.utf8))
            handler(WebSocketConnection(fd: cfd, limits: limits, leftover: leftover))
        } else {
            // A non-upgrade HTTP request on the JSON-RPC port: reject cleanly.
            let resp = "HTTP/1.1 426 Upgrade Required\r\n"
                + "Connection: close\r\nContent-Length: 0\r\n\r\n"
            PosixSocket.writeAll(cfd, Array(resp.utf8))
            close(cfd)
        }
    }

    /// Index just past `CRLFCRLF`, or nil if the terminator is not yet present.
    static func afterHeaderIndex(_ bytes: [UInt8]) -> Int? {
        let sep: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where Array(bytes[i..<i+4]) == sep {
            return i + 4
        }
        return nil
    }

    static func headerValue(_ header: String, _ name: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func requestPath(_ header: String) -> String? {
        guard let first = header.split(separator: "\r\n").first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }
}
