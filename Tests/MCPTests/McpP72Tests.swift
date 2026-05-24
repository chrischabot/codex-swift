import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import InfraPrimitives
import ProtocolModel
import WireProtocol

/// P7.2 — H-47 / H-48 / H-49 parity. Covers:
///  * stdio server-push notifications no longer being silently dropped
///  * HTTP 404 session recovery (re-init + retry once, single-flight)
///  * HTTP elicitation handler now invoked when the server sends an
///    `elicitation/create` server request inline with a tools/call SSE
///    stream
final class McpP72Tests: XCTestCase {

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

    /// H-48: a stdio MCP server emitting `notifications/message` reaches
    /// the configured `McpNotificationSink`. Before the fix this frame
    /// was dropped by `handleLine` (id-gated dispatch).
    func testMcpServerPushNotificationsForwarded() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let dir = tempDir("mcp-notif-")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/server.py"
        // After `initialize` we emit one notifications/message and one
        // notifications/tools/list_changed BEFORE responding to
        // tools/list — exercising the no-id dispatch path inside the
        // ordered consumer task.
        let body = #"""
        import sys, json
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            s = line.strip()
            if not s:
                continue
            try:
                msg = json.loads(s)
            except Exception:
                continue
            m = msg.get("method"); i = msg.get("id")
            if m == "initialize":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"protocolVersion":"2025-06-18"}}), flush=True)
            elif m == "notifications/initialized":
                pass
            elif m == "tools/list":
                # server-push notification frames first (no id), then the
                # actual tools/list response with id.
                print(json.dumps({"jsonrpc":"2.0","method":"notifications/message",
                                  "params":{"level":"info","logger":"srv","data":"hello"}}), flush=True)
                print(json.dumps({"jsonrpc":"2.0","method":"notifications/tools/list_changed",
                                  "params":{}}), flush=True)
                print(json.dumps({"jsonrpc":"2.0","id":i,
                                  "result":{"tools":[]}}), flush=True)
        """#
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        let sink = CapturingMcpNotificationSink()
        let cfg = McpServerConfig(name: "notif", command: "python3", args: [script])
        let client = McpClient(cfg, requestTimeout: .seconds(10),
                               notificationSink: sink)
        try await client.start()
        try await client.initialize()
        _ = try await client.listTools()
        await client.stop()

        let captured = sink.snapshot()
        XCTAssertGreaterThanOrEqual(captured.count, 2,
            "expected at least one log + one tool-list-changed notification")
        var sawLog = false
        var sawListChanged = false
        for n in captured {
            if case .logging(let server, let level, _, let data) = n {
                XCTAssertEqual(server, "notif")
                XCTAssertEqual(level, "info")
                XCTAssertEqual(data, "hello")
                sawLog = true
            }
            if case .toolListChanged(let server) = n {
                XCTAssertEqual(server, "notif")
                sawListChanged = true
            }
        }
        XCTAssertTrue(sawLog, "notifications/message must reach the sink")
        XCTAssertTrue(sawListChanged,
            "notifications/tools/list_changed must reach the sink")
    }

    /// H-48: cancellation notifications resolve the matching pending
    /// request with an error instead of leaving the caller hanging
    /// until the request timeout fires.
    func testMcpCancelledNotificationUnblocksPendingRequest() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let dir = tempDir("mcp-cancel-")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/server.py"
        // The server accepts a tools/call, replies *only* with a
        // notifications/cancelled (referencing the call's id), and
        // never sends a real result. The client must surface this as
        // an error promptly (not wait for the per-call timeout).
        let body = #"""
        import sys, json
        while True:
            line = sys.stdin.readline()
            if not line: break
            s = line.strip()
            if not s: continue
            try: msg = json.loads(s)
            except Exception: continue
            m = msg.get("method"); i = msg.get("id")
            if m == "initialize":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"protocolVersion":"2025-06-18"}}), flush=True)
            elif m == "notifications/initialized":
                pass
            elif m == "tools/list":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"tools":[{"name":"slow","description":"","inputSchema":{"type":"object"}}]}}), flush=True)
            elif m == "tools/call":
                print(json.dumps({"jsonrpc":"2.0","method":"notifications/cancelled",
                                  "params":{"requestId":i,"reason":"user_abort"}}), flush=True)
        """#
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        let cfg = McpServerConfig(name: "cx", command: "python3", args: [script])
        // Use a long timeout to prove the cancellation unblocks BEFORE
        // the timeout would.
        let client = McpClient(cfg, requestTimeout: .seconds(30))
        try await client.start()
        try await client.initialize()
        _ = try await client.listTools()
        let start = Date()
        do {
            _ = try await client.callTool("slow", argumentsJSON: "{}")
            XCTFail("expected cancellation error")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 5,
                "cancelled notification must unblock pending request promptly")
            XCTAssertTrue("\(error)".contains("cancelled"),
                "error should mention cancellation, got \(error)")
        }
        await client.stop()
    }

    /// H-47: HTTP session recovery. The stub returns 404 on the FIRST
    /// non-initialize call (forcing a re-init) and 200 on the SECOND
    /// attempt. Asserts the client transparently retried after
    /// re-initializing.
    func testMcpHttpSessionRecoveryOn404() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let port = try await startStubServer(scenario: "recover")
        defer { stubCleanup() }

        let cfg = McpServerConfig(name: "stub",
                                  url: "http://127.0.0.1:\(port)/mcp")
        let client = McpHttpClient(cfg, requestTimeout: .seconds(8))
        try await client.start()
        try await client.initialize()
        // First tools/list: stub returns 404 once. Client must re-init
        // then retry; the second attempt succeeds with one tool.
        let tools = try await client.listTools()
        XCTAssertEqual(tools.first?.name, "echo",
            "after 404 → re-init → retry, tools/list must succeed")
        let count = await client.reinitCount
        XCTAssertEqual(count, 1, "exactly one re-initialize must have occurred")
        await client.stop()
    }

    /// H-47: when N concurrent requests all hit a 404, only ONE
    /// re-initialize is performed (the others fold into the single
    /// in-flight recovery Task). Parity with the upstream
    /// `session_recovery_lock` semaphore.
    func testMcpConcurrentRequestsShareReinit() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let port = try await startStubServer(scenario: "concurrent")
        defer { stubCleanup() }

        let cfg = McpServerConfig(name: "stub",
                                  url: "http://127.0.0.1:\(port)/mcp")
        let client = McpHttpClient(cfg, requestTimeout: .seconds(10))
        try await client.start()
        try await client.initialize()

        // Fire 5 concurrent listTools. Each first attempt returns 404
        // (until the stub has "reinitialized"); the retry returns 200.
        let results: [Bool] = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        let tools = try await client.listTools()
                        return tools.first?.name == "echo"
                    } catch { return false }
                }
            }
            var acc: [Bool] = []
            for await ok in group { acc.append(ok) }
            return acc
        }
        XCTAssertTrue(results.allSatisfy { $0 },
            "all 5 concurrent callers must observe the recovered call result")
        let count = await client.reinitCount
        XCTAssertEqual(count, 1,
            "concurrent 404 callers must share a single re-initialize")
        await client.stop()
    }

    /// H-49: HTTP elicitation. The stub responds to `tools/call` with an
    /// SSE stream containing an inline `elicitation/create` server
    /// request, then (after a brief pause) the actual tools/call
    /// result. The client must invoke `elicitationHandler` with the
    /// request's params; before the fix the handler was discarded via
    /// `_ = elicitationHandler`.
    func testMcpHttpElicitationHandlerInvoked() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let port = try await startStubServer(scenario: "elicit")
        defer { stubCleanup() }

        let cfg = McpServerConfig(name: "stub",
                                  url: "http://127.0.0.1:\(port)/mcp")
        let client = McpHttpClient(cfg, requestTimeout: .seconds(8))
        try await client.start()
        try await client.initialize()
        _ = try await client.listTools()

        let box = ElicitationCapture()
        let handler: McpElicitationHandler = { @Sendable _, server, params in
            box.record(server: server, params: params)
            return .object([
                "action": .string("accept"),
                "content": .object(["answer": .string("hello-mcp")]),
                "_meta": .null,
            ])
        }
        let result = try await client.callTool("echo", argumentsJSON: "{}",
                                                elicitationHandler: handler)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "pong")
        let captured = box.snapshot()
        XCTAssertEqual(captured.count, 1,
            "elicitation handler must be invoked exactly once")
        XCTAssertEqual(captured.first?.server, "stub")
    }

    /// P7.2 follow-up: when `elicitationHandler` is nil, the HTTP path
    /// must reply with `{"action": "decline"}` instead of silently
    /// dropping the server's `elicitation/create` frame. This matches the
    /// stdio path's `handleServerRequest` behavior and prevents servers
    /// from hanging on an unanswered elicitation request.
    func testMcpHttpElicitationDeclinesWhenNoHandler() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let port = try await startStubServer(scenario: "elicit_nil")
        defer { stubCleanup() }

        let cfg = McpServerConfig(name: "stub",
                                  url: "http://127.0.0.1:\(port)/mcp")
        let client = McpHttpClient(cfg, requestTimeout: .seconds(8))
        try await client.start()
        try await client.initialize()
        _ = try await client.listTools()

        // Note: no elicitationHandler is passed in.
        let result = try await client.callTool("echo", argumentsJSON: "{}")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "pong")
        await client.stop()

        // Poll the stub's /captured endpoint: the client should have
        // posted exactly one JSON-RPC reply whose `result.action` is
        // `"decline"` (id == 9001 — the elicitation request id we
        // synthesized in the SSE stream).
        let capturedURL = URL(string:
            "http://127.0.0.1:\(port)/captured")!
        var declines: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let (data, _) = try? await URLSession.shared.data(from: capturedURL),
               let parsed = try? JSONSerialization.jsonObject(with: data) as?
                   [[String: Any]], !parsed.isEmpty {
                declines = parsed
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(declines.count, 1,
            "expected exactly one elicitation reply POST back to the stub")
        let first = declines.first ?? [:]
        XCTAssertEqual(first["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(first["id"] as? Int, 9001)
        let resultObj = first["result"] as? [String: Any] ?? [:]
        XCTAssertEqual(resultObj["action"] as? String, "decline",
            "nil-handler reply must carry action=decline")
        XCTAssertTrue(resultObj["content"] is NSNull,
            "content must be JSON null for an auto-decline")
        XCTAssertTrue(resultObj["_meta"] is NSNull,
            "_meta must be JSON null for an auto-decline")
    }

    // MARK: - Test stub server

    private final class ElicitationCapture: @unchecked Sendable {
        struct Record { let server: String; let params: JSONValue }
        private let lock = NSLock()
        private var records: [Record] = []
        func record(server: String, params: JSONValue) {
            lock.lock(); defer { lock.unlock() }
            records.append(Record(server: server, params: params))
        }
        func snapshot() -> [Record] {
            lock.lock(); defer { lock.unlock() }
            return records
        }
    }

    private var stubProcess: Process?

    private func stubCleanup() {
        if let p = stubProcess, p.isRunning { p.terminate() }
        stubProcess = nil
    }

    /// Spawns a python HTTP MCP stub configured for one of several
    /// scenarios:
    ///   * `recover`    — first non-initialize POST returns 404, then 200
    ///   * `concurrent` — every POST returns 404 until *any* re-init has
    ///                    been observed (so the shared re-init test can
    ///                    assert exactly-one)
    ///   * `elicit`     — tools/call returns an SSE stream with an
    ///                    elicitation/create frame followed by the result
    ///   * `elicit_nil` — same SSE shape as `elicit`, but also records the
    ///                    body of any follow-up POST whose JSON-RPC `id`
    ///                    matches the elicitation request, exposed via
    ///                    `GET /captured`. Used to verify that when no
    ///                    elicitationHandler is supplied, the HTTP client
    ///                    still posts a `decline` reply back (parity with
    ///                    the stdio path).
    private func startStubServer(scenario: String) async throws -> Int {
        let dir = tempDir("mcp-stub-")
        let scriptPath = dir + "/stub.py"
        let stub = """
        import sys, os, json, signal, threading, time
        from http.server import BaseHTTPRequestHandler, HTTPServer

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
        STATE = {"hits": 0, "reinited": False, "captured": []}
        LOCK = threading.Lock()

        class H(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.0'
            def log_message(self, *a): pass
            def do_GET(self):
                # Test-only inspection endpoint for the elicit_nil
                # scenario: returns the list of captured elicitation
                # reply bodies (JSON-encoded).
                if self.path == '/captured':
                    with LOCK:
                        out = json.dumps(STATE.get("captured", [])).encode()
                    self.send_response(200)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length', str(len(out)))
                    self.send_header('Connection','close')
                    self.end_headers()
                    self.wfile.write(out); return
                self.send_response(404); self.end_headers()
            def do_POST(self):
                n = int(self.headers.get('Content-Length', '0'))
                body = self.rfile.read(n) if n else b''
                try: req = json.loads(body)
                except Exception: req = {}
                method = req.get('method')
                rid = req.get('id')
                # elicit_nil: capture any follow-up POST whose `id`
                # matches the elicitation request we emitted (9001).
                # Its body should carry `result.action == "decline"`.
                if SCENARIO == 'elicit_nil' and rid == 9001 and method is None:
                    with LOCK:
                        STATE["captured"].append(req)
                    out = b'{}'
                    self.send_response(202)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length', str(len(out)))
                    self.send_header('Connection','close')
                    self.end_headers()
                    self.wfile.write(out); return
                with LOCK:
                    STATE["hits"] += 1
                    hits = STATE["hits"]
                # notifications/initialized has no id; just 202.
                if method == 'notifications/initialized':
                    out = b'{}'
                    self.send_response(202)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length', str(len(out)))
                    self.send_header('Connection','close')
                    self.end_headers()
                    self.wfile.write(out); return
                # initialize always succeeds.
                if method == 'initialize':
                    res = {'protocolVersion':'2025-06-18','capabilities':{},
                           'serverInfo':{'name':'stub','version':'0'}}
                    out = json.dumps({'jsonrpc':'2.0','id':rid,'result':res}).encode()
                    self.send_response(200)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length', str(len(out)))
                    self.send_header('Connection','close')
                    self.end_headers()
                    self.wfile.write(out)
                    with LOCK: STATE["reinited"] = True
                    return
                # Scenario hooks.
                if SCENARIO == 'recover':
                    # tools/list returns 404 on first call, 200 on retry.
                    with LOCK:
                        was = STATE.get("served404", 0)
                        if method == 'tools/list' and was == 0:
                            STATE["served404"] = 1
                            self.send_response(404)
                            self.send_header('Content-Type','text/plain')
                            self.send_header('Connection','close')
                            self.end_headers()
                            return
                if SCENARIO == 'concurrent':
                    # Until we've seen a fresh re-init since the last
                    # 404 wave, every tools/list returns 404. We use a
                    # generation counter so each call only triggers one
                    # 404 per "fresh" state.
                    if method == 'tools/list':
                        with LOCK:
                            served = STATE.get("served404", 0)
                            limit = 5  # number of concurrent callers
                            if served < limit:
                                STATE["served404"] = served + 1
                                STATE["reinited"] = False
                                self.send_response(404)
                                self.send_header('Content-Type','text/plain')
                                self.send_header('Connection','close')
                                self.end_headers()
                                return
                # Default result by method.
                if method == 'tools/list':
                    res = {'tools':[{'name':'echo','description':'',
                                     'inputSchema':{'type':'object'}}]}
                elif method == 'tools/call':
                    if SCENARIO == 'elicit' or SCENARIO == 'elicit_nil':
                        # SSE stream: elicitation/create then result.
                        self.send_response(200)
                        self.send_header('Content-Type','text/event-stream')
                        self.send_header('Connection','close')
                        self.end_headers()
                        elicit = {'jsonrpc':'2.0','id':9001,'method':'elicitation/create',
                                  'params':{'requestedSchema':{'type':'object'}}}
                        self.wfile.write(('data: ' + json.dumps(elicit) + '\\n\\n').encode())
                        self.wfile.flush()
                        result = {'jsonrpc':'2.0','id':rid,
                                  'result':{'content':[{'type':'text','text':'pong'}],
                                            'isError':False}}
                        self.wfile.write(('data: ' + json.dumps(result) + '\\n\\n').encode())
                        self.wfile.flush()
                        return
                    res = {'content':[{'type':'text','text':'pong'}],'isError':False}
                else:
                    res = {}
                out = json.dumps({'jsonrpc':'2.0','id':rid,'result':res}).encode()
                self.send_response(200)
                self.send_header('Content-Type','application/json')
                self.send_header('Content-Length', str(len(out)))
                self.send_header('Connection','close')
                self.end_headers()
                self.wfile.write(out)

        s = HTTPServer(('127.0.0.1', 0), H)
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
        // Read the port number the stub printed.
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
            reader.name = "ai.igent.codexkit.test.mcphttp.p72.port"
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
