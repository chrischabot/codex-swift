import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import InfraPrimitives

private func maTmp() -> String {
    let p = NSTemporaryDirectory() + "mcpadv-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}
private func maWriteServer(_ dir: String, name: String, body: String) -> String {
    let path = dir + "/\(name).py"
    try? body.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

final class McpAdversarialTests: XCTestCase {

    // MARK: unbounded no-newline stdout flood is shed (read-buffer cap)

    func testServerStdoutFloodNoNewlineIsBounded() async throws {
        let dir = maTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        // On tools/call the server emits a large blob with NO newline forever.
        let script = maWriteServer(dir, name: "flood", body: #"""
        import sys, json
        def send(o):
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
        while True:
            line = sys.stdin.readline()
            if line == "": break
            line = line.strip()
            if not line: continue
            m = json.loads(line); mid = m.get("id"); meth = m.get("method")
            if meth == "initialize":
                send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-06-18"}})
            elif meth == "notifications/initialized":
                pass
            elif meth == "tools/list":
                send({"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"x","description":"d","inputSchema":{"type":"object"}}]}})
            elif meth == "tools/call":
                while True:
                    sys.stdout.write("X" * 65536)   # no newline, ever
                    sys.stdout.flush()
        """#)
        let client = McpClient(McpServerConfig(name: "flood", command: "python3",
                                               args: ["-u", script]),
                               requestTimeout: .seconds(5),
                               maxFrameBytes: 1 * 1024 * 1024)
        try await client.start()
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map { $0.name }, ["x"])
        let started = Date()
        do {
            _ = try await client.callTool("x", argumentsJSON: "{}")
            XCTFail("a no-newline stdout flood must not succeed")
        } catch {
            XCTAssertTrue(error is McpError, "clean transport failure: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 12,
                          "the flood is shed promptly (no OOM / indefinite hang)")
        await client.stop()
    }

    // MARK: huge valid result is bounded by the ToolRouter output ring

    func testHugeValidToolResultBoundedDownstream() async throws {
        let dir = maTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = maWriteServer(dir, name: "huge", body: #"""
        import sys, json
        def send(o):
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
        while True:
            line = sys.stdin.readline()
            if line == "": break
            line = line.strip()
            if not line: continue
            m = json.loads(line); mid = m.get("id"); meth = m.get("method")
            if meth == "initialize":
                send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-06-18"}})
            elif meth == "notifications/initialized":
                pass
            elif meth == "tools/list":
                send({"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"big","description":"d","inputSchema":{"type":"object"}}]}})
            elif meth == "tools/call":
                send({"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":"Z"*3000000}],"isError":False}})
        """#)
        var lim = Limits(); lim.maxToolOutputBytes = 4096
        let router = ToolRouter(limits: lim)
        let mgr = McpManager()
        await mgr.startAll([McpServerConfig(name: "srv", command: "python3",
                                            args: ["-u", script])], router: router)
        let r = await router.dispatch(
            ToolCall(callId: "1", name: "mcp__srv__big", argumentsJSON: "{}"),
            cwd: dir, deadline: .fromNow(.seconds(15)))
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.truncated, "a 3 MB MCP result is truncated downstream")
        XCTAssertLessThan(r.output.utf8.count, 200_000,
                          "the model is not flooded by a huge MCP result")
        XCTAssertTrue(r.output.contains("bytes elided"))
        await mgr.stopAll()
    }

    // MARK: garbage / non-JSON frames are ignored, valid still works

    func testGarbageFramesIgnoredValidStillWorks() async throws {
        let dir = maTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = maWriteServer(dir, name: "noisy", body: #"""
        import sys, json
        def raw(s):
            sys.stdout.write(s + "\n"); sys.stdout.flush()
        def send(o):
            raw(json.dumps(o))
        while True:
            line = sys.stdin.readline()
            if line == "": break
            line = line.strip()
            if not line: continue
            m = json.loads(line); mid = m.get("id"); meth = m.get("method")
            raw("this is not json at all <<<>>>")
            raw("{not: valid, json}")
            raw("12345")
            if meth == "initialize":
                send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-06-18"}})
            elif meth == "notifications/initialized":
                pass
            elif meth == "tools/list":
                send({"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"ok","description":"d","inputSchema":{"type":"object"}}]}})
            elif meth == "tools/call":
                raw("garbage-after")
                send({"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":"pong"}],"isError":False}})
        """#)
        let client = McpClient(McpServerConfig(name: "noisy", command: "python3",
                                               args: ["-u", script]),
                               requestTimeout: .seconds(10))
        try await client.start()
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map { $0.name }, ["ok"],
                       "valid frames decode despite interleaved garbage")
        let r = try await client.callTool("ok", argumentsJSON: "{}")
        XCTAssertEqual(r.text, "pong")
        XCTAssertFalse(r.isError)
        await client.stop()
    }

    // MARK: deeply nested JSON result does not crash the client

    func testDeeplyNestedResultDoesNotCrash() async throws {
        let dir = maTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = maWriteServer(dir, name: "deep", body: #"""
        import sys, json
        def send(o):
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
        while True:
            line = sys.stdin.readline()
            if line == "": break
            line = line.strip()
            if not line: continue
            m = json.loads(line); mid = m.get("id"); meth = m.get("method")
            if meth == "initialize":
                send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-06-18"}})
            elif meth == "notifications/initialized":
                pass
            elif meth == "tools/list":
                send({"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"d","description":"x","inputSchema":{"type":"object"}}]}})
            elif meth == "tools/call":
                nested = "[" * 2000 + "1" + "]" * 2000
                sys.stdout.write('{"jsonrpc":"2.0","id":%s,"result":{"deep":%s,"content":[{"type":"text","text":"ok"}]}}\n' % (mid, nested))
                sys.stdout.flush()
        """#)
        let client = McpClient(McpServerConfig(name: "deep", command: "python3",
                                               args: ["-u", script]),
                               requestTimeout: .seconds(10))
        try await client.start()
        try await client.initialize()
        _ = try await client.listTools()
        // Must return cleanly (or throw a clean McpError) — never trap.
        do {
            let r = try await client.callTool("d", argumentsJSON: "{}")
            // Reaching here without trapping is the property under test; the
            // result is well-formed (isError is a Bool, text is a String).
            XCTAssertTrue(r.isError == true || r.isError == false)
        } catch {
            XCTAssertTrue(error is McpError,
                          "deep nesting yields a clean McpError, never a trap")
        }
        await client.stop()
    }

    // MARK: per-server failure isolation under a mixed startAll

    func testMixedStartAllIsolatesFailures() async {
        let dir = maTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let good = maWriteServer(dir, name: "good", body: #"""
        import sys, json
        def send(o):
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
        while True:
            line = sys.stdin.readline()
            if line == "": break
            line = line.strip()
            if not line: continue
            m = json.loads(line); mid = m.get("id"); meth = m.get("method")
            if meth == "initialize":
                send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-06-18"}})
            elif meth == "notifications/initialized":
                pass
            elif meth == "tools/list":
                send({"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"g","description":"d","inputSchema":{"type":"object"}}]}})
        """#)
        let router = ToolRouter(limits: Limits())
        let mgr = McpManager()
        await mgr.startAll([
            McpServerConfig(name: "boom", command: "python3",
                            args: ["-c", "import sys; sys.exit(2)"]),
            McpServerConfig(name: "good", command: "python3", args: ["-u", good]),
        ], router: router)
        let specs = await router.specs()
        XCTAssertTrue(specs.contains { $0.name == "mcp__good__g" },
                      "the good server's tool is registered")
        XCTAssertFalse(specs.contains { $0.name.hasPrefix("mcp__boom__") },
                       "the crashing server contributes no tools")
        let statuses = await mgr.statusList()
        XCTAssertTrue(statuses.contains { $0.name == "boom" && $0.state == "failed" })
        XCTAssertTrue(statuses.contains { $0.name == "good" && $0.state == "ready" })
        await mgr.stopAll()
    }
}