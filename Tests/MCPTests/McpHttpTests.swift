import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import InfraPrimitives

final class McpHttpTests: XCTestCase {

    private func tempDir() -> String {
        let d = NSTemporaryDirectory() + "/mcp-http-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: d,
                                                 withIntermediateDirectories: true)
        return d
    }

    func testConfigDecodeLegacyServersArray() throws {
        let json = #"{"servers":[{"name":"s","command":"x","args":["-a"]}]}"#
        let home = tempDir()
        try Data(json.utf8).write(to: URL(fileURLWithPath: home + "/mcp.json"))
        let cfgs = McpManager.loadConfigs(codexHome: home)
        XCTAssertEqual(cfgs.count, 1)
        XCTAssertEqual(cfgs[0].name, "s")
        XCTAssertEqual(cfgs[0].command, "x")
        XCTAssertEqual(cfgs[0].args, ["-a"])
        XCTAssertFalse(cfgs[0].isHTTP)
    }

    func testConfigDecodeCodexMcpServersMapStdioAndUrl() throws {
        let json = """
        {"mcpServers":{"a":{"command":"c"},"b":{"url":"https://h/mcp",\
        "bearer_token_env_var":"B","http_headers":{"X":"y"}}}}
        """
        let home = tempDir()
        try Data(json.utf8).write(to: URL(fileURLWithPath: home + "/mcp.json"))
        let cfgs = McpManager.loadConfigs(codexHome: home)
        XCTAssertEqual(cfgs.count, 2)
        XCTAssertEqual(cfgs[0].name, "a")
        XCTAssertEqual(cfgs[1].name, "b")
        XCTAssertEqual(cfgs[0].command, "c")
        XCTAssertFalse(cfgs[0].isHTTP)
        XCTAssertTrue(cfgs[1].isHTTP)
        XCTAssertEqual(cfgs[1].url, "https://h/mcp")
        XCTAssertEqual(cfgs[1].bearerTokenEnvVar, "B")
        XCTAssertEqual(cfgs[1].httpHeaders, ["X": "y"])
    }

    func testHttpAuthHeaderPrecedence() async throws {
        let home = tempDir()
        let store = McpOAuthStore(codexHome: home)
        try store.save(StoredOAuthTokens(accessToken: "stored"), server: "srv")

        let cfgEnv = McpServerConfig(name: "srv", url: "https://h/mcp",
                                     bearerTokenEnvVar: "TOK")
        let cEnv = McpHttpClient(cfgEnv, env: ["TOK": "abc"], oauthStore: store)
        let hEnv = await cEnv.authorizationHeaderForTesting()
        XCTAssertEqual(hEnv, "Bearer abc")

        let cStore = McpHttpClient(cfgEnv, env: [:], oauthStore: store)
        let hStore = await cStore.authorizationHeaderForTesting()
        XCTAssertEqual(hStore, "Bearer stored")

        let cfgNone = McpServerConfig(name: "other", url: "https://h/mcp")
        let cNone = McpHttpClient(cfgNone, env: [:], oauthStore: store)
        let hNone = await cNone.authorizationHeaderForTesting()
        XCTAssertNil(hNone)
    }

    func testOAuthStoreRoundTripAndPerms() throws {
        let home = tempDir()
        let store = McpOAuthStore(codexHome: home)
        let future = Date().timeIntervalSince1970 + 3600
        let t = StoredOAuthTokens(accessToken: "A", refreshToken: "R",
                                  tokenType: "Bearer", expiresAtEpoch: future)
        try store.save(t, server: "my server")
        let loaded = store.load(server: "my server")
        XCTAssertEqual(loaded, t)

        let path = home + "/.mcp-oauth/my_server.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        store.delete(server: "my server")
        XCTAssertNil(store.load(server: "my server"))

        let past = StoredOAuthTokens(accessToken: "x",
                                     expiresAtEpoch: Date().timeIntervalSince1970 - 10)
        XCTAssertTrue(past.isExpired)
        let none = StoredOAuthTokens(accessToken: "x")
        XCTAssertFalse(none.isExpired)
        let fut = StoredOAuthTokens(accessToken: "x", expiresAtEpoch: future)
        XCTAssertFalse(fut.isExpired)
    }

    func testSSEResponseExtractionByID() throws {
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7," +
                  "\"result\":{\"ok\":true}}\n\n"
        let parsedSSE = McpHttpClient.parseRPCResponse(body: sse, id: 7)
        XCTAssertNotNil(parsedSSE)
        if case .object(let r)? = parsedSSE?["result"],
           case .bool(let ok)? = r["ok"] {
            XCTAssertTrue(ok)
        } else {
            XCTFail("expected result.ok true")
        }

        let single = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"x\":1}}"
        let parsedSingle = McpHttpClient.parseRPCResponse(body: single, id: 1)
        XCTAssertNotNil(parsedSingle?["result"])

        let errBody = "{\"jsonrpc\":\"2.0\",\"id\":1," +
                      "\"error\":{\"code\":-1,\"message\":\"bad\"}}"
        let parsedErr = McpHttpClient.parseRPCResponse(body: errBody, id: 1)
        XCTAssertNotNil(parsedErr?["error"])
        XCTAssertNil(parsedErr?["result"])

        let mismatch = McpHttpClient.parseRPCResponse(body: sse, id: 99)
        XCTAssertNil(mismatch)
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

    func testHttpEndToEndAgainstLocalStub() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")

        let stub = """
        import sys, os, json, signal, threading, time
        from http.server import BaseHTTPRequestHandler, HTTPServer

        signal.signal(signal.SIGTERM, lambda *a: os._exit(0))

        _start = time.time()
        _ppid0 = os.getppid()

        def _watchdog():
            while True:
                if os.getppid() != _ppid0:
                    os._exit(0)
                if time.time() - _start > 90:
                    os._exit(0)
                time.sleep(0.2)

        threading.Thread(target=_watchdog, daemon=True).start()

        class H(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.0'
            def log_message(self, *a): pass
            def do_POST(self):
                n = int(self.headers.get('Content-Length', '0'))
                body = self.rfile.read(n) if n else b''
                req = json.loads(body) if body else {}
                method = req.get('method')
                rid = req.get('id')
                if method == 'notifications/initialized':
                    out = b'{}'
                    self.send_response(202)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(out)))
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    self.wfile.write(out)
                    return
                if method == 'initialize':
                    res = {'protocolVersion': '2025-06-18', 'capabilities': {},
                           'serverInfo': {'name': 'stub', 'version': '0'}}
                elif method == 'tools/list':
                    res = {'tools': [{'name': 'echo',
                                      'description': 'echo tool',
                                      'inputSchema': {'type': 'object'}}]}
                elif method == 'tools/call':
                    res = {'content': [{'type': 'text', 'text': 'pong'}],
                           'isError': False}
                else:
                    res = {}
                out = json.dumps({'jsonrpc': '2.0', 'id': rid,
                                  'result': res}).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(out)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(out)

        s = HTTPServer(('127.0.0.1', 0), H)
        print(s.server_address[1])
        sys.stdout.flush()
        s.serve_forever()
        """
        let dir = tempDir()
        let scriptPath = dir + "/stub.py"
        try Data(stub.utf8).write(to: URL(fileURLWithPath: scriptPath))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", scriptPath]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        try p.run()
        defer { p.terminate() }

        let outHandle = outPipe.fileHandleForReading
        let port: Int? = await withCheckedContinuation {
            (cont: CheckedContinuation<Int?, Never>) in
            final class Once: @unchecked Sendable {
                private let l = NSLock()
                private var done = false
                func go() -> Bool {
                    l.lock(); defer { l.unlock() }
                    if done { return false }
                    done = true
                    return true
                }
            }
            let once = Once()
            let reader = Thread {
                var acc = Data()
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    let chunk = outHandle.availableData
                    if chunk.isEmpty {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
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
            reader.name = "ai.igent.codexkit.test.mcphttp.port"
            reader.start()
            let watchdog = Thread {
                Thread.sleep(forTimeInterval: 12)
                if once.go() { cont.resume(returning: nil) }
            }
            watchdog.start()
        }
        guard let port, port > 0 else {
            XCTFail("stub did not report a port")
            return
        }

        let cfg = McpServerConfig(name: "stub",
                                  url: "http://127.0.0.1:\(port)/mcp")
        let client = McpHttpClient(cfg, requestTimeout: .seconds(8))

        let ok: Bool = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do {
                    try await client.start()
                    try await client.initialize()
                    let tools = try await client.listTools()
                    guard tools.first?.name == "echo" else { return false }
                    let result = try await client.callTool("echo",
                                                           argumentsJSON: "{}")
                    await client.stop()
                    return result.text == "pong" && !result.isError
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
        XCTAssertTrue(ok, "MCP HTTP e2e round-trip (echo→pong) within the time budget")
    }
}