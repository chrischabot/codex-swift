import XCTest
import Foundation
@testable import Supervisor
@testable import SessionWorkerCore
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import IPC
@testable import ProtocolModel
@testable import WireProtocol
@testable import InfraPrimitives

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - POSIX loopback client helpers (file-private)

private func ssDisableSigpipe(_ fd: Int32) {
    #if canImport(Darwin)
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes,
               socklen_t(MemoryLayout<Int32>.size))
    #endif
}

private func ssConnect(_ port: UInt16) -> Int32 {
    #if canImport(Glibc)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    ssDisableSigpipe(fd)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
    var tv = timeval(tv_sec: 6, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc != 0 { close(fd); return -1 }
    return fd
}

private func ssConnectUnix(_ path: String) -> Int32 {
    do {
        return try PosixSocket.connectUnix(path: path)
    } catch {
        return -1
    }
}

private func ssShortTempRoot(_ prefix: String) -> String {
    "/tmp/\(prefix)-\(getpid())-\(UUID().uuidString.prefix(8))"
}

private func ssSend(_ fd: Int32, _ bytes: [UInt8]) {
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

private func ssRecvSome(_ fd: Int32, _ max: Int = 65536) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: max)
    let n = b.withUnsafeMutableBytes { recv(fd, $0.baseAddress, max, 0) }
    return n > 0 ? Array(b[0..<n]) : []
}

/// Read until a newline (TCP JSONL response) within the socket timeout.
private func ssRecvLine(_ fd: Int32) -> String? {
    var acc = [UInt8]()
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
        let chunk = ssRecvSome(fd)
        if chunk.isEmpty { break }
        acc.append(contentsOf: chunk)
        if let nl = acc.firstIndex(of: 0x0A) {
            return String(decoding: acc[0..<nl], as: UTF8.self)
        }
    }
    return acc.isEmpty ? nil : String(decoding: acc, as: UTF8.self)
}

private final class SSJSONLClient {
    private let fd: Int32
    private var buffer: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
    }

    func sendRaw(_ raw: String) {
        ssSend(fd, Array((raw + "\n").utf8))
    }

    func recvObject(deadline: Date = Date().addingTimeInterval(6)) -> [String: Any]? {
        while Date() < deadline {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<nl])
                buffer.removeFirst(nl + 1)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    return nil
                }
                return obj
            }
            let chunk = ssRecvSome(fd)
            if chunk.isEmpty {
                continue
            }
            buffer.append(contentsOf: chunk)
        }
        return nil
    }

    func recvUntil(timeout: TimeInterval = 10,
                   _ predicate: ([String: Any]) -> Bool) -> ([String: Any]?, [[String: Any]]) {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [[String: Any]] = []
        while Date() < deadline {
            guard let obj = recvObject(deadline: deadline) else { continue }
            seen.append(obj)
            if predicate(obj) {
                return (obj, seen)
            }
        }
        return (nil, seen)
    }
}

private func ssMessageId(_ obj: [String: Any]) -> Int? {
    if let n = obj["id"] as? NSNumber { return n.intValue }
    return obj["id"] as? Int
}

/// Mask + frame a client text payload (RFC 6455 §5.3).
private func ssClientTextFrame(_ payload: [UInt8]) -> [UInt8] {
    var f: [UInt8] = [0x81]   // FIN + text
    let n = payload.count
    if n < 126 { f.append(0x80 | UInt8(n)) }
    else { f.append(0x80 | 126); f.append(UInt8((n >> 8) & 0xff)); f.append(UInt8(n & 0xff)) }
    let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    f.append(contentsOf: mask)
    for (i, byte) in payload.enumerated() { f.append(byte ^ mask[i % 4]) }
    return f
}

/// Read a single unmasked server text frame's payload as a String.
private func ssRecvServerTextFrame(_ fd: Int32) -> String? {
    var acc = [UInt8]()
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline {
        let chunk = ssRecvSome(fd)
        if chunk.isEmpty { if acc.isEmpty { continue } } else { acc.append(contentsOf: chunk) }
        guard acc.count >= 2 else { continue }
        let op = acc[0] & 0x0F
        guard op == 0x1 || op == 0x2 else { return nil }   // expect text/binary
        var len = Int(acc[1] & 0x7F)
        var off = 2
        if len == 126 {
            guard acc.count >= 4 else { continue }
            len = (Int(acc[2]) << 8) | Int(acc[3]); off = 4
        } else if len == 127 {
            guard acc.count >= 10 else { continue }
            len = 0; for i in 0..<8 { len = (len << 8) | Int(acc[2 + i]) }; off = 10
        }
        guard acc.count >= off + len else { continue }
        return String(decoding: acc[off..<off + len], as: UTF8.self)
    }
    return nil
}

final class SocketServerTests: XCTestCase {
    private func codexdBinary() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            cwd + "/.build/debug/codexd",
            cwd + "/.build/arm64-apple-macosx/debug/codexd",
            cwd + "/.build/x86_64-unknown-linux-gnu/debug/codexd",
            cwd + "/.build/release/codexd",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: pure codec / handshake

    func testSHA1AndAcceptKeyVectors() {
        XCTAssertEqual(
            SHA1.hash(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
            "a9993e364706816aba3e25717850c26c9cd0d89d")
        // RFC 6455 §1.3 example.
        XCTAssertEqual(
            WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testWSFrameRoundTripAndErrorClasses() {
        let payload = Array("hello".utf8)
        let server = WSFrameCodec.encode(opcode: .text, payload: payload)
        XCTAssertEqual(server[0], 0x81)              // FIN+text
        XCTAssertEqual(server[1], 5)                 // unmasked len
        // A masked client frame decodes back to the original payload.
        let client = ssClientTextFrame(payload)
        guard case .frame(let f, let used) = WSFrameCodec.decode(client) else {
            return XCTFail("expected a decoded frame")
        }
        XCTAssertEqual(f.opcode, .text)
        XCTAssertTrue(f.fin)
        XCTAssertEqual(f.payload, payload)
        XCTAssertEqual(used, client.count)
        // Truncated → incomplete.
        XCTAssertEqual(WSFrameCodec.decode(Array(client.prefix(3))), .incomplete)
        XCTAssertEqual(WSFrameCodec.decode([]), .incomplete)
        // Unmasked client frame → invalid (RFC 6455 §5.1).
        XCTAssertEqual(WSFrameCodec.decode(server), .invalid)
        // Unknown opcode → invalid.
        XCTAssertEqual(WSFrameCodec.decode([0x8F, 0x80, 0, 0, 0, 0]), .invalid)
    }

    func testHeaderHelpers() {
        let hdr = "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
            + "Sec-WebSocket-Key: abc==\r\n\r\n"
        let bytes = Array(hdr.utf8)
        XCTAssertEqual(SocketListener.afterHeaderIndex(bytes), bytes.count)
        XCTAssertNil(SocketListener.afterHeaderIndex(Array("GET / HTTP/1.1\r\n".utf8)))
        XCTAssertEqual(SocketListener.headerValue(hdr, "sec-websocket-key"), "abc==")
        XCTAssertEqual(SocketListener.headerValue(hdr, "upgrade"), "websocket")
        XCTAssertNil(SocketListener.headerValue(hdr, "absent"))
        XCTAssertEqual(SocketListener.requestPath(hdr), "/ws")
    }

    // MARK: end-to-end through the real router

    private func makeRouter() throws -> (RequestRouter, String) {
        let home = NSTemporaryDirectory() + "sock-" + UUID().uuidString
        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        let model = MockModelClient(repeating: .hello("ok"), times: 16)
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link) { c in
                SessionEngine(config: c, model: model, store: store,
                              router: ToolRouter(limits: limits), limits: limits)
            }
            let t = Task { await rt.run() }
            return WorkerHandle(link: link, task: t)
        }
        let sup = SessionSupervisor(factory: factory)
        return (RequestRouter(supervisor: sup, store: store, codexHome: home), home)
    }

    private func wire(_ listener: SocketListener, _ router: RequestRouter) {
        listener.start { conn in
            Task {
                for await m in conn.incoming() { await router.handle(m, conn) }
                await router.connectionClosed(conn)
            }
        }
    }

    private func wire(_ listener: UnixSocketListener, _ router: RequestRouter) {
        listener.start { conn in
            Task {
                for await m in conn.incoming() { await router.handle(m, conn) }
                await router.connectionClosed(conn)
            }
        }
    }

    func testTCPJSONLInitializeEndToEnd() async throws {
        let (router, home) = try makeRouter()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let listener = try SocketListener()
        defer { listener.stop() }
        wire(listener, router)
        try await Task.sleep(for: .milliseconds(50))

        let fd = ssConnect(listener.port)
        XCTAssertGreaterThanOrEqual(fd, 0, "client connected")
        defer { close(fd) }
        let req = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"sock"}}}"#
        ssSend(fd, Array((req + "\n").utf8))
        let line = ssRecvLine(fd)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("\"userAgent\"") == true,
                      "TCP JSONL initialize round-trips through the router: \(line ?? "nil")")
        XCTAssertTrue(line?.contains("CodexKit/0.1 (sock)") == true)
    }

    func testWebSocketInitializeEndToEnd() async throws {
        let (router, home) = try makeRouter()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let listener = try SocketListener()
        defer { listener.stop() }
        wire(listener, router)
        try await Task.sleep(for: .milliseconds(50))

        let fd = ssConnect(listener.port)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let upgrade = "GET /ws HTTP/1.1\r\nHost: localhost\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        ssSend(fd, Array(upgrade.utf8))
        // 101 handshake with the exact accept key.
        var handshake = ""
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !handshake.contains("\r\n\r\n") {
            let c = ssRecvSome(fd)
            if c.isEmpty { break }
            handshake += String(decoding: c, as: UTF8.self)
        }
        XCTAssertTrue(handshake.contains("101 Switching Protocols"))
        XCTAssertTrue(handshake.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        // Send initialize as a masked text frame; read the server text frame.
        let req = #"{"id":7,"method":"initialize","params":{"clientInfo":{"name":"wsc"}}}"#
        ssSend(fd, ssClientTextFrame(Array(req.utf8)))
        let payload = ssRecvServerTextFrame(fd)
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.contains("\"userAgent\"") == true,
                      "WS initialize round-trips through the router: \(payload ?? "nil")")
        XCTAssertTrue(payload?.contains("CodexKit/0.1 (wsc)") == true)
    }

    func testUnixSocketJSONLInitializeEndToEnd() async throws {
        let (router, home) = try makeRouter()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let socketRoot = ssShortTempRoot("cxuds-jsonl")
        defer { try? FileManager.default.removeItem(atPath: socketRoot) }
        let socketPath = socketRoot + "/ctl.sock"
        let listener = try UnixSocketListener(path: socketPath)
        defer { listener.stop() }
        wire(listener, router)
        try await Task.sleep(for: .milliseconds(50))

        let fd = ssConnectUnix(socketPath)
        XCTAssertGreaterThanOrEqual(fd, 0, "client connected to unix socket")
        defer { close(fd) }
        let req = #"{"id":11,"method":"initialize","params":{"clientInfo":{"name":"uds-jsonl"}}}"#
        ssSend(fd, Array((req + "\n").utf8))
        let line = ssRecvLine(fd)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("\"userAgent\"") == true,
                      "UDS JSONL initialize round-trips through the router: \(line ?? "nil")")
        XCTAssertTrue(line?.contains("CodexKit/0.1 (uds-jsonl)") == true)
    }

    func testUnixSocketWebSocketInitializeEndToEnd() async throws {
        let (router, home) = try makeRouter()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let socketRoot = ssShortTempRoot("cxuds-ws")
        defer { try? FileManager.default.removeItem(atPath: socketRoot) }
        let socketPath = socketRoot + "/ctl.sock"
        let listener = try UnixSocketListener(path: socketPath)
        defer { listener.stop() }
        wire(listener, router)
        try await Task.sleep(for: .milliseconds(50))

        let fd = ssConnectUnix(socketPath)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let upgrade = "GET /ws HTTP/1.1\r\nHost: localhost\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        ssSend(fd, Array(upgrade.utf8))
        var handshake = ""
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !handshake.contains("\r\n\r\n") {
            let c = ssRecvSome(fd)
            if c.isEmpty { break }
            handshake += String(decoding: c, as: UTF8.self)
        }
        XCTAssertTrue(handshake.contains("101 Switching Protocols"))
        XCTAssertTrue(handshake.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))

        let req = #"{"id":12,"method":"initialize","params":{"clientInfo":{"name":"uds-ws"}}}"#
        ssSend(fd, ssClientTextFrame(Array(req.utf8)))
        let payload = ssRecvServerTextFrame(fd)
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.contains("\"userAgent\"") == true,
                      "UDS WS initialize round-trips through the router: \(payload ?? "nil")")
        XCTAssertTrue(payload?.contains("CodexKit/0.1 (uds-ws)") == true)
    }

    func testUnixSocketJSONLFullTurnEndToEnd() async throws {
        let (router, home) = try makeRouter()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let socketRoot = ssShortTempRoot("cxuds-turn")
        defer { try? FileManager.default.removeItem(atPath: socketRoot) }
        let socketPath = socketRoot + "/ctl.sock"
        let listener = try UnixSocketListener(path: socketPath)
        defer { listener.stop() }
        wire(listener, router)
        try await Task.sleep(for: .milliseconds(50))

        let fd = ssConnectUnix(socketPath)
        XCTAssertGreaterThanOrEqual(fd, 0, "client connected to unix socket")
        defer { close(fd) }
        let client = SSJSONLClient(fd: fd)

        client.sendRaw(#"{"id":21,"method":"initialize","params":{"clientInfo":{"name":"uds-turn"}}}"#)
        let (initResp, _) = client.recvUntil { ssMessageId($0) == 21 }
        XCTAssertNotNil(initResp)
        XCTAssertNotNil((initResp?["result"] as? [String: Any])?["userAgent"])
        client.sendRaw(#"{"method":"initialized"}"#)

        client.sendRaw(#"{"id":22,"method":"thread/start","params":{"cwd":"/work","model":"mock"}}"#)
        let (startResp, _) = client.recvUntil { ssMessageId($0) == 22 }
        guard let result = startResp?["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let threadId = thread["id"] as? String else {
            return XCTFail("UDS JSONL thread/start did not return a thread id: \(String(describing: startResp))")
        }

        client.sendRaw("""
        {"id":23,"method":"turn/start","params":{"threadId":"\(threadId)","input":[{"type":"text","text":"full turn over uds"}]}}
        """)
        let (completed, seen) = client.recvUntil(timeout: 20) {
            ($0["method"] as? String) == "turn/completed"
                && (($0["params"] as? [String: Any])?["threadId"] as? String) == threadId
        }
        XCTAssertNotNil(completed, "UDS JSONL full turn should emit turn/completed; seen=\(seen)")
        let methods = seen.compactMap { $0["method"] as? String }
        XCTAssertTrue(methods.contains("turn/started"), "UDS JSONL full turn should emit turn/started; seen=\(seen)")
        XCTAssertTrue(methods.contains("item/agentMessage/delta"),
                      "UDS JSONL full turn should stream model deltas; seen=\(seen)")
        XCTAssertTrue(methods.contains("item/completed"), "UDS JSONL full turn should complete an item; seen=\(seen)")
    }

    func testUnixSocketPermissionsAndStalePathHandling() throws {
        let home = ssShortTempRoot("cxuds-perm")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = home + "/ctl"
        let socketPath = dir + "/app.sock"
        let listener = try UnixSocketListener(path: socketPath)
        var stopped = false
        defer { if !stopped { listener.stop() } }

        let socketAttrs = try FileManager.default.attributesOfItem(atPath: socketPath)
        let socketPerms = (socketAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(socketPerms & 0o777, 0o600)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir)
        let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(dirPerms & 0o777, 0o700)

        listener.stop()
        stopped = true
        try "not a socket".write(toFile: socketPath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try UnixSocketListener(path: socketPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath),
                      "regular files at the socket path are not unlinked")

        try FileManager.default.removeItem(atPath: socketPath)
        let staleFd = try PosixSocket.listenUnix(path: socketPath)
        close(staleFd)
        let replacement = try UnixSocketListener(path: socketPath)
        replacement.stop()
    }

    func testNonUpgradeHTTPGets426() async throws {
        let (router, home) = try makeRouter()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let listener = try SocketListener()
        defer { listener.stop() }
        wire(listener, router)
        try await Task.sleep(for: .milliseconds(50))
        let fd = ssConnect(listener.port)
        defer { close(fd) }
        ssSend(fd, Array("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        var resp = ""
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !resp.contains("\r\n\r\n") {
            let c = ssRecvSome(fd)
            if c.isEmpty { break }
            resp += String(decoding: c, as: UTF8.self)
        }
        XCTAssertTrue(resp.contains("426 Upgrade Required"),
                      "a non-upgrade HTTP request on the JSON-RPC port is rejected")
    }

    func testSlowHTTPClientDoesNotBlockAcceptLoop() async throws {
        let (router, home) = try makeRouter()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let listener = try SocketListener()
        defer { listener.stop() }
        wire(listener, router)
        try await Task.sleep(for: .milliseconds(50))

        let slow = ssConnect(listener.port)
        XCTAssertGreaterThanOrEqual(slow, 0)
        defer { close(slow) }
        ssSend(slow, Array("GET /ws HTTP/1.1\r\nHost: slow\r\n".utf8))

        let healthy = ssConnect(listener.port)
        XCTAssertGreaterThanOrEqual(healthy, 0)
        defer { close(healthy) }
        let req = #"{"id":31,"method":"initialize","params":{"clientInfo":{"name":"healthy","title":"Healthy","version":"1"}}}"#
        ssSend(healthy, Array((req + "\n").utf8))
        let line = ssRecvLine(healthy)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("\"userAgent\"") == true,
                      "a healthy JSONL client initializes while another client drips HTTP headers: \(line ?? "nil")")
    }

    func testHealthAndReadyRoutes() async throws {
        let (router, home) = try makeRouter()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let listener = try SocketListener()
        defer { listener.stop() }
        wire(listener, router)
        try await Task.sleep(for: .milliseconds(50))

        for path in ["/readyz", "/healthz"] {
            let fd = ssConnect(listener.port)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { close(fd) }
            ssSend(fd, Array("GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
            var resp = ""
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline, !resp.contains(#"{"status":"ok"}"#) {
                let c = ssRecvSome(fd)
                if c.isEmpty { break }
                resp += String(decoding: c, as: UTF8.self)
            }
            XCTAssertTrue(resp.contains("200 OK"), "\(path) returned 200: \(resp)")
            XCTAssertTrue(resp.contains(#"{"status":"ok"}"#),
                          "\(path) returned health JSON: \(resp)")
        }
    }

    func testWebSocketOriginRejectedWith403() async throws {
        let (router, home) = try makeRouter()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let listener = try SocketListener()
        defer { listener.stop() }
        wire(listener, router)
        try await Task.sleep(for: .milliseconds(50))

        let fd = ssConnect(listener.port)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let upgrade = "GET /ws HTTP/1.1\r\nHost: localhost\r\n"
            + "Origin: https://evil.example\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        ssSend(fd, Array(upgrade.utf8))
        var resp = ""
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !resp.contains("\r\n\r\n") {
            let c = ssRecvSome(fd)
            if c.isEmpty { break }
            resp += String(decoding: c, as: UTF8.self)
        }
        XCTAssertTrue(resp.contains("403 Forbidden"),
                      "WebSocket requests with Origin are rejected: \(resp)")
    }

    func testCodexdRejectsNonLoopbackWebSocketListenBind() throws {
        guard let codexd = codexdBinary() else {
            throw XCTSkip("codexd binary not built at .build/*/codexd")
        }
        let home = ssShortTempRoot("cx-nonloopback")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexd)
        process.arguments = ["--listen", "ws://0.0.0.0:0"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home
        env["CODEXKIT_MOCK"] = "1"
        process.environment = env
        let stderr = Pipe()
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()
        let errorText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 2)
        XCTAssertTrue(errorText.contains("unsupported --listen ws bind: 0.0.0.0:0"),
                      "non-loopback listen must fail closed instead of exposing unauthenticated TCP: \(errorText)")
    }
}
