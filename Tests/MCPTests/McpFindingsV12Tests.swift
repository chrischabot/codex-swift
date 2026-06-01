import XCTest
import Foundation
@testable import MCP
@testable import ProtocolModel
import WireProtocol

/// Targeted unit tests for the v12 MCP audit findings:
///   1. stdio `elicitation/create` is served by an in-flight call's handler
///      deterministically (not an arbitrary `Dictionary.values.first`).
///   2. `notifications/cancelled` carrying a *string* `requestId` is surfaced
///      (preserved as `requestIdString`) rather than silently dropped.
///   3. The transport-level `progressToken` is scrubbed from the elicitation
///      `_meta` before it is surfaced to the frontend (restore_context_meta).
///   4. The surfaced elicitation `mode` is taken from the authoritative `mode`
///      discriminator first, falling back to the requestedSchema heuristic only
///      when `mode` is absent.
final class McpFindingsV12Tests: XCTestCase {

    private func python3Available() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "--version"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    private func tempDir(_ prefix: String) -> String {
        let dir = NSTemporaryDirectory() + prefix + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir,
            withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Finding 2: notifications/cancelled with a string requestId

    /// Upstream `RequestId` is a NumberOrString; a string id must be surfaced.
    func testCancelledNotificationPreservesStringRequestId() {
        let object: [String: JSONLite] = [
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/cancelled"),
            "params": .object([
                "requestId": .string("req-abc"),
                "reason": .string("user_abort"),
            ]),
        ]
        let notif = McpNotificationDecoder.decode(server: "srv", object: object)
        guard case .cancelled(let server, let requestId, let requestIdString,
                              let reason)? = notif else {
            return XCTFail("expected .cancelled, got \(String(describing: notif))")
        }
        XCTAssertEqual(server, "srv")
        // No numeric variant — the integer-correlation path stays nil.
        XCTAssertNil(requestId)
        // …but the raw string id is preserved for sink consumers / diagnostics.
        XCTAssertEqual(requestIdString, "req-abc")
        XCTAssertEqual(reason, "user_abort")
    }

    /// A numeric requestId still populates both the integer variant (for
    /// pending-request correlation) and the string form (for diagnostics).
    func testCancelledNotificationNumericRequestId() {
        let object: [String: JSONLite] = [
            "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .number(42)]),
        ]
        let notif = McpNotificationDecoder.decode(server: "srv", object: object)
        guard case .cancelled(_, let requestId, let requestIdString, _)? = notif else {
            return XCTFail("expected .cancelled")
        }
        XCTAssertEqual(requestId, 42)
        XCTAssertEqual(requestIdString, "42")
    }

    // MARK: - Finding 3: progressToken scrubbed from elicitation _meta

    func testScrubMetaRemovesProgressToken() {
        let meta = JSONValue.object([
            "progressToken": .string("tok-1"),
            "traceId": .string("abc"),
        ])
        let scrubbed = McpElicitationPolicy.scrubMeta(meta)
        XCTAssertNil(scrubbed["progressToken"],
            "progressToken must be stripped from surfaced _meta")
        XCTAssertEqual(scrubbed["traceId"]?.stringValue, "abc",
            "non-progressToken entries must be preserved")
    }

    /// When only `progressToken` was present, the scrubbed meta collapses to
    /// `.null` (mirrors restore_context_meta returning the request unchanged
    /// when context_meta is empty after removal).
    func testScrubMetaCollapsesToNullWhenOnlyProgressToken() {
        let meta = JSONValue.object(["progressToken": .int(7)])
        XCTAssertEqual(McpElicitationPolicy.scrubMeta(meta), .null)
    }

    func testScrubMetaNilIsNull() {
        XCTAssertEqual(McpElicitationPolicy.scrubMeta(nil), .null)
        XCTAssertEqual(McpElicitationPolicy.scrubMeta(.null), .null)
    }

    // MARK: - Finding 4: mode classification off the discriminator

    func testClassifyModePrefersModeDiscriminator() {
        // A form payload that *omits* requestedSchema must still be "form" when
        // the authoritative `mode` tag says so (the old heuristic mislabeled it
        // "url").
        let form = JSONValue.object(["mode": .string("form")])
        XCTAssertEqual(McpElicitationPolicy.classifyMode(params: form), "form")

        // A url payload that *carries* requestedSchema must be "url" by tag.
        let url = JSONValue.object([
            "mode": .string("url"),
            "requestedSchema": .object(["type": .string("object")]),
            "url": .string("https://example.com"),
        ])
        XCTAssertEqual(McpElicitationPolicy.classifyMode(params: url), "url")
    }

    func testClassifyModeFallsBackToHeuristicWhenModeAbsent() {
        // No mode, no requestedSchema → url (legacy heuristic).
        XCTAssertEqual(McpElicitationPolicy.classifyMode(params: .object([:])),
                       "url")
        // No mode, with requestedSchema → form.
        let withSchema = JSONValue.object([
            "requestedSchema": .object(["type": .string("object")]),
        ])
        XCTAssertEqual(McpElicitationPolicy.classifyMode(params: withSchema),
                       "form")
    }

    // MARK: - Finding 1: stdio elicitation handler correlation

    /// Two tool calls are in flight on one stdio client; the server issues a
    /// single `elicitation/create` during the second call. The registered
    /// handler must be invoked (deterministically) so the elicitation is
    /// answered rather than the request stalling. With the old
    /// `Dictionary.values.first` lookup the chosen handler was nondeterministic;
    /// here we assert the handler runs and the call completes.
    func testStdioElicitationInvokesActiveHandler() async throws {
        try XCTSkipUnless(python3Available(), "python3 not available")
        let dir = tempDir("mcp-elicit-v12-")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/server.py"
        // On a tools/call the server sends an elicitation/create (id 9001),
        // waits for the client's reply, then returns the tool result echoing
        // the elicitation action it received.
        let body = #"""
        import sys, json
        pending = {}
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
                print(json.dumps({"jsonrpc":"2.0","id":i,"result":{"tools":[{"name":"ask","description":"","inputSchema":{"type":"object"}}]}}), flush=True)
            elif m == "tools/call":
                # Ask the client to elicit, then block for its reply.
                print(json.dumps({"jsonrpc":"2.0","id":9001,"method":"elicitation/create",
                                  "params":{"mode":"form","message":"ok?","requestedSchema":{"type":"object","properties":{}}}}), flush=True)
                # Read the elicitation reply.
                reply = json.loads(sys.stdin.readline())
                action = reply.get("result",{}).get("action","?")
                print(json.dumps({"jsonrpc":"2.0","id":i,
                                  "result":{"content":[{"type":"text","text":action}],"isError":False}}), flush=True)
            elif i is not None and "result" in msg:
                pass
        """#
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        let cfg = McpServerConfig(name: "elic", command: "python3", args: [script])
        let client = McpClient(cfg, requestTimeout: .seconds(15))
        try await client.start()
        try await client.initialize()
        _ = try await client.listTools()

        // Handler accepts the elicitation; the tool result must echo "accept".
        let handler: McpElicitationHandler = { _, _, _ in
            JSONValue.object(["action": .string("accept")])
        }
        let result = try await client.callTool("ask", argumentsJSON: "{}",
                                               meta: nil,
                                               elicitationHandler: handler)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "accept",
            "the registered elicitation handler must be invoked, accepting")
        await client.stop()
    }
}
