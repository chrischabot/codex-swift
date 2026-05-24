import Foundation
import InfraPrimitives
import Tools
import ProtocolModel
import WireProtocol

public typealias McpElicitationHandler =
    @Sendable (_ requestId: RequestId, _ serverName: String, _ params: JSONValue) async -> JSONValue?

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
}

public struct McpCallResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool
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
    func listTools() async throws -> [McpToolSpec]
    func callTool(_ name: String, argumentsJSON: String,
                  elicitationHandler: McpElicitationHandler?) async throws -> McpCallResult
    func readResource(uri: String) async throws -> [String: JSONLite]
    func stop() async
}

public extension McpClientProtocol {
    func callTool(_ name: String, argumentsJSON: String) async throws -> McpCallResult {
        try await callTool(name, argumentsJSON: argumentsJSON, elicitationHandler: nil)
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
    private var nextId = 1
    private var readerThread: Thread?
    private var consumerTask: Task<Void, Never>?
    private var lineContinuation: AsyncStream<Data>.Continuation?
    private var initialized = false
    private let requestTimeout: Duration
    private let maxFrameBytes: Int
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
        p.environment = Self.buildStdioEnvironment(config: config)
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
            while true {
                let chunk = outHandle.availableData       // blocking — OK on a real thread
                if chunk.isEmpty { break }                // EOF / pipe closed
                buf.append(contentsOf: chunk)
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
                if scan == buf.count && buf.count > cap {
                    break
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
                activeElicitationHandlers.removeValue(forKey: id)
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
        if case .cancelled(_, let requestId, let reason) = notif,
           let rid = requestId,
           let cont = pending.removeValue(forKey: rid) {
            activeElicitationHandlers.removeValue(forKey: rid)
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
        for (_, c) in pending { c.resume(throwing: error) }
        pending.removeAll()
    }

    private func fireTimeout(_ id: Int) {
        timeouts.removeValue(forKey: id)
        activeElicitationHandlers.removeValue(forKey: id)
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
                activeElicitationHandlers.removeValue(forKey: id)
                timeouts.removeValue(forKey: id)?.cancel()
                cont.resume(throwing: error)
            }
        }
    }

    private func handleServerRequest(id: Int, object: [String: JSONLite]) async {
        guard case .string("elicitation/create")? = object["method"] else { return }
        let handler = activeElicitationHandlers.values.first
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

    private static func defaultElicitationResult(action: String) -> JSONValue {
        .object(["action": .string(action), "content": .null, "_meta": .null])
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
        _ = try await request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "CodexKit", "version": "0.1"],
        ])
        try writeMessage(["jsonrpc": "2.0", "method": "notifications/initialized"])
        initialized = true
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
            return McpToolSpec(name: name, description: desc, inputSchemaJSON: schema)
        }
    }

    public func callTool(_ name: String, argumentsJSON: String,
                         elicitationHandler: McpElicitationHandler? = nil) async throws
        -> McpCallResult {
        let argsObject: Any
        if let d = argumentsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: d) {
            argsObject = parsed
        } else {
            argsObject = [String: Any]()
        }
        let r = try await request("tools/call", ["name": name, "arguments": argsObject],
                                  elicitationHandler: elicitationHandler)
        var text = ""
        if let content = r["content"], case .array(let items) = content {
            for it in items {
                if case .object(let o) = it, case .string(let s)? = o["text"] { text += s }
            }
        }
        var isError = false
        if case .bool(let b)? = r["isError"] { isError = b }
        return McpCallResult(text: text, isError: isError)
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
    /// Remote-sourced entries are dropped — they are an upstream
    /// remote-executor concept and have no meaning locally.
    static func buildStdioEnvironment(config: McpServerConfig) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var out: [String: String] = [:]
        for name in defaultEnvAllowlist {
            if let v = parent[name] { out[name] = v }
        }
        if let envVars = config.envVars {
            for item in envVars where !item.isRemoteSource {
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
