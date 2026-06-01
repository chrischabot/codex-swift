import Foundation
import InfraPrimitives
import Tools

/// Model-visible MCP resource-discovery/read tools. Faithful port of upstream
/// `core/src/tools/handlers/mcp_resource_spec.rs` +
/// `core/src/tools/handlers/mcp_resource/{list_mcp_resources,
/// list_mcp_resource_templates,read_mcp_resource}.rs`.
///
/// Upstream registers all three whenever any MCP server is configured (gated
/// only on `params.mcp_tools.is_some()`, no feature flag — `spec_plan.rs:385-389`).
/// `McpManager.startAll` mirrors that gate, registering these once at least one
/// server is loaded.
///
/// All three handlers declare `supports_parallel_tool_calls() == true`
/// upstream, so the proxies are parallel-safe.

// MARK: - Shared helpers

/// Stable JSON serialization for resource-tool output (sorted keys, no escaped
/// slashes), matching the byte determinism the rest of the MCP layer uses.
private func mcpResourceJSON(_ obj: [String: JSONLite]) -> String {
    JSONLite.stringify(.object(obj))
}

/// Upstream `normalize_optional_string`: trim, then map empty → nil.
private func normalizeOptional(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
    else { return nil }
    return t
}

private func mcpResourceArgs(_ json: String) -> [String: Any] {
    guard let d = json.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    else { return [:] }
    return o
}

/// Build the `resources`/`resourceTemplates` array for the output payload by
/// flattening a `{server, ...resource}` object onto each entry. Upstream
/// `ResourceWithServer`/`ResourceTemplateWithServer` use `#[serde(flatten)]`,
/// so `server` sits alongside the resource's own fields.
private func flattenWithServer(_ server: String, _ items: [JSONLite]) -> [JSONLite] {
    items.map { item in
        guard case .object(var o) = item else {
            return .object(["server": .string(server)])
        }
        o["server"] = .string(server)
        return .object(o)
    }
}

// MARK: - list_mcp_resources

public struct ListMcpResourcesTool: Tool {
    public let name = "list_mcp_resources"
    /// Upstream `supports_parallel_tool_calls() -> true`.
    public let parallelSafe = true

    public var toolDescription: String {
        "Lists resources provided by MCP servers. Resources allow servers to "
        + "share data that provides context to language models, such as files, "
        + "database schemas, or application-specific information. Prefer "
        + "resources over web search when possible."
    }

    /// Upstream `create_list_mcp_resources_tool`. BTreeMap-sorted properties:
    /// `cursor`, `server`; no required fields; `additionalProperties=false`.
    public var jsonSchema: String {
        #"{"type":"object","properties":{"cursor":{"type":"string","description":"Opaque cursor returned by a previous list_mcp_resources call for the same server."},"server":{"type":"string","description":"Optional MCP server name. When omitted, lists resources from every configured server."}},"additionalProperties":false}"#
    }

    private let manager: McpManager
    public init(manager: McpManager) { self.manager = manager }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = mcpResourceArgs(call.argumentsJSON)
        let server = normalizeOptional(a["server"] as? String)
        let cursor = normalizeOptional(a["cursor"] as? String)
        do {
            var payload: [String: JSONLite] = [:]
            if let server {
                let result = try await manager.listResources(server: server, cursor: cursor)
                payload["server"] = .string(server)
                if case .array(let arr)? = result["resources"] {
                    payload["resources"] = .array(flattenWithServer(server, arr))
                } else {
                    payload["resources"] = .array([])
                }
                if case .string(let next)? = result["nextCursor"] {
                    payload["nextCursor"] = .string(next)
                }
            } else {
                if cursor != nil {
                    return ToolResult(callId: call.callId,
                        output: "cursor can only be used when a server is specified",
                        success: false, truncated: false)
                }
                let byServer = await manager.listAllResources()
                var resources: [JSONLite] = []
                for name in byServer.keys.sorted() {
                    resources.append(contentsOf: flattenWithServer(name, byServer[name] ?? []))
                }
                payload["resources"] = .array(resources)
            }
            return ToolResult(callId: call.callId, output: mcpResourceJSON(payload),
                              success: true, truncated: false)
        } catch {
            return ToolResult(callId: call.callId,
                              output: "resources/list failed: \(error)",
                              success: false, truncated: false)
        }
    }
}

// MARK: - list_mcp_resource_templates

public struct ListMcpResourceTemplatesTool: Tool {
    public let name = "list_mcp_resource_templates"
    public let parallelSafe = true

    public var toolDescription: String {
        "Lists resource templates provided by MCP servers. Parameterized "
        + "resource templates allow servers to share data that takes parameters "
        + "and provides context to language models, such as files, database "
        + "schemas, or application-specific information. Prefer resource "
        + "templates over web search when possible."
    }

    /// Upstream `create_list_mcp_resource_templates_tool`. Sorted properties:
    /// `cursor`, `server`; no required fields.
    public var jsonSchema: String {
        #"{"type":"object","properties":{"cursor":{"type":"string","description":"Opaque cursor returned by a previous list_mcp_resource_templates call for the same server."},"server":{"type":"string","description":"Optional MCP server name. When omitted, lists resource templates from all configured servers."}},"additionalProperties":false}"#
    }

    private let manager: McpManager
    public init(manager: McpManager) { self.manager = manager }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = mcpResourceArgs(call.argumentsJSON)
        let server = normalizeOptional(a["server"] as? String)
        let cursor = normalizeOptional(a["cursor"] as? String)
        do {
            var payload: [String: JSONLite] = [:]
            if let server {
                let result = try await manager.listResourceTemplates(server: server,
                                                                      cursor: cursor)
                payload["server"] = .string(server)
                if case .array(let arr)? = result["resourceTemplates"] {
                    payload["resourceTemplates"] = .array(flattenWithServer(server, arr))
                } else {
                    payload["resourceTemplates"] = .array([])
                }
                if case .string(let next)? = result["nextCursor"] {
                    payload["nextCursor"] = .string(next)
                }
            } else {
                if cursor != nil {
                    return ToolResult(callId: call.callId,
                        output: "cursor can only be used when a server is specified",
                        success: false, truncated: false)
                }
                let byServer = await manager.listAllResourceTemplates()
                var templates: [JSONLite] = []
                for name in byServer.keys.sorted() {
                    templates.append(contentsOf: flattenWithServer(name, byServer[name] ?? []))
                }
                payload["resourceTemplates"] = .array(templates)
            }
            return ToolResult(callId: call.callId, output: mcpResourceJSON(payload),
                              success: true, truncated: false)
        } catch {
            return ToolResult(callId: call.callId,
                              output: "resources/templates/list failed: \(error)",
                              success: false, truncated: false)
        }
    }
}

// MARK: - read_mcp_resource

public struct ReadMcpResourceTool: Tool {
    public let name = "read_mcp_resource"
    public let parallelSafe = true

    public var toolDescription: String {
        "Read a specific resource from an MCP server given the server name and "
        + "resource URI."
    }

    /// Upstream `create_read_mcp_resource_tool`. Sorted properties:
    /// `server`, `uri`; required `["server","uri"]`.
    public var jsonSchema: String {
        #"{"type":"object","properties":{"server":{"type":"string","description":"MCP server name exactly as configured. Must match the 'server' field returned by list_mcp_resources."},"uri":{"type":"string","description":"Resource URI to read. Must be one of the URIs returned by list_mcp_resources."}},"required":["server","uri"],"additionalProperties":false}"#
    }

    private let manager: McpManager
    public init(manager: McpManager) { self.manager = manager }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = mcpResourceArgs(call.argumentsJSON)
        guard let server = normalizeOptional(a["server"] as? String) else {
            return ToolResult(callId: call.callId, output: "server must be provided",
                              success: false, truncated: false)
        }
        guard let uri = normalizeOptional(a["uri"] as? String) else {
            return ToolResult(callId: call.callId, output: "uri must be provided",
                              success: false, truncated: false)
        }
        do {
            let result = try await manager.readResource(server: server, uri: uri)
            // Upstream `ReadResourcePayload` flattens the read result onto
            // `{server, uri, ...result}`.
            var payload: [String: JSONLite] = result
            payload["server"] = .string(server)
            payload["uri"] = .string(uri)
            return ToolResult(callId: call.callId, output: mcpResourceJSON(payload),
                              success: true, truncated: false)
        } catch {
            return ToolResult(callId: call.callId,
                              output: "resources/read failed: \(error)",
                              success: false, truncated: false)
        }
    }
}
