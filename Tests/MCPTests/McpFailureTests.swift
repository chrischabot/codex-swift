import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import InfraPrimitives

private func mfTmp() -> String {
    let p = NSTemporaryDirectory() + "mcpfail-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

/// A responsive readline MCP stdio server whose `tools/call` reply is
/// configurable (`error` → JSON-RPC error object, `iserror` → isError:true).
private func responsiveServer(_ dir: String, callMode: String) -> String {
    let path = dir + "/srv_\(callMode).py"
    let callReply: String
    if callMode == "error" {
        callReply = #"""
                send({"jsonrpc": "2.0", "id": mid,
                      "error": {"code": -32000, "message": "server boom"}})
"""#
    } else {
        callReply = #"""
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": "partial-bad"}],
                    "isError": True}})
"""#
    }
    let body = """
    import sys, json
    def send(o):
        sys.stdout.write(json.dumps(o) + "\\n")
        sys.stdout.flush()
    while True:
        line = sys.stdin.readline()
        if line == "":
            break
        line = line.strip()
        if not line:
            continue
        m = json.loads(line)
        mid = m.get("id")
        meth = m.get("method")
        if meth == "initialize":
            send({"jsonrpc": "2.0", "id": mid,
                  "result": {"protocolVersion": "2025-06-18"}})
        elif meth == "notifications/initialized":
            pass
        elif meth == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
                {"name": "x", "description": "d",
                 "inputSchema": {"type": "object"}}]}})
        elif meth == "tools/call":
    \(callReply)
    """
    try? body.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

final class McpFailureTests: XCTestCase {

    // A server that exits immediately → startAll marks it failed, no proxy.

    func testCrashingServerIsHandled() async {
        let dir = mfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = ToolRouter(limits: Limits())
        let mgr = McpManager()
        await mgr.startAll([McpServerConfig(name: "crash", command: "python3",
                                            args: ["-c", "import sys; sys.exit(1)"])],
                           router: router)
        let specs = await router.specs()
        XCTAssertFalse(specs.contains { $0.name.hasPrefix("mcp__crash__") },
                       "a crashing MCP server registers no tools")
        let statuses = await mgr.statusList()
        XCTAssertTrue(statuses.contains { $0.name == "crash" && $0.state == "failed" },
                      "the crashing server is marked failed (no harness crash)")
    }

    // A silent server that never replies → request times out cleanly.

    func testSilentServerRequestTimesOut() async throws {
        let dir = mfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/silent.py"
        try "import time\ntry:\n    time.sleep(10)\nexcept Exception:\n    pass\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        let client = McpClient(McpServerConfig(name: "silent", command: "python3",
                                               args: ["-u", script]),
                               requestTimeout: .seconds(2))
        try await client.start()
        let started = Date()
        do {
            try await client.initialize()
            XCTFail("expected initialize to time out against a silent server")
        } catch {
            XCTAssertTrue(error is McpError, "surfaced as McpError: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8,
                          "timeout fired promptly (no indefinite hang)")
        await client.stop()
    }

    // tools/call returns a JSON-RPC error → proxy yields a clean failure.

    func testToolCallServerErrorBecomesCleanToolFailure() async throws {
        let dir = mfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = responsiveServer(dir, callMode: "error")
        let router = ToolRouter(limits: Limits())
        let mgr = McpManager()
        await mgr.startAll([McpServerConfig(name: "srv", command: "python3",
                                            args: ["-u", script])], router: router)
        let specs = await router.specs()
        XCTAssertTrue(specs.contains { $0.name == "mcp__srv__x" },
                      "responsive server's tool is advertised")
        let r = await router.dispatch(
            ToolCall(callId: "1", name: "mcp__srv__x", argumentsJSON: "{}"),
            cwd: dir, deadline: .fromNow(.seconds(15)))
        XCTAssertFalse(r.success, "a server JSON-RPC error becomes a failed tool result")
        XCTAssertTrue(r.output.contains("mcp error"),
                      "the server error message is surfaced: \(r.output)")
        await mgr.stopAll()
    }

    // tools/call returns isError content → proxy yields a clean failure.

    func testToolCallIsErrorBecomesCleanToolFailure() async throws {
        let dir = mfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = responsiveServer(dir, callMode: "iserror")
        let router = ToolRouter(limits: Limits())
        let mgr = McpManager()
        await mgr.startAll([McpServerConfig(name: "srv", command: "python3",
                                            args: ["-u", script])], router: router)
        let r = await router.dispatch(
            ToolCall(callId: "1", name: "mcp__srv__x", argumentsJSON: "{}"),
            cwd: dir, deadline: .fromNow(.seconds(15)))
        XCTAssertFalse(r.success, "isError:true content is a failed tool result")
        XCTAssertTrue(r.output.contains("partial-bad"),
                      "the error content is still surfaced to the agent")
        await mgr.stopAll()
    }
}
