import XCTest
import Foundation
@testable import MCP
@testable import Tools

/// tools-router audit (v13) parallel-safety findings.
///
/// Finding 1 (major): MCP tool calls must be SERIAL. Upstream
/// `McpToolHandler::supports_parallel_tool_calls` returns
/// `self.tool_info.supports_parallel_tool_calls`
/// (core/src/tools/handlers/mcp.rs:86-88), and the production `rmcp` client
/// always sets that to `false` (codex-mcp/src/rmcp_client.rs:378), so every MCP
/// tool takes the exclusive side of the per-turn tool gate.
///
/// Finding 2 (minor, intentional alignment): MCP RESOURCE tools
/// (list_mcp_resources, list_mcp_resource_templates, read_mcp_resource) are
/// parallel-safe upstream — all three handlers explicitly override
/// `supports_parallel_tool_calls -> true`
/// (core/src/tools/handlers/mcp_resource/*.rs:39-41). The backlog's claim that
/// they inherit the default `false` is factually incorrect, so the Swift
/// `parallelSafe = true` is the faithful reproduction. This test pins that.
final class ToolsRouterParallelSafetyTests: XCTestCase {

    private actor StubMcpClient: McpClientProtocol {
        func start() throws {}
        func initialize() async throws {}
        func supportsSandboxStateMeta() async -> Bool { false }
        func serverInstructions() async -> String? { nil }
        func listTools() async throws -> [McpToolSpec] { [] }
        func callTool(_ name: String, argumentsJSON: String,
                      meta: [String: Any]?,
                      elicitationHandler: McpElicitationHandler?) async throws -> McpCallResult {
            McpCallResult(text: "ok", isError: false)
        }
        func readResource(uri: String) async throws -> [String: JSONLite] { [:] }
        func stop() async {}
    }

    // Finding 1: MCP tool proxy is serial (exclusive gate), not parallel-safe.
    func testMcpToolProxyIsSerial() {
        let proxy = McpToolProxy(server: "srv", tool: "do_thing", client: StubMcpClient())
        XCTAssertFalse(proxy.parallelSafe,
            "Upstream always serializes MCP tool calls (rmcp_client.rs:378 supports_parallel_tool_calls=false)")
    }

    // Finding 2 (intentional): resource tools remain parallel-safe to match the
    // upstream explicit override to true.
    func testMcpResourceToolsRemainParallelSafe() {
        let mgr = McpManager()
        XCTAssertTrue(ListMcpResourcesTool(manager: mgr).parallelSafe,
            "list_mcp_resources upstream supports_parallel_tool_calls -> true")
        XCTAssertTrue(ListMcpResourceTemplatesTool(manager: mgr).parallelSafe,
            "list_mcp_resource_templates upstream supports_parallel_tool_calls -> true")
        XCTAssertTrue(ReadMcpResourceTool(manager: mgr).parallelSafe,
            "read_mcp_resource upstream supports_parallel_tool_calls -> true")
    }
}
