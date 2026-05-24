import XCTest
import Foundation
@testable import Tools
@testable import InfraPrimitives
@testable import Sandbox

final class CodeModeTests: XCTestCase {

    func testNormalizeIdentifier() {
        XCTAssertEqual(CodeMode.normalizeIdentifier("My Tool!!"), "my_tool")
        XCTAssertEqual(CodeMode.normalizeIdentifier("a--b__c"), "a_b_c")
        XCTAssertEqual(CodeMode.normalizeIdentifier("___"), "_")
        XCTAssertEqual(CodeMode.normalizeIdentifier("OK"), "ok")
    }

    func testIsNestedTool() {
        // Both `exec` (PUBLIC_TOOL_NAME) and `wait` (WAIT_TOOL_NAME) are
        // excluded from nested re-entry, matching upstream
        // `is_code_mode_nested_tool`.
        XCTAssertFalse(CodeMode.isNestedTool("exec"))
        XCTAssertFalse(CodeMode.isNestedTool("wait"))
        XCTAssertFalse(CodeMode.isNestedTool("mcp__srv__t"))
        XCTAssertTrue(CodeMode.isNestedTool("shell_command"))
    }

    func testRenderSampleDeterministicAndFiltered() {
        let a = CodeMode.renderSample(toolNames: ["shell_command", "exec", "wait", "mcp__x__y", "apply_patch"])
        let b = CodeMode.renderSample(toolNames: ["shell_command", "exec", "wait", "mcp__x__y", "apply_patch"])
        XCTAssertEqual(a, b)
        // Self-referencing `exec` / `wait` and namespaced MCP tools are filtered out.
        XCTAssertFalse(a.contains("callTool(\"exec\""))
        XCTAssertFalse(a.contains("callTool(\"wait\""))
        XCTAssertFalse(a.contains("mcp__x__y"))
        XCTAssertTrue(a.contains("callTool(\"apply_patch\""))
        XCTAssertTrue(a.contains("callTool(\"shell_command\""))
        // Sorted: apply_patch precedes shell_command.
        let ai = a.range(of: "apply_patch")!.lowerBound
        let si = a.range(of: "\"shell_command\"")!.lowerBound
        XCTAssertTrue(ai < si)
    }

    func testCodeModeToolBadArgs() async throws {
        let tool = CodeModeTool(dispatch: { _, _, _, _ in "{}" })

        let bad = try await tool.run(
            ToolCall(callId: "c0", name: "exec", argumentsJSON: "{}"),
            cwd: ".")
        XCTAssertFalse(bad.success)
        XCTAssertEqual(bad.output, "invalid exec arguments")

        let good = try await tool.run(
            ToolCall(callId: "c1", name: "exec",
                     argumentsJSON: #"{"source":"return 1"}"#),
            cwd: ".")
        #if canImport(JavaScriptCore)
        XCTAssertTrue(good.success)
        XCTAssertEqual(good.output, "1")
        #else
        XCTAssertFalse(good.success)
        XCTAssertTrue(good.output.contains("JavaScriptCore"))
        XCTAssertTrue(good.output.contains("callTool"))
        #endif
    }

    func testInstallCodeModeRegistersExecAndWaitTools() async {
        let router = ToolRouter(limits: Limits())
        await installCodeMode(on: router, dispatch: { _, _, _, _ in "{}" })
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("exec"), "installCodeMode must register `exec` (upstream PUBLIC_TOOL_NAME)")
        XCTAssertTrue(names.contains("wait"), "installCodeMode must register `wait` (upstream WAIT_TOOL_NAME)")
    }

    func testCodeModeToolIsNamedExec() {
        // Asserts the model-visible name matches upstream
        // `codex_code_mode::PUBLIC_TOOL_NAME = "exec"`.
        let tool = CodeModeTool(dispatch: { _, _, _, _ in "{}" })
        XCTAssertEqual(tool.name, "exec")
        XCTAssertEqual(CodeMode.publicToolName, "exec")
    }

    func testWaitToolIsRegistered() async {
        // DefaultTools.register must install the `wait` tool alongside `exec`
        // so the tool inventory matches upstream's code-mode pair.
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        let names = Set((await router.specs()).map { $0.name })
        XCTAssertTrue(names.contains("wait"),
                      "DefaultTools.register must expose the `wait` tool (upstream WAIT_TOOL_NAME)")
    }

    func testWaitToolHasUpstreamCompatibleSchema() throws {
        // Mirrors upstream `wait_spec.rs::create_wait_tool()`:
        //   required: ["cell_id"]
        //   properties: cell_id (string), yield_time_ms (number),
        //               max_tokens (number), terminate (boolean)
        //   additionalProperties: false
        let tool = WaitTool()
        XCTAssertEqual(tool.name, "wait")
        XCTAssertEqual(CodeMode.waitToolName, "wait")

        let schemaData = Data(tool.jsonSchema.utf8)
        let parsed = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]

        XCTAssertEqual(parsed["type"] as? String, "object")
        XCTAssertEqual(parsed["additionalProperties"] as? Bool, false)
        XCTAssertEqual(parsed["required"] as? [String], ["cell_id"])

        let props = parsed["properties"] as! [String: Any]
        // cell_id is a string.
        XCTAssertEqual((props["cell_id"] as? [String: Any])?["type"] as? String, "string")
        // Numeric fields use upstream's `number` (not `integer`).
        XCTAssertEqual((props["yield_time_ms"] as? [String: Any])?["type"] as? String, "number")
        XCTAssertEqual((props["max_tokens"] as? [String: Any])?["type"] as? String, "number")
        // terminate is a boolean.
        XCTAssertEqual((props["terminate"] as? [String: Any])?["type"] as? String, "boolean")

        // Description mentions the exec pair and the cell_id-driven behavior
        // so the model recognizes how to use it.
        XCTAssertTrue(tool.toolDescription.contains("`exec`"))
        XCTAssertTrue(tool.toolDescription.contains("cell_id"))
    }

    func testWaitToolRunReportsNoLiveCell() async throws {
        // The Swift `exec` runtime never yields cells; any `wait` call must
        // surface that honestly rather than silently succeed.
        let tool = WaitTool()
        let result = try await tool.run(
            ToolCall(callId: "cw", name: "wait",
                     argumentsJSON: #"{"cell_id":"abc"}"#),
            cwd: ".")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("no live exec cell"), result.output)
        XCTAssertTrue(result.output.contains("abc"), result.output)
    }

    func testDispatchBridgeContract() async {
        let router = ToolRouter(limits: Limits())
        await installCodeMode(on: router, dispatch: { _, _, _, _ in #"{"ok":true}"# })
        let call = ToolCall(callId: "cbridge", name: "exec",
                            argumentsJSON: #"{"source":"return 1"}"#)
        let result = await router.dispatch(call, cwd: ".",
                                           deadline: Deadline.fromNow(.seconds(30)))
        XCTAssertEqual(result.callId, "cbridge")
        #if canImport(JavaScriptCore)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "1")
        #else
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("JavaScriptCore"))
        XCTAssertTrue(result.output.contains("callTool"))
        #endif
    }

    #if canImport(JavaScriptCore)
    func testJSCallToolRoundTrip() async throws {
        let tool = CodeModeTool(dispatch: { _, _, _, _ in #"{"v":42}"# })
        let result = try await tool.run(
            ToolCall(callId: "cjs", name: "exec",
                     argumentsJSON: #"{"source":"return JSON.stringify(callTool(\"echo\",{}))"}"#),
            cwd: ".")
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("42"))
    }
    #endif

    func testDefaultCodeToolCallsNestedReadFileWithoutGateDeadlock() async throws {
        let root = NSTemporaryDirectory() + "codexkit-code-mode-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "nested-ok".write(toFile: root + "/note.txt", atomically: true, encoding: .utf8)

        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))

        let specs = await router.specs()
        XCTAssertTrue(specs.contains { $0.name == "exec" },
                      "DefaultTools must advertise code-mode on macOS builds")
        #if canImport(JavaScriptCore)
        let result = await router.dispatch(
            ToolCall(callId: "cnested",
                     name: "exec",
                     argumentsJSON: #"{"source":"return callTool(\"read_file\", {path:\"note.txt\"})"}"#),
            cwd: root,
            deadline: .fromNow(.seconds(5)))
        XCTAssertTrue(result.success, result.output)
        XCTAssertEqual(result.output, "nested-ok")
        #else
        let result = await router.dispatch(
            ToolCall(callId: "cnested",
                     name: "exec",
                     argumentsJSON: #"{"source":"return callTool(\"read_file\", {path:\"note.txt\"})"}"#),
            cwd: root,
            deadline: .fromNow(.seconds(5)))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("JavaScriptCore"))
        #endif
    }

    func testDefaultCodeToolCallsNestedSerialWriteFileWithoutGateDeadlock() async throws {
        let root = NSTemporaryDirectory() + "codexkit-code-mode-write-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(
            on: router,
            sandbox: WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [root])))

        let result = await router.dispatch(
            ToolCall(callId: "cwrite",
                     name: "exec",
                     argumentsJSON: #"{"source":"return callTool(\"write_file\", {path:\"from-code.txt\", content:\"serial-ok\"})"}"#),
            cwd: root,
            deadline: .fromNow(.seconds(5)))

        #if canImport(JavaScriptCore)
        XCTAssertTrue(result.success, result.output)
        XCTAssertTrue(result.output.contains("wrote 9 bytes"))
        XCTAssertEqual(try String(contentsOfFile: root + "/from-code.txt", encoding: .utf8),
                       "serial-ok")
        #else
        XCTAssertFalse(result.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/from-code.txt"))
        XCTAssertTrue(result.output.contains("JavaScriptCore"))
        #endif
    }
}
