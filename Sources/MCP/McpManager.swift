import Foundation
import Config
import InfraPrimitives
import ProtocolModel
import Tools

/// Server-namespaced proxy that lets the model invoke an MCP tool through the
/// harness ToolRouter (Codex `mcp__<server>__<tool>` exposure). Serial: upstream
/// always runs MCP tool calls on the exclusive side of the per-turn tool gate.
/// `McpToolHandler::supports_parallel_tool_calls` returns
/// `self.tool_info.supports_parallel_tool_calls` (core/src/tools/handlers/mcp.rs:86-88),
/// and the production `rmcp` client always sets that to `false`
/// (codex-mcp/src/rmcp_client.rs:378, mcp/mod.rs:446). Reproduce that constant
/// `false` so MCP calls cannot race with other parallel-safe tools.
public struct McpToolProxy: Tool {
    public let name: String
    public let parallelSafe = false
    public let toolDescription: String
    public let jsonSchema: String
    private let server: String
    private let tool: String
    private let client: any McpClientProtocol
    private let elicitationHandler: McpElicitationHandler?
    /// Conversation/thread id injected into every `tools/call` request's
    /// `_meta.threadId` (upstream `with_mcp_tool_call_thread_id_meta`,
    /// `core/src/mcp_tool_call.rs:561-562/1075-1097`). `nil` for standalone
    /// construction (tests) where no session context exists.
    private let threadId: String?
    /// The turn's sandbox state, injected into every `tools/call` request's
    /// `_meta` under `codex/sandbox-state-meta` — but ONLY for servers that
    /// advertised the matching experimental capability in `initialize`
    /// (upstream `augment_mcp_tool_request_meta_with_sandbox_state`,
    /// `core/src/mcp_tool_call.rs:705-751`). `nil` when no session/turn
    /// context was threaded (tests, status-only paths).
    private let sandboxState: SandboxStateMeta?
    /// Server-advertised `codex/sandbox-state-meta` support, captured at
    /// registration time so `run()` need not re-query the actor. Upstream
    /// reads this through `server_supports_sandbox_state_meta_capability`.
    private let serverSupportsSandboxStateMeta: Bool
    /// The server's `initialize` `instructions`, used upstream as the
    /// `namespace_description` for this server's tools when they carry no
    /// connector metadata (`rmcp_client.rs:371-375`). Preserved here for the
    /// deferred-tool / tool-search exposure path.
    public let serverInstructions: String?
    public init(server: String, tool: String, client: any McpClientProtocol,
                description: String = "",
                elicitationHandler: McpElicitationHandler? = nil,
                schemaJSON: String = #"{"type":"object","additionalProperties":true}"#,
                modelName: String? = nil,
                threadId: String? = nil,
                sandboxState: SandboxStateMeta? = nil,
                serverSupportsSandboxStateMeta: Bool = false,
                serverInstructions: String? = nil) {
        self.server = server
        self.tool = tool
        self.client = client
        self.elicitationHandler = elicitationHandler
        self.threadId = threadId
        self.sandboxState = sandboxState
        self.serverSupportsSandboxStateMeta = serverSupportsSandboxStateMeta
        self.serverInstructions = serverInstructions
        if let modelName {
            // Caller (McpManager) ran the upstream collision-resolution +
            // length-fitting pass (`normalize_tools_for_model`) and supplied
            // the unique, <=64-char model-visible name.
            self.name = modelName
        } else {
            // Standalone construction (tests / single-tool callers): mirror the
            // upstream single-tool naming. `sanitize_responses_api_tool_name`
            // (codex-mcp/src/tools.rs): the model-visible name must contain only
            // `[A-Za-z0-9_]`; every other character (dots, hyphens, spaces, …)
            // is replaced with `_`, then fitted to the 64-char tool-name cap.
            let norm = McpToolNormalization.normalizeToolsForModel([
                McpToolNormalization.ToolInfo(
                    serverName: server, toolName: tool,
                    tool: McpToolSpec(name: tool, description: description,
                                      inputSchemaJSON: schemaJSON))
            ])
            self.name = norm.first?.modelName
                ?? String(("mcp__\(McpToolProxy.sanitizeResponsesAPIToolName(server))__"
                           + McpToolProxy.sanitizeResponsesAPIToolName(tool)).prefix(64))
        }
        self.toolDescription = description
        self.jsonSchema = schemaJSON.isEmpty
            ? #"{"type":"object","additionalProperties":true}"# : schemaJSON
    }
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

    /// Upstream `MCP_TOOL_THREAD_ID_META_KEY` (`core/src/mcp_tool_call.rs:986`).
    static let threadIdMetaKey = "threadId"

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        do {
            // Upstream unconditionally injects `_meta.threadId = <conversation_id>`
            // into the params of EVERY `tools/call` request
            // (`core/src/mcp_tool_call.rs:561-562` →
            // `with_mcp_tool_call_thread_id_meta`). Thread it through here so
            // servers that correlate calls to a conversation receive it.
            var metaDict: [String: Any] = [:]
            if let threadId, !threadId.isEmpty {
                metaDict[McpToolProxy.threadIdMetaKey] = threadId
            }
            // Upstream `augment_mcp_tool_request_meta_with_sandbox_state`
            // (`core/src/mcp_tool_call.rs:705-751`): inject the full
            // `SandboxState` under `codex/sandbox-state-meta` ONLY for servers
            // that advertised the capability in `initialize`.
            if serverSupportsSandboxStateMeta, let sandboxState {
                metaDict[SandboxStateMeta.metaKey] = sandboxState.metaObject()
            }
            let meta: [String: Any]? = metaDict.isEmpty ? nil : metaDict
            let r = try await client.callTool(tool, argumentsJSON: call.argumentsJSON,
                                              meta: meta,
                                              elicitationHandler: elicitationHandler)
            return ToolResult(callId: call.callId,
                              output: r.text.isEmpty ? "(no content)" : r.text,
                              success: !r.isError, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "mcp error: \(error)",
                              success: false, truncated: false)
        }
    }
}

public struct McpServerStatus: Sendable, Equatable {
    public var name: String
    public var state: String          // starting | ready | failed
    public var tools: [McpToolSpec]
    public var error: String?
}

/// Loads/starts configured MCP servers and exposes their tools to the
/// harness. Configuration is read from two locations, in order:
/// 1. `$CODEX_HOME/config.toml` — the upstream codex standard. Servers
///    are declared under the `[mcp_servers.<name>]` TOML table with
///    fields `command`, `args`, `env`, `url`, `bearer_token_env_var`,
///    and `http_headers`.
/// 2. `$CODEX_HOME/mcp.json` — legacy back-compat path. Accepts either
///    `{ "servers": [ { "name", "command", "args", "env" } ] }` or the
///    codex-shaped `{ "mcpServers": { "<name>": { stdio | http } } }` map.
/// Entries from `config.toml` take precedence; `mcp.json` entries are
/// folded in only for names not already declared in TOML, so a partial
/// migration works cleanly.
public actor McpManager {
    private var clients: [String: any McpClientProtocol] = [:]
    private var statuses: [String: McpServerStatus] = [:]
    /// Per-server config, captured at start so the call boundary can
    /// re-enforce the enabled/disabled tool filter (upstream
    /// `ToolFilter::allows`, connection_manager.rs:582-594) on direct
    /// `mcpServer/tool/call` requests, independent of model-exposure filtering.
    private var configByName: [String: McpServerConfig] = [:]

    public init() {}

    public static func loadConfigs(codexHome: String) -> [McpServerConfig] {
        // 1. Try the standard upstream location: config.toml [mcp_servers].
        let tomlServers = loadConfigsFromConfigToml(codexHome: codexHome)
        // 2. Legacy mcp.json fallback (back-compat).
        let jsonServers = loadConfigsFromMcpJson(codexHome: codexHome)

        if tomlServers.isEmpty { return jsonServers }
        if jsonServers.isEmpty { return tomlServers }

        // Merge: TOML wins; mcp.json fills in names TOML didn't define.
        var byName: [String: McpServerConfig] = [:]
        for cfg in tomlServers { byName[cfg.name] = cfg }
        for cfg in jsonServers where byName[cfg.name] == nil {
            byName[cfg.name] = cfg
        }
        return byName.keys.sorted().compactMap { byName[$0] }
    }

    /// Reads `$CODEX_HOME/config.toml` and extracts the `[mcp_servers]`
    /// table. Returns an empty array on any IO/parse failure or when the
    /// table is absent — callers fall back to `mcp.json`.
    static func loadConfigsFromConfigToml(codexHome: String) -> [McpServerConfig] {
        let path = codexHome + "/config.toml"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let root: [String: ConfigValue]
        do {
            root = try TOML.parse(text)
        } catch {
            return []
        }
        guard case .object(let servers)? = root["mcp_servers"] else { return [] }
        var result: [McpServerConfig] = []
        for name in servers.keys.sorted() {
            guard case .object(let entry)? = servers[name] else { continue }
            if let cfg = makeConfig(name: name, entry: entry) {
                result.append(cfg)
            }
        }
        return result
    }

    /// Convert a parsed TOML `[mcp_servers.<name>]` table into an
    /// `McpServerConfig`. Decodes all upstream-parity fields (H-46 / F2):
    /// `cwd`, `env_vars`, `env_http_headers`, `startup_timeout_sec`,
    /// `tool_timeout_sec`, `enabled_tools`, `disabled_tools`, `required`,
    /// `supports_parallel_tool_calls`, `scopes`, `oauth`, `oauth_resource`.
    private static func makeConfig(name: String,
                                    entry: [String: ConfigValue]) -> McpServerConfig? {
        // HTTP transport: any `url` present (even if empty string, but
        // empty means "not set" by isHTTP logic) takes the HTTP path.
        var cfg: McpServerConfig
        if case .string(let url)? = entry["url"], !url.isEmpty {
            var headers: [String: String] = [:]
            if case .object(let h)? = entry["http_headers"] {
                for (k, v) in h { if case .string(let s) = v { headers[k] = s } }
            }
            var bearer: String? = nil
            if case .string(let b)? = entry["bearer_token_env_var"] { bearer = b }
            cfg = McpServerConfig(name: name, url: url,
                                  bearerTokenEnvVar: bearer,
                                  httpHeaders: headers)
        } else {
            // stdio transport.
            var command = ""
            if case .string(let c)? = entry["command"] { command = c }
            var args: [String] = []
            if case .array(let a)? = entry["args"] {
                for v in a { if case .string(let s) = v { args.append(s) } }
            }
            var env: [String: String]? = nil
            if case .object(let e)? = entry["env"] {
                var m: [String: String] = [:]
                for (k, v) in e { if case .string(let s) = v { m[k] = s } }
                if !m.isEmpty { env = m }
            }
            // Treat entries that supply neither command nor url as invalid.
            if command.isEmpty { return nil }
            cfg = McpServerConfig(name: name, command: command,
                                  args: args, env: env)
        }
        applyCommonFields(entry: entry, into: &cfg)
        return cfg
    }

    /// Shared decoder for fields that apply to both transports. Pulled out
    /// so adding a new upstream field requires touching one place only.
    private static func applyCommonFields(entry: [String: ConfigValue],
                                          into cfg: inout McpServerConfig) {
        if case .string(let s)? = entry["cwd"], !s.isEmpty { cfg.cwd = s }
        if case .array(let arr)? = entry["env_vars"] {
            var out: [McpServerEnvVar] = []
            for v in arr {
                switch v {
                case .string(let s):
                    out.append(McpServerEnvVar(name: s))
                case .object(let o):
                    guard case .string(let n)? = o["name"] else { continue }
                    var src: String? = nil
                    if case .string(let s)? = o["source"] { src = s }
                    out.append(McpServerEnvVar(name: n, source: src))
                default:
                    continue
                }
            }
            if !out.isEmpty { cfg.envVars = out }
        }
        if case .object(let h)? = entry["env_http_headers"] {
            var m: [String: String] = [:]
            for (k, v) in h { if case .string(let s) = v { m[k] = s } }
            if !m.isEmpty { cfg.envHttpHeaders = m }
        }
        cfg.startupTimeoutSec = decodeSeconds(entry["startup_timeout_sec"])
        cfg.toolTimeoutSec = decodeSeconds(entry["tool_timeout_sec"])
        if case .array(let a)? = entry["enabled_tools"] {
            let names = a.compactMap { v -> String? in
                if case .string(let s) = v { return s }
                return nil
            }
            if !names.isEmpty { cfg.enabledTools = names }
        }
        if case .array(let a)? = entry["disabled_tools"] {
            let names = a.compactMap { v -> String? in
                if case .string(let s) = v { return s }
                return nil
            }
            if !names.isEmpty { cfg.disabledTools = names }
        }
        if case .bool(let b)? = entry["required"] { cfg.required = b }
        if case .bool(let b)? = entry["supports_parallel_tool_calls"] {
            cfg.supportsParallelToolCalls = b
        }
        if case .array(let a)? = entry["scopes"] {
            let s = a.compactMap { v -> String? in
                if case .string(let s) = v { return s }
                return nil
            }
            if !s.isEmpty { cfg.scopes = s }
        }
        if case .object(let o)? = entry["oauth"] {
            var oa = McpOAuthConfig()
            if case .string(let cid)? = o["client_id"] { oa.clientId = cid }
            else if case .string(let cid)? = o["clientId"] { oa.clientId = cid }
            cfg.oauth = oa
        }
        if case .string(let s)? = entry["oauth_resource"], !s.isEmpty {
            cfg.oauthResource = s
        }
    }

    /// TOML accepts both integer and float for duration fields. The
    /// upstream `option_duration_secs` deserializer reads `f64`.
    private static func decodeSeconds(_ v: ConfigValue?) -> TimeInterval? {
        switch v {
        case .int(let i): return TimeInterval(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Legacy reader: `$CODEX_HOME/mcp.json` in either the `servers` array
    /// shape or the `mcpServers` map shape.
    static func loadConfigsFromMcpJson(codexHome: String) -> [McpServerConfig] {
        let path = codexHome + "/mcp.json"
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let dec = JSONDecoder()

        struct LegacyFile: Decodable { var servers: [McpServerConfig]? }
        struct MapEntry: Decodable {
            var command: String?
            var args: [String]?
            var env: [String: String]?
            var url: String?
            var bearerTokenEnvVar: String?
            var httpHeaders: [String: String]?
            enum CodingKeys: String, CodingKey {
                case command, args, env, url
                case bearerTokenEnvVar
                case bearerTokenEnvVarSnake = "bearer_token_env_var"
                case httpHeaders
                case httpHeadersSnake = "http_headers"
            }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                command = try c.decodeIfPresent(String.self, forKey: .command)
                args = try c.decodeIfPresent([String].self, forKey: .args)
                env = try c.decodeIfPresent([String: String].self, forKey: .env)
                url = try c.decodeIfPresent(String.self, forKey: .url)
                if let b = try c.decodeIfPresent(String.self,
                                                 forKey: .bearerTokenEnvVar) {
                    bearerTokenEnvVar = b
                } else {
                    bearerTokenEnvVar = try c.decodeIfPresent(
                        String.self, forKey: .bearerTokenEnvVarSnake)
                }
                if let h = try c.decodeIfPresent([String: String].self,
                                                 forKey: .httpHeaders) {
                    httpHeaders = h
                } else {
                    httpHeaders = try c.decodeIfPresent(
                        [String: String].self, forKey: .httpHeadersSnake)
                }
            }
        }
        struct CodexFile: Decodable { var mcpServers: [String: MapEntry]? }

        var result: [McpServerConfig] = []
        if let legacy = try? dec.decode(LegacyFile.self, from: data),
           let servers = legacy.servers {
            result.append(contentsOf: servers)
        }
        if let codex = try? dec.decode(CodexFile.self, from: data),
           let map = codex.mcpServers {
            for name in map.keys.sorted() {
                guard let e = map[name] else { continue }
                if let u = e.url, !u.isEmpty {
                    result.append(McpServerConfig(
                        name: name, url: u,
                        bearerTokenEnvVar: e.bearerTokenEnvVar,
                        httpHeaders: e.httpHeaders ?? [:]))
                } else {
                    result.append(McpServerConfig(
                        name: name, command: e.command ?? "",
                        args: e.args ?? [], env: e.env))
                }
            }
        }
        return result
    }

    /// Start every configured server, discover its tools, and register
    /// namespaced proxies on `router`. Failures are isolated per-server.
    public func startAll(_ configs: [McpServerConfig]) async {
        await startAll(configs, router: ToolRouter(limits: Limits()))
    }

    /// Convenience: same defaults as `startAll(_:)` but with a startup-status
    /// callback so callers without a `ToolRouter` (e.g. the app-server's
    /// `mcpServer/startupStatus/list` path) can stream
    /// `mcpServer/startupStatus/updated` notifications.
    public func startAll(_ configs: [McpServerConfig],
                         onStatusUpdate: StartupStatusUpdate?) async {
        await startAll(configs, router: ToolRouter(limits: Limits()),
                       oauthStore: nil, elicitationHandler: nil,
                       supportsImageInput: false, threadId: nil,
                       sandboxState: nil, onStatusUpdate: onStatusUpdate)
    }

    public func startAll(_ configs: [McpServerConfig], router: ToolRouter) async {
        await startAll(configs, router: router, oauthStore: nil)
    }

    public func startAll(_ configs: [McpServerConfig], router: ToolRouter,
                         oauthStore: McpOAuthStore?) async {
        await startAll(configs, router: router, oauthStore: oauthStore,
                       elicitationHandler: nil)
    }

    public func startAll(_ configs: [McpServerConfig], router: ToolRouter,
                         oauthStore: McpOAuthStore?,
                         elicitationHandler: McpElicitationHandler?) async {
        await startAll(configs, router: router, oauthStore: oauthStore,
                       elicitationHandler: elicitationHandler,
                       supportsImageInput: false)
    }

    public func startAll(_ configs: [McpServerConfig], router: ToolRouter,
                         oauthStore: McpOAuthStore?,
                         elicitationHandler: McpElicitationHandler?,
                         supportsImageInput: Bool) async {
        await startAll(configs, router: router, oauthStore: oauthStore,
                       elicitationHandler: elicitationHandler,
                       supportsImageInput: supportsImageInput,
                       threadId: nil)
    }

    /// `supportsImageInput` mirrors the session model's image-input capability
    /// (`models.json` `input_modalities` contains `image`). When false, MCP
    /// `image` content blocks are replaced with the upstream placeholder; when
    /// true they are forwarded to the model verbatim
    /// (`mcp_tool_call.rs::sanitize_mcp_tool_result_for_model`).
    /// `threadId` is the conversation/thread id of the owning session; it is
    /// injected into every `tools/call` request's `_meta.threadId` by the
    /// registered `McpToolProxy` (upstream `with_mcp_tool_call_thread_id_meta`).
    public func startAll(_ configs: [McpServerConfig], router: ToolRouter,
                         oauthStore: McpOAuthStore?,
                         elicitationHandler: McpElicitationHandler?,
                         supportsImageInput: Bool,
                         threadId: String?) async {
        await startAll(configs, router: router, oauthStore: oauthStore,
                       elicitationHandler: elicitationHandler,
                       supportsImageInput: supportsImageInput,
                       threadId: threadId, sandboxState: nil)
    }

    /// `sandboxState`, when supplied, is the turn's `SandboxState` payload that
    /// each registered `McpToolProxy` injects into `tools/call` `_meta` under
    /// `codex/sandbox-state-meta` — but only for servers that advertised the
    /// capability in `initialize` (upstream
    /// `augment_mcp_tool_request_meta_with_sandbox_state`).
    public func startAll(_ configs: [McpServerConfig], router: ToolRouter,
                         oauthStore: McpOAuthStore?,
                         elicitationHandler: McpElicitationHandler?,
                         supportsImageInput: Bool,
                         threadId: String?,
                         sandboxState: SandboxStateMeta?) async {
        await startAll(configs, router: router, oauthStore: oauthStore,
                       elicitationHandler: elicitationHandler,
                       supportsImageInput: supportsImageInput,
                       threadId: threadId, sandboxState: sandboxState,
                       onStatusUpdate: nil)
    }

    /// Callback invoked as each configured MCP server transitions through its
    /// startup lifecycle (`starting` before connect, then `ready`/`failed`/
    /// `cancelled`). Mirrors upstream's per-server `EventMsg::McpStartupUpdate`,
    /// which the v2 app-server surfaces as the `mcpServer/startupStatus/updated`
    /// notification (bespoke_event_handling.rs:196-218). `error` carries the
    /// curated init-failure message on `failed`, `nil` otherwise.
    public typealias StartupStatusUpdate =
        @Sendable (_ server: String, _ status: McpServerStartupState,
                   _ error: String?) async -> Void

    /// `onStatusUpdate`, when supplied, receives a per-server startup-status
    /// update (Starting before each connect, then Ready/Failed) so the caller
    /// can stream `mcpServer/startupStatus/updated` notifications to the
    /// frontend (upstream `connection_manager.rs:202-311`).
    public func startAll(_ configs: [McpServerConfig], router: ToolRouter,
                         oauthStore: McpOAuthStore?,
                         elicitationHandler: McpElicitationHandler?,
                         supportsImageInput: Bool,
                         threadId: String?,
                         sandboxState: SandboxStateMeta?,
                         onStatusUpdate: StartupStatusUpdate?) async {
        // Phase 1: start each server, discover + filter its tools, and record
        // which client owns each tool. Failures are isolated per-server.
        var pendingTools: [McpToolNormalization.ToolInfo] = []
        var clientByServer: [String: any McpClientProtocol] = [:]
        // Per-server capability + instructions captured from `initialize`
        // (upstream `rmcp_client.rs:496-506`).
        var sandboxMetaByServer: [String: Bool] = [:]
        var instructionsByServer: [String: String] = [:]
        for cfg in configs {
            if statuses[cfg.name]?.state == "ready", clients[cfg.name] != nil {
                continue
            }
            // Record the config so the call boundary can re-enforce the
            // enabled/disabled tool filter (finding 6).
            configByName[cfg.name] = cfg
            // Finding 5 (MCP server-name validation): upstream
            // `validate_mcp_server_name` rejects names not matching
            // `^[a-zA-Z0-9_-]+$` BEFORE the client is started.
            if let err = Self.validateServerName(cfg.name) {
                statuses[cfg.name] = McpServerStatus(name: cfg.name, state: "failed",
                                                     tools: [], error: err)
                await onStatusUpdate?(cfg.name, McpServerStartupState.failed, err)
                continue
            }
            // Bearer-token validation: a declared-but-unresolvable
            // `bearer_token_env_var` is a fatal misconfiguration upstream
            // (`resolve_bearer_token`), so the server must fail to start
            // rather than connect unauthenticated.
            if let err = Self.validateBearerToken(cfg, env: ProcessInfo.processInfo.environment) {
                statuses[cfg.name] = McpServerStatus(name: cfg.name, state: "failed",
                                                     tools: [], error: err)
                await onStatusUpdate?(cfg.name, McpServerStartupState.failed, err)
                continue
            }
            // Emit the Starting update before the connect attempt (upstream
            // emits `McpStartupStatus::Starting` per server first).
            statuses[cfg.name] = McpServerStatus(name: cfg.name, state: "starting",
                                                 tools: [], error: nil)
            await onStatusUpdate?(cfg.name, McpServerStartupState.starting, nil)
            let client: any McpClientProtocol = cfg.isHTTP
                ? McpHttpClient(cfg, oauthStore: oauthStore,
                                supportsImageInput: supportsImageInput)
                : McpClient(cfg, supportsImageInput: supportsImageInput)
            clients[cfg.name] = client
            do {
                try await client.start()
                try await client.initialize()
                let rawTools = try await client.listTools()
                // Upstream parity: apply enabled_tools (allowlist) +
                // disabled_tools (denylist) before exposing to the model.
                let tools = cfg.filterTools(rawTools)
                clientByServer[cfg.name] = client
                // Capture the server's advertised sandbox-state-meta capability
                // and instructions for the registration pass below.
                sandboxMetaByServer[cfg.name] = await client.supportsSandboxStateMeta()
                instructionsByServer[cfg.name] = await client.serverInstructions()
                for t in tools {
                    pendingTools.append(McpToolNormalization.ToolInfo(
                        serverName: cfg.name, toolName: t.name, tool: t))
                }
                statuses[cfg.name] = McpServerStatus(name: cfg.name, state: "ready",
                                                     tools: tools, error: nil)
                await onStatusUpdate?(cfg.name, McpServerStartupState.ready, nil)
            } catch {
                // Classify the failure into curated operator guidance
                // (finding: mcp_init_error_display) before surfacing it.
                let display = Self.mcpInitErrorDisplay(serverName: cfg.name,
                                                       config: cfg,
                                                       rawError: "\(error)")
                statuses[cfg.name] = McpServerStatus(name: cfg.name, state: "failed",
                                                     tools: [], error: display)
                await onStatusUpdate?(cfg.name, McpServerStartupState.failed, display)
            }
        }

        // Phase 2: run the upstream `normalize_tools_for_model` pass across the
        // combined tool set so colliding callable names are disambiguated with
        // SHA1 hash suffixes and fitted to 64 chars (instead of silently
        // overwriting in the ToolRouter). Then register each proxy with its
        // resolved, unique model-visible name.
        let normalized = McpToolNormalization.normalizeToolsForModel(pendingTools) { msg in
            FileHandle.standardError.write(Data(("[mcp] " + msg + "\n").utf8))
        }
        for n in normalized {
            guard let client = clientByServer[n.serverName] else { continue }
            // Finding 4: present the model-visible input schema, masking any
            // `_meta["openai/fileParams"]` properties to an absolute-file-path
            // string/array + guidance text (upstream
            // `tool_with_model_visible_input_schema`, applied at manager return
            // boundaries — connection_manager.rs:421-426). Raw metadata stays
            // on the spec for protocol calls.
            let maskedSchema = McpToolNormalization.maskedInputSchemaJSON(for: n.tool)
            await router.register(McpToolProxy(
                server: n.serverName, tool: n.toolName, client: client,
                description: n.tool.description,
                elicitationHandler: elicitationHandler,
                schemaJSON: maskedSchema,
                modelName: n.modelName,
                threadId: threadId,
                sandboxState: sandboxState,
                serverSupportsSandboxStateMeta:
                    sandboxMetaByServer[n.serverName] ?? false,
                serverInstructions: instructionsByServer[n.serverName]))
        }

        // Phase 3: register the three model-visible MCP resource tools whenever
        // any MCP server is configured. Upstream gates these on
        // `params.mcp_tools.is_some()` (no feature flag) — i.e. MCP is enabled
        // for this thread (`spec_plan.rs:385-389`). We mirror that by gating on
        // a non-empty config set so the tools are advertised even if a server
        // failed to start (matching upstream, where the tools are present
        // independent of per-server readiness).
        if !configs.isEmpty {
            await router.register(ListMcpResourcesTool(manager: self))
            await router.register(ListMcpResourceTemplatesTool(manager: self))
            await router.register(ReadMcpResourceTool(manager: self))
        }
    }

    /// Upstream `validate_mcp_server_name` (codex-mcp/src/rmcp_client.rs:448):
    /// reject any server name not matching `^[a-zA-Z0-9_-]+$`. Returns the
    /// upstream-style error string, or `nil` when valid.
    static func validateServerName(_ name: String) -> String? {
        let pattern = "[a-zA-Z0-9_-]+"
        let valid = !name.isEmpty && name.unicodeScalars.allSatisfy { sc in
            (sc >= "a" && sc <= "z") || (sc >= "A" && sc <= "Z")
                || (sc >= "0" && sc <= "9") || sc == "_" || sc == "-"
        }
        if valid { return nil }
        return "Invalid MCP server name '\(name)': must match pattern ^\(pattern)$"
    }

    /// Eagerly resolve a configured `bearer_token_env_var` BEFORE the client
    /// connects, mirroring upstream `resolve_bearer_token`
    /// (codex-mcp/src/rmcp_client.rs:421-446). A declared-but-unresolvable
    /// bearer-token env var is a fatal misconfiguration: the server must fail
    /// to start rather than silently connecting unauthenticated. Returns the
    /// upstream-style error string, or `nil` when there is nothing to validate
    /// (no env var configured) or the value resolves to a non-empty string.
    static func validateBearerToken(_ cfg: McpServerConfig,
                                    env: [String: String]) -> String? {
        guard let envVar = cfg.bearerTokenEnvVar else { return nil }
        guard let value = env[envVar] else {
            return "Environment variable \(envVar) for MCP server "
                + "'\(cfg.name)' is not set"
        }
        if value.isEmpty {
            return "Environment variable \(envVar) for MCP server "
                + "'\(cfg.name)' is empty"
        }
        return nil
    }

    /// GitHub MCP endpoint that does not support OAuth (upstream constant in
    /// `mcp_init_error_display`).
    static let gitHubMcpURL = "https://api.githubcopilot.com/mcp/"

    /// Port of `mcp_init_error_display` (connection_manager.rs:708-749):
    /// classify a startup failure and produce curated operator guidance —
    /// GitHub-MCP PAT instructions, an `Auth required` login hint, or a
    /// startup-timeout config hint — falling back to a generic message.
    static func mcpInitErrorDisplay(serverName: String,
                                    config: McpServerConfig,
                                    rawError: String) -> String {
        // GitHub MCP without OAuth/bearer/headers: PAT setup guidance.
        if config.url == gitHubMcpURL,
           config.bearerTokenEnvVar == nil,
           config.httpHeaders.isEmpty {
            return "GitHub MCP does not support OAuth. Log in by adding a "
                + "personal access token "
                + "(https://github.com/settings/personal-access-tokens) to your "
                + "environment and config.toml:\n[mcp_servers.\(serverName)]\n"
                + "bearer_token_env_var = CODEX_GITHUB_PERSONAL_ACCESS_TOKEN"
        }
        // Auth-required error (matches upstream substring check).
        if rawError.contains("Auth required") {
            return "The \(serverName) MCP server is not logged in. "
                + "Run `codex mcp login \(serverName)`."
        }
        // Startup-timeout error (matches upstream substring checks).
        if rawError.contains("request timed out")
            || rawError.contains("timed out handshaking with MCP server") {
            let secs = Int(config.effectiveStartupTimeout)
            return "MCP client for `\(serverName)` timed out after \(secs) "
                + "seconds. Add or adjust `startup_timeout_sec` in your "
                + "config.toml:\n[mcp_servers.\(serverName)]\nstartup_timeout_sec = XX"
        }
        return "MCP client for `\(serverName)` failed to start: \(rawError)"
    }

    public func statusList() -> [McpServerStatus] {
        statuses.values.sorted { $0.name < $1.name }
    }

    /// Test-only seam: register a client under `name` without spawning a real
    /// transport, so resource-tool behavior can be exercised against a mock.
    func _seedClientForTesting(_ name: String, _ client: any McpClientProtocol,
                               config: McpServerConfig? = nil) {
        clients[name] = client
        statuses[name] = McpServerStatus(name: name, state: "ready",
                                         tools: [], error: nil)
        if let config { configByName[name] = config }
    }

    public func callTool(server: String, tool: String, argumentsJSON: String,
                         elicitationHandler: McpElicitationHandler? = nil) async throws
        -> McpCallResult {
        guard let client = clients[server] else {
            throw McpError.server("MCP server not loaded: \(server)")
        }
        // Re-enforce the per-server enabled/disabled tool filter at the call
        // boundary as defense-in-depth, regardless of how the call arrived
        // (a direct frontend `mcpServer/tool/call` bypasses model-exposure
        // filtering). Mirrors upstream `call_tool` (connection_manager.rs:582-594).
        if let cfg = configByName[server], !cfg.toolAllowed(tool) {
            throw McpError.server(
                "tool '\(tool)' is disabled for MCP server '\(server)'")
        }
        return try await client.callTool(tool, argumentsJSON: argumentsJSON,
                                         elicitationHandler: elicitationHandler)
    }

    public func readResource(server: String, uri: String) async throws -> [String: JSONLite] {
        guard let client = clients[server] else {
            throw McpError.server("MCP server not loaded: \(server)")
        }
        return try await client.readResource(uri: uri)
    }

    /// Whether at least one MCP server is configured/loaded. Mirrors upstream's
    /// `params.mcp_tools.is_some()` gate that decides whether the resource tools
    /// are registered (`spec_plan.rs:385-389`).
    public func hasConfiguredServers() -> Bool { !clients.isEmpty }

    /// Single-page `resources/list` for one server, returning the raw result
    /// (`resources` array + optional `nextCursor`). Backs the
    /// `list_mcp_resources` tool's single-server branch.
    public func listResources(server: String, cursor: String?) async throws
        -> [String: JSONLite] {
        guard let client = clients[server] else {
            throw McpError.server("MCP server not loaded: \(server)")
        }
        return try await client.listResourcesPage(cursor: cursor)
    }

    /// Single-page `resources/templates/list` for one server. Backs the
    /// `list_mcp_resource_templates` tool's single-server branch.
    public func listResourceTemplates(server: String, cursor: String?) async throws
        -> [String: JSONLite] {
        guard let client = clients[server] else {
            throw McpError.server("MCP server not loaded: \(server)")
        }
        return try await client.listResourceTemplatesPage(cursor: cursor)
    }

    /// Aggregate `resources/list` across every ready server, fully paginated.
    /// Returns server name → resource objects (`JSONLite`). Mirrors upstream
    /// `McpConnectionManager::list_all_resources`.
    public func listAllResources() async -> [String: [JSONLite]] {
        var out: [String: [JSONLite]] = [:]
        for name in clients.keys.sorted() {
            guard let client = clients[name] else { continue }
            if let r = try? await Self.paginateAll(
                client, arrayKey: "resources",
                page: { try await client.listResourcesPage(cursor: $0) }) {
                out[name] = r
            }
        }
        return out
    }

    /// Aggregate `resources/templates/list` across every ready server, fully
    /// paginated. Mirrors upstream `list_all_resource_templates`.
    public func listAllResourceTemplates() async -> [String: [JSONLite]] {
        var out: [String: [JSONLite]] = [:]
        for name in clients.keys.sorted() {
            guard let client = clients[name] else { continue }
            if let r = try? await Self.paginateAll(
                client, arrayKey: "resourceTemplates",
                page: { try await client.listResourceTemplatesPage(cursor: $0) }) {
                out[name] = r
            }
        }
        return out
    }

    /// Walk a single-page list method page-by-page accumulating `arrayKey`,
    /// stopping when `nextCursor` is absent and erroring on a repeated cursor
    /// (matches the per-client `paginate` driver).
    private static func paginateAll(
        _ client: any McpClientProtocol, arrayKey: String,
        page: (String?) async throws -> [String: JSONLite]) async throws -> [JSONLite] {
        var collected: [JSONLite] = []
        var cursor: String?
        while true {
            let r = try await page(cursor)
            if case .array(let arr)? = r[arrayKey] { collected.append(contentsOf: arr) }
            guard case .string(let next)? = r["nextCursor"], !next.isEmpty else {
                return collected
            }
            if cursor == next {
                throw McpError.server("\(arrayKey) list returned duplicate cursor")
            }
            cursor = next
        }
    }

    public func stopAll() async {
        for (_, c) in clients { await c.stop() }
        clients.removeAll()
        statuses.removeAll()
    }
}
