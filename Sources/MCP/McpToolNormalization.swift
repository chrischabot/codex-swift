import Foundation
import CryptoKit

/// Model-visible MCP tool-name normalization, ported from upstream
/// `codex-rs/codex-mcp/src/tools.rs::normalize_tools_for_model`.
///
/// Two MCP tools whose sanitized names collide (e.g. names differing only past
/// the 64-char cap, or differing only by characters that sanitize to `_`) must
/// not clobber each other. Upstream disambiguates colliding or over-length
/// model names by appending a 12-hex-char SHA1 suffix and truncating to
/// `MAX_TOOL_NAME_LENGTH` (64), guaranteeing every model-visible tool name is
/// unique and <= 64 chars. Exact-duplicate raw identities are skipped.
///
/// Intentional port divergence (audit unit `mcp`, finding 5): upstream also
/// ships a host-owned ChatGPT-backed `codex_apps` connectors MCP server with
/// connector-aware callable naming and a tools disk cache
/// (`codex-rs/codex-mcp/src/mcp/mod.rs:44,203-221` + `codex_apps.rs:88-120`).
/// The Swift port targets user-configured stdio/HTTP MCP servers only, so it
/// always uses the `mcp__<server>__` namespace below and does not reproduce the
/// `codex_apps`/`host_owned_codex_apps_enabled` subsystem. This is a documented
/// scope decision (no wire break for the servers the port supports); revisit only
/// if ChatGPT app connectors are brought into scope.
public enum McpToolNormalization {
    static let mcpToolNameDelimiter = "__"
    static let maxToolNameLength = 64
    static let callableNameHashLen = 12

    /// One tool candidate carrying its raw (collision-detection) identities
    /// and the sanitized callable parts upstream operates on.
    public struct ToolInfo: Sendable {
        public let serverName: String
        /// The original (un-sanitized) tool name as reported by the server.
        public let toolName: String
        public let tool: McpToolSpec
        public init(serverName: String, toolName: String, tool: McpToolSpec) {
            self.serverName = serverName
            self.toolName = toolName
            self.tool = tool
        }
        /// Raw callable namespace upstream forms as `mcp__<server>__`. This is
        /// the pre-sanitization namespace; sanitization happens during
        /// normalization.
        var rawCallableNamespace: String { "mcp\(mcpToolNameDelimiter)\(serverName)\(mcpToolNameDelimiter)" }
        /// Raw callable name (the tool name itself).
        var rawCallableName: String { toolName }
    }

    /// The normalized result for one tool: the final model-visible name plus
    /// the original spec/server/tool identity needed to route a call back.
    public struct NormalizedTool: Sendable {
        public let modelName: String
        public let serverName: String
        public let toolName: String
        public let tool: McpToolSpec
    }

    private struct Candidate {
        let info: ToolInfo
        let rawNamespaceIdentity: String
        let rawToolIdentity: String
        var callableNamespace: String
        var callableName: String
    }

    /// Apply the upstream collision-resolution + length-fitting algorithm.
    /// `warn` receives messages for skipped duplicate tools (parity with
    /// upstream `warn!("skipping duplicated tool ...")`).
    public static func normalizeToolsForModel(
        _ tools: [ToolInfo],
        warn: (String) -> Void = { _ in }
    ) -> [NormalizedTool] {
        var seenRawNames = Set<String>()
        var candidates: [Candidate] = []
        for info in tools {
            // Upstream raw identity uses NUL-separated parts:
            //   server \0 callable_namespace \0 connector_id
            // We have no connector_id (always empty), matching the default.
            let rawNamespaceIdentity = "\(info.serverName)\u{0}\(info.rawCallableNamespace)\u{0}"
            let rawToolIdentity = "\(rawNamespaceIdentity)\u{0}\(info.rawCallableName)\u{0}\(info.tool.name)"
            if !seenRawNames.insert(rawToolIdentity).inserted {
                warn("skipping duplicated tool \(info.tool.name)")
                continue
            }
            candidates.append(Candidate(
                info: info,
                rawNamespaceIdentity: rawNamespaceIdentity,
                rawToolIdentity: rawToolIdentity,
                callableNamespace: sanitizeResponsesAPIToolName(info.rawCallableNamespace),
                callableName: sanitizeResponsesAPIToolName(info.rawCallableName)))
        }

        // Disambiguate colliding namespaces.
        var namespaceIdentitiesByBase: [String: Set<String>] = [:]
        for c in candidates {
            namespaceIdentitiesByBase[c.callableNamespace, default: []].insert(c.rawNamespaceIdentity)
        }
        let collidingNamespaces = Set(
            namespaceIdentitiesByBase.filter { $0.value.count > 1 }.map { $0.key })
        for i in candidates.indices where collidingNamespaces.contains(candidates[i].callableNamespace) {
            candidates[i].callableNamespace = appendNamespaceHashSuffix(
                candidates[i].callableNamespace, candidates[i].rawNamespaceIdentity)
        }

        // Disambiguate colliding (namespace, name) tool pairs.
        var toolIdentitiesByBase: [String: Set<String>] = [:]
        for c in candidates {
            let key = c.callableNamespace + "\u{0}" + c.callableName
            toolIdentitiesByBase[key, default: []].insert(c.rawToolIdentity)
        }
        let collidingTools = Set(
            toolIdentitiesByBase.filter { $0.value.count > 1 }.map { $0.key })
        for i in candidates.indices {
            let key = candidates[i].callableNamespace + "\u{0}" + candidates[i].callableName
            if collidingTools.contains(key) {
                candidates[i].callableName = appendHashSuffix(
                    candidates[i].callableName, candidates[i].rawToolIdentity)
            }
        }

        // Stable order by raw tool identity (upstream sorts before fitting).
        candidates.sort { $0.rawToolIdentity < $1.rawToolIdentity }

        var usedNames = Set<String>()
        var result: [NormalizedTool] = []
        for c in candidates {
            let (ns, name) = uniqueCallableParts(
                c.callableNamespace, c.callableName, c.rawToolIdentity, &usedNames)
            result.append(NormalizedTool(
                modelName: ns + name,
                serverName: c.info.serverName,
                toolName: c.info.toolName,
                tool: c.info.tool))
        }
        return result
    }

    // MARK: - openai/fileParams input-schema masking (Finding 4)

    /// Verbatim upstream guidance text appended to a masked file-path param's
    /// `description` (codex-mcp/src/tools.rs:255).
    static let fileParamGuidance =
        "This parameter expects an absolute local file path. If you want to upload a file, provide the absolute path to that file here."

    /// Return the model-visible view of a tool's input-schema JSON, masking
    /// every property named in `_meta["openai/fileParams"]` so the model sees
    /// an absolute-file-path string (or array of strings) instead of the raw
    /// (often base64/binary) schema. Mirrors upstream
    /// `tool_with_model_visible_input_schema` /
    /// `mask_input_schema_for_file_path_params` / `mask_input_property_schema`
    /// (codex-mcp/src/tools.rs:117-130, 251-295).
    ///
    /// When the tool declares no file params the original schema string is
    /// returned unchanged (parity with the early-return on empty file_params).
    public static func maskedInputSchemaJSON(for tool: McpToolSpec) -> String {
        let fileParams = tool.openaiFileParams
        if fileParams.isEmpty { return tool.inputSchemaJSON }
        guard let data = tool.inputSchemaJSON.data(using: .utf8),
              let parsed = try? JSONLite.parse(data),
              case .object(var schema) = parsed else {
            return tool.inputSchemaJSON
        }
        guard case .object(var properties)? = schema["properties"] else {
            // No `properties` object → nothing to mask (parity with the
            // let-else early return in mask_input_schema_for_file_path_params).
            return tool.inputSchemaJSON
        }
        for fieldName in fileParams {
            guard let prop = properties[fieldName] else { continue }
            properties[fieldName] = maskInputPropertySchema(prop)
        }
        schema["properties"] = .object(properties)
        return JSONLite.stringify(.object(schema))
    }

    /// Port of `mask_input_property_schema` (tools.rs:268-295): rewrite one
    /// property schema to `{type:string}` or `{type:array, items:{type:string},
    /// description}` (when the original declared `type:"array"` or carried
    /// `items`), with the guidance text appended to (or used as) the
    /// description. Non-object schemas are returned unchanged.
    static func maskInputPropertySchema(_ schema: JSONLite) -> JSONLite {
        guard case .object(let object) = schema else { return schema }
        // Existing description (string) or empty.
        var description = ""
        if case .string(let d)? = object["description"] { description = d }
        if description.isEmpty {
            description = fileParamGuidance
        } else if !description.contains(fileParamGuidance) {
            description = "\(description) \(fileParamGuidance)"
        }
        // is_array: original `type == "array"` OR an `items` key is present.
        let typeIsArray: Bool
        if case .string("array")? = object["type"] { typeIsArray = true }
        else { typeIsArray = object["items"] != nil }
        // object.clear() then re-insert (upstream clears all other keys).
        var out: [String: JSONLite] = ["description": .string(description)]
        if typeIsArray {
            out["type"] = .string("array")
            out["items"] = .object(["type": .string("string")])
        } else {
            out["type"] = .string("string")
        }
        return .object(out)
    }

    // MARK: - Sanitization

    /// Upstream `sanitize_responses_api_tool_name`: replace every character
    /// that is not ASCII alphanumeric or `_` with `_`; never returns empty.
    public static func sanitizeResponsesAPIToolName(_ s: String) -> String {
        let out = String(s.unicodeScalars.map { sc -> Character in
            let ok = (sc >= "a" && sc <= "z") || (sc >= "A" && sc <= "Z")
                || (sc >= "0" && sc <= "9") || sc == "_"
            return ok ? Character(sc) : "_"
        })
        return out.isEmpty ? "_" : out
    }

    // MARK: - Hashing helpers

    static func sha1Hex(_ s: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func callableNameHashSuffix(_ rawIdentity: String) -> String {
        let hash = sha1Hex(rawIdentity)
        return "_" + String(hash.prefix(callableNameHashLen))
    }

    static func appendHashSuffix(_ value: String, _ rawIdentity: String) -> String {
        value + callableNameHashSuffix(rawIdentity)
    }

    static func appendNamespaceHashSuffix(_ namespace: String, _ rawIdentity: String) -> String {
        if namespace.hasSuffix(mcpToolNameDelimiter) {
            let base = String(namespace.dropLast(mcpToolNameDelimiter.count))
            return base + callableNameHashSuffix(rawIdentity) + mcpToolNameDelimiter
        }
        return appendHashSuffix(namespace, rawIdentity)
    }

    /// Truncate to `maxLen` characters (Unicode scalars / chars, matching
    /// upstream `value.chars().take(max_len)`).
    static func truncateName(_ value: String, _ maxLen: Int) -> String {
        String(value.prefix(maxLen))
    }

    static func fitCallablePartsWithHash(
        _ namespace: String, _ toolName: String, _ rawIdentity: String
    ) -> (String, String) {
        let suffix = callableNameHashSuffix(rawIdentity)
        let nsLen = namespace.count
        // saturating_sub
        let maxToolLen = nsLen >= maxToolNameLength ? 0 : maxToolNameLength - nsLen
        if maxToolLen >= suffix.count {
            let prefixLen = maxToolLen - suffix.count
            return (namespace, truncateName(toolName, prefixLen) + suffix)
        }
        let maxNamespaceLen = maxToolNameLength - suffix.count
        return (truncateName(namespace, maxNamespaceLen), suffix)
    }

    static func uniqueCallableParts(
        _ namespace: String, _ toolName: String, _ rawIdentity: String,
        _ usedNames: inout Set<String>
    ) -> (String, String) {
        let modelName = namespace + toolName
        if modelName.count <= maxToolNameLength, usedNames.insert(modelName).inserted {
            return (namespace, toolName)
        }
        var attempt: UInt32 = 0
        while true {
            let hashInput = attempt == 0
                ? rawIdentity
                : "\(rawIdentity)\u{0}\(attempt)"
            let (ns, name) = fitCallablePartsWithHash(namespace, toolName, hashInput)
            let candidate = ns + name
            if usedNames.insert(candidate).inserted {
                return (ns, name)
            }
            if attempt != UInt32.max { attempt += 1 }
        }
    }
}
