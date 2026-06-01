import XCTest
import Foundation
@testable import MCP
@testable import ProtocolModel
@testable import WireProtocol

/// Targeted unit tests for the v9 MCP audit findings:
///   1. standalone GET SSE listening stream delivers server-initiated frames
///   2. DELETE-on-stop releases the server-side session
///   3. tool `_meta` (connector identity + openai/fileParams) preserved
///   4. openai/fileParams input-schema masking
///   5. elicitation form-vs-url classification keyed off the `mode` tag
final class McpFindingsV9Tests: XCTestCase {

    // MARK: - Finding 5: elicitation `mode` tag classification

    private func policy(_ params: JSONValue) -> Bool {
        McpElicitationPolicy.canAutoAccept(params: params)
    }

    func testModeUrlNeverAutoAcceptsEvenWithoutUrlField() {
        // A malformed url elicitation: `mode:"url"` but NO `url` field.
        // The tag is authoritative → must NOT auto-accept.
        let p = JSONValue.object([
            "mode": .string("url"),
            "requestedSchema": .object(["properties": .object([:])]),
        ])
        XCTAssertFalse(policy(p))
    }

    func testModeFormWithEmptyPropertiesAutoAccepts() {
        let p = JSONValue.object([
            "mode": .string("form"),
            "requestedSchema": .object(["properties": .object([:])]),
        ])
        XCTAssertTrue(policy(p))
    }

    func testModeFormWithStrayUrlStillAutoAcceptsWhenSchemaless() {
        // A form that carries a stray `url` field — the `mode` tag wins, so we
        // evaluate properties emptiness (and auto-accept), not the url field.
        let p = JSONValue.object([
            "mode": .string("form"),
            "url": .string("https://example.com/should-be-ignored"),
            "requestedSchema": .object(["properties": .object([:])]),
        ])
        XCTAssertTrue(policy(p))
    }

    func testModeFormWithPropertiesDoesNotAutoAccept() {
        let p = JSONValue.object([
            "mode": .string("form"),
            "requestedSchema": .object(["properties": .object(["a": .object([:])])]),
        ])
        XCTAssertFalse(policy(p))
    }

    func testMissingModeWithUrlFieldClassifiedAsUrl() {
        // Spec-conformant url payload that omits `mode` → url fallback fires.
        let p = JSONValue.object([
            "url": .string("https://example.com/oauth"),
        ])
        XCTAssertFalse(policy(p))
    }

    func testMissingModeNoUrlSchemalessAutoAccepts() {
        let p = JSONValue.object([
            "requestedSchema": .object(["properties": .object([:])]),
        ])
        XCTAssertTrue(policy(p))
    }

    func testUnknownModeIsConservative() {
        let p = JSONValue.object([
            "mode": .string("bogus"),
            "requestedSchema": .object(["properties": .object([:])]),
        ])
        XCTAssertFalse(policy(p))
    }

    // MARK: - Finding 3: tool `_meta` preservation + connector accessors

    func testMetaPreservedAndConnectorAccessors() {
        let meta = JSONLite.object([
            "connector_id": .string("conn-123"),
            "connector_display_name": .string("My Connector"),
            "connectorDescription": .string("does things"),
        ])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: "{}", meta: meta)
        XCTAssertEqual(spec.connectorId, "conn-123")
        // connector_name absent → falls back to connector_display_name.
        XCTAssertEqual(spec.connectorName, "My Connector")
        // connector_description absent → falls back to connectorDescription.
        XCTAssertEqual(spec.connectorDescription, "does things")
    }

    func testConnectorNamePrecedence() {
        let meta = JSONLite.object([
            "connector_name": .string("Primary"),
            "connector_display_name": .string("Fallback"),
        ])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: "{}", meta: meta)
        XCTAssertEqual(spec.connectorName, "Primary")
    }

    func testMetaStringTrimsAndDropsEmpty() {
        let meta = JSONLite.object([
            "connector_id": .string("   "),   // whitespace-only → nil
        ])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: "{}", meta: meta)
        XCTAssertNil(spec.connectorId)
    }

    func testOpenaiFileParamsExtraction() {
        let meta = JSONLite.object([
            "openai/fileParams": .array([.string("doc"), .string(""),
                                         .string("attachment")]),
        ])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: "{}", meta: meta)
        // Empty string entry is dropped (parity with upstream filter).
        XCTAssertEqual(spec.openaiFileParams, ["doc", "attachment"])
    }

    func testMcpToolSpecRoundTripsMetaThroughCodable() throws {
        let meta = JSONLite.object(["connector_id": .string("c")])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: "{\"type\":\"object\"}", meta: meta)
        let data = try JSONEncoder().encode(spec)
        let back = try JSONDecoder().decode(McpToolSpec.self, from: data)
        XCTAssertEqual(back, spec)
        XCTAssertEqual(back.connectorId, "c")
    }

    // MARK: - Finding 4: openai/fileParams input-schema masking

    func testMaskNoFileParamsLeavesSchemaUnchanged() {
        let schema = "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"number\"}}}"
        let spec = McpToolSpec(name: "t", description: "d", inputSchemaJSON: schema)
        XCTAssertEqual(McpToolNormalization.maskedInputSchemaJSON(for: spec), schema)
    }

    func testMaskScalarFileParamBecomesStringWithGuidance() throws {
        let schema = """
        {"type":"object","properties":{"file":{"type":"object","description":"the upload","format":"binary"}}}
        """
        let meta = JSONLite.object(["openai/fileParams": .array([.string("file")])])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: schema, meta: meta)
        let masked = McpToolNormalization.maskedInputSchemaJSON(for: spec)
        let parsed = try JSONLite.parse(Data(masked.utf8))
        guard case .object(let o) = parsed,
              case .object(let props)? = o["properties"],
              case .object(let fileProp)? = props["file"] else {
            return XCTFail("masked schema malformed: \(masked)")
        }
        // type rewritten to string, format/other keys cleared.
        XCTAssertEqual(fileProp["type"], .string("string"))
        XCTAssertNil(fileProp["format"])
        XCTAssertNil(fileProp["items"])
        guard case .string(let desc)? = fileProp["description"] else {
            return XCTFail("missing description")
        }
        XCTAssertTrue(desc.hasPrefix("the upload "))
        XCTAssertTrue(desc.contains(McpToolNormalization.fileParamGuidance))
    }

    func testMaskArrayFileParamBecomesArrayOfStrings() throws {
        // `type:"array"` → masked to array of string items.
        let schema = """
        {"type":"object","properties":{"files":{"type":"array","items":{"type":"object"}}}}
        """
        let meta = JSONLite.object(["openai/fileParams": .array([.string("files")])])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: schema, meta: meta)
        let masked = McpToolNormalization.maskedInputSchemaJSON(for: spec)
        let parsed = try JSONLite.parse(Data(masked.utf8))
        guard case .object(let o) = parsed,
              case .object(let props)? = o["properties"],
              case .object(let p)? = props["files"] else {
            return XCTFail("masked schema malformed: \(masked)")
        }
        XCTAssertEqual(p["type"], .string("array"))
        XCTAssertEqual(p["items"], .object(["type": .string("string")]))
        // No prior description → guidance becomes the whole description.
        XCTAssertEqual(p["description"], .string(McpToolNormalization.fileParamGuidance))
    }

    func testMaskItemsPresenceImpliesArray() throws {
        // No `type` but `items` present → treated as array (upstream `is_array`).
        let schema = """
        {"type":"object","properties":{"f":{"items":{"type":"object"}}}}
        """
        let meta = JSONLite.object(["openai/fileParams": .array([.string("f")])])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: schema, meta: meta)
        let masked = McpToolNormalization.maskedInputSchemaJSON(for: spec)
        let parsed = try JSONLite.parse(Data(masked.utf8))
        guard case .object(let o) = parsed,
              case .object(let props)? = o["properties"],
              case .object(let p)? = props["f"] else {
            return XCTFail("malformed: \(masked)")
        }
        XCTAssertEqual(p["type"], .string("array"))
    }

    func testMaskGuidanceNotDuplicatedWhenAlreadyPresent() throws {
        let desc = "Existing. " + McpToolNormalization.fileParamGuidance
        let schema = """
        {"type":"object","properties":{"f":{"type":"string","description":\(jsonString(desc))}}}
        """
        let meta = JSONLite.object(["openai/fileParams": .array([.string("f")])])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: schema, meta: meta)
        let masked = McpToolNormalization.maskedInputSchemaJSON(for: spec)
        let parsed = try JSONLite.parse(Data(masked.utf8))
        guard case .object(let o) = parsed,
              case .object(let props)? = o["properties"],
              case .object(let p)? = props["f"],
              case .string(let out)? = p["description"] else {
            return XCTFail("malformed: \(masked)")
        }
        // Guidance appears exactly once.
        let occurrences = out.components(
            separatedBy: McpToolNormalization.fileParamGuidance).count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testMaskMissingPropertyIsSkipped() {
        // file param names a property that does not exist → schema unchanged
        // for that name (no crash, other props intact).
        let schema = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"number\"}}}"
        let meta = JSONLite.object(["openai/fileParams": .array([.string("ghost")])])
        let spec = McpToolSpec(name: "t", description: "d",
                               inputSchemaJSON: schema, meta: meta)
        let masked = McpToolNormalization.maskedInputSchemaJSON(for: spec)
        XCTAssertTrue(masked.contains("\"number\""))
    }

    private func jsonString(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s], options: [])
        var str = String(decoding: d, as: UTF8.self)
        str.removeFirst(); str.removeLast()   // strip the array brackets
        return str
    }

    // MARK: - Findings 1 & 2: GET listening stream + DELETE on stop (HTTP)

    private var stubProcess: Process?

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

    private func stubCleanup() {
        if let p = stubProcess, p.isRunning { p.terminate() }
        stubProcess = nil
    }

    /// Finding 1: the client opens a standalone GET text/event-stream after
    /// initialize (assigning a session id) and routes server-pushed
    /// notification frames through the notification sink. Finding 2: stop()
    /// issues a DELETE with the session id. The stub records both events and
    /// exposes them via `GET /inspect`.
    func testGetStreamDeliversNotificationAndStopSendsDelete() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let port = try await startGetStreamStub()
        defer { stubCleanup() }

        let sink = CapturingMcpNotificationSink()
        let cfg = McpServerConfig(name: "stub",
                                  url: "http://127.0.0.1:\(port)/mcp")
        let client = McpHttpClient(cfg, requestTimeout: .seconds(10),
                                   notificationSink: sink)
        try await client.start()
        try await client.initialize()

        // The GET stream should deliver a server-pushed notification shortly
        // after initialize. Poll the sink for up to ~5s.
        var sawNotif = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !sink.snapshot().isEmpty { sawNotif = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(sawNotif,
            "GET listening stream must deliver the server-pushed notification")

        await client.stop()

        // Verify the server observed a GET on /mcp (the listening stream) and
        // a DELETE on stop.
        let inspect = try await fetchInspect(port: port)
        XCTAssertTrue(inspect["got_get"] == true,
            "server must have received the standalone GET stream request")
        // Give the best-effort DELETE a brief moment in case of races.
        var sawDelete = inspect["got_delete"] == true
        if !sawDelete {
            try? await Task.sleep(for: .milliseconds(300))
            let again = try await fetchInspect(port: port)
            sawDelete = again["got_delete"] == true
        }
        XCTAssertTrue(sawDelete, "stop() must issue a DELETE to release the session")
    }

    private func fetchInspect(port: Int) async throws -> [String: Bool] {
        let url = URL(string: "http://127.0.0.1:\(port)/inspect")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
        return obj ?? [:]
    }

    private func startGetStreamStub() async throws -> Int {
        let dir = tempDir("mcp-getstream-")
        let scriptPath = dir + "/stub.py"
        let stub = """
        import sys, os, json, signal, threading, time
        from http.server import BaseHTTPRequestHandler, HTTPServer
        from socketserver import ThreadingMixIn

        signal.signal(signal.SIGTERM, lambda *a: os._exit(0))
        _start = time.time(); _ppid0 = os.getppid()
        def _wd():
            while True:
                if os.getppid() != _ppid0: os._exit(0)
                if time.time() - _start > 90: os._exit(0)
                time.sleep(0.2)
        threading.Thread(target=_wd, daemon=True).start()

        STATE = {"got_get": False, "got_delete": False}
        LOCK = threading.Lock()

        class H(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *a): pass
            def _json(self, code, obj):
                out = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header('Content-Type','application/json')
                self.send_header('Content-Length', str(len(out)))
                self.end_headers()
                self.wfile.write(out)
            def do_GET(self):
                if self.path == '/inspect':
                    with LOCK:
                        snap = dict(STATE)
                    self._json(200, snap); return
                # Standalone listening stream: emit a notification frame and
                # hold the connection open briefly, then close.
                with LOCK: STATE["got_get"] = True
                self.send_response(200)
                self.send_header('Content-Type','text/event-stream')
                self.end_headers()
                notif = {'jsonrpc':'2.0','method':'notifications/message',
                         'params':{'level':'info','data':'hello-from-get'}}
                self.wfile.write(('data: ' + json.dumps(notif) + '\\n\\n').encode())
                self.wfile.flush()
                time.sleep(0.5)
            def do_DELETE(self):
                with LOCK: STATE["got_delete"] = True
                self.send_response(200); self.send_header('Content-Length','0')
                self.end_headers()
            def do_POST(self):
                n = int(self.headers.get('Content-Length', '0'))
                body = self.rfile.read(n) if n else b''
                try: req = json.loads(body)
                except Exception: req = {}
                method = req.get('method'); rid = req.get('id')
                if method == 'initialize':
                    res = {'protocolVersion':'2025-06-18','capabilities':{},
                           'serverInfo':{'name':'stub','version':'0'}}
                    out = json.dumps({'jsonrpc':'2.0','id':rid,'result':res}).encode()
                    self.send_response(200)
                    self.send_header('Content-Type','application/json')
                    self.send_header('Mcp-Session-Id','sess-abc')
                    self.send_header('Content-Length', str(len(out)))
                    self.end_headers(); self.wfile.write(out); return
                if method == 'notifications/initialized':
                    self._json(202, {}); return
                self._json(200, {'jsonrpc':'2.0','id':rid,'result':{}})

        class TS(ThreadingMixIn, HTTPServer):
            daemon_threads = True
        s = TS(('127.0.0.1', 0), H)
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
                            .trimmingCharacters(in: .whitespaces))
                        if once.go() { cont.resume(returning: parsed) }
                        return
                    }
                }
                if once.go() { cont.resume(returning: nil) }
            }
            reader.start()
        }
        guard let port else {
            throw XCTSkip("stub server did not report a port")
        }
        // Give the server a moment to bind.
        try? await Task.sleep(for: .milliseconds(150))
        return port
    }
}
