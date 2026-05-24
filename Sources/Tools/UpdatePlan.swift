import Foundation
import InfraPrimitives

/// `update_plan` — let the model emit/update a multi-step TODO/checklist plan
/// that the UI renders. Upstream parity (Codex H-18 / P3.4,
/// `codex-rs/core/src/tools/handlers/plan.rs` + `plan_spec.rs`).
///
/// JSON schema (verbatim parity with upstream `create_update_plan_tool`):
///
///     {
///       "type": "object",
///       "properties": {
///         "explanation": {"type": "string"},
///         "plan": {
///           "type": "array",
///           "description": "The list of steps",
///           "items": {
///             "type": "object",
///             "properties": {
///               "step":   {"type": "string"},
///               "status": {"type": "string",
///                          "description": "One of: pending, in_progress, completed"}
///             },
///             "required": ["step", "status"],
///             "additionalProperties": false
///           }
///         }
///       },
///       "required": ["plan"],
///       "additionalProperties": false
///     }
///
/// Behaviour:
///   * Validates the args against the upstream `UpdatePlanArgs` shape (every
///     `status` must be `pending|in_progress|completed`; rejection otherwise).
///   * Enforces upstream invariant: at most one step may be `in_progress` at
///     a time. Mirrors the description hint upstream surfaces in the spec.
///   * Publishes the parsed payload to `PlanUpdateBus` so `SessionEngine` can
///     emit a `ServerNotification.planUpdate` event for the active turn.
///   * Returns the acknowledgement string `"Plan updated"` (upstream
///     `PlanToolOutput::PLAN_UPDATED_MESSAGE`).
public struct UpdatePlanTool: Tool {
    public let name = "update_plan"
    /// Serial. Updating the rendered plan must be ordered with respect to
    /// the surrounding tool calls so the UI never displays a stale plan after
    /// a newer one was emitted earlier in the same turn.
    public let parallelSafe = false

    public var toolDescription: String {
        // Verbatim from upstream `plan_spec.rs::create_update_plan_tool`.
        "Updates the task plan.\n"
        + "Provide an optional explanation and a list of plan items, each with a step and status.\n"
        + "At most one step can be in_progress at a time.\n"
    }

    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"explanation":{"type":"string"},"plan":{"type":"array","description":"The list of steps","items":{"type":"object","properties":{"step":{"type":"string"},"status":{"type":"string","description":"One of: pending, in_progress, completed"}},"required":["step","status"],"additionalProperties":false}}},"required":["plan"],"additionalProperties":false}
        """#
    }

    public init() {}

    private struct ItemArg: Decodable {
        var step: String
        var status: String
    }
    private struct Args: Decodable {
        var explanation: String?
        var plan: [ItemArg]
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId,
                              output: "invalid update_plan arguments",
                              success: false, truncated: false)
        }
        // Validate every status against the upstream snake_case enum surface
        // (`pending`, `in_progress`, `completed`).
        var inProgressCount = 0
        for item in args.plan {
            switch item.status {
            case "pending", "completed": break
            case "in_progress": inProgressCount += 1
            default:
                return ToolResult(callId: call.callId,
                                  output: "invalid update_plan status: \(item.status)",
                                  success: false, truncated: false)
            }
        }
        if inProgressCount > 1 {
            return ToolResult(callId: call.callId,
                              output: "update_plan: at most one step can be in_progress",
                              success: false, truncated: false)
        }

        // Forward the parsed payload verbatim (the host re-parses to the typed
        // `PlanItemArg` model when emitting the wire notification).
        await PlanUpdateBus.shared.publish(callId: call.callId,
                                           payloadJSON: call.argumentsJSON)

        return ToolResult(callId: call.callId,
                          output: "Plan updated",
                          success: true, truncated: false)
    }
}
