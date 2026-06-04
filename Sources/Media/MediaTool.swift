import Foundation
import Tools
import ProtocolModel

/// The model-facing `media_generate` tool. Generation is async: the tool submits
/// and returns a task_id immediately (the turn never blocks on a slow render);
/// the supervisor poller finishes + delivers. Setting `deliver_to` (a push
/// target #7) makes the result push outbound — so that variant declares a
/// `.required` approval (owner consent for an outbound delivery), while a plain
/// generate-and-hold is ungated.
public struct MediaGenerateTool: Tool {
    public let name = "media_generate"
    public let parallelSafe = false

    private let ledger: MediaTaskLedger

    public init(ledger: MediaTaskLedger) { self.ledger = ledger }

    public var toolDescription: String {
        "Generate media asynchronously. kind ∈ " +
        MediaKind.allCases.map(\.rawValue).joined(separator: "/") +
        ". Returns a task_id immediately; the result is delivered when ready. " +
        "Set deliver_to (a push target like \"ntfy:topic\") to push the asset."
    }

    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"kind":{"type":"string"},"prompt":{"type":"string"},"deliver_to":{"type":"string"},"idempotency_key":{"type":"string"}},"required":["kind","prompt"],"additionalProperties":false}
        """#
    }

    private struct Args: Decodable {
        let kind: String
        let prompt: String
        let deliver_to: String?
        let idempotency_key: String?
    }
    private func parse(_ call: ToolCall) -> Args? {
        guard let d = call.argumentsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Args.self, from: d)
    }

    public func approvalRequirement(_ call: ToolCall) -> ToolApprovalRequirement {
        // Only the OUTBOUND-delivering variant needs consent.
        guard let args = parse(call), args.deliver_to != nil else { return .none }
        return .required(summary: "generate \(args.kind) and push to '\(args.deliver_to!)'")
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let args = parse(call), let kind = MediaKind(rawValue: args.kind.lowercased()),
              !args.prompt.isEmpty else {
            return ToolResult(callId: call.callId,
                              output: "media_generate: invalid arguments (need kind ∈ \(MediaKind.allCases.map(\.rawValue).joined(separator: "/")) + prompt)",
                              success: false, truncated: false)
        }
        let task = await ledger.submit(kind: kind, prompt: args.prompt,
                                       idempotencyKey: args.idempotency_key, deliverTo: args.deliver_to)
        let status: String
        switch task.status {
        case .done:   status = task.assetPath.map { "done: \($0)" } ?? "done"
        case .failed: status = "failed: \(task.error ?? "unknown")"
        default:      status = "queued"
        }
        return ToolResult(callId: call.callId,
                          output: "media_generate task_id=\(task.id) status=\(status)",
                          success: task.status != .failed, truncated: false)
    }
}
