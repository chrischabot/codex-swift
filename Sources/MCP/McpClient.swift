import Foundation
import InfraPrimitives
import Tools
import ProtocolModel
import WireProtocol

public typealias McpElicitationHandler =
    @Sendable (_ requestId: RequestId, _ serverName: String, _ params: JSONValue) async -> JSONValue?

/// Upstream `Implementation` identity sent in the MCP `initialize` request
/// (`codex-rs/codex-mcp/src/rmcp_client.rs:483-490`): `name =
/// "codex-mcp-client"`, `title = Some("Codex")`, `version =
/// env!("CARGO_PKG_VERSION")`. The upstream workspace version is `0.0.0`
/// (`codex-rs/Cargo.toml`), so we mirror that here as the build version.
public enum McpClientInfo {
    public static let name = "codex-mcp-client"
    public static let title = "Codex"
    /// Build version. Mirrors upstream `CARGO_PKG_VERSION` (workspace `0.0.0`).
    public static let version = "0.0.0"

    /// The `clientInfo` object for the `initialize` request, in the order
    /// upstream emits its `Implementation` struct (name, title, version).
    public static var initializeClientInfo: [String: Any] {
        ["name": name, "title": title, "version": version]
    }

    /// Whether the `AuthElicitation` feature is enabled. Upstream
    /// `Feature::AuthElicitation.default_enabled() == false` (stage
    /// `UnderDevelopment`, `features/src/tests.rs:297-298`), so this is `false`
    /// and the advertised capability is the empty object `{}`.
    public static let authElicitationEnabled = false

    /// The client `elicitation` capability advertised in `initialize`. Upstream
    /// `client_elicitation_capability` (`core/src/session/session.rs:1027-1031`)
    /// is `ElicitationCapability { form: Some(..), url: Some(..) }` (wire
    /// `{"form":{},"url":{}}`) ONLY when `Feature::AuthElicitation` is enabled;
    /// otherwise it is `ElicitationCapability::default()`, which — because both
    /// `form` and `url` are `skip_serializing_if = "Option::is_none"`
    /// (`rmcp-0.15.0/src/model.rs:209-216`) — serializes to the empty object
    /// `{}`. `initialize` always sets `elicitation: Some(..)`
    /// (`codex-mcp/src/rmcp_client.rs:480`), so the key is always present.
    public static var elicitationCapability: [String: Any] {
        capability(authElicitationEnabled: authElicitationEnabled)
    }

    /// Pure mapping from the AuthElicitation feature flag to the wire-shape of
    /// the `elicitation` capability. Exposed so both branches are testable
    /// without a mutable global.
    public static func capability(authElicitationEnabled: Bool) -> [String: Any] {
        if authElicitationEnabled {
            return ["form": [String: Any](), "url": [String: Any]()]
        }
        return [String: Any]()
    }
}

/// Wire-faithful reproduction of upstream `codex_mcp::SandboxState`
/// (`codex-mcp/src/runtime.rs:18-29`), serialized into the `tools/call`
/// request `_meta` under the key `codex/sandbox-state-meta` for servers that
/// advertise the matching experimental capability
/// (`core/src/mcp_tool_call.rs:705-751`).
///
/// Field-for-field serde parity (struct is `#[serde(rename_all = "camelCase")]`):
///  - `permissionProfile`: `Option`, `skip_serializing_if = "Option::is_none"`
///    → the key is OMITTED when nil.
///  - `sandboxPolicy`: the **core** `SandboxPolicy`
///    (`protocol/src/protocol.rs:991-994`), an internally-tagged enum
///    `#[serde(tag = "type", rename_all = "kebab-case")]` →
///    `{"type":"danger-full-access"}` / `{"type":"read-only", ...}` /
///    `{"type":"workspace-write", ...}` / `{"type":"external-sandbox", ...}`.
///    NOTE: this is the kebab-case core wire shape, NOT the v2 app-server
///    camelCase `ProtocolModel.SandboxPolicy`.
///  - `codexLinuxSandboxExe`: `Option<PathBuf>` with NO skip attribute →
///    the key is ALWAYS present, emitting JSON `null` when absent.
///  - `sandboxCwd`: always present string.
///  - `useLegacyLandlock`: `#[serde(default)]` bool, always present.
public struct SandboxStateMeta: Sendable, Equatable {
    /// Upstream `codex/sandbox-state-meta` capability + `_meta` key.
    public static let metaKey = "codex/sandbox-state-meta"

    /// Core `SandboxPolicy` wire shape. The kebab-case `type` tag mirrors
    /// `protocol/src/protocol.rs` (`danger-full-access` / `read-only` /
    /// `workspace-write` / `external-sandbox`).
    public enum Policy: Sendable, Equatable {
        case dangerFullAccess
        case readOnly(networkAccess: Bool)
        case workspaceWrite(writableRoots: [String], networkAccess: Bool,
                            excludeTmpdirEnvVar: Bool, excludeSlashTmp: Bool)
        case externalSandbox(networkAccess: NetworkAccess)
    }

    /// Optional permission profile. When `nil`, the `permissionProfile` key
    /// is omitted (upstream `skip_serializing_if = "Option::is_none"`). The
    /// value, when present, is the verbatim serialized `PermissionProfile`
    /// JSON object as passed by the caller.
    public var permissionProfile: JSONLite?
    public var sandboxPolicy: Policy
    /// `Option<PathBuf>` with no skip — emits `null` when nil.
    public var codexLinuxSandboxExe: String?
    public var sandboxCwd: String
    public var useLegacyLandlock: Bool

    public init(permissionProfile: JSONLite? = nil,
                sandboxPolicy: Policy,
                codexLinuxSandboxExe: String? = nil,
                sandboxCwd: String,
                useLegacyLandlock: Bool = false) {
        self.permissionProfile = permissionProfile
        self.sandboxPolicy = sandboxPolicy
        self.codexLinuxSandboxExe = codexLinuxSandboxExe
        self.sandboxCwd = sandboxCwd
        self.useLegacyLandlock = useLegacyLandlock
    }

    /// Build a `SandboxStateMeta.Policy` from the session's sandbox mode +
    /// writable roots + network flag. Mirrors how upstream derives the core
    /// `SandboxPolicy` for a turn: `read-only` carries `network_access`,
    /// `workspace-write` carries the writable roots + network flag (and the
    /// two tmp-exclusion booleans, which the port does not surface and so
    /// default to `false`), and `danger-full-access` carries nothing.
    public static func policy(mode: SandboxModeKind,
                              writableRoots: [String],
                              networkAccess: Bool) -> Policy {
        switch mode {
        case .dangerFullAccess:
            return .dangerFullAccess
        case .readOnly:
            return .readOnly(networkAccess: networkAccess)
        case .workspaceWrite:
            return .workspaceWrite(writableRoots: writableRoots,
                                   networkAccess: networkAccess,
                                   excludeTmpdirEnvVar: false,
                                   excludeSlashTmp: false)
        }
    }

    /// Serialize the core `SandboxPolicy` to its internally-tagged
    /// kebab-case wire object. `skip_serializing_if` rules are reproduced:
    ///  - `read-only.network_access`: `skip_serializing_if = Not::not` → omit
    ///    when `false`.
    ///  - `workspace-write.writable_roots`: `skip_serializing_if = Vec::is_empty`
    ///    → omit when empty; the other three booleans use `#[serde(default)]`
    ///    only (always emitted).
    ///  - `external-sandbox.network_access`: `#[serde(default)]` (always emitted)
    ///    serialized as the lowercase `NetworkAccess` string.
    private func policyJSON() -> [String: Any] {
        switch sandboxPolicy {
        case .dangerFullAccess:
            return ["type": "danger-full-access"]
        case .readOnly(let net):
            var o: [String: Any] = ["type": "read-only"]
            if net { o["network_access"] = true }   // skip when false
            return o
        case .workspaceWrite(let roots, let net, let exTmp, let exSlash):
            var o: [String: Any] = ["type": "workspace-write"]
            if !roots.isEmpty { o["writable_roots"] = roots }   // skip when empty
            o["network_access"] = net
            o["exclude_tmpdir_env_var"] = exTmp
            o["exclude_slash_tmp"] = exSlash
            return o
        case .externalSandbox(let net):
            return ["type": "external-sandbox", "network_access": net.rawValue]
        }
    }

    /// Build the `JSONSerialization`-compatible object for this state, suitable
    /// to insert into the `tools/call` `_meta` map. `permissionProfile` is
    /// omitted entirely when nil; `codexLinuxSandboxExe` emits `NSNull` when nil.
    public func metaObject() -> [String: Any] {
        var o: [String: Any] = [:]
        if let pp = permissionProfile {
            o["permissionProfile"] = McpClient.jsonLiteToAny(pp)
        }
        o["sandboxPolicy"] = policyJSON()
        o["codexLinuxSandboxExe"] = codexLinuxSandboxExe ?? NSNull()
        o["sandboxCwd"] = sandboxCwd
        o["useLegacyLandlock"] = useLegacyLandlock
        return o
    }
}

/// Upstream parity: `[mcp_servers.NAME] env_vars` accepts either a bare
/// string (the variable name, sourced locally) or an inline-table with
/// `name` + optional `source = "local" | "remote"`. The `remote` form lets
/// the server inherit the variable from an executor secret store rather
/// than the local environment. We decode both shapes.
public struct McpServerEnvVar: Sendable, Codable, Equatable {
    public var name: String
    /// `nil` or `"local"` means "read from local env"; `"remote"` means
    /// "pull from executor secret store" (Codex CLI / remote executor).
    public var source: String?

    public init(name: String, source: String? = nil) {
        self.name = name
        self.source = source
    }

    public var isRemoteSource: Bool { source == "remote" }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let s = try? single.decode(String.self) {
            self.name = s
            self.source = nil
            return
        }
        struct Keyed: Decodable { let name: String; let source: String? }
        let k = try Keyed(from: decoder)
        self.name = k.name
        self.source = k.source
    }

    public func encode(to encoder: any Encoder) throws {
        if source == nil {
            var c = encoder.singleValueContainer()
            try c.encode(name)
        } else {
            enum Keys: String, CodingKey { case name, source }
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(source, forKey: .source)
        }
    }
}

/// Upstream parity: optional OAuth client overrides for HTTP/streamable
/// transports. Mirrors `McpServerOAuthConfig` in `codex-rs`.
public struct McpOAuthConfig: Sendable, Codable, Equatable {
    public var clientId: String?

    public init(clientId: String? = nil) {
        self.clientId = clientId
    }

    private enum CodingKeys: String, CodingKey {
        case clientId
        case clientIdSnake = "client_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .clientId) {
            clientId = v
        } else {
            clientId = try c.decodeIfPresent(String.self, forKey: .clientIdSnake)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(clientId, forKey: .clientId)
    }
}

public struct McpServerConfig: Sendable, Codable, Equatable {
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [String: String]?
    public var url: String?
    public var bearerTokenEnvVar: String?
    public var httpHeaders: [String: String]

    // MARK: - Upstream-parity fields (H-46 / audit area 04 F2)

    /// Working directory for stdio MCP server processes.
    public var cwd: String?
    /// Named env vars (with optional `source: "remote"`) that should be
    /// forwarded to the stdio server in addition to `env`.
    public var envVars: [McpServerEnvVar]?
    /// HTTP headers whose VALUES are environment variable NAMES (the
    /// referenced env var is resolved at request time). Distinct from
    /// `httpHeaders`, which is verbatim key/value.
    public var envHttpHeaders: [String: String]?
    /// Initialization handshake timeout. Upstream default: 10s.
    public var startupTimeoutSec: TimeInterval?
    /// Per-tool-call timeout. Upstream default: 120s (we previously
    /// hardcoded 30s, which is the audit's major-severity gap).
    public var toolTimeoutSec: TimeInterval?
    /// Allowlist: when set, only these tools from this server are exposed.
    public var enabledTools: [String]?
    /// Denylist: tools to drop after applying `enabledTools`.
    public var disabledTools: [String]?
    /// Whether session start should fail if this server fails to initialize.
    public var required: Bool?
    /// Hint to the model: this server's tools are safe to call in parallel.
    public var supportsParallelToolCalls: Bool?
    /// OAuth scopes (HTTP/streamable transports).
    public var scopes: [String]?
    /// OAuth client overrides (e.g. fixed `client_id`).
    public var oauth: McpOAuthConfig?
    /// OAuth resource indicator (RFC 8707).
    public var oauthResource: String?

    /// Upstream default for `tool_timeout_sec` is **120 seconds**.
    /// Exposed as a constant so callers (clients, tests) can reference it
    /// without duplicating the magic number.
    public static let defaultToolTimeoutSec: TimeInterval = 120
    /// Upstream default for `startup_timeout_sec` is 30 seconds
    /// (`codex-mcp/src/rmcp_client.rs` `DEFAULT_STARTUP_TIMEOUT`).
    public static let defaultStartupTimeoutSec: TimeInterval = 30

    /// Effective tool timeout, with the upstream default applied.
    public var effectiveToolTimeout: TimeInterval {
        toolTimeoutSec ?? McpServerConfig.defaultToolTimeoutSec
    }
    /// Effective startup timeout, with the upstream default applied.
    public var effectiveStartupTimeout: TimeInterval {
        startupTimeoutSec ?? McpServerConfig.defaultStartupTimeoutSec
    }

    /// Existing memberwise (stdio) initializer — unchanged behavior.
    public init(name: String, command: String, args: [String] = [],
                env: [String: String]? = nil) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.url = nil
        self.bearerTokenEnvVar = nil
        self.httpHeaders = [:]
    }

    /// HTTP (Streamable-HTTP) convenience initializer.
    public init(name: String, url: String, bearerTokenEnvVar: String? = nil,
                httpHeaders: [String: String] = [:]) {
        self.name = name
        self.command = ""
        self.args = []
        self.env = nil
        self.url = url
        self.bearerTokenEnvVar = bearerTokenEnvVar
        self.httpHeaders = httpHeaders
    }

    public var isHTTP: Bool { url != nil && !(url ?? "").isEmpty }

    /// After applying `enabledTools` (allowlist) and `disabledTools`
    /// (denylist), return only the surviving tool specs. The model never
    /// sees filtered tools.
    public func filterTools(_ tools: [McpToolSpec]) -> [McpToolSpec] {
        var out = tools
        if let allow = enabledTools, !allow.isEmpty {
            let allowed = Set(allow)
            out = out.filter { allowed.contains($0.name) }
        }
        if let deny = disabledTools, !deny.isEmpty {
            let denied = Set(deny)
            out = out.filter { !denied.contains($0.name) }
        }
        return out
    }

    /// Whether `toolName` is allowed by this server's enabled/disabled filter.
    /// Mirrors upstream `ToolFilter::allows` (codex-mcp/src/tools.rs:103-112):
    /// a tool is allowed iff (no allowlist is set OR the tool is in the
    /// allowlist) AND the tool is not in the denylist. Enforced at the
    /// `tools/call` boundary as defense-in-depth, independent of how the call
    /// arrived (connection_manager.rs:582-594).
    public func toolAllowed(_ toolName: String) -> Bool {
        if let allow = enabledTools, !allow.isEmpty, !allow.contains(toolName) {
            return false
        }
        if let deny = disabledTools, deny.contains(toolName) {
            return false
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case name, command, args, env, url
        case bearerTokenEnvVar
        case bearerTokenEnvVarSnake = "bearer_token_env_var"
        case httpHeaders
        case httpHeadersSnake = "http_headers"
        case cwd
        case envVars
        case envVarsSnake = "env_vars"
        case envHttpHeaders
        case envHttpHeadersSnake = "env_http_headers"
        case startupTimeoutSec
        case startupTimeoutSecSnake = "startup_timeout_sec"
        case toolTimeoutSec
        case toolTimeoutSecSnake = "tool_timeout_sec"
        case enabledTools
        case enabledToolsSnake = "enabled_tools"
        case disabledTools
        case disabledToolsSnake = "disabled_tools"
        case required
        case supportsParallelToolCalls
        case supportsParallelToolCallsSnake = "supports_parallel_tool_calls"
        case scopes
        case oauth
        case oauthResource
        case oauthResourceSnake = "oauth_resource"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        command = (try c.decodeIfPresent(String.self, forKey: .command)) ?? ""
        args = (try c.decodeIfPresent([String].self, forKey: .args)) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        if let b = try c.decodeIfPresent(String.self, forKey: .bearerTokenEnvVar) {
            bearerTokenEnvVar = b
        } else {
            bearerTokenEnvVar = try c.decodeIfPresent(String.self,
                                                      forKey: .bearerTokenEnvVarSnake)
        }
        if let h = try c.decodeIfPresent([String: String].self, forKey: .httpHeaders) {
            httpHeaders = h
        } else {
            httpHeaders = (try c.decodeIfPresent([String: String].self,
                                                 forKey: .httpHeadersSnake)) ?? [:]
        }
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        if let v = try c.decodeIfPresent([McpServerEnvVar].self, forKey: .envVars) {
            envVars = v
        } else {
            envVars = try c.decodeIfPresent([McpServerEnvVar].self,
                                            forKey: .envVarsSnake)
        }
        if let v = try c.decodeIfPresent([String: String].self,
                                         forKey: .envHttpHeaders) {
            envHttpHeaders = v
        } else {
            envHttpHeaders = try c.decodeIfPresent([String: String].self,
                                                    forKey: .envHttpHeadersSnake)
        }
        if let v = try c.decodeIfPresent(Double.self, forKey: .startupTimeoutSec) {
            startupTimeoutSec = v
        } else {
            startupTimeoutSec = try c.decodeIfPresent(Double.self,
                                                       forKey: .startupTimeoutSecSnake)
        }
        if let v = try c.decodeIfPresent(Double.self, forKey: .toolTimeoutSec) {
            toolTimeoutSec = v
        } else {
            toolTimeoutSec = try c.decodeIfPresent(Double.self,
                                                    forKey: .toolTimeoutSecSnake)
        }
        if let v = try c.decodeIfPresent([String].self, forKey: .enabledTools) {
            enabledTools = v
        } else {
            enabledTools = try c.decodeIfPresent([String].self,
                                                  forKey: .enabledToolsSnake)
        }
        if let v = try c.decodeIfPresent([String].self, forKey: .disabledTools) {
            disabledTools = v
        } else {
            disabledTools = try c.decodeIfPresent([String].self,
                                                   forKey: .disabledToolsSnake)
        }
        required = try c.decodeIfPresent(Bool.self, forKey: .required)
        if let v = try c.decodeIfPresent(Bool.self,
                                         forKey: .supportsParallelToolCalls) {
            supportsParallelToolCalls = v
        } else {
            supportsParallelToolCalls = try c.decodeIfPresent(
                Bool.self, forKey: .supportsParallelToolCallsSnake)
        }
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes)
        oauth = try c.decodeIfPresent(McpOAuthConfig.self, forKey: .oauth)
        if let v = try c.decodeIfPresent(String.self, forKey: .oauthResource) {
            oauthResource = v
        } else {
            oauthResource = try c.decodeIfPresent(String.self,
                                                   forKey: .oauthResourceSnake)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if !command.isEmpty { try c.encode(command, forKey: .command) }
        if !args.isEmpty { try c.encode(args, forKey: .args) }
        if let env { try c.encode(env, forKey: .env) }
        if let url { try c.encode(url, forKey: .url) }
        if let bearerTokenEnvVar {
            try c.encode(bearerTokenEnvVar, forKey: .bearerTokenEnvVar)
        }
        if !httpHeaders.isEmpty { try c.encode(httpHeaders, forKey: .httpHeaders) }
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(envVars, forKey: .envVars)
        try c.encodeIfPresent(envHttpHeaders, forKey: .envHttpHeaders)
        try c.encodeIfPresent(startupTimeoutSec, forKey: .startupTimeoutSec)
        try c.encodeIfPresent(toolTimeoutSec, forKey: .toolTimeoutSec)
        try c.encodeIfPresent(enabledTools, forKey: .enabledTools)
        try c.encodeIfPresent(disabledTools, forKey: .disabledTools)
        try c.encodeIfPresent(required, forKey: .required)
        try c.encodeIfPresent(supportsParallelToolCalls,
                              forKey: .supportsParallelToolCalls)
        try c.encodeIfPresent(scopes, forKey: .scopes)
        try c.encodeIfPresent(oauth, forKey: .oauth)
        try c.encodeIfPresent(oauthResource, forKey: .oauthResource)
    }
}

public struct McpToolSpec: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
    /// The tool object's `_meta` map, preserved verbatim (upstream
    /// `rmcp::model::Tool.meta`). Carries connector identity
    /// (`connector_id` / `connector_name` / `connector_display_name` /
    /// `connector_description` / `connectorDescription`) and the
    /// `openai/fileParams` input-schema-masking hint. `nil` when the tool
    /// declared no `_meta`. (Finding 3 — required by the `openai/fileParams`
    /// masking in Finding 4 and by codex-apps connector gating upstream.)
    public var meta: JSONLite?

    public init(name: String, description: String,
                inputSchemaJSON: String, meta: JSONLite? = nil) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchemaJSON, meta
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = (try c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        inputSchemaJSON = (try c.decodeIfPresent(String.self,
                                                 forKey: .inputSchemaJSON)) ?? "{}"
        meta = try c.decodeIfPresent(JSONLite.self, forKey: .meta)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(inputSchemaJSON, forKey: .inputSchemaJSON)
        try c.encodeIfPresent(meta, forKey: .meta)
    }

    // MARK: - Connector identity (Finding 3)

    /// Mirror of upstream `meta_string` (rmcp_client.rs:489-495): read the
    /// string value of `key` from `_meta`, trimmed; `nil` if absent, not a
    /// string, or empty after trimming.
    private func metaString(_ key: String) -> String? {
        guard case .object(let o)? = meta, case .string(let s)? = o[key] else {
            return nil
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `_meta["connector_id"]` (rmcp_client.rs:467).
    public var connectorId: String? { metaString("connector_id") }
    /// `_meta["connector_name"]` falling back to `_meta["connector_display_name"]`
    /// (rmcp_client.rs:468-469).
    public var connectorName: String? {
        metaString("connector_name") ?? metaString("connector_display_name")
    }
    /// `_meta["connector_description"]` falling back to
    /// `_meta["connectorDescription"]` (rmcp_client.rs:470-471).
    public var connectorDescription: String? {
        metaString("connector_description") ?? metaString("connectorDescription")
    }

    /// Upstream `declared_openai_file_input_param_names` (tools.rs:62-78):
    /// the non-empty string entries of `_meta["openai/fileParams"]`. Empty
    /// when the key is absent or not an array of strings.
    public var openaiFileParams: [String] {
        guard case .object(let o)? = meta,
              case .array(let arr)? = o[McpToolSpec.metaOpenAIFileParamsKey]
        else { return [] }
        return arr.compactMap { v in
            guard case .string(let s) = v, !s.isEmpty else { return nil }
            return s
        }
    }

    /// Upstream `META_OPENAI_FILE_PARAMS` (tools.rs:249).
    static let metaOpenAIFileParamsKey = "openai/fileParams"
}

public struct McpCallResult: Sendable, Equatable {
    /// Concatenated `text` of all text content blocks — the primary
    /// model-visible output for simple consumers (back-compat).
    public var text: String
    public var isError: Bool
    /// Full content block array, preserved verbatim from the MCP result
    /// (upstream `CallToolResult.content`). Image content is converted to the
    /// upstream placeholder text block when the model cannot accept images.
    /// Empty when the server returned no content.
    public var content: [JSONLite]
    /// Upstream `CallToolResult.structured_content` — passed through untouched
    /// for advanced consumers. `nil` when absent.
    public var structuredContent: JSONLite?
    /// Upstream `CallToolResult.meta` (the result-level `_meta`). `nil` when
    /// absent.
    public var meta: JSONLite?

    public init(text: String, isError: Bool,
                content: [JSONLite] = [],
                structuredContent: JSONLite? = nil,
                meta: JSONLite? = nil) {
        self.text = text
        self.isError = isError
        self.content = content
        self.structuredContent = structuredContent
        self.meta = meta
    }
}

/// Shared MCP `CallToolResult` decoding so the stdio and HTTP transports stay
/// byte-for-byte consistent with each other and with upstream
/// `connection_manager.rs::call_tool` + `mcp_tool_call.rs`.
public enum McpResultDecoder {
    /// Upstream placeholder substituted for `image` content blocks when the
    /// model does not support image input (`mcp_tool_call.rs`).
    public static let imageOmittedPlaceholder =
        "<image content omitted because you do not support image input>"

    /// Build an `McpCallResult` from a raw JSON-RPC `result` object, preserving
    /// the full content array, structuredContent and `_meta`. Text blocks are
    /// concatenated into `.text`.
    ///
    /// Upstream parity (`mcp_tool_call.rs::sanitize_mcp_tool_result_for_model`):
    /// `image` blocks are passed through verbatim when the model supports image
    /// input, and only replaced with the placeholder text block when it does
    /// not. The default keeps the historical behaviour (no image input) so
    /// existing callers stay byte-identical.
    public static func decode(_ r: [String: JSONLite],
                              supportsImageInput: Bool = false) -> McpCallResult {
        var text = ""
        var content: [JSONLite] = []
        if let c = r["content"], case .array(let items) = c {
            for it in items {
                guard case .object(let o) = it else { content.append(it); continue }
                if case .string("image")? = o["type"] {
                    if supportsImageInput {
                        // Image-capable model: preserve the block verbatim
                        // (parity with `if supports_image_input { return result }`).
                        content.append(it)
                        continue
                    }
                    // Convert image block → placeholder text block (parity with
                    // upstream `sanitize_mcp_tool_result_for_model`).
                    let placeholder = JSONLite.object([
                        "type": .string("text"),
                        "text": .string(imageOmittedPlaceholder),
                    ])
                    content.append(placeholder)
                    text += imageOmittedPlaceholder
                    continue
                }
                content.append(it)
                if case .string(let s)? = o["text"] { text += s }
            }
        }
        var isError = false
        if case .bool(let b)? = r["isError"] { isError = b }
        let structured = r["structuredContent"]
        let meta = r["_meta"]
        return McpCallResult(text: text, isError: isError,
                             content: content,
                             structuredContent: structured,
                             meta: meta)
    }
}

public enum McpError: Error, Sendable, CustomStringConvertible {
    case spawn(String), timeout(String), transport(String), server(String)
    public var description: String {
        switch self {
        case .spawn(let s): return "mcp spawn: \(s)"
        case .timeout(let s): return "mcp timeout: \(s)"
        case .transport(let s): return "mcp transport: \(s)"
        case .server(let s): return "mcp server error: \(s)"
        }
    }
}

/// Transport-agnostic MCP client surface (stdio or Streamable-HTTP).
public protocol McpClientProtocol: Sendable, Actor {
    func start() throws
    func initialize() async throws
    /// Whether the server advertised the `codex/sandbox-state-meta`
    /// experimental capability in its `initialize` response
    /// (upstream `server_supports_sandbox_state_meta_capability`,
    /// `codex-mcp/src/rmcp_client.rs:501-506`). `false` until `initialize`
    /// runs, and for any server that did not declare the capability.
    func supportsSandboxStateMeta() async -> Bool
    /// The server's `instructions` string captured from the `initialize`
    /// response (upstream `initialize_result.instructions`,
    /// `codex-mcp/src/rmcp_client.rs:496-499`). Used as the `namespace_description`
    /// for the server's tools when they carry no connector metadata. `nil`
    /// when the server returned no instructions.
    func serverInstructions() async -> String?
    func listTools() async throws -> [McpToolSpec]
    func callTool(_ name: String, argumentsJSON: String,
                  meta: [String: Any]?,
                  elicitationHandler: McpElicitationHandler?) async throws -> McpCallResult
    func readResource(uri: String) async throws -> [String: JSONLite]
    /// Single-page `resources/list` request returning the raw result object
    /// (`resources` array + optional `nextCursor`). Used by the model-visible
    /// `list_mcp_resources` tool, which surfaces upstream's paginated single-
    /// server shape. `cursor` requests the next page when provided.
    func listResourcesPage(cursor: String?) async throws -> [String: JSONLite]
    /// Single-page `resources/templates/list` request returning the raw result
    /// object (`resourceTemplates` array + optional `nextCursor`). Backs the
    /// `list_mcp_resource_templates` tool.
    func listResourceTemplatesPage(cursor: String?) async throws -> [String: JSONLite]
    func stop() async
}

public extension McpClientProtocol {
    /// Default: servers are assumed not to support the capability until a
    /// conforming client overrides this after reading the `initialize`
    /// response. Keeps mock / test clients source-compatible.
    func supportsSandboxStateMeta() async -> Bool { false }
    /// Default: no server instructions. Conforming clients override after
    /// capturing `initialize_result.instructions`.
    func serverInstructions() async -> String? { nil }

    /// Default single-page list: no resources, no cursor. Real transports
    /// (`McpClient`, `McpHttpClient`) override with a `resources/list` request.
    func listResourcesPage(cursor: String?) async throws -> [String: JSONLite] {
        ["resources": .array([])]
    }
    /// Default single-page template list: no templates, no cursor. Real
    /// transports override with a `resources/templates/list` request.
    func listResourceTemplatesPage(cursor: String?) async throws -> [String: JSONLite] {
        ["resourceTemplates": .array([])]
    }

    func callTool(_ name: String, argumentsJSON: String) async throws -> McpCallResult {
        try await callTool(name, argumentsJSON: argumentsJSON, meta: nil, elicitationHandler: nil)
    }
    /// Back-compat overload (no `_meta`).
    func callTool(_ name: String, argumentsJSON: String,
                  elicitationHandler: McpElicitationHandler?) async throws -> McpCallResult {
        try await callTool(name, argumentsJSON: argumentsJSON, meta: nil,
                           elicitationHandler: elicitationHandler)
    }
}

/// A Model Context Protocol stdio client. MCP uses JSON-RPC 2.0; the stdio
/// transport frames messages as newline-delimited JSON. The actor serializes
/// stdin writes and correlates responses by id. Every outbound message is
/// built with `JSONSerialization` (no string interpolation). Each request
/// arms an explicit timeout that removes and resumes its pending continuation
/// so no continuation is ever leaked.
///
/// The server's stdout is drained on a **dedicated OS thread** — a blocking
/// `FileHandle.availableData` must never run on a Swift concurrency
/// cooperative thread, or it starves the actor continuation that has to send
/// the next request (the first request can slip through, the second
/// deadlocks). Complete newline-delimited frames are forwarded through an
/// ordered `AsyncStream` consumed on the actor, preserving response order.
public actor McpClient: McpClientProtocol {
    public let config: McpServerConfig
    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [Int: CheckedContinuation<[String: JSONLite], any Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var activeElicitationHandlers: [Int: McpElicitationHandler] = [:]
    /// Registration order of `activeElicitationHandlers` keys. Upstream binds a
    /// single `send_elicitation` closure per client connection
    /// (`elicitation_client_service.rs:50-61`), so an inbound `elicitation/create`
    /// is always served by the in-flight call's handler. The Swift port registers
    /// a handler per outbound request; when several are in flight we must pick a
    /// deterministic one rather than an arbitrary `Dictionary.values.first`. We
    /// pick the most-recently-registered in-flight call — the one most likely to
    /// have just triggered the elicitation.
    private var activeElicitationOrder: [Int] = []
    private var nextId = 1
    private var readerThread: Thread?
    private var consumerTask: Task<Void, Never>?
    private var lineContinuation: AsyncStream<Data>.Continuation?
    private var initialized = false
    /// Whether the server advertised `codex/sandbox-state-meta` in its
    /// `initialize` response (upstream
    /// `server_supports_sandbox_state_meta_capability`). `false` until
    /// `initialize` runs.
    private var sandboxStateMetaSupported = false
    /// `initialize_result.instructions`, captured from the handshake. `nil`
    /// when the server returned none.
    private var instructions: String?
    private let requestTimeout: Duration
    private let maxFrameBytes: Int
    /// Whether the session's model accepts image input. When false (the
    /// default), `image` content blocks returned by `tools/call` are replaced
    /// with the upstream placeholder; when true they are preserved verbatim
    /// (parity with `mcp_tool_call.rs::sanitize_mcp_tool_result_for_model`).
    private let supportsImageInput: Bool
    /// Where to route server-push notifications (logging, progress,
    /// list-changed, cancelled, …). Defaults to a stderr sink; tests use
    /// `CapturingMcpNotificationSink` to assert behavior.
    private let notificationSink: any McpNotificationSink

    /// Initializes a stdio MCP client. If `requestTimeout` is `nil` (the
    /// new default), the per-call timeout is read from
    /// `config.effectiveToolTimeout` — i.e. the upstream-parity value of
    /// `tool_timeout_sec` (default **120s**, was hardcoded to 30s before
    /// fix P7.1 / H-46).
    public init(_ config: McpServerConfig, requestTimeout: Duration? = nil,
                maxFrameBytes: Int = 16 * 1024 * 1024,
                supportsImageInput: Bool = false,
                notificationSink: (any McpNotificationSink)? = nil) {
        self.config = config
        if let requestTimeout {
            self.requestTimeout = requestTimeout
        } else {
            let secs = config.effectiveToolTimeout
            // `Duration.seconds(_:)` accepts an integer; round up to
            // nearest whole second and clamp to >=1 to avoid 0-timeout.
            let whole = Swift.max(1, Int(secs.rounded(.up)))
            self.requestTimeout = .seconds(whole)
        }
        self.maxFrameBytes = Swift.max(4096, maxFrameBytes)
        self.supportsImageInput = supportsImageInput
        self.notificationSink = notificationSink ?? StderrMcpNotificationSink()
    }

    public func start() throws {
        guard process == nil else { return }
        let p = Process()
        if config.command.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: config.command)
            p.arguments = config.args
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [config.command] + config.args
        }
        // F6 (MEDIUM security): sanitized environment. Upstream
        // `stdio_server_launcher.rs` calls `env_clear()` and only forwards a
        // small DEFAULT_ENV_VARS allowlist plus the explicitly named
        // `env_vars` entries plus the literal `env` overrides. The previous
        // Swift impl inherited the FULL parent environment when no override
        // was set, leaking `CODEX_API_KEY`, `ANTHROPIC_API_KEY`, and other
        // secrets to MCP servers. We ALWAYS set `p.environment` now so the
        // Foundation default (inherit-all) never applies.
        p.environment = try Self.buildStdioEnvironment(config: config)
        // Upstream parity: honor `cwd` for stdio servers.
        if let cwd = config.cwd, !cwd.isEmpty {
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let inPipe = Pipe(); let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() }
        catch { throw McpError.spawn("\(config.command): \(error)") }
        process = p
        stdin = inPipe.fileHandleForWriting
        // F7 (MEDIUM): place the child in its own process group so a single
        // `kill(-pgid, …)` on stop reaches the MCP server AND any
        // grandchildren it spawned. Upstream uses `process_group(0)`, which
        // sets PGID before exec. Foundation's `Process` does not expose
        // posix_spawn attributes, so we race-fix from the parent right
        // after `run()` — both sides may call setpgid, and the second one
        // is a no-op once the child is already a group leader. If the
        // child has already called execve and is its own group leader we
        // get EACCES (harmless); if the child has already exited we get
        // ESRCH (also harmless).
        #if os(macOS) || os(Linux)
        _ = setpgid(p.processIdentifier, p.processIdentifier)
        #endif

        // Ordered line transport: dedicated OS thread (safe to block) →
        // AsyncStream → actor consumer (sequential, in order).
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lineContinuation = continuation
        let outHandle = outPipe.fileHandleForReading

        let cap = maxFrameBytes
        let thread = Thread {
            var buf = [UInt8]()
            var scan = 0
            // Finding 6/7: when set, we have dropped an oversized partial frame
            // and are discarding bytes until the next newline so the FOLLOWING
            // frame parses cleanly. We never tear down the connection for an
            // oversized frame — only EOF does that.
            var resyncing = false
            while true {
                let chunk = outHandle.availableData       // blocking — OK on a real thread
                if chunk.isEmpty { break }                // EOF / pipe closed
                if resyncing {
                    // Discard up to and including the next newline, then resume
                    // normal framing with whatever follows it.
                    if let nl = chunk.firstIndex(of: 0x0A) {
                        let after = chunk[(nl + 1)...]
                        buf = Array(after)
                        scan = 0
                        resyncing = false
                    } else {
                        continue   // still no newline; keep discarding
                    }
                } else {
                    buf.append(contentsOf: chunk)
                }
                while scan < buf.count {
                    if let nl = buf[scan...].firstIndex(of: 0x0A) {
                        let line = Array(buf[0..<nl])
                        buf.removeSubrange(0...nl)
                        scan = 0
                        if !line.isEmpty { continuation.yield(Data(line)) }
                    } else {
                        scan = buf.count
                        break
                    }
                }
                // Finding 6/7: an oversized partial frame (no newline within
                // `cap` bytes) must NOT tear down the whole connection. Upstream
                // imposes no hard newline-frame size cap that kills the session.
                // We keep `cap` only as a Swift-specific memory-safety bound:
                // on overflow we DROP the in-progress (incomplete) frame and
                // resync to the next newline, rather than breaking the reader
                // loop and failing all in-flight requests.
                if scan == buf.count && buf.count > cap {
                    FileHandle.standardError.write(Data(
                        "[mcp] dropping oversized stdio frame (\(buf.count) bytes > cap \(cap)); resyncing\n".utf8))
                    buf.removeAll(keepingCapacity: false)
                    scan = 0
                    resyncing = true
                }
            }
            continuation.finish()
        }
        thread.stackSize = 1 << 20
        thread.name = "ai.igent.codexkit.mcp.reader"
        thread.start()
        readerThread = thread

        consumerTask = Task { [weak self] in
            for await line in stream {
                await self?.handleLine(line)
            }
            await self?.failAllPending(McpError.transport("server stdout closed"))
        }
    }

    private func handleLine(_ data: Data) async {
        guard let obj = try? JSONLite.parse(data), case .object(let o) = obj else { return }
        // Distinguish three message shapes:
        //   1. response  → has `id` AND (`result` or `error`); correlates to a
        //      pending request we initiated.
        //   2. server request → has `id` AND `method` (e.g. `elicitation/create`).
        //   3. notification → has `method` but NO `id`. Upstream
        //      `logging_client_handler.rs` dispatches these to tracing; we
        //      route them to `notificationSink`. H-48 / area-04 F4 was that
        //      the old code dropped these on the floor.
        if let idVal = o["id"], case .number(let idn) = idVal {
            let id = Int(idn)
            if let cont = pending.removeValue(forKey: id) {
                removeElicitationHandler(id)
                timeouts.removeValue(forKey: id)?.cancel()
                if let errVal = o["error"], case .object(let e) = errVal {
                    let msg: String
                    if case .string(let s)? = e["message"] { msg = s } else { msg = "error" }
                    cont.resume(throwing: McpError.server(msg))
                    return
                }
                if let resVal = o["result"], case .object(let r) = resVal {
                    cont.resume(returning: r)
                } else {
                    cont.resume(returning: [:])
                }
                return
            }
            // Has id but no pending entry → must be an inbound server
            // request (elicitation/create).
            await handleServerRequest(id: id, object: o)
            return
        }
        // No id → server-push notification. Decode + forward.
        handleNotification(object: o)
    }

    /// Dispatch a parsed notification frame. Cancellation notifications
    /// also abort the corresponding in-flight request so callers stop
    /// waiting for a response the server will never send.
    private func handleNotification(object: [String: JSONLite]) {
        guard let notif = McpNotificationDecoder.decode(server: config.name,
                                                         object: object) else {
            return
        }
        // notifications/cancelled has side-effects: resolve any pending
        // continuation with a timeout/cancel error so the caller unblocks.
        if case .cancelled(_, let requestId, _, let reason) = notif,
           let rid = requestId,
           let cont = pending.removeValue(forKey: rid) {
            removeElicitationHandler(rid)
            timeouts.removeValue(forKey: rid)?.cancel()
            cont.resume(throwing: McpError.server(
                "cancelled by server: \(reason ?? "no reason")"))
        }
        notificationSink.handle(notif)
    }

    private func failAllPending(_ error: any Error) {
        for (_, t) in timeouts { t.cancel() }
        timeouts.removeAll()
        activeElicitationHandlers.removeAll()
        activeElicitationOrder.removeAll()
        for (_, c) in pending { c.resume(throwing: error) }
        pending.removeAll()
    }

    private func fireTimeout(_ id: Int) {
        timeouts.removeValue(forKey: id)
        removeElicitationHandler(id)
        if let c = pending.removeValue(forKey: id) {
            c.resume(throwing: McpError.timeout("request \(id)"))
        }
    }

    private func writeMessage(_ message: [String: Any]) throws {
        guard let stdin else { throw McpError.transport("stdin closed") }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func writeLiteMessage(_ message: JSONLite) throws {
        guard let stdin else { throw McpError.transport("stdin closed") }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func request(_ method: String, _ params: Any,
                         elicitationHandler: McpElicitationHandler? = nil) async throws
        -> [String: JSONLite] {
        let id = nextId; nextId += 1
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            if let elicitationHandler {
                activeElicitationHandlers[id] = elicitationHandler
                activeElicitationOrder.append(id)
            }
            let timeout = requestTimeout
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if Task.isCancelled { return }
                await self?.fireTimeout(id)
            }
            do {
                try writeMessage(message)
            } catch {
                pending.removeValue(forKey: id)
                removeElicitationHandler(id)
                timeouts.removeValue(forKey: id)?.cancel()
                cont.resume(throwing: error)
            }
        }
    }

    /// Drop an in-flight elicitation handler and its ordering entry together so
    /// `activeElicitationOrder` never references a removed id.
    private func removeElicitationHandler(_ id: Int) {
        if activeElicitationHandlers.removeValue(forKey: id) != nil {
            activeElicitationOrder.removeAll { $0 == id }
        }
    }

    private func handleServerRequest(id: Int, object: [String: JSONLite]) async {
        guard case .string("elicitation/create")? = object["method"] else { return }
        // Serve the most-recently-registered in-flight call's handler. Upstream
        // binds one closure per connection, so any in-flight call's handler is
        // equivalent; picking the newest is deterministic (unlike
        // `Dictionary.values.first`) and matches the call most likely to have
        // just triggered the elicitation.
        let handler = activeElicitationOrder.last.flatMap { activeElicitationHandlers[$0] }
        let result: JSONValue
        if let handler {
            result = await handler(.int(Int64(id)), config.name,
                                   Self.jsonLiteToValue(object["params"] ?? .object([:])))
                ?? Self.defaultElicitationResult(action: "decline")
        } else {
            result = Self.defaultElicitationResult(action: "decline")
        }
        let response = JSONLite.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "result": Self.jsonValueToLite(result),
        ])
        try? writeLiteMessage(response)
    }

    /// Upstream `CreateElicitationResultWithMeta` serializes `content` and
    /// `_meta` with `skip_serializing_if = "Option::is_none"`
    /// (`rmcp-client/src/elicitation_client_service.rs:124-151`), so a decline
    /// (no content, no meta) emits `{"action":"decline"}` only — we omit the
    /// nil fields rather than writing JSON `null`.
    private static func defaultElicitationResult(action: String) -> JSONValue {
        .object(["action": .string(action)])
    }

    public static func jsonLiteToValue(_ value: JSONLite) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n):
            if n.isFinite, n.rounded() == n,
               n >= -9_223_372_036_854_775_808.0,
               n <  9_223_372_036_854_775_808.0 {
                return .int(Int64(n))
            }
            return .double(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(jsonLiteToValue(_:)))
        case .object(let o): return .object(o.mapValues(jsonLiteToValue(_:)))
        }
    }

    /// Convert a `JSONLite` value into a `JSONSerialization`-compatible `Any`
    /// for embedding in an outbound request body (e.g. the verbatim
    /// `permissionProfile` object inside `SandboxState`). `null` maps to
    /// `NSNull`.
    public static func jsonLiteToAny(_ value: JSONLite) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(jsonLiteToAny(_:))
        case .object(let o):
            var dict = [String: Any](minimumCapacity: o.count)
            for (k, v) in o { dict[k] = jsonLiteToAny(v) }
            return dict
        }
    }

    public static func jsonValueToLite(_ value: JSONValue) -> JSONLite {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(jsonValueToLite(_:)))
        case .object(let o): return .object(o.mapValues(jsonValueToLite(_:)))
        }
    }

    public func initialize() async throws {
        guard !initialized else { return }
        // Upstream identity is `codex-mcp-client`, and the client declares the
        // `elicitation` capability so servers know they may issue
        // `elicitation/create` server-requests (which we route to the host).
        let result = try await request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": ["elicitation": McpClientInfo.elicitationCapability],
            "clientInfo": McpClientInfo.initializeClientInfo,
        ])
        // Capture the server's advertised capabilities + instructions instead
        // of discarding the result (upstream `rmcp_client.rs:496-506`).
        Self.applyInitializeResult(result,
                                   sandboxStateMetaSupported: &sandboxStateMetaSupported,
                                   instructions: &instructions)
        try writeMessage(["jsonrpc": "2.0", "method": "notifications/initialized"])
        initialized = true
    }

    /// Shared parser for the `initialize` result: records whether the server
    /// advertised `codex/sandbox-state-meta` under
    /// `capabilities.experimental` and captures `instructions`. Static + pure
    /// so both transports (and tests) use identical logic.
    static func applyInitializeResult(_ result: [String: JSONLite],
                                      sandboxStateMetaSupported: inout Bool,
                                      instructions: inout String?) {
        if case .object(let caps)? = result["capabilities"],
           case .object(let exp)? = caps["experimental"],
           exp[SandboxStateMeta.metaKey] != nil {
            sandboxStateMetaSupported = true
        }
        if case .string(let s)? = result["instructions"] {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            instructions = trimmed.isEmpty ? nil : trimmed
        }
    }

    public func supportsSandboxStateMeta() async -> Bool { sandboxStateMetaSupported }
    public func serverInstructions() async -> String? { instructions }

    /// `resources/list` — list the server's concrete resources. Mirrors the
    /// upstream rmcp client's resource listing (used by `mcpServer/resource/read`
    /// discovery). Returns the raw resource descriptors as JSON-lite values.
    ///
    /// Finding 3 (pagination): upstream `list_all_resources` walks every page,
    /// sending `{ "cursor": <next> }` until `nextCursor` is absent and erroring
    /// on a duplicate cursor (`"resources/list returned duplicate cursor"`).
    public func listResources() async throws -> [JSONLite] {
        try await paginate(method: "resources/list", arrayKey: "resources")
    }

    /// `resources/templates/list` — list URI-templated resources. Same
    /// pagination semantics as `listResources` (Finding 3).
    public func listResourceTemplates() async throws -> [JSONLite] {
        try await paginate(method: "resources/templates/list",
                           arrayKey: "resourceTemplates")
    }

    public func listResourcesPage(cursor: String?) async throws -> [String: JSONLite] {
        let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
        return try await request("resources/list", params)
    }

    public func listResourceTemplatesPage(cursor: String?) async throws
        -> [String: JSONLite] {
        let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
        return try await request("resources/templates/list", params)
    }

    /// Shared paginated-list driver. Walks `method` page by page, accumulating
    /// the `arrayKey` array, passing `{ "cursor": <next> }` for subsequent
    /// pages, stopping when `nextCursor` is absent, and erroring on a repeated
    /// cursor. Mirrors upstream `list_all_resources` / `list_all_resource_templates`.
    private func paginate(method: String, arrayKey: String) async throws -> [JSONLite] {
        var collected: [JSONLite] = []
        var cursor: String?
        while true {
            let params: [String: Any]
            if let cursor { params = ["cursor": cursor] } else { params = [:] }
            let r = try await request(method, params)
            if case .array(let arr)? = r[arrayKey] { collected.append(contentsOf: arr) }
            guard case .string(let next)? = r["nextCursor"], !next.isEmpty else {
                return collected
            }
            if cursor == next {
                throw McpError.server("\(method) returned duplicate cursor")
            }
            cursor = next
        }
    }

    public func listTools() async throws -> [McpToolSpec] {
        let r = try await request("tools/list", [String: Any]())
        guard let toolsVal = r["tools"], case .array(let arr) = toolsVal else { return [] }
        return arr.compactMap { v in
            guard case .object(let t) = v,
                  case .string(let name)? = t["name"] else { return nil }
            let desc: String
            if case .string(let d)? = t["description"] { desc = d } else { desc = "" }
            let schema = t["inputSchema"].map { JSONLite.stringify($0) } ?? "{}"
            // Finding 3: preserve the tool's `_meta` (connector identity +
            // openai/fileParams) verbatim.
            return McpToolSpec(name: name, description: desc,
                               inputSchemaJSON: schema, meta: t["_meta"])
        }
    }

    public func callTool(_ name: String, argumentsJSON: String,
                         meta: [String: Any]? = nil,
                         elicitationHandler: McpElicitationHandler? = nil) async throws
        -> McpCallResult {
        let args = try McpClient.parseToolArguments(argumentsJSON)
        // Upstream `tools/call` carries optional request-level `_meta`
        // (e.g. a `progressToken`); include it when supplied.
        var params: [String: Any] = ["name": name]
        if let args { params["arguments"] = args }
        if let meta, !meta.isEmpty { params["_meta"] = meta }
        let r = try await request("tools/call", params,
                                  elicitationHandler: elicitationHandler)
        return McpResultDecoder.decode(r, supportsImageInput: supportsImageInput)
    }

    /// Parse the model-supplied tool-call argument JSON into a JSON object.
    ///
    /// Upstream parity (`rmcp-client/src/rmcp_client.rs:553-561`): an empty /
    /// absent argument string maps to *no arguments* (`nil`), a JSON object maps
    /// to that object, and any other JSON value (array, number, string, …) is
    /// rejected with `"MCP tool arguments must be a JSON object"` instead of
    /// being silently coerced to `{}`.
    static func parseToolArguments(_ argumentsJSON: String) throws -> [String: Any]? {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Upstream parity (`rmcp-client/src/rmcp_client.rs:553-560`): the error
        // surfaced for non-object arguments includes the offending value:
        // `"MCP tool arguments must be a JSON object, got {other}"`.
        guard let d = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                with: d, options: [.fragmentsAllowed]) else {
            throw McpError.server(
                "MCP tool arguments must be a JSON object, got \(trimmed)")
        }
        guard let obj = parsed as? [String: Any] else {
            throw McpError.server(
                "MCP tool arguments must be a JSON object, got \(trimmed)")
        }
        return obj
    }

    public func readResource(uri: String) async throws -> [String: JSONLite] {
        try await request("resources/read", ["uri": uri])
    }

    public func stop() async {
        consumerTask?.cancel()
        consumerTask = nil
        lineContinuation?.finish()
        lineContinuation = nil
        for (_, t) in timeouts { t.cancel() }
        timeouts.removeAll()
        failAllPending(McpError.transport("client stopped"))
        if let p = process {
            // F7 (MEDIUM): graceful process-group shutdown. Upstream sends
            // SIGTERM to the whole PGID, waits `PROCESS_GROUP_TERM_GRACE_PERIOD`
            // (2 seconds), then SIGKILL the group. Falling back to single-PID
            // SIGKILL via `reapProcessTree` loses grandchildren and gives the
            // server no chance to flush state.
            //
            // P7.3: the grace-period polling now runs on a detached
            // DispatchQueue worker — see `terminateProcessGroupGracefully` —
            // so the actor's executor is free to dispatch other messages
            // while we wait. We still `await` the worker so the semantics
            // (`stop()` returns only after the process is reaped or killed)
            // match the prior blocking implementation.
            await McpClient.terminateProcessGroupGracefully(pid: p.processIdentifier)
        }
        process = nil
        stdin = nil
        readerThread = nil
    }

    // MARK: - Environment & process-group helpers (F6 / F7)

    /// Upstream `DEFAULT_ENV_VARS` allowlist (codex-rs/rmcp-client/utils.rs).
    /// These are the only parent-env vars forwarded to MCP servers by default.
    /// All other vars (including `CODEX_API_KEY`, `ANTHROPIC_API_KEY`, OAuth
    /// tokens, etc.) are dropped so a misconfigured MCP server cannot ex-
    /// filtrate secrets that were never intended for it.
    #if os(macOS)
    static let defaultEnvAllowlist: [String] = [
        "HOME", "LOGNAME", "PATH", "SHELL", "USER",
        "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL",
        "TERM", "TMPDIR", "TZ",
    ]
    #elseif os(Linux)
    static let defaultEnvAllowlist: [String] = [
        "HOME", "LOGNAME", "PATH", "SHELL", "USER",
        "LANG", "LC_ALL", "TERM", "TMPDIR", "TZ",
    ]
    #else
    static let defaultEnvAllowlist: [String] = ["PATH", "HOME"]
    #endif

    /// Build the sanitized child environment for a stdio MCP server.
    /// Order of precedence (low → high):
    ///   1. `DEFAULT_ENV_VARS` allowlist read from parent env
    ///   2. Locally-sourced `config.envVars` (parent env values)
    ///   3. `config.env` literal overrides
    /// A remote-sourced `env_vars` entry on a LOCAL stdio launch is a hard
    /// configuration error (upstream `local_stdio_env_var_names`,
    /// `rmcp-client/src/utils.rs:50-58`): we throw `McpError.spawn` with the
    /// upstream message rather than silently dropping the entry and starting
    /// the server anyway.
    static func buildStdioEnvironment(config: McpServerConfig) throws -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var out: [String: String] = [:]
        for name in defaultEnvAllowlist {
            if let v = parent[name] { out[name] = v }
        }
        if let envVars = config.envVars {
            if let remote = envVars.first(where: { $0.isRemoteSource }) {
                throw McpError.spawn(
                    "env_vars entry `\(remote.name)` uses source `remote`, "
                    + "which requires remote MCP stdio")
            }
            for item in envVars {
                if let v = parent[item.name] { out[item.name] = v }
            }
        }
        if let env = config.env {
            for (k, v) in env { out[k] = v }
        }
        return out
    }

    /// Test-only PID accessor for parity tests (process group, signal
    /// delivery). Not exposed for production callers — Foundation's
    /// `Process.processIdentifier` is the canonical accessor inside the
    /// module.
    public func _testChildPID() -> Int32? { process?.processIdentifier }

    /// Upstream parity grace period before SIGKILL escalation.
    static let processGroupTermGracePeriod: Duration = .seconds(2)

    /// SIGTERM the whole process group, wait up to 2s for clean exit,
    /// then SIGKILL the group. Uses negative PID to address the PGID; the
    /// child was placed into its own group at spawn via `setpgid(pid,pid)`.
    ///
    /// Non-blocking with respect to the calling actor: the SIGTERM is issued
    /// synchronously (so callers see the immediate effect upstream relies on),
    /// then the grace-period polling and any SIGKILL escalation run on a
    /// detached `DispatchQueue.global()` worker. The caller `await`s a
    /// continuation that fires when the worker finishes, so the actor's
    /// executor thread is free to service other messages during the 2-second
    /// wait — mirroring upstream's pattern (`spawn(move || { sleep(...); ...
    /// })` in `rmcp-client/src/stdio_server_launcher.rs::terminate`).
    static func terminateProcessGroupGracefully(pid: Int32) async {
        #if os(macOS) || os(Linux)
        // Verify pgid before signalling. If pgid != pid the child never
        // became a group leader (setpgid lost the race against execve);
        // we must NOT `kill(-pid)` because that would target the parent's
        // group. In that case fall back to a single-PID escalation.
        let pgid = getpgid(pid)
        let inOwnGroup = (pgid == pid)
        let groupTermOk = inOwnGroup && (kill(-pid, SIGTERM) == 0)
        let usePerProcessSignal = !groupTermOk
        if usePerProcessSignal {
            // Fall back: single-process SIGTERM with 2s grace, then SIGKILL.
            if kill(pid, SIGTERM) != 0 {
                reapProcessTree(pid)
                return
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(2.0)
                while Date() < deadline {
                    // kill(pid, 0) probes existence without sending a signal.
                    if kill(pid, 0) != 0 { cont.resume(); return }   // exited
                    usleep(50_000)
                }
                if usePerProcessSignal {
                    _ = kill(pid, SIGKILL)
                } else {
                    _ = kill(-pid, SIGKILL)
                }
                cont.resume()
            }
        }
        #else
        reapProcessTree(pid)
        #endif
    }
}
