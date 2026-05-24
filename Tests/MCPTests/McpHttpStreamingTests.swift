import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import InfraPrimitives
import ProtocolModel
import WireProtocol

/// Tests for the streaming HTTP transport. The previous implementation used
/// `FileHandle.readDataToEndOfFile()`, which buffered the entire SSE body
/// before parsing any frames. That defeats Streamable-HTTP's design: a real
/// server may emit a frame (typically `elicitation/create`) and then HOLD
/// the response connection open pending the client's reply. With buffered
/// reads the client never sees the first frame, never replies, and the
/// server never sends the next frame — deadlock.
///
/// These tests exercise the streaming reader:
///   * `testStreamingFramesObservedIncrementally` — the server emits a
///     notification frame, sleeps, then emits the result. The client must
///     observe the notification BEFORE the result frame arrives (proving
///     incremental delivery via the notification timestamp vs. call return
///     time).
///   * `testElicitationDeadlockCaseNowResolves` — the regression test for
///     the original deadlock: the server emits an elicitation/create
///     frame, then BLOCKS on a Condition until it sees the matching
///     reply POST on a side endpoint, only then emitting the result frame.
///     With buffered reads this would hang until the per-request timeout
///     fired; with streaming reads it completes in well under the timeout.
final class McpHttpStreamingTests: XCTestCase {

    private func tempDir(_ prefix: String) -> String {
        let d = NSTemporaryDirectory() + prefix + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: d,
                                                 withIntermediateDirectories: true)
        return d
    }

    private func python3Available() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Streams MUST deliver frames as they arrive, not after the response
    /// connection closes. We prove this by emitting a server-push
    /// notification frame, sleeping ~1s on the server side (keeping the
    /// response connection open), then emitting the actual call result.
    ///
    /// `CapturingMcpNotificationSink` records a wall-clock timestamp
    /// against each captured notification. The notification must have
    /// been observed before the call returns by at least the server-side
    /// sleep duration (with margin for scheduler jitter).
    func testStreamingFramesObservedIncrementally() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let port = try await startStubServer(scenario: "delayed_notif")
        defer { stubCleanup() }

        let sink = TimestampedSink()
        let cfg = McpServerConfig(name: "stub",
                                  url: "http://127.0.0.1:\(port)/mcp")
        let client = McpHttpClient(cfg, requestTimeout: .seconds(10),
                                   notificationSink: sink)
        try await client.start()
        try await client.initialize()
        _ = try await client.listTools()

        let callStart = Date()
        let result = try await client.callTool("slow", argumentsJSON: "{}")
        let callEnd = Date()
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "pong")
        await client.stop()

        let captured = sink.snapshot()
        let logs = captured.filter { entry in
            if case .logging = entry.notif { return true } else { return false }
        }
        XCTAssertGreaterThanOrEqual(logs.count, 1,
            "the pre-result notification must reach the sink")
        guard let firstLog = logs.first else { return }
        // Server sleeps ~1.0s between the notification and the result.
        // The notification must be observed at least ~0.5s before the
        // call returns. (Slack for CI jitter; the buffered impl would
        // have observed both at ~callEnd.)
        let gap = callEnd.timeIntervalSince(firstLog.observed)
        XCTAssertGreaterThan(gap, 0.5,
            "streaming reader must surface notifications mid-stream — " +
            "observed gap was \(gap)s (notif observed at \(firstLog.observed), " +
            "call returned at \(callEnd))")
        // And the notification must arrive AFTER the call started (sanity).
        XCTAssertGreaterThan(firstLog.observed.timeIntervalSince(callStart), -0.01)
    }

    /// REGRESSION: the canonical deadlock case for `readDataToEndOfFile()`.
    /// The server emits an `elicitation/create` frame on the response
    /// connection, then blocks the response writer until it receives the
    /// matching JSON-RPC reply POST on a separate connection. Only after
    /// the reply arrives does it emit the result frame and close.
    ///
    /// With buffered reads the client cannot see the first frame until
    /// the connection closes, but the connection won't close until the
    /// client replies — guaranteed hang. With the streaming reader the
    /// frame arrives immediately, the handler runs, the reply unblocks
    /// the server, and the result frame is delivered.
    func testElicitationDeadlockCaseNowResolves() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let port = try await startStubServer(scenario: "blocking_elicit")
        defer { stubCleanup() }

        let cfg = McpServerConfig(name: "stub",
                                  url: "http://127.0.0.1:\(port)/mcp")
        // Use a 6s request timeout — comfortably more than the natural
        // protocol round-trip but well below an unbounded wait. The
        // buggy (buffered) impl would hit this timeout; the streaming
        // impl must complete in well under it.
        let client = McpHttpClient(cfg, requestTimeout: .seconds(6))
        try await client.start()
        try await client.initialize()
        _ = try await client.listTools()

        let handler: McpElicitationHandler = { @Sendable _, _, _ in
            return .object([
                "action": .string("accept"),
                "content": .object(["answer": .string("ok")]),
                "_meta": .null,
            ])
        }
        let start = Date()
        let result = try await client.callTool("blocking_echo",
                                                argumentsJSON: "{}",
                                                elicitationHandler: handler)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "pong")
        // The buggy impl would have hung until the 6s timeout. We must
        // complete promptly — the server blocks only until the client's
        // reply lands, which is sub-second under streaming.
        XCTAssertLessThan(elapsed, 4.0,
            "streaming reader must observe the elicitation frame mid-response — " +
            "deadlock case took \(elapsed)s")
        await client.stop()
    }

    // MARK: - Sink with per-event timestamps

    /// Notification sink that records when each notification was observed
    /// (wall clock). The base `CapturingMcpNotificationSink` discards
    /// timing info, but the streaming-vs-buffered distinction is
    /// invisible without it.
    private final class TimestampedSink: McpNotificationSink, @unchecked Sendable {
        struct Entry {
            let notif: McpNotification
            let observed: Date
        }
        private let lock = NSLock()
        private var entries: [Entry] = []
        func handle(_ notification: McpNotification) {
            lock.lock(); defer { lock.unlock() }
            entries.append(Entry(notif: notification, observed: Date()))
        }
        func snapshot() -> [Entry] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    // MARK: - Test stub server

    private var stubProcess: Process?

    private func stubCleanup() {
        if let p = stubProcess, p.isRunning { p.terminate() }
        stubProcess = nil
    }

    /// Scenarios:
    ///   * `delayed_notif`    — tools/call returns SSE: notifications/message
    ///                          frame → ~1s sleep → result frame → close.
    ///                          Proves frames are observed incrementally.
    ///   * `blocking_elicit`  — tools/call returns SSE: elicitation/create
    ///                          frame, then BLOCKS the response writer on
    ///                          a `threading.Event` until the matching
    ///                          reply POST arrives, then writes the result
    ///                          and closes. Proves the streaming reader
    ///                          breaks the buffered-read deadlock.
    private func startStubServer(scenario: String) async throws -> Int {
        let dir = tempDir("mcp-stream-stub-")
        let scriptPath = dir + "/stub.py"
        let stub = """
        import sys, os, json, signal, threading, time
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        signal.signal(signal.SIGTERM, lambda *a: os._exit(0))

        _start = time.time()
        _ppid0 = os.getppid()
        def _wd():
            while True:
                if os.getppid() != _ppid0: os._exit(0)
                if time.time() - _start > 90: os._exit(0)
                time.sleep(0.2)
        threading.Thread(target=_wd, daemon=True).start()

        SCENARIO = "\(scenario)"
        # Signaled when the matching elicitation reply POST arrives. The
        # response writer for the original tools/call connection blocks
        # on this event before emitting its result frame.
        ELICIT_REPLY = threading.Event()

        class H(BaseHTTPRequestHandler):
            # HTTP/1.1 lets us keep the SSE response open without
            # Content-Length while still flushing partial bodies. The
            # streaming reader must cope with chunked transfer encoding,
            # which Python's BaseHTTPRequestHandler will use by default
            # when no Content-Length is provided.
            protocol_version = 'HTTP/1.1'
            def log_message(self, *a): pass
            def do_POST(self):
                n = int(self.headers.get('Content-Length', '0'))
                body = self.rfile.read(n) if n else b''
                try: req = json.loads(body)
                except Exception: req = {}
                method = req.get('method')
                rid = req.get('id')
                # Detect the elicitation reply (id == 9100 and no method).
                if method is None and rid == 9100:
                    ELICIT_REPLY.set()
                    out = b'{}'
                    self.send_response(202)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length', str(len(out)))
                    self.send_header('Connection','close')
                    self.end_headers()
                    self.wfile.write(out); return
                if method == 'notifications/initialized':
                    out = b'{}'
                    self.send_response(202)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length', str(len(out)))
                    self.send_header('Connection','close')
                    self.end_headers()
                    self.wfile.write(out); return
                if method == 'initialize':
                    res = {'protocolVersion':'2025-06-18','capabilities':{},
                           'serverInfo':{'name':'stub','version':'0'}}
                    out = json.dumps({'jsonrpc':'2.0','id':rid,'result':res}).encode()
                    self.send_response(200)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length', str(len(out)))
                    self.send_header('Connection','close')
                    self.end_headers()
                    self.wfile.write(out); return
                if method == 'tools/list':
                    res = {'tools':[{'name':'slow','description':'',
                                     'inputSchema':{'type':'object'}},
                                     {'name':'blocking_echo','description':'',
                                      'inputSchema':{'type':'object'}}]}
                    out = json.dumps({'jsonrpc':'2.0','id':rid,'result':res}).encode()
                    self.send_response(200)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length', str(len(out)))
                    self.send_header('Connection','close')
                    self.end_headers()
                    self.wfile.write(out); return
                if method == 'tools/call':
                    # Force chunked transfer encoding by sending no
                    # Content-Length on an HTTP/1.1 SSE response.
                    self.send_response(200)
                    self.send_header('Content-Type','text/event-stream')
                    self.send_header('Cache-Control','no-cache')
                    self.send_header('Transfer-Encoding','chunked')
                    self.send_header('Connection','close')
                    self.end_headers()
                    if SCENARIO == 'delayed_notif':
                        notif = {'jsonrpc':'2.0',
                                 'method':'notifications/message',
                                 'params':{'level':'info','logger':'srv',
                                           'data':'streaming-frame-1'}}
                        self._chunk(('data: ' + json.dumps(notif) + '\\n\\n').encode())
                        time.sleep(1.0)
                        result = {'jsonrpc':'2.0','id':rid,
                                  'result':{'content':[{'type':'text','text':'pong'}],
                                            'isError':False}}
                        self._chunk(('data: ' + json.dumps(result) + '\\n\\n').encode())
                        self._chunk_end()
                        return
                    if SCENARIO == 'blocking_elicit':
                        elicit = {'jsonrpc':'2.0','id':9100,
                                  'method':'elicitation/create',
                                  'params':{'requestedSchema':{'type':'object'}}}
                        self._chunk(('data: ' + json.dumps(elicit) + '\\n\\n').encode())
                        # Block here until the reply POST lands. With
                        # buffered reads the client cannot see the
                        # elicit frame yet, so it never sends the
                        # reply, and this wait would expire on the
                        # client-side request timeout (deadlock).
                        ok = ELICIT_REPLY.wait(timeout=8.0)
                        if not ok:
                            # Surface as an error in the SSE so the
                            # test fails informatively rather than
                            # timing out silently.
                            err = {'jsonrpc':'2.0','id':rid,
                                   'error':{'code':-1,
                                            'message':'reply wait timed out'}}
                            self._chunk(('data: ' + json.dumps(err) + '\\n\\n').encode())
                            self._chunk_end()
                            return
                        result = {'jsonrpc':'2.0','id':rid,
                                  'result':{'content':[{'type':'text','text':'pong'}],
                                            'isError':False}}
                        self._chunk(('data: ' + json.dumps(result) + '\\n\\n').encode())
                        self._chunk_end()
                        return

            def _chunk(self, payload):
                # Write one chunk in HTTP/1.1 chunked transfer encoding
                # and flush immediately so the client observes it now.
                size = ('%x\\r\\n' % len(payload)).encode()
                self.wfile.write(size + payload + b'\\r\\n')
                self.wfile.flush()
            def _chunk_end(self):
                self.wfile.write(b'0\\r\\n\\r\\n')
                self.wfile.flush()

        # ThreadingHTTPServer so the elicitation reply POST is handled
        # concurrently with the still-open tools/call response.
        s = ThreadingHTTPServer(('127.0.0.1', 0), H)
        print(s.server_address[1]); sys.stdout.flush()
        s.serve_forever()
        """
        try Data(stub.utf8).write(to: URL(fileURLWithPath: scriptPath))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", scriptPath]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        try p.run()
        stubProcess = p
        let outHandle = outPipe.fileHandleForReading
        let port: Int? = await withCheckedContinuation {
            (cont: CheckedContinuation<Int?, Never>) in
            final class Once: @unchecked Sendable {
                private let l = NSLock(); private var done = false
                func go() -> Bool {
                    l.lock(); defer { l.unlock() }
                    if done { return false }; done = true; return true
                }
            }
            let once = Once()
            let reader = Thread {
                var acc = Data()
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    let chunk = outHandle.availableData
                    if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05); continue }
                    acc.append(chunk)
                    if let str = String(data: acc, encoding: .utf8),
                       let nl = str.firstIndex(of: "\n") {
                        let parsed = Int(String(str[str.startIndex..<nl])
                            .trimmingCharacters(in: .whitespacesAndNewlines))
                        if once.go() { cont.resume(returning: parsed) }
                        return
                    }
                }
                if once.go() { cont.resume(returning: nil) }
            }
            reader.stackSize = 1 << 20
            reader.name = "ai.igent.codexkit.test.mcphttp.stream.port"
            reader.start()
            let wd = Thread {
                Thread.sleep(forTimeInterval: 12)
                if once.go() { cont.resume(returning: nil) }
            }
            wd.start()
        }
        guard let port, port > 0 else {
            throw NSError(domain: "test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "stub port"])
        }
        return port
    }
}
