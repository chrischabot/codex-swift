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
import Workflows
import IPC
import SessionWorkerCore
import Tokenizer
import Observability
import Auth
import Config
import MemoryExtension
import Mem0Extension
import Push
import GoogleWorkspace
import Media

/// #8 Media delivery (spawned worker): mirror codexd. Push a "ready"
/// notification for a finished asset through this worker's PushRouter. Returns
/// false → undelivered (the inline stub delivers synchronously so this is the
/// only delivery; an async provider would need the daemon poller / in-process
/// workers).
@Sendable func sessionMediaPushDeliver(_ task: MediaTask) async -> Bool {
    guard let router = PushRouterHolder.shared.current(),
          let target = task.deliverTo, let asset = task.assetPath else { return false }
    let result = await router.send(
        target: target,
        text: "media \(task.kind.rawValue) ready: \(asset)",
        idempotencyKey: "media-\(task.id)")
    return result.ok
}

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
        let endpoint: String = {
            if let base = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"], !base.isEmpty {
                var trimmed = base
                while trimmed.hasSuffix("/") { trimmed.removeLast() }
                return "\(trimmed)/responses"
            }
            return "https://api.openai.com/v1/responses"
        }()
        #if os(macOS)
        if ProcessInfo.processInfo.environment["CODEXKIT_RESPONSES_WEBSOCKET"] == "1" {
            let ws = WebSocketResponsesClient(
                apiKey: apiKey,
                limits: limits,
                options: .init(
                    prewarm: ProcessInfo.processInfo.environment["CODEXKIT_WS_PREWARM"] != "0",
                    explicitNoZstd: true),
                attestationProvider: attestationProvider)
            let http = URLSessionResponsesClient(apiKey: apiKey, endpoint: endpoint, limits: limits)
            return TransportFallbackModelClient(primary: ws, fallback: http, limits: limits)
        }
        return URLSessionResponsesClient(apiKey: apiKey, endpoint: endpoint, limits: limits)
        #else
        return OpenAIResponsesClient(apiKey: apiKey, endpoint: endpoint, limits: limits)
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

        // Honor the configured credential store mode
        // (`cli_auth_credentials_store`, upstream default File) instead of
        // unconditionally using the Keychain; keeps interop with the official
        // codex CLI on a shared CODEX_HOME.
        let authStoreMode = AuthCredentialsStoreMode.parse(
            ConfigLoader(codexHome: codexHome).load()
                .value("cli_auth_credentials_store")?.stringValue)
        let authManager = AuthManager(
            store: TokenStoreFactory.production(codexHome: codexHome, mode: authStoreMode),
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
        let mem0AuthProvider: Mem0SessionAuthProvider?
        let wikiAuthProvider: WikiMemoryAuthProvider?
        if useMock {
            mem0AuthProvider = nil
            wikiAuthProvider = nil
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
            mem0AuthProvider = .staticToken(apiKey)
            wikiAuthProvider = .staticToken(apiKey)
            model = openAIClient(apiKey: apiKey,
                                 limits: limits,
                                 attestationProvider: attestationProvider)
            log.info("codex-session using OpenAI Responses client from OPENAI_API_KEY")
        } else if let brokerAuth = brokerAuthClient(codexHome: codexHome),
                  let token = await brokerAuth.validAccessToken() {
            mem0AuthProvider = Mem0SessionAuthProvider(
                accessToken: { await brokerAuth.validAccessToken() },
                refreshToken: { await brokerAuth.refreshAccessToken() })
            wikiAuthProvider = WikiMemoryAuthProvider(
                accessToken: { await brokerAuth.validAccessToken() },
                refreshToken: { await brokerAuth.refreshAccessToken() })
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
            mem0AuthProvider = Mem0SessionAuthProvider(
                accessToken: { await authManager.validAccessToken() },
                refreshToken: { await authManager.refreshAccessToken() })
            wikiAuthProvider = WikiMemoryAuthProvider(
                accessToken: { await authManager.validAccessToken() },
                refreshToken: { await authManager.refreshAccessToken() })
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
            mem0AuthProvider = nil
            wikiAuthProvider = nil
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
            // Upstream `spec_plan.rs` gates the shell-tool family on the model's
            // `shell_type` (`ConfigShellToolType`): the model is offered exactly
            // one coherent shell interface. Resolve it from the bundled catalog
            // (every shipped model declares `shell_command`; falls back to
            // `.shellCommand` for unknown slugs).
            let shellType = ShellToolType.from(
                rawValue: ModelsCatalog.entry(for: c.model)?.shellType)
            await DefaultTools.register(on: router, sandbox: sb, limits: limits,
                                        shellType: shellType,
                                        // computer_use drives THIS host's desktop —
                                        // only meaningful for a local (non-remote)
                                        // session, never one bound to a remote
                                        // exec container.
                                        computerUseEnabled: c.remoteEnvironment == nil,
                                        spawnAgentOptions: spawnAgentOptions)
            // Dynamic workflows: enabled gate (the orchestrator is wired after
            // the engine exists, so progress can be pushed over its stream).
            let workflowsEnabled = WorkflowGating.isEnabled()
            if let remote = c.remoteEnvironment {
                await RemoteExecServerTools.register(
                    on: router,
                    websocketURL: remote.execServerUrl,
                    limits: limits)
            }
            let addonConfig = ConfigLoader(codexHome: codexHome, cwdOverride: c.cwd).load()
            let configuredMemoryProvider = addonConfig.value("memory")?.objectValue?["provider"]?.stringValue
            let memory = MemoryStore(codexHome: codexHome)
            // Upstream parity (H-32 / P4.8): wire the model client into the
            // memory store so end-of-turn consolidation runs the Stage-1
            // structured-output pipeline (raw_memory / rollout_summary /
            // rollout_slug) instead of local truncation. On any error we fall
            // back to the deterministic local summary.
            await memory.setModelClient(model)
            if shouldRegisterCoreMemoryTools(config: addonConfig) {
                await router.register(MemoryTool(store: memory))
                await router.register(MemoriesListTool(store: memory))
                await router.register(MemoriesReadTool(store: memory))
                await router.register(MemoriesSearchTool(store: memory))
            }
            let mcp = McpManager()
            // Upstream parity (codex-mcp/src/elicitation.rs::make_sender):
            // apply the elicitation policy BEFORE surfacing a prompt. Under
            // approval policy `Never` (or Granular with MCP elicitations off)
            // we auto-decline; schemaless confirm/approval form elicitations
            // are auto-accepted when the permission prompt is auto-approved
            // (Never + full-disk-write/danger-full-access). Only otherwise is
            // the request forwarded to the frontend. `auto_deny` has no host
            // toggle here, so it is always false.
            let elicitationAutoApproved =
                c.approvalPolicy == .never && c.sandboxMode == .dangerFullAccess
            let mcpElicitationHandler: McpElicitationHandler = { requestId, serverName, params in
                switch McpElicitationPolicy.decide(approvalPolicy: c.approvalPolicy,
                                                   autoDeny: false,
                                                   autoApproved: elicitationAutoApproved,
                                                   params: params) {
                case .decline:
                    return .object(["action": .string("decline")])
                case .accept:
                    return .object(["action": .string("accept"),
                                    "content": .object([:])])
                case .prompt:
                    break
                }
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
            // Upstream parity (mcp_tool_call.rs::sanitize_mcp_tool_result_for_model):
            // forward MCP `image` content blocks to the model only when it
            // accepts image input (`models.json` `input_modalities` ∋ image).
            let modelSupportsImageInput =
                ModelsCatalog.entry(for: c.model)?.supportsImageInput ?? false
            // Upstream `augment_mcp_tool_request_meta_with_sandbox_state`
            // (`core/src/mcp_tool_call.rs:705-751`): build the turn's
            // `SandboxState` so MCP servers that advertised the
            // `codex/sandbox-state-meta` capability receive it in every
            // `tools/call` request's `_meta`. The port does not surface a
            // `permission_profile` or `codex_linux_sandbox_exe` at this layer,
            // so those are omitted/null (matching the serde skip / null rules).
            let mcpWritableRoots = c.writableRoots.isEmpty ? [c.cwd] : c.writableRoots
            let mcpSandboxState = SandboxStateMeta(
                permissionProfile: nil,
                sandboxPolicy: SandboxStateMeta.policy(
                    mode: c.sandboxMode,
                    writableRoots: mcpWritableRoots,
                    networkAccess: c.networkAccess || c.sandboxMode == .dangerFullAccess),
                codexLinuxSandboxExe: nil,
                sandboxCwd: c.cwd,
                useLegacyLandlock: false)
            await mcp.startAll(McpManager.loadConfigs(codexHome: codexHome),
                               router: router,
                               oauthStore: mcpOAuthStore,
                               elicitationHandler: mcpElicitationHandler,
                               supportsImageInput: modelSupportsImageInput,
                               threadId: c.threadId.raw,
                               sandboxState: mcpSandboxState)
            let skills = SkillsDiscovery()
                .discover(codexHome: codexHome, cwds: [c.cwd])
                .map { PromptComposer.SkillInjection(
                    name: $0.name, description: $0.description, path: $0.path,
                    scopeRank: $0.scope.promptScopeRank) }
            let connectors = ConnectorsDiscovery()
                .discover(codexHome: codexHome)
                .map { PromptComposer.ConnectorInjection(
                    id: $0.id, name: $0.name, description: $0.description) }
            // Upstream `auto_compact_token_limit()` mins the model's 90%
            // context-window value with any user-configured
            // `model_auto_compact_token_limit` (openai_models.rs:322).
            let autoCompactOverride = ConfigLoader(codexHome: codexHome, cwdOverride: c.cwd)
                .load().modelAutoCompactTokenLimit
            let autoCompact = ModelCatalog.default.autoCompactLimit(
                for: c.model, configOverride: autoCompactOverride)
            let approved = ApprovedRuleStore(codexHome: codexHome)
            // Extension spine (ARCHITECTURE.md §5.4 / Phase 0): build this
            // session's registry from enabled `[extensions]` manifests plus the
            // selected memory provider. General manifests are feature-gated;
            // memory can install independently because mem0 is the default
            // personal-memory path.
            // Phase 1 (ARCHITECTURE.md §7.1): the memory slot candidates.
            // mem0 is the default personal-memory provider when
            // `[memory].provider` is unset; "core", "wiki", and "none" remain
            // explicit choices. Recall (fenced) + capture wire into the
            // registry; the legacy core memory *tools* are exposed only for
            // explicit core/legacy-tools configurations.
            //
            // The vector "Memory Wiki" candidate is built ONLY when
            // `[memory].provider == "wiki"` — constructing it opens a SQLite
            // handle on the wiki DB, which we must not do for sessions that
            // never select it. `makeWikiMemoryProvider` reuses THIS session's
            // `ModelClient` for the wiki's own text inference (D1) and returns
            // nil if the DB can't be opened, so a configured-but-unavailable
            // wiki disables recall rather than crashing the session.
            var memoryCandidates: [any MemoryProvider] = [CoreMemoriesProvider(store: memory)]
            if (configuredMemoryProvider == nil || configuredMemoryProvider == "mem0"),
               let mem0 = makeMem0MemoryProvider(config: addonConfig,
                                                 authProvider: mem0AuthProvider) {
                memoryCandidates.append(mem0)
            }
            if configuredMemoryProvider == "wiki",
               let wiki = makeWikiMemoryProvider(config: addonConfig,
                                                 modelClient: model,
                                                 authProvider: wikiAuthProvider) {
                memoryCandidates.append(wiki)
            }
            let memoryProvider = selectMemoryProvider(
                config: addonConfig, candidates: memoryCandidates)
            // Register the selected provider's tools (core's are [] — the core
            // memory tools are registered above; mem0 contributes mem0_search /
            // mem0_add; wiki contributes its MemoryToolset in compatibility
            // mode). Memory is no longer gated by the general `extensions`
            // feature because mem0 is the default personal-memory product path.
            for t in (memoryProvider?.tools() ?? []) { await router.register(t) }
            // ADDONS Phase 0 #2: addon tool-pack seam (mirrors codexd). #4
            // (Google Workspace), #7 (Push), #8 (Media) append their packs here;
            // each is gated by `[features].<pack.id>` and self-prunes when
            // unconfigured.
            var toolPacks: [any ToolPack] = []
            if addonConfig.isFeatureEnabled("push") {
                let pushRouter = await PushRouter.makeDefault(directory: codexHome + "/push")
                // Publish on the holder so the #8 media deliver closure (and any
                // owner-path push) reach this worker's router.
                PushRouterHolder.shared.set(pushRouter)
                toolPacks.append(PushToolPack(router: pushRouter))
            }
            if let gpack = GoogleWiring.toolPack(
                addonConfig: addonConfig, codexHome: codexHome,
                env: ProcessInfo.processInfo.environment) {
                toolPacks.append(gpack)
            }
            // #8 Media: the spawned worker holds its OWN ledger (the daemon poller
            // lives in another process and can't reach it — fine for the inline
            // stub, which delivers synchronously inside submit). Build once per
            // process; deny-default off when [features].media is unset.
            // A spawned worker has NO daemon poller in-process, so async
            // providers self-prune here (inProcessWorkers: false); the inline
            // stub still works (synchronous delivery).
            if MediaLedgerHolder.shared.current() == nil,
               let ledger = await MediaWiring.makeLedger(
                   addonConfig: addonConfig, codexHome: codexHome,
                   env: ProcessInfo.processInfo.environment,
                   inProcessWorkers: false, deliver: sessionMediaPushDeliver) {
                MediaLedgerHolder.shared.set(ledger)
            }
            toolPacks.append(MediaToolPack(ledger: MediaLedgerHolder.shared.current()))
            await ToolPackRegistry(toolPacks).install(on: router, config: addonConfig)
            let extRegistry = installAddons(
                config: addonConfig, sessionConfig: c, memoryProvider: memoryProvider)
            let engine = SessionEngine(config: c, model: model, store: store,
                                       router: router, limits: limits,
                                       autoCompactTokens: autoCompact,
                                       autoCompactConfigOverride: autoCompactOverride,
                                       recomputeAutoCompactPerTurn: true,
                                       memoryStore: memory, sandbox: sb,
                                       skills: skills, connectors: connectors,
                                       approvedStore: approved, execPolicy: execPolicy,
                                       workflowsEnabled: workflowsEnabled,
                                       hooks: HookEngine.load(
                                        codexHome: codexHome, cwd: c.cwd,
                                        legacyNotifyArgv: c.notify),
                                       registry: extRegistry)
            // Dynamic workflows: install the orchestrator on the shared bus.
            // Subagents get a fresh default tool router (plus any schema
            // `final_answer` tool); progress is pushed (16ms-debounced) over
            // this session's already-relayed event stream.
            if workflowsEnabled {
                let wfRunner = WorkflowAgentRunner(
                    store: store, limits: limits, model: model,
                    routerFactory: { subCwd, extra in
                        let r = ToolRouter(limits: limits)
                        await DefaultTools.register(on: r, sandbox: sb, limits: limits,
                                                    shellType: shellType)
                        for t in extra { await r.register(t) }
                        return r
                    })
                let orch = WorkflowOrchestrator(
                    store: WorkflowStore(codexHome: codexHome),
                    codexHome: codexHome, runner: wfRunner, defaultModel: c.model,
                    progressSink: { n in Task { await engine.injectNotification(n) } })
                await orch.installOnBus()
                WorkflowHolder.shared.set(orch)   // retain for process lifetime
            }
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
        // Finding 4 (v12): classify off the authoritative `mode` discriminator
        // (rmcp tags `CreateElicitationRequestParams` by `mode` = "form"/"url").
        // Finding 3 (v12): scrub the transport-level `progressToken` out of
        // `_meta` before surfacing to the frontend (restore_context_meta). Both
        // live in McpElicitationPolicy so the policy + surfaced-event paths share
        // one classification/scrub implementation.
        return McpElicitationParams(
            threadId: threadId,
            turnId: nil,
            serverName: serverName,
            mode: McpElicitationPolicy.classifyMode(params: params),
            meta: McpElicitationPolicy.scrubMeta(params["_meta"]),
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
                // Finding 2 (v7): surface the full content array,
                // structuredContent and result `_meta` instead of collapsing to
                // a single text block (parity with upstream call_tool result).
                let content: JSONValue
                if result.content.isEmpty {
                    content = .array([
                        .object(["type": .string("text"), "text": .string(result.text)])
                    ])
                } else {
                    content = .array(result.content.map(Self.jsonLiteToValue(_:)))
                }
                return WorkerMcpResponse(requestId: request.requestId, result: .object([
                    "content": content,
                    "structuredContent": result.structuredContent.map(Self.jsonLiteToValue(_:)) ?? .null,
                    "isError": .bool(result.isError),
                    "_meta": result.meta.map(Self.jsonLiteToValue(_:)) ?? .null,
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
