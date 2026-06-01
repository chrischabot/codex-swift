import XCTest
import Foundation
@testable import HarnessCore
@testable import ProtocolModel
@testable import ModelClient

/// Severe tests for #1 (replayed function_call name must be a valid OpenAI
/// identifier) and #8 (computer_use is gated through the `.hostControl` approval
/// op).
final class ComputerUseAndContextFidelityTests: XCTestCase {

    private func toolOutputName(_ inputs: [PromptInput]) -> String? {
        for i in inputs {
            if case .toolOutput(_, let name, _, _) = i { return name }
        }
        return nil
    }

    // #1 — a `.userShell` command execution stores the RAW user-typed command as
    // command[0] (e.g. "git status"); replaying that verbatim as a function_call
    // name 400s the Responses API. forPrompt must emit a valid name.
    func testUserShellReplayUsesValidFunctionName() {
        let item = ThreadItem.commandExecution(
            id: ItemId("c1"), command: ["git status --porcelain"], cwd: "/tmp",
            status: .completed, commandActions: [],
            aggregatedOutput: "M file.swift", exitCode: 0, source: .userShell)
        var ctx = ContextManager()
        ctx.load([item])
        let name = toolOutputName(ctx.forPrompt())
        XCTAssertEqual(name, "shell_command",
            "a user-shell command (raw string with spaces) must replay as a valid tool name")
        XCTAssertTrue(ContextManager.isValidFunctionName(name ?? ""),
            "the replayed name must satisfy ^[A-Za-z0-9_-]+$")
    }

    // The agent tool-call path keeps the real (already-valid) tool name.
    func testAgentToolCallKeepsRealName() {
        for tool in ["shell_command", "apply_patch"] {
            let item = ThreadItem.commandExecution(
                id: ItemId("c"), command: [tool], cwd: "/tmp",
                status: .completed, commandActions: [],
                aggregatedOutput: "ok", exitCode: 0, source: .agent)
            var ctx = ContextManager()
            ctx.load([item])
            XCTAssertEqual(toolOutputName(ctx.forPrompt()), tool)
        }
    }

    func testIsValidFunctionName() {
        XCTAssertTrue(ContextManager.isValidFunctionName("shell_command"))
        XCTAssertTrue(ContextManager.isValidFunctionName("apply_patch"))
        XCTAssertTrue(ContextManager.isValidFunctionName("web-search_2"))
        XCTAssertFalse(ContextManager.isValidFunctionName(""))
        XCTAssertFalse(ContextManager.isValidFunctionName("git status"))   // space
        XCTAssertFalse(ContextManager.isValidFunctionName("ls -la"))       // space + dash-with-space
        XCTAssertFalse(ContextManager.isValidFunctionName("echo|cat"))     // pipe
        XCTAssertFalse(ContextManager.isValidFunctionName("café"))         // non-ASCII
    }

    // #8 — computer_use must map to the dedicated host-control approval op and be
    // gated under cautious policies (and NOT under never/onFailure).
    func testComputerUseApprovalOp() {
        XCTAssertEqual(ApprovalPolicyEngine.op(forTool: "computer_use"), .hostControl)
        XCTAssertEqual(ApprovalPolicyEngine.op(forTool: "shell_command"), .command)
        XCTAssertEqual(ApprovalPolicyEngine.op(forTool: "apply_patch"), .patch)
        XCTAssertEqual(ApprovalPolicyEngine.op(forTool: "read_file"), .none)
    }

    func testDecideHostControlPerPolicy() {
        XCTAssertFalse(ApprovalPolicyEngine.decideHostControl(policy: .never),
            "never = the user opted into no prompts")
        XCTAssertFalse(ApprovalPolicyEngine.decideHostControl(policy: .onFailure))
        XCTAssertTrue(ApprovalPolicyEngine.decideHostControl(policy: .onRequest),
            "onRequest must prompt before desktop control")
        XCTAssertTrue(ApprovalPolicyEngine.decideHostControl(policy: .unlessTrusted),
            "unlessTrusted must prompt — desktop control is never trusted")
    }
}
