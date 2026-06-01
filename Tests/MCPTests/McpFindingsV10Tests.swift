import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import ProtocolModel

/// Targeted unit tests for the v10 MCP audit findings:
///   1. tools/call requests carry `_meta.threadId = <conversation id>`
///   2. default elicitation capability is the empty object `{}`
///   3. remote-source env_vars on a local stdio launch are a hard error
///   4. tool-argument validation error includes the offending value
final class McpFindingsV10Tests: XCTestCase {

    // MARK: - Finding 1: `_meta.threadId` injection on tools/call

    /// Records the `meta` map handed to `callTool` so we can assert the
    /// proxy injected `threadId`.
    private actor RecordingMcpClient: McpClientProtocol {
        private(set) var metaWasNil = true
        private(set) var threadIdMeta: String?
        private(set) var callCount = 0
        func start() throws {}
        func initialize() async throws {}
        func listTools() async throws -> [McpToolSpec] { [] }
        func callTool(_ name: String, argumentsJSON: String,
                      meta: [String: Any]?,
                      elicitationHandler: McpElicitationHandler?) async throws -> McpCallResult {
            callCount += 1
            metaWasNil = (meta == nil)
            threadIdMeta = meta?["threadId"] as? String
            return McpCallResult(text: "ok", isError: false)
        }
        func readResource(uri: String) async throws -> [String: JSONLite] { [:] }
        func stop() async {}
    }

    func testProxyInjectsThreadIdMetaOnCall() async throws {
        let client = RecordingMcpClient()
        let proxy = McpToolProxy(server: "srv", tool: "do_thing", client: client,
                                 threadId: "conv-abc-123")
        let r = try await proxy.run(ToolCall(callId: "c1", name: proxy.name,
                                             argumentsJSON: "{}"), cwd: "/")
        XCTAssertTrue(r.success)
        let nilMeta = await client.metaWasNil
        let tid = await client.threadIdMeta
        XCTAssertFalse(nilMeta, "tools/call must carry a _meta map")
        XCTAssertEqual(tid, "conv-abc-123")
    }

    /// With no threadId (standalone construction, e.g. tests), no synthetic
    /// `_meta` is forced — matching the absence of a session context.
    func testProxyOmitsMetaWhenNoThreadId() async throws {
        let client = RecordingMcpClient()
        let proxy = McpToolProxy(server: "srv", tool: "do_thing", client: client)
        _ = try await proxy.run(ToolCall(callId: "c1", name: proxy.name,
                                         argumentsJSON: "{}"), cwd: "/")
        let nilMeta = await client.metaWasNil
        XCTAssertTrue(nilMeta, "no threadId → no injected _meta")
    }

    /// End-to-end through the real stdio client: the python mock echoes the
    /// received `_meta` back, so we verify `threadId` actually reached the
    /// wire (not just the in-process proxy).
    func testThreadIdReachesStdioWire() async throws {
        let dir = NSTemporaryDirectory() + "mcp-meta-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/server.py"
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
            p = msg.get("params") or {}
            if m == "initialize":
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"protocolVersion":"2025-06-18"}}), flush=True)
            elif m == "notifications/initialized":
                pass
            elif m == "tools/call":
                meta = p.get("_meta") or {}
                tid = meta.get("threadId", "<none>")
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"content":[{"type":"text","text":tid}],"isError":False}}), flush=True)
        """#
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        let client = McpClient(McpServerConfig(name: "meta", command: "python3",
                                               args: [script]),
                               requestTimeout: .seconds(10))
        try await client.start()
        try await client.initialize()
        let proxy = McpToolProxy(server: "meta", tool: "echo_meta", client: client,
                                 threadId: "thr-wire-987")
        let r = try await proxy.run(ToolCall(callId: "c1", name: proxy.name,
                                             argumentsJSON: "{}"), cwd: "/")
        XCTAssertEqual(r.output, "thr-wire-987",
                       "server must observe _meta.threadId on the wire")
        await client.stop()
    }

    // MARK: - Finding 2: default elicitation capability is empty {}

    func testElicitationCapabilityDefaultsToEmpty() {
        // Default: AuthElicitation disabled → ElicitationCapability::default()
        // → wire `{}`.
        XCTAssertFalse(McpClientInfo.authElicitationEnabled)
        XCTAssertTrue(McpClientInfo.elicitationCapability.isEmpty,
                      "default elicitation capability must be {} not {form,url}")
    }

    func testElicitationCapabilityWithAuthElicitationOn() {
        let cap = McpClientInfo.capability(authElicitationEnabled: true)
        XCTAssertNotNil(cap["form"])
        XCTAssertNotNil(cap["url"])
        XCTAssertEqual(cap.count, 2)
    }

    // MARK: - Finding 4: tool-argument validation error includes the value

    func testNonObjectArgumentsErrorIncludesValue() {
        XCTAssertThrowsError(
            try McpClient.parseToolArguments("[1,2,3]")
        ) { err in
            let msg = "\(err)"
            XCTAssertTrue(msg.contains("MCP tool arguments must be a JSON object"), msg)
            XCTAssertTrue(msg.contains("got [1,2,3]"), msg)
        }
    }

    func testNonJsonArgumentsErrorIncludesValue() {
        XCTAssertThrowsError(
            try McpClient.parseToolArguments("not json at all")
        ) { err in
            let msg = "\(err)"
            XCTAssertTrue(msg.contains("got not json at all"), msg)
        }
    }

    func testEmptyArgumentsStillMapsToNil() throws {
        XCTAssertNil(try McpClient.parseToolArguments(""))
        XCTAssertNil(try McpClient.parseToolArguments("   "))
    }
}
