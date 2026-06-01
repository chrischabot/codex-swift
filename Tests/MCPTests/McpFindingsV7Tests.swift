import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import InfraPrimitives

/// Targeted unit tests for the v7 MCP audit findings.
final class McpFindingsV7Tests: XCTestCase {

    // MARK: - Finding 1: tool-name collision resolution + 64-char hashing

    /// SHA1 hex matches the canonical value (parity with upstream `sha1_hex`).
    func testSha1HexCanonical() {
        // SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
        XCTAssertEqual(McpToolNormalization.sha1Hex("abc"),
                       "a9993e364706816aba3e25717850c26c9cd0d89d")
        // SHA1("") = da39a3ee5e6b4b0d3255bfef95601890afd80709
        XCTAssertEqual(McpToolNormalization.sha1Hex(""),
                       "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    /// A single non-colliding short tool keeps the plain `mcp__server__tool`
    /// name (no hash suffix, no truncation).
    func testSingleToolNoHash() {
        let info = McpToolNormalization.ToolInfo(
            serverName: "srv", toolName: "do_thing",
            tool: McpToolSpec(name: "do_thing", description: "", inputSchemaJSON: "{}"))
        let out = McpToolNormalization.normalizeToolsForModel([info])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].modelName, "mcp__srv__do_thing")
    }

    /// Two tools that sanitize to the SAME model name (differ only by a
    /// character that sanitizes to `_`) must NOT collide: both survive with
    /// distinct, hash-suffixed names, both <= 64 chars.
    func testCollidingToolNamesGetDistinctHashedNames() {
        // "a.b" and "a-b" both sanitize to "a_b".
        let t1 = McpToolNormalization.ToolInfo(
            serverName: "srv", toolName: "a.b",
            tool: McpToolSpec(name: "a.b", description: "", inputSchemaJSON: "{}"))
        let t2 = McpToolNormalization.ToolInfo(
            serverName: "srv", toolName: "a-b",
            tool: McpToolSpec(name: "a-b", description: "", inputSchemaJSON: "{}"))
        let out = McpToolNormalization.normalizeToolsForModel([t1, t2])
        XCTAssertEqual(out.count, 2, "both colliding tools must survive")
        let names = Set(out.map { $0.modelName })
        XCTAssertEqual(names.count, 2, "model names must be unique: \(names)")
        for n in names {
            XCTAssertLessThanOrEqual(n.count, 64)
            XCTAssertTrue(n.hasPrefix("mcp__srv__a_b"),
                          "hash suffix is appended to the sanitized base: \(n)")
        }
        // Each name routes back to the correct original tool name.
        let byTool = Dictionary(uniqueKeysWithValues: out.map { ($0.toolName, $0.modelName) })
        XCTAssertNotNil(byTool["a.b"])
        XCTAssertNotNil(byTool["a-b"])
        XCTAssertNotEqual(byTool["a.b"], byTool["a-b"])
    }

    /// An over-64-char model name is truncated and hash-fitted to <= 64.
    func testOverLengthNameTruncatedToFit() {
        let longTool = String(repeating: "x", count: 200)
        let info = McpToolNormalization.ToolInfo(
            serverName: "srv", toolName: longTool,
            tool: McpToolSpec(name: longTool, description: "", inputSchemaJSON: "{}"))
        let out = McpToolNormalization.normalizeToolsForModel([info])
        XCTAssertEqual(out.count, 1)
        XCTAssertLessThanOrEqual(out[0].modelName.count, 64)
        XCTAssertTrue(out[0].modelName.hasPrefix("mcp__srv__x"))
    }

    /// Exact-duplicate raw identities are skipped with a warning (upstream
    /// `warn!("skipping duplicated tool ...")`), not registered twice.
    func testExactDuplicateRawIdentitySkipped() {
        let spec = McpToolSpec(name: "dup", description: "", inputSchemaJSON: "{}")
        let a = McpToolNormalization.ToolInfo(serverName: "srv", toolName: "dup", tool: spec)
        let b = McpToolNormalization.ToolInfo(serverName: "srv", toolName: "dup", tool: spec)
        var warnings: [String] = []
        let out = McpToolNormalization.normalizeToolsForModel([a, b]) { warnings.append($0) }
        XCTAssertEqual(out.count, 1, "duplicate raw identity is dropped")
        XCTAssertTrue(warnings.contains { $0.contains("skipping duplicated tool dup") },
                      "warnings: \(warnings)")
    }

    /// Cross-server namespace collisions (two servers that sanitize to the same
    /// namespace) are disambiguated so tools from both remain reachable.
    func testCollidingNamespacesDisambiguated() {
        // "a.b" and "a-b" servers both sanitize to "mcp__a_b__".
        let s1 = McpToolNormalization.ToolInfo(
            serverName: "a.b", toolName: "t",
            tool: McpToolSpec(name: "t", description: "", inputSchemaJSON: "{}"))
        let s2 = McpToolNormalization.ToolInfo(
            serverName: "a-b", toolName: "t",
            tool: McpToolSpec(name: "t", description: "", inputSchemaJSON: "{}"))
        let out = McpToolNormalization.normalizeToolsForModel([s1, s2])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Set(out.map { $0.modelName }).count, 2,
                       "namespace collision must yield distinct names")
    }

    // MARK: - Finding 4: non-object tool arguments rejected

    func testNonObjectArgumentsRejected() {
        XCTAssertThrowsError(try McpClient.parseToolArguments("[1,2,3]")) { e in
            XCTAssertTrue("\(e)".contains("must be a JSON object"), "\(e)")
        }
        XCTAssertThrowsError(try McpClient.parseToolArguments("42")) { e in
            XCTAssertTrue("\(e)".contains("must be a JSON object"), "\(e)")
        }
        XCTAssertThrowsError(try McpClient.parseToolArguments("\"hi\"")) { e in
            XCTAssertTrue("\(e)".contains("must be a JSON object"), "\(e)")
        }
        XCTAssertThrowsError(try McpClient.parseToolArguments("not json")) { e in
            XCTAssertTrue("\(e)".contains("must be a JSON object"), "\(e)")
        }
    }

    func testEmptyArgumentsMapToNoArguments() throws {
        XCTAssertNil(try McpClient.parseToolArguments(""))
        XCTAssertNil(try McpClient.parseToolArguments("   "))
    }

    func testObjectArgumentsParsed() throws {
        let parsed = try McpClient.parseToolArguments(#"{"a":1,"b":"x"}"#)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["b"] as? String, "x")
    }

    // MARK: - Finding 5: server-name validation

    func testServerNameValidation() {
        XCTAssertNil(McpManager.validateServerName("good_name-123"))
        XCTAssertNil(McpManager.validateServerName("OK"))
        XCTAssertNotNil(McpManager.validateServerName(""))
        XCTAssertNotNil(McpManager.validateServerName("has space"))
        XCTAssertNotNil(McpManager.validateServerName("has.dot"))
        XCTAssertNotNil(McpManager.validateServerName("has/slash"))
        if let msg = McpManager.validateServerName("bad name") {
            XCTAssertTrue(msg.contains("Invalid MCP server name 'bad name'"), msg)
            XCTAssertTrue(msg.contains("a-zA-Z0-9_-"), msg)
        } else {
            XCTFail("expected validation error")
        }
    }

    /// A server with an invalid name is marked failed and never started.
    func testInvalidServerNameMarkedFailed() async {
        let mgr = McpManager()
        let router = ToolRouter(limits: Limits())
        let cfg = McpServerConfig(name: "bad name", command: "/bin/true")
        await mgr.startAll([cfg], router: router)
        let statuses = await mgr.statusList()
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0].state, "failed")
        XCTAssertTrue(statuses[0].error?.contains("Invalid MCP server name") ?? false,
                      "\(String(describing: statuses[0].error))")
    }

    // MARK: - Finding 2: CallToolResult preserves content / structuredContent / _meta

    func testDecodePreservesStructuredContentAndMeta() {
        let r: [String: JSONLite] = [
            "content": .array([
                .object(["type": .string("text"), "text": .string("hello")]),
            ]),
            "structuredContent": .object(["k": .string("v")]),
            "_meta": .object(["m": .number(1)]),
            "isError": .bool(false),
        ]
        let result = McpResultDecoder.decode(r)
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.content.count, 1)
        XCTAssertEqual(result.structuredContent, .object(["k": .string("v")]))
        XCTAssertEqual(result.meta, .object(["m": .number(1)]))
        XCTAssertFalse(result.isError)
    }

    func testDecodeImageBlockBecomesPlaceholder() {
        let r: [String: JSONLite] = [
            "content": .array([
                .object(["type": .string("image"),
                         "data": .string("base64..."),
                         "mimeType": .string("image/png")]),
                .object(["type": .string("text"), "text": .string(" caption")]),
            ]),
        ]
        let result = McpResultDecoder.decode(r)
        XCTAssertEqual(result.content.count, 2)
        // The image block was replaced by a text placeholder block.
        if case .object(let o)? = result.content.first {
            XCTAssertEqual(o["type"], .string("text"))
            XCTAssertEqual(o["text"], .string(McpResultDecoder.imageOmittedPlaceholder))
        } else {
            XCTFail("first block should be a placeholder text block")
        }
        XCTAssertTrue(result.text.contains(McpResultDecoder.imageOmittedPlaceholder))
        XCTAssertTrue(result.text.contains(" caption"))
    }

    func testDecodeNonTextBlockPreservedVerbatim() {
        // A resource_link block (non-text, non-image) is preserved as-is and
        // contributes no text.
        let block: JSONLite = .object([
            "type": .string("resource_link"),
            "uri": .string("file:///x"),
        ])
        let r: [String: JSONLite] = ["content": .array([block])]
        let result = McpResultDecoder.decode(r)
        XCTAssertEqual(result.content, [block])
        XCTAssertEqual(result.text, "")
    }
}
