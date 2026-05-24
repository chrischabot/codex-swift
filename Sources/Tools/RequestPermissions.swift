import Foundation
import InfraPrimitives

/// `request_permissions` — let the model ask for additional filesystem or
/// network permissions and wait for the host (typically via an approval
/// coordinator + UI prompt) to grant a subset of the requested profile.
/// Upstream parity (Codex H-17 / P3.4,
/// `codex-rs/core/src/tools/handlers/request_permissions.rs` +
/// `shell_spec.rs::create_request_permissions_tool`).
///
/// Schema (verbatim parity with upstream `create_request_permissions_tool`):
///
///     {
///       "type": "object",
///       "properties": {
///         "reason": {"type":"string",
///                    "description":"Optional short explanation for why
///                                   additional permissions are needed."},
///         "permissions": {
///           "type": "object",
///           "properties": {
///             "network":     {"type":"object",
///                              "properties":{"enabled":{"type":"boolean",
///                                                       "description":"Set to true to request network access."}},
///                              "additionalProperties":false},
///             "file_system": {"type":"object",
///                              "properties":{
///                                "read":  {"type":"array",
///                                          "description":"Absolute paths to grant read access to.",
///                                          "items":{"type":"string"}},
///                                "write": {"type":"array",
///                                          "description":"Absolute paths to grant write access to.",
///                                          "items":{"type":"string"}}
///                              },
///                              "additionalProperties":false}
///           },
///           "additionalProperties": false
///         }
///       },
///       "required": ["permissions"],
///       "additionalProperties": false
///     }
///
/// Behaviour:
///   * Parses upstream `RequestPermissionsArgs` and rejects an empty profile
///     (`permissions.network == null && permissions.file_system == null`) the
///     same way the upstream handler does
///     (`request_permissions requires at least one permission`).
///   * Publishes the payload to `RequestPermissionsBus` and BLOCKS until the
///     host responds with a `RequestPermissionsResponse` JSON shape. If no
///     subscriber is attached the tool fails fast with a clear error rather
///     than hanging the turn.
///   * Result: the upstream `RequestPermissionsResponse` JSON
///     (`{permissions, scope, strict_auto_review?}`).
public struct RequestPermissionsTool: Tool {
    public let name = "request_permissions"
    /// Serial — the request is gating future shell executions; it must not
    /// race with other tool calls that depend on the granted permissions.
    public let parallelSafe = false

    public var toolDescription: String {
        // Verbatim from upstream `request_permissions_tool_description`.
        "Request additional filesystem or network permissions from the user and wait for the client to grant a subset of the requested permission profile. Granted permissions apply automatically to later shell-like commands in the current turn, or for the rest of the session if the client approves them at session scope."
    }

    public var jsonSchema: String {
        #"""
        {"type":"object","properties":{"reason":{"type":"string","description":"Optional short explanation for why additional permissions are needed."},"permissions":{"type":"object","properties":{"network":{"type":"object","properties":{"enabled":{"type":"boolean","description":"Set to true to request network access."}},"additionalProperties":false},"file_system":{"type":"object","properties":{"read":{"type":"array","description":"Absolute paths to grant read access to.","items":{"type":"string"}},"write":{"type":"array","description":"Absolute paths to grant write access to.","items":{"type":"string"}}},"additionalProperties":false}},"additionalProperties":false}},"required":["permissions"],"additionalProperties":false}
        """#
    }

    public init() {}

    private struct NetworkArg: Decodable { var enabled: Bool? }
    private struct FsArg: Decodable {
        var read: [String]?
        var write: [String]?
    }
    private struct PermissionsArg: Decodable {
        var network: NetworkArg?
        var file_system: FsArg?
    }
    private struct Args: Decodable {
        var reason: String?
        var permissions: PermissionsArg
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId,
                              output: "invalid request_permissions arguments",
                              success: false, truncated: false)
        }
        let profile = args.permissions
        let networkEmpty = profile.network == nil
        let fsEmpty: Bool = {
            guard let fs = profile.file_system else { return true }
            let r = (fs.read ?? []).isEmpty
            let w = (fs.write ?? []).isEmpty
            return r && w
        }()
        // Upstream rejects an empty profile (both buckets unset). The Swift
        // tool additionally treats `{file_system:{}}` (both lists empty) as
        // empty so the model cannot accidentally request "nothing" and stall
        // the turn waiting for an approval that does nothing.
        if networkEmpty && fsEmpty {
            return ToolResult(callId: call.callId,
                              output: "request_permissions requires at least one permission",
                              success: false, truncated: false)
        }

        let subs = await RequestPermissionsBus.shared.subscriptionCount()
        guard subs > 0 else {
            return ToolResult(callId: call.callId,
                              output: "request_permissions is unavailable: no permission channel attached",
                              success: false, truncated: false)
        }

        let reply = await RequestPermissionsBus.shared.ask(
            callId: call.callId, payloadJSON: call.argumentsJSON)
        guard let reply else {
            return ToolResult(callId: call.callId,
                              output: "request_permissions was cancelled before receiving a response",
                              success: false, truncated: false)
        }
        return ToolResult(callId: call.callId, output: reply,
                          success: true, truncated: false)
    }
}
