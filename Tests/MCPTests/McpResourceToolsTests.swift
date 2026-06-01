import XCTest
import Foundation
@testable import MCP
@testable import Tools
@testable import InfraPrimitives

/// Tests for the model-visible MCP resource tools (audit tools-router finding 1):
/// `list_mcp_resources`, `list_mcp_resource_templates`, `read_mcp_resource`.
/// Ports the spec assertions from upstream `mcp_resource_spec_tests.rs` plus the
/// single-/all-server behavior from `mcp_resource_tests.rs`.
final class McpResourceToolsTests: XCTestCase {

    /// Mock client that serves canned resource/template/read pages.
    private actor FakeResourceClient: McpClientProtocol {
        let resources: [JSONLite]
        let templates: [JSONLite]
        let read: [String: JSONLite]
        init(resources: [JSONLite] = [], templates: [JSONLite] = [],
             read: [String: JSONLite] = [:]) {
            self.resources = resources
            self.templates = templates
            self.read = read
        }
        func start() throws {}
        func initialize() async throws {}
        func listTools() async throws -> [McpToolSpec] { [] }
        func callTool(_ name: String, argumentsJSON: String, meta: [String: Any]?,
                      elicitationHandler: McpElicitationHandler?) async throws -> McpCallResult {
            McpCallResult(text: "", isError: false)
        }
        func readResource(uri: String) async throws -> [String: JSONLite] { read }
        func listResourcesPage(cursor: String?) async throws -> [String: JSONLite] {
            ["resources": .array(resources)]
        }
        func listResourceTemplatesPage(cursor: String?) async throws -> [String: JSONLite] {
            ["resourceTemplates": .array(templates)]
        }
        func stop() async {}
    }

    private func parse(_ s: String) -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { XCTFail("not JSON: \(s)"); return [:] }
        return o
    }

    // MARK: - Spec parity (mcp_resource_spec_tests.rs)

    func testListMcpResourcesSpecMatchesUpstream() {
        let tool = ListMcpResourcesTool(manager: McpManager())
        XCTAssertEqual(tool.name, "list_mcp_resources")
        XCTAssertTrue(tool.parallelSafe, "upstream supports_parallel_tool_calls=true")
        XCTAssertEqual(tool.toolDescription,
            "Lists resources provided by MCP servers. Resources allow servers to share data that provides context to language models, such as files, database schemas, or application-specific information. Prefer resources over web search when possible.")
        let obj = parse(tool.jsonSchema)
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertNil(obj["required"], "list tools have no required fields")
        let props = obj["properties"] as? [String: Any] ?? [:]
        XCTAssertNotNil(props["server"])
        XCTAssertNotNil(props["cursor"])
    }

    func testListMcpResourceTemplatesSpecMatchesUpstream() {
        let tool = ListMcpResourceTemplatesTool(manager: McpManager())
        XCTAssertEqual(tool.name, "list_mcp_resource_templates")
        XCTAssertTrue(tool.parallelSafe)
        XCTAssertEqual(tool.toolDescription,
            "Lists resource templates provided by MCP servers. Parameterized resource templates allow servers to share data that takes parameters and provides context to language models, such as files, database schemas, or application-specific information. Prefer resource templates over web search when possible.")
        let obj = parse(tool.jsonSchema)
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertNil(obj["required"])
    }

    func testReadMcpResourceSpecMatchesUpstream() {
        let tool = ReadMcpResourceTool(manager: McpManager())
        XCTAssertEqual(tool.name, "read_mcp_resource")
        XCTAssertTrue(tool.parallelSafe)
        XCTAssertEqual(tool.toolDescription,
            "Read a specific resource from an MCP server given the server name and resource URI.")
        let obj = parse(tool.jsonSchema)
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertEqual(obj["required"] as? [String], ["server", "uri"],
                       "read_mcp_resource requires server+uri")
    }

    // MARK: - Behavior

    func testListResourcesSingleServerFlattensServerAndCursor() async throws {
        let mgr = McpManager()
        let client = FakeResourceClient(resources: [
            .object(["uri": .string("file:///a"), "name": .string("a")]),
        ])
        await mgr._seedClientForTesting("srv", client)
        let tool = ListMcpResourcesTool(manager: mgr)
        let r = try await tool.run(ToolCall(callId: "c", name: tool.name,
                                            argumentsJSON: #"{"server":"srv"}"#),
                                   cwd: "/tmp")
        XCTAssertTrue(r.success)
        let out = parse(r.output)
        XCTAssertEqual(out["server"] as? String, "srv")
        let res = out["resources"] as? [[String: Any]] ?? []
        XCTAssertEqual(res.count, 1)
        XCTAssertEqual(res.first?["server"] as? String, "srv",
                       "each resource must be flattened with its server name")
        XCTAssertEqual(res.first?["uri"] as? String, "file:///a")
    }

    func testListResourcesAllServersAggregatesSorted() async throws {
        let mgr = McpManager()
        await mgr._seedClientForTesting("bbb",
            FakeResourceClient(resources: [.object(["uri": .string("file:///b")])]))
        await mgr._seedClientForTesting("aaa",
            FakeResourceClient(resources: [.object(["uri": .string("file:///a")])]))
        let tool = ListMcpResourcesTool(manager: mgr)
        let r = try await tool.run(ToolCall(callId: "c", name: tool.name,
                                            argumentsJSON: "{}"), cwd: "/tmp")
        XCTAssertTrue(r.success)
        let out = parse(r.output)
        XCTAssertNil(out["server"], "all-servers list omits the server field")
        let res = out["resources"] as? [[String: Any]] ?? []
        XCTAssertEqual(res.map { $0["server"] as? String }, ["aaa", "bbb"],
                       "servers must be aggregated in sorted order")
    }

    func testListResourcesCursorWithoutServerIsRejected() async throws {
        let mgr = McpManager()
        await mgr._seedClientForTesting("srv", FakeResourceClient())
        let tool = ListMcpResourcesTool(manager: mgr)
        let r = try await tool.run(ToolCall(callId: "c", name: tool.name,
                                            argumentsJSON: #"{"cursor":"x"}"#),
                                   cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("cursor can only be used when a server is specified"),
                      r.output)
    }

    func testReadMcpResourceFlattensServerAndUri() async throws {
        let mgr = McpManager()
        await mgr._seedClientForTesting("srv",
            FakeResourceClient(read: ["contents": .array([.string("data")])]))
        let tool = ReadMcpResourceTool(manager: mgr)
        let r = try await tool.run(ToolCall(callId: "c", name: tool.name,
            argumentsJSON: #"{"server":"srv","uri":"file:///a"}"#), cwd: "/tmp")
        XCTAssertTrue(r.success)
        let out = parse(r.output)
        XCTAssertEqual(out["server"] as? String, "srv")
        XCTAssertEqual(out["uri"] as? String, "file:///a")
        XCTAssertNotNil(out["contents"], "read result must be flattened onto the payload")
    }

    func testReadMcpResourceMissingFieldsErrors() async throws {
        let mgr = McpManager()
        await mgr._seedClientForTesting("srv", FakeResourceClient())
        let tool = ReadMcpResourceTool(manager: mgr)
        let r1 = try await tool.run(ToolCall(callId: "c", name: tool.name,
            argumentsJSON: #"{"uri":"file:///a"}"#), cwd: "/tmp")
        XCTAssertFalse(r1.success)
        XCTAssertTrue(r1.output.contains("server must be provided"), r1.output)
        let r2 = try await tool.run(ToolCall(callId: "c", name: tool.name,
            argumentsJSON: #"{"server":"srv"}"#), cwd: "/tmp")
        XCTAssertFalse(r2.success)
        XCTAssertTrue(r2.output.contains("uri must be provided"), r2.output)
    }

    func testListTemplatesSingleServer() async throws {
        let mgr = McpManager()
        await mgr._seedClientForTesting("srv",
            FakeResourceClient(templates: [.object(["uriTemplate": .string("file:///{id}")])]))
        let tool = ListMcpResourceTemplatesTool(manager: mgr)
        let r = try await tool.run(ToolCall(callId: "c", name: tool.name,
            argumentsJSON: #"{"server":"srv"}"#), cwd: "/tmp")
        XCTAssertTrue(r.success)
        let out = parse(r.output)
        XCTAssertEqual(out["server"] as? String, "srv")
        let t = out["resourceTemplates"] as? [[String: Any]] ?? []
        XCTAssertEqual(t.first?["server"] as? String, "srv")
    }

    // MARK: - Registration gate (spec_plan.rs:385-389)

    func testResourceToolsRegisteredWhenServerConfigured() async {
        let mgr = McpManager()
        let router = ToolRouter(limits: Limits())
        // A failing/invalid config still means MCP is configured for the thread.
        await mgr.startAll([McpServerConfig(name: "srv", command: "/bin/true")],
                           router: router)
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("list_mcp_resources"))
        XCTAssertTrue(names.contains("list_mcp_resource_templates"))
        XCTAssertTrue(names.contains("read_mcp_resource"))
    }

    func testResourceToolsNotRegisteredWithoutServers() async {
        let mgr = McpManager()
        let router = ToolRouter(limits: Limits())
        await mgr.startAll([], router: router)
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertFalse(names.contains("list_mcp_resources"))
        XCTAssertFalse(names.contains("list_mcp_resource_templates"))
        XCTAssertFalse(names.contains("read_mcp_resource"))
    }
}
