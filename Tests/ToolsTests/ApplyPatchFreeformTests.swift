import XCTest
import Foundation
@testable import Tools
@testable import ModelClient
import Sandbox
import InfraPrimitives

/// apply_patch as a Freeform custom-grammar (lark) tool — upstream
/// `core/src/tools/handlers/apply_patch_spec.rs` +
/// `tools/src/responses_api.rs`. Covers:
///   1. The freeform spec shape (type:custom + grammar format).
///   2. Byte-faithful lark grammar (and the environment-id rewrite).
///   3. ApplyPatchTool accepting BOTH raw patch text (custom_tool_call input)
///      and the legacy JSON `{"patch":"…"}` (function_call arguments).
final class ApplyPatchFreeformTests: XCTestCase {

    private func tmpDir() -> String {
        let d = NSTemporaryDirectory() + "ap-freeform-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d,
                                                 withIntermediateDirectories: true)
        return d
    }

    // MARK: - Spec shape

    func testApplyPatchAdvertisesFreeformFormat() {
        let tool = ApplyPatchTool(sandbox: WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite)))
        let fmt = tool.freeformToolFormat
        XCTAssertNotNil(fmt, "apply_patch must declare a freeform tool format")
        XCTAssertEqual(fmt?.type, "grammar")
        XCTAssertEqual(fmt?.syntax, "lark")
        XCTAssertEqual(tool.toolDescription,
            "Use the `apply_patch` tool to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.")
    }

    func testRouterSpecsCarryFreeformFormatForApplyPatchOnly() async {
        let router = ToolRouter(limits: Limits())
        await router.register(ApplyPatchTool(sandbox: WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite))))
        await router.register(EchoSpecTool())
        let specs = await router.specs()
        let ap = specs.first { $0.name == "apply_patch" }
        let echo = specs.first { $0.name == "echo_spec" }
        XCTAssertNotNil(ap?.freeformFormat, "apply_patch spec must be freeform")
        XCTAssertNil(echo?.freeformFormat, "other tools must remain JSON function tools")
    }

    // MARK: - Lark grammar byte fidelity

    func testLarkGrammarIsByteFaithful() {
        let g = ApplyPatchTool.larkGrammar()
        // First and last lines.
        XCTAssertTrue(g.hasPrefix("start: begin_patch hunk+ end_patch\n"))
        XCTAssertTrue(g.hasSuffix("%import common.LF\n"),
                      "grammar must preserve the trailing newline after %import")
        // Spot-check a few exact rules.
        XCTAssertTrue(g.contains("add_line: \"+\" /(.*)/ LF -> line\n"))
        XCTAssertTrue(g.contains("change_context: (\"@@\" | \"@@ \" /(.+)/) LF\n"))
        XCTAssertTrue(g.contains("eof_line: \"*** End of File\" LF\n"))
        // 578 bytes upstream (include_str! of apply_patch.lark).
        XCTAssertEqual(g.utf8.count, 578)
    }

    func testLarkGrammarEnvironmentIdRewrite() {
        let g = ApplyPatchTool.larkGrammar(includeEnvironmentId: true)
        XCTAssertFalse(g.contains("start: begin_patch hunk+ end_patch\n"),
                       "the plain start rule must be rewritten")
        XCTAssertTrue(g.contains("start: begin_patch environment_id? hunk+ end_patch\n"))
        XCTAssertTrue(g.contains("environment_id: \"*** Environment ID: \" filename LF\n"))
    }

    // MARK: - Dual-input handling (raw + JSON)

    func testApplyPatchAcceptsRawPatchEnvelope() async throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = ApplyPatchTool(sandbox: WorkspaceSandbox(
            SandboxPolicy(mode: .workspaceWrite, writableRoots: [root])))
        // Raw freeform input — NOT wrapped in JSON.
        let raw = "*** Begin Patch\n*** Add File: hello.txt\n+hi there\n*** End Patch\n"
        let r = try await tool.run(
            ToolCall(callId: "c1", name: "apply_patch", argumentsJSON: raw), cwd: root)
        XCTAssertTrue(r.success, "raw patch envelope must apply; got: \(r.output)")
        XCTAssertEqual(try String(contentsOfFile: root + "/hello.txt", encoding: .utf8),
                       "hi there\n")
    }

    func testApplyPatchAcceptsLegacyJSONArguments() async throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = ApplyPatchTool(sandbox: WorkspaceSandbox(
            SandboxPolicy(mode: .workspaceWrite, writableRoots: [root])))
        // Legacy JSON function-call shape — must still work (back-compat).
        let patch = "*** Begin Patch\n*** Add File: a.txt\n+abc\n*** End Patch\n"
        let json = String(data: try JSONEncoder().encode(["patch": patch]),
                          encoding: .utf8)!
        let r = try await tool.run(
            ToolCall(callId: "c2", name: "apply_patch", argumentsJSON: json), cwd: root)
        XCTAssertTrue(r.success, "legacy JSON patch must apply; got: \(r.output)")
        XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8), "abc\n")
    }

    // MARK: - v12 Finding 4: success summary ends with a trailing newline

    /// Upstream `print_summary` (lib.rs:851-866) uses `writeln!` for the header
    /// AND each file line, so the tool's stdout ends with a trailing '\n'
    /// (e.g. "Success. Updated the following files:\nA hello.txt\n"). The Swift
    /// router must be byte-identical, including that final newline.
    func testApplyPatchSuccessSummaryHasTrailingNewline() async throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = ApplyPatchTool(sandbox: WorkspaceSandbox(
            SandboxPolicy(mode: .workspaceWrite, writableRoots: [root])))
        let raw = "*** Begin Patch\n*** Add File: hello.txt\n+hi there\n*** End Patch\n"
        let r = try await tool.run(
            ToolCall(callId: "n1", name: "apply_patch", argumentsJSON: raw), cwd: root)
        XCTAssertTrue(r.success, "got: \(r.output)")
        XCTAssertEqual(r.output, "Success. Updated the following files:\nA hello.txt\n")
    }

    // MARK: - v12 Finding 3: empty patch surfaces the bare apply-time message

    /// An empty (boundary-valid) patch is NOT a parse error upstream; the
    /// "No files were modified." text is an apply-time bail surfaced as a BARE
    /// stderr line with NO "apply_patch verification failed:"/"invalid patch:"
    /// prefix (lib.rs:371-373).
    func testApplyPatchEmptyPatchBareMessageViaRouter() async throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = ApplyPatchTool(sandbox: WorkspaceSandbox(
            SandboxPolicy(mode: .workspaceWrite, writableRoots: [root])))
        let raw = "*** Begin Patch\n*** End Patch\n"
        let r = try await tool.run(
            ToolCall(callId: "e1", name: "apply_patch", argumentsJSON: raw), cwd: root)
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.output, "No files were modified.")
    }

    func testApplyPatchRejectsGarbageInput() async throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = ApplyPatchTool(sandbox: WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite)))
        let r = try await tool.run(
            ToolCall(callId: "c3", name: "apply_patch", argumentsJSON: "not a patch and not json"),
            cwd: root)
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("invalid apply_patch arguments"))
    }
}

private struct EchoSpecTool: Tool {
    let name = "echo_spec"; let parallelSafe = true
    var toolDescription: String { "echoes" }
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        ToolResult(callId: call.callId, output: "ok", success: true, truncated: false)
    }
}
