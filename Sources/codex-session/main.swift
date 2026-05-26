import Foundation
import InfraPrimitives
import WireProtocol
import ProtocolModel
import Persistence
import ModelClient
import Tools
import Sandbox
import Prompts
import MCP
import Skills
import Connectors
import HarnessCore
import IPC
import SessionWorkerCore
import Tokenizer
import Observability
import Auth

/// Fails clearly until the production HTTP/WS Responses client is wired
/// (parity with codexd). `CODEXKIT_MOCK=1` forces the deterministic mock.
struct SessionNotConfiguredModel: ModelClient {
    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        throw ModelError("model backend not configured (set CODEXKIT_MOCK=1 or "
                         + "OPENAI_API_KEY)", retryable: false)
    }
}

private struct WorkerMainError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct SessionWorkerMain {
    private static func openAIClient(apiKey: String,
                                     limits: Limits,
                                     attestationProvider: (@Sendable (String) async -> String?)? = nil)
    -> any ModelClient {
        #if os(macOS)
        if ProcessInfo.processInfo.environment["CODEXKIT_RESPONSES_WEBSOCKET"] == "1" {
            let ws = WebSocketResponsesClient(
                apiKey: apiKey,
                limits: limits,
                options: .init(
                    prewarm: ProcessInfo.processInfo.environment["CODEXKIT_WS_PREWARM"] != "0",
                    explicitNoZstd: true),
                attestationProvider: attestationProvider)
            let http = URLSessionResponsesClient(apiKey: apiKey, limits: limits)
            return TransportFallbackModelClient(primary: ws, fallback: http, limits: limits)
        }
        return URLSessionResponsesClient(apiKey: apiKey, limits: limits)
        #else
        return OpenAIResponsesClient(apiKey: apiKey, limits: limits)
        #endif
    }

    private static func brokerAuthClient(codexHome: String) -> BrokerAuthClient? {
        let env = ProcessInfo.processInfo.environment
        let raw = env["CODEXKIT_AUTH_BROKER"]
            ?? env["CODEX_BROKER_LISTEN"]
            ?? "unix://\(BrokerAuthClient.defaultSocketPath(codexHome: codexHome))"
        guard raw.hasPrefix("unix://") else { return nil }
        let path = String(raw.dropFirst("unix://".count))
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return BrokerAuthClient(socketPath: path)
    }

    /// Parse `--profile-v2 NAME` / `--profile-v2=NAME` from argv (matches
    /// upstream codex CLI). When present we surface it via the
    /// `CODEX_PROFILE_V2` environment variable so any in-process
    /// `ConfigLoader.load(env:)` call picks it up the same way codexd does.
    /// Returns the resolved name (or nil).
    private static func profileV2Flag() -> String? {
        let args = CommandLine.arguments
        for i in 1..<args.count {
            let arg = args[i]
            if arg == "--profile-v2", i + 1 < args.count { return args[i + 1] }
            if arg.hasPrefix("--profile-v2=") {
                return String(arg.dropFirst("--profile-v2=".count))
            }
        }
        return nil
    }

    static func main() async {
        let log = Log(category: "codex-session")
        if let pv2 = profileV2Flag() { setenv("CODEX_PROFILE_V2", pv2, 1) }
        let env = ProcessInfo.processInfo.environment

        guard let fdStr = env["CODEXKIT_IPC_FD"], let fd = Int32(fdStr) else {
            log.info("codex-session is supervisor-driven; no CODEXKIT_IPC_FD. Exiting.")
            return
        }

        let codexHome = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        // Apply optional `$CODEX_HOME/config.toml` overrides (F1).
        let limits = Limits.loadingOverrides(codexHome: codexHome).clamped()
        guard let store = try? ThreadStore(codexHome: codexHome, limits: limits) else {
            log.error("codex-session: failed to open ThreadStore at \(codexHome)")
            return
        }

        let link = WorkerLink.make()
        let serverRequestBroker = WorkerServerRequestBroker()
        let attestationBroker = WorkerAttestationBroker()
        let attestationProvider: @Sendable (String) async -> String? = { threadId in
            await attestationBroker.header(for: threadId, link: link)
        }

        let authManager = AuthManager(
            store: TokenStoreFactory.production(codexHome: codexHome),
            externalTokenRefresh: { previousAccountId in
                let request = ServerRequest.chatgptAuthTokensRefresh(
                    .string("auth_refresh_\(UUID().uuidString.lowercased())"),
                    ChatgptAuthTokensRefreshParams(
                        reason: "unauthorized",
                        previousAccountId: previousAccountId))
                let response = await serverRequestBroker.request(request, link: link)
                guard !response.failed, let result = response.result,
                      let accessToken = result["accessToken"]?.stringValue,
                      !accessToken.isEmpty,
                      let accountId = result["chatgptAccountId"]?.stringValue,
                      !accountId.isEmpty else {
                    return nil
                }
                return AuthTokens(accessToken: accessToken,
                                  refreshToken: nil,
                                  tokenType: "BearerExternal",
                                  expiresAtUnix: 4_102_444_800,
                                  accountId: accountId)
            },
            apiKeyExchanger: CurlAPIKeyExchanger(),
            revoker: CurlTokenRevoker(),
            env: ProcessInfo.processInfo.environment)
        let useMock = env["CODEXKIT_MOCK"] == "1"
        let apiKey = env["OPENAI_API_KEY"]
        let model: any ModelClient
        if useMock {
            let mockText = env["CODEXKIT_MOCK_TEXT"] ?? "Hello from codex-session (mock)."
            if env["CODEXKIT_MOCK_SCENARIO"] == "tool-loop-compact" {
                model = MockModelClient(MockScenario.toolLoopCompactionSequence(repetitions: 256))
            } else if let slowRaw = env["CODEXKIT_MOCK_SLOW_MS"],
               let slowMs = Int(slowRaw), slowMs > 0 {
                model = MockModelClient(repeating: MockScenario([
                    .created,
                    .slowMillis(slowMs),
                    .delta(itemId: "msg_1", mockText),
                    .agentDone(itemId: "msg_1", mockText),
                    .completeEndTurn(responseId: "resp_1", tokens: 12),
                ]), times: 1024)
            } else {
                model = MockModelClient(repeating: .hello(mockText), times: 1024)
            }
        } else if let apiKey, !apiKey.isEmpty {
            model = openAIClient(apiKey: apiKey,
                                 limits: limits,
                                 attestationProvider: attestationProvider)
            log.info("codex-session using OpenAI Responses client from OPENAI_API_KEY")
        } else if let brokerAuth = brokerAuthClient(codexHome: codexHome),
                  let token = await brokerAuth.validAccessToken() {
            model = AuthRefreshingModelClient(
                initial: openAIClient(apiKey: token,
                                      limits: limits,
                                      attestationProvider: attestationProvider),
                refreshToken: { await brokerAuth.refreshAccessToken() },
                makeClient: { openAIClient(apiKey: $0,
                                           limits: limits,
                                           attestationProvider: attestationProvider) })
            log.info("codex-session using OpenAI Responses client from broker auth with 401 refresh")
        } else if let token = await authManager.validAccessToken() {
            model = AuthRefreshingModelClient(
                initial: openAIClient(apiKey: token,
                                      limits: limits,
                                      attestationProvider: attestationProvider),
                refreshToken: { await authManager.refreshAccessToken() },
                makeClient: { openAIClient(apiKey: $0,
                                           limits: limits,
                                           attestationProvider: attestationProvider) })
            log.info("codex-session using OpenAI Responses client from stored auth with 401 refresh")
        } else {
            model = SessionNotConfiguredModel()
        }

        ProcessIPC.runWorkerBridge(link: link, fd: fd)

        let runtime = WorkerRuntime(link: link,
                                    attestationBroker: attestationBroker,
                                    serverRequestBroker: serverRequestBroker,
                                    makeComponents: { c in
            let execPolicy = ExecPolicy.load(codexHome: codexHome)
            // Honor the SessionConfig the client passed at thread/start /
            // turn/start. Previously this hardcoded `.workspaceWrite` and
            // [c.cwd], which silently downgraded `danger-full-access`
            // sessions and broke any client supplying additional writable
            // roots or asking for network egress.
            let sb = SessionSandboxBuilder.make(config: c, execPolicy: execPolicy)
            let router = ToolRouter(limits: limits)
            // Upstream parity (`ToolsConfig::agent_type_description`): when the
            // SessionConfig advertises an agent-role rubric, propagate it into
            // the `spawn_agent` tool's `agent_type` JSON-schema description so
            // the model sees the host-supplied options. nil → tool keeps its
            // built-in default placeholder.
            var spawnAgentOptions = SpawnAgentToolOptions()
            if let agentTypeDesc = c.agentTypeDescription, !agentTypeDesc.isEmpty {
                spawnAgentOptions.agentTypeDescription = agentTypeDesc
            }
            await DefaultTools.register(on: router, sandbox: sb, limits: limits,
                                        spawnAgentOptions: spawnAgentOptions)
            if let remote = c.remoteEnvironment {
                await RemoteExecServerTools.register(
                    on: router,
                    websocketURL: remote.execServerUrl,
                    limits: limits)
            }
            let memory = MemoryStore(codexHome: codexHome)
            // Upstream parity (H-32 / P4.8): wire the model client into the
            // memory store so end-of-turn consolidation runs the Stage-1
            // structured-output pipeline (raw_memory / rollout_summary /
            // rollout_slug) instead of local truncation. On any error we fall
            // back to the deterministic local summary.
            await memory.setModelClient(model)
            await router.register(MemoryTool(store: memory))
            // Upstream parity (H-32 / P4.8): three namespaced memory tools.
            // The legacy single `memory` tool is kept registered for back-
            // compat; new sessions and the model should prefer these.
            await router.register(MemoriesListTool(store: memory))
            await router.register(MemoriesReadTool(store: memory))
            await router.register(MemoriesSearchTool(store: memory))
            let mcp = McpManager()
            let mcpElicitationHandler: McpElicitationHandler = { requestId, serverName, params in
                let request = ServerRequest.mcpElicitation(
                    requestId,
                    Self.mcpElicitationParams(threadId: c.threadId,
                                              serverName: serverName,
                                              params: params))
                let response = await serverRequestBroker.request(request, link: link)
                guard !response.failed else { return nil }
                return response.result
            }
            // F8 (MEDIUM): load persisted OAuth tokens from `mcp login` so
            // OAuth-protected HTTP MCP servers can re-attach without re-
            // authenticating every session. Was hardcoded `nil` before P7.3.
            let mcpOAuthStore = McpOAuthStore(codexHome: codexHome)
            await mcp.startAll(McpManager.loadConfigs(codexHome: codexHome),
                               router: router,
                               oauthStore: mcpOAuthStore,
                               elicitationHandler: mcpElicitationHandler)
            let skills = SkillsDiscovery()
                .discover(codexHome: codexHome, cwds: [c.cwd])
                .map { PromptComposer.SkillInjection(
                    name: $0.name, description: $0.description, path: $0.path) }
            let connectors = ConnectorsDiscovery()
                .discover(codexHome: codexHome)
                .map { PromptComposer.ConnectorInjection(
                    id: $0.id, name: $0.name, description: $0.description) }
            let autoCompact = ModelCatalog.default.autoCompactLimit(for: c.model)
            let approved = ApprovedRuleStore(codexHome: codexHome)
            let engine = SessionEngine(config: c, model: model, store: store,
                                       router: router, limits: limits,
                                       autoCompactTokens: autoCompact,
                                       memoryStore: memory, sandbox: sb,
                                       skills: skills, connectors: connectors,
                                       approvedStore: approved, execPolicy: execPolicy,
                                       hooks: HookEngine.load(
                                        codexHome: codexHome, cwd: c.cwd,
                                        legacyNotifyArgv: c.notify))
            let directMcp: WorkerMcpHandler = { request in
                await Self.handleDirectMcp(request,
                                           manager: mcp,
                                           elicitationHandler: mcpElicitationHandler)
            }
            return SessionRuntimeComponents(engine: engine, mcpHandler: directMcp)
        })

        log.info("codex-session worker ready (fd=\(fd), mock=\(useMock))")
        FileHandle.standardError.write(Data("codex-session worker ready\n".utf8))
        await runtime.run()
        log.info("codex-session worker finished; exiting")
    }

    private static func mcpElicitationParams(threadId: ThreadId, serverName: String,
                                             params: JSONValue) -> McpElicitationParams {
        let mode = params["requestedSchema"] == nil ? "url" : "form"
        return McpElicitationParams(
            threadId: threadId,
            turnId: nil,
            serverName: serverName,
            mode: mode,
            meta: params["_meta"] ?? .null,
            message: params["message"]?.stringValue ?? "",
            requestedSchema: params["requestedSchema"],
            url: params["url"]?.stringValue,
            elicitationId: params["elicitationId"]?.stringValue)
    }

    private static func handleDirectMcp(_ request: WorkerMcpRequest,
                                        manager: McpManager,
                                        elicitationHandler: McpElicitationHandler?) async
        -> WorkerMcpResponse {
        do {
            switch request.kind {
            case .callTool:
                guard let tool = request.tool, let argumentsJSON = request.argumentsJSON else {
                    throw WorkerMainError("worker MCP tool call missing tool or arguments")
                }
                let result = try await manager.callTool(server: request.server,
                                                        tool: tool,
                                                        argumentsJSON: argumentsJSON,
                                                        elicitationHandler: elicitationHandler)
                return WorkerMcpResponse(requestId: request.requestId, result: .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(result.text)])
                    ]),
                    "structuredContent": .null,
                    "isError": .bool(result.isError),
                    "_meta": .null,
                ]))
            case .readResource:
                guard let uri = request.uri else {
                    throw WorkerMainError("worker MCP resource read missing uri")
                }
                let result = try await manager.readResource(server: request.server, uri: uri)
                return WorkerMcpResponse(
                    requestId: request.requestId,
                    result: .object(result.mapValues(Self.jsonLiteToValue(_:))))
            }
        } catch {
            return WorkerMcpResponse(requestId: request.requestId,
                                     result: nil,
                                     error: error.localizedDescription)
        }
    }

    private static func jsonLiteToValue(_ value: JSONLite) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            if n.isFinite, n.rounded() == n,
               n >= -9_223_372_036_854_775_808.0,
               n <  9_223_372_036_854_775_808.0 {
                return .int(Int64(n))
            }
            return .double(n)
        case .string(let s):
            return .string(s)
        case .array(let a):
            return .array(a.map(jsonLiteToValue(_:)))
        case .object(let o):
            return .object(o.mapValues(jsonLiteToValue(_:)))
        }
    }
}
