import Foundation
import Config
import InfraPrimitives
import Tools

/// Server-namespaced proxy that lets the model invoke an MCP tool through the
/// harness ToolRouter (Codex `mcp__<server>__<tool>` exposure). Parallel-safe:
/// MCP calls do not mutate the local workspace directly.
public struct McpToolProxy: Tool {
    public let name: String
    public let parallelSafe = true
    public let toolDescription: String
    public let jsonSchema: String
    private let server: String
    private let tool: String
    private let client: any McpClientProtocol
    private let elicitationHandler: McpElicitationHandler?
    public init(server: String, tool: String, client: any McpClientProtocol,
                description: String = "",
                elicitationHandler: McpElicitationHandler? = nil,
                schemaJSON: String = #"{"type":"object","additionalProperties":true}"#) {
        self.server = server
        self.tool = tool
        self.client = client
        self.elicitationHandler = elicitationHandler
        self.name = "mcp__\(server)__\(tool)"
        self.toolDescription = description
        self.jsonSchema = schemaJSON.isEmpty
            ? #"{"type":"object","additionalProperties":true}"# : schemaJSON
    }
    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        do {
            let r = try await client.callTool(tool, argumentsJSON: call.argumentsJSON,
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
        for cfg in configs {
            if statuses[cfg.name]?.state == "ready", clients[cfg.name] != nil {
                continue
            }
            let client: any McpClientProtocol = cfg.isHTTP
                ? McpHttpClient(cfg, oauthStore: oauthStore)
                : McpClient(cfg)
            clients[cfg.name] = client
            statuses[cfg.name] = McpServerStatus(name: cfg.name, state: "starting",
                                                 tools: [], error: nil)
            do {
                try await client.start()
                try await client.initialize()
                let rawTools = try await client.listTools()
                // Upstream parity: apply enabled_tools (allowlist) +
                // disabled_tools (denylist) before exposing to the model.
                let tools = cfg.filterTools(rawTools)
                for t in tools {
                    await router.register(McpToolProxy(server: cfg.name, tool: t.name,
                                                       client: client,
                                                       description: t.description,
                                                       elicitationHandler: elicitationHandler,
                                                       schemaJSON: t.inputSchemaJSON))
                }
                statuses[cfg.name] = McpServerStatus(name: cfg.name, state: "ready",
                                                     tools: tools, error: nil)
            } catch {
                statuses[cfg.name] = McpServerStatus(name: cfg.name, state: "failed",
                                                     tools: [], error: "\(error)")
            }
        }
    }

    public func statusList() -> [McpServerStatus] {
        statuses.values.sorted { $0.name < $1.name }
    }

    public func callTool(server: String, tool: String, argumentsJSON: String,
                         elicitationHandler: McpElicitationHandler? = nil) async throws
        -> McpCallResult {
        guard let client = clients[server] else {
            throw McpError.server("MCP server not loaded: \(server)")
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

    public func stopAll() async {
        for (_, c) in clients { await c.stop() }
        clients.removeAll()
        statuses.removeAll()
    }
}
