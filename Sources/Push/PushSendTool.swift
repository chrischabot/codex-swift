import Foundation
import Tools
import ProtocolModel

// ADDONS.md #7 — the model-facing `push_send` tool (renamed from `send_message`
// to avoid the MultiAgent collision, per the Phase 0 §A corrections). It funnels
// through the same durable PushRouter as the CLI / RPC, and is gated TWO ways:
//   1. a declared `.required` approval (Phase 0 #3) so an outbound push always
//      asks for owner consent — it is a `.none`-op tool that would otherwise
//      dispatch with no gate (the confused-deputy hole);
//   2. an optional NAMED-TARGET allowlist so the model can only push to
//      operator-approved destinations, never an arbitrary attacker-chosen URL.
public struct PushSendTool: Tool {
    public let name = "push_send"
    public let parallelSafe = false

    private let router: PushRouter
    /// Operator-approved targets. When non-nil, a push to any other target is
    /// refused BEFORE the approval prompt. nil = any target (still approval-gated).
    private let allowedTargets: Set<String>?

    public init(router: PushRouter, allowedTargets: Set<String>? = nil) {
        self.router = router
        self.allowedTargets = allowedTargets
    }

    public var toolDescription: String {
        "Send an outbound push notification/message to a configured target " +
        "(\"scheme:rest\", e.g. \"ntfy:alerts\" or \"telegram:12345\")."
    }

    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"target":{"type":"string","description":"scheme:rest target"},"text":{"type":"string","description":"message body"}},"required":["target","text"],"additionalProperties":false}
        """#
    }

    private struct Args: Decodable { let target: String; let text: String }

    private func parseArgs(_ call: ToolCall) -> Args? {
        guard let data = call.argumentsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Args.self, from: data)
    }

    public func approvalRequirement(_ call: ToolCall) -> ToolApprovalRequirement {
        guard let args = parseArgs(call) else {
            return .required(summary: "send an outbound push")
        }
        return .required(summary: "send an outbound push to '\(args.target)'")
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let args = parseArgs(call), !args.target.isEmpty else {
            return ToolResult(callId: call.callId, output: "push_send: invalid arguments (need target + text)",
                              success: false, truncated: false)
        }
        if let allowed = allowedTargets, !allowed.contains(args.target) {
            return ToolResult(callId: call.callId,
                              output: "push_send: target '\(args.target)' is not in the allowed-target list",
                              success: false, truncated: false)
        }
        let result = await router.send(target: args.target, text: args.text)
        return ToolResult(callId: call.callId,
                          output: result.ok ? "push_send: \(result.detail)" : "push_send failed: \(result.detail)",
                          success: result.ok, truncated: false)
    }
}
