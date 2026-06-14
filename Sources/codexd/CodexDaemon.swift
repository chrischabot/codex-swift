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
import Supervisor
import WikiQueryKit
import Transport
import Observability
import Auth
import Tokenizer
import Config
import MemoryExtension
import Mem0Extension
import WebGateway
import Push
import GoogleWorkspace
import Media
import Cron
import Channels
import Gmail

/// #8 Media delivery (codexd): push a "ready" notification for a finished asset
/// through the daemon-scope PushRouter (#7). Returns false → the ledger marks it
/// undelivered and the poller retries (bounded). Local-path delivery for the
/// MVP; a signed MediaToken URL needs the gateway signer shared — see
/// MediaWiring (documented follow-on). Namespaced (not a top-level func) so the
/// codexd module stays `@main`-compatible.
enum MediaGlue {
    @Sendable static func push(_ task: MediaTask) async -> Bool {
        guard let router = PushRouterHolder.shared.current(),
              let target = task.deliverTo, let asset = task.assetPath else { return false }
        // #4: prefer a stable, signed `/media/:token` URL the recipient can open
        // in a browser; fall back to the local asset path when there's no gateway
        // signer published, or the asset resolves outside the gateway media root
        // (the holder enforces the contained-under-root check). Deny-default: with
        // no published signer (persist off / gateway not started) this is exactly
        // the previous behavior — the local path.
        let delivered = MediaTokenSignerHolder.shared.signedURL(forAssetPath: asset) ?? asset
        let result = await router.send(
            target: target,
            text: "media \(task.kind.rawValue) ready: \(delivered)",
            idempotencyKey: "media-\(task.id)")
        return result.ok
    }
}

/// #1/#2 Channels composition root (Telegram MVP). Deny-default behind
/// `[channels.telegram].enabled`. The TurnRunner bakes the non-owner lockdown
/// into SessionConfig (ChannelGlue.channelSessionConfig) so the owner-gate is
/// enforced in BOTH in-process and spawned worker modes.
enum ChannelsGlue {
    private static func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// Build ONE ChannelManager over a shared host + thread store, then register
    /// every ENABLED channel (Telegram, Gmail, …). The thread store keys by
    /// channelId/conversationId (injective), so distinct transports never collide
    /// on one shared store. Deny-default: returns nil (nothing started) when no
    /// channel is enabled/resolvable — byte-identical to a daemon without channels.
    static func bootstrap(config: Config, codexHome: String, supervisor: SessionSupervisor,
                          defaultModel: String, env: [String: String]) async -> ChannelManager? {
        let runner = ChannelGlue.makeTurnRunner(
            supervisor: supervisor,
            defaultCwd: FileManager.default.currentDirectoryPath,
            defaultModel: defaultModel)
        let threadStore = ChannelThreadStore(
            path: codexHome + "/channels/threads.json",
            mint: { ThreadId.generate().raw })
        let host = SupervisorChannelHost(threadStore: threadStore, runTurn: runner)
        let manager = ChannelManager(host: host)
        var registered = 0

        // --- Telegram ---
        if let obj = config.value("channels.telegram")?.objectValue, obj["enabled"]?.boolValue == true {
            var owners: [String] = []
            if case .array(let a)? = obj["owners"] { owners = a.compactMap { $0.stringValue } }
            if let tg = TelegramConfig.load(
                enabled: true, botTokenEnvVar: obj["bot_token_env"]?.stringValue, owners: owners,
                pollTimeoutSeconds: obj["poll_timeout_seconds"]?.intValue.map(Int.init),
                apiBase: obj["api_base"]?.stringValue, env: env) {
                await manager.register(TelegramChannel(config: tg))
                registered += 1
                log("codexd channels: telegram started (\(owners.count) owner(s))")
                if owners.isEmpty { log("codexd channels: telegram has NO owners — every sender is NON-OWNER (read-only, locked-down)") }
            } else {
                log("codexd channels: telegram enabled but no bot token resolved; skipping")
            }
        }

        // --- Gmail (#5) — rides the SAME connected Google account as google_api ---
        if let obj = config.value("channels.gmail")?.objectValue, obj["enabled"]?.boolValue == true {
            var ownerEmails: [String] = []
            if case .array(let a)? = obj["owner_emails"] { ownerEmails = a.compactMap { $0.stringValue } }
            if let gm = GmailConfig.load(
                enabled: true, ownerEmails: ownerEmails,
                fromAddress: obj["from_address"]?.stringValue,
                pollMs: obj["poll_ms"]?.intValue.map(Int.init)),
               let client = GoogleWiring.makeAPIClient(addonConfig: config, codexHome: codexHome, env: env) {
                await manager.register(GmailChannel(
                    api: client, ownerEmails: Set(gm.ownerEmails),
                    fromAddress: gm.fromAddress, pollMs: gm.pollMs))
                registered += 1
                log("codexd channels: gmail started (\(gm.ownerEmails.count) owner(s)); needs gmail.modify scope on the connected account")
                if gm.ownerEmails.isEmpty { log("codexd channels: gmail has NO owner_emails — every sender is NON-OWNER (read-only, locked-down)") }
            } else {
                log("codexd channels: gmail enabled but no [connectors.google] connection resolved; run `codexd google-connect`. skipping")
            }
        }

        guard registered > 0 else { return nil }   // deny-default
        ChannelManagerHolder.shared.set(manager)
        await manager.startAll()
        return manager
    }
}

/// Fails clearly when no model credentials are configured. Set
/// CODEXKIT_MOCK=1 to run the full pipeline against the deterministic mock.
struct NotConfiguredModelClient: ModelClient {
    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        throw ModelError("model backend not configured (set CODEXKIT_MOCK=1 for the mock; "
                         + "or set OPENAI_API_KEY for the live Responses client)",
                         retryable: false)
    }
}

@main
struct CodexDaemon {
    private static func listenURL() -> String {
        let args = CommandLine.arguments
        for i in 1..<args.count {
            let arg = args[i]
            if arg == "--listen", i + 1 < args.count { return args[i + 1] }
            if arg.hasPrefix("--listen=") {
                return String(arg.dropFirst("--listen=".count))
            }
        }
        return ProcessInfo.processInfo.environment["CODEXKIT_LISTEN"]
            ?? AppServerTransport.defaultListenURL
    }

    /// Parse `--profile-v2 NAME` / `--profile-v2=NAME` from argv (matches
    /// upstream codex CLI). Returns `nil` when the flag is absent, in which
    /// case the loader falls back to `CODEX_PROFILE_V2` env.
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

    private static func wsPort(from bind: String) -> UInt16? {
        guard let colon = bind.lastIndex(of: ":"),
              let port = UInt16(bind[bind.index(after: colon)...]) else {
            return nil
        }
        let host = String(bind[..<colon])
        guard host == "127.0.0.1" || host == "localhost" || host == "[::1]" else {
            return nil
        }
        return port
    }

    /// Parse `--listen-web[=HOST:PORT]` / `CODEXKIT_LISTEN_WEB` into a gateway
    /// config, or nil when the web gateway is not requested. Defaults to
    /// loopback 127.0.0.1:8443. `wwwRoot`/cert/key are overridable via env.
    private static func webGatewayConfig(codexHome: String, config: Config) -> WebGatewayConfig? {
        let args = CommandLine.arguments
        var present = false
        var raw: String?
        for i in 1..<args.count {
            let a = args[i]
            if a == "--listen-web" {
                present = true
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { raw = args[i + 1] }
            } else if a.hasPrefix("--listen-web=") {
                present = true
                raw = String(a.dropFirst("--listen-web=".count))
            }
        }
        let env = ProcessInfo.processInfo.environment
        if !present, let e = env["CODEXKIT_LISTEN_WEB"], !e.isEmpty { present = true; raw = e }
        guard present else { return nil }

        var host = "127.0.0.1"
        var port = 8443
        if let raw, !raw.isEmpty {
            if let colon = raw.lastIndex(of: ":"), let p = Int(raw[raw.index(after: colon)...]) {
                let h = String(raw[..<colon])
                if !h.isEmpty { host = h }
                port = p
            } else if let p = Int(raw) {
                port = p
            }
        }
        let wwwRoot = env["CODEXKIT_WEB_ROOT"]
            ?? (FileManager.default.currentDirectoryPath + "/www/dist")
        let certPath = env["CODEXKIT_WEB_CERT"] ?? (codexHome + "/web-gateway/cert.pem")
        let keyPath = env["CODEXKIT_WEB_KEY"] ?? (codexHome + "/web-gateway/key.pem")
        // Plaintext (no TLS) is local-dev/CI only — never for a real bind.
        let tls = env["CODEXKIT_WEB_INSECURE"] != "1"

        // Auth is mandatory for any non-loopback bind (fail-closed), and can be
        // forced on for loopback via CODEXKIT_WEB_REQUIRE_AUTH=1. The agent
        // control-plane is arbitrary local RCE; never expose it unauthenticated.
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        let requireAuth = !loopback || env["CODEXKIT_WEB_REQUIRE_AUTH"] == "1"
        var token = env["CODEXKIT_WEB_TOKEN"]
        if requireAuth, (token?.isEmpty ?? true) {
            token = Self.generateToken()
            FileHandle.standardError.write(
                Data("codexd web gateway auth token: \(token!)\n".utf8))
        }
        let origins = (env["CODEXKIT_WEB_ORIGINS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // #4: persist the `/media` signing key (deny-default) so signed media URLs
        // survive a daemon restart. Off → a per-launch random key (path-only
        // delivery, the previous behavior).
        let persistSigner = env["CODEXKIT_WEB_PERSIST_MEDIA_SIGNER"] == "1"
        // Browser-reachable origin for signed media URLs (required for a wildcard
        // bind / reverse-proxy fronting). nil → derived from a concrete host:port.
        let publicBase = (env["CODEXKIT_WEB_PUBLIC_BASE_URL"]?.isEmpty == false)
            ? env["CODEXKIT_WEB_PUBLIC_BASE_URL"] : nil
        // Serve + sign media from the SAME root the media provider writes to
        // (MediaConfig's resolution), so signed `/media/:token` delivery actually
        // resolves. A divergent `web-gateway/media` default would make every
        // minted URL fall back to the local path. Falls back to the legacy
        // gateway dir only when [media] isn't configured at all.
        let mediaRoot = config.value("media") != nil
            ? MediaConfig.resolveMediaRoot(config: config, codexHome: codexHome)
            : codexHome + "/web-gateway/media"
        return WebGatewayConfig(host: host, port: port, wwwRoot: wwwRoot,
                                certPath: certPath, keyPath: keyPath, tls: tls,
                                requireAuth: requireAuth, bearerToken: token,
                                allowedOrigins: origins,
                                mediaRoot: mediaRoot,
                                persistMediaSignerKey: persistSigner,
                                publicBaseURL: publicBase)
    }

    /// A URL-safe random bearer token for the web gateway.
    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Live realtime-voice backend (OpenAI Realtime API bridge), opt-in via
    /// `CODEXKIT_REALTIME_LIVE=1`. Requires a direct `OPENAI_API_KEY` (the
    /// `/v1/realtime` socket is Bearer-authenticated and does not accept the
    /// ChatGPT OAuth token, same as computer-use). Falls back to nil — the
    /// built-in echo backend — when unset or unconfigured, so the default web
    /// experience is unchanged. `CODEXKIT_REALTIME_MODEL` overrides the model
    /// (default `gpt-realtime-2`); `CODEXKIT_REALTIME_ENDPOINT` overrides the
    /// wss endpoint.
    private static func realtimeBackendFactory() -> RealtimeBackendFactory? {
        let env = ProcessInfo.processInfo.environment
        guard env["CODEXKIT_REALTIME_LIVE"] == "1" else { return nil }
        guard let key = env["OPENAI_API_KEY"], !key.isEmpty else {
            FileHandle.standardError.write(Data(
                "codexd: CODEXKIT_REALTIME_LIVE=1 but OPENAI_API_KEY is unset; realtime voice uses the echo backend\n".utf8))
            return nil
        }
        let model = env["CODEXKIT_REALTIME_MODEL"] ?? "gpt-realtime-2"
        let backend: LiveRealtimeBackend
        if let endpoint = env["CODEXKIT_REALTIME_ENDPOINT"], !endpoint.isEmpty {
            backend = LiveRealtimeBackend(model: model, apiKey: key, endpoint: endpoint)
        } else {
            backend = LiveRealtimeBackend(model: model, apiKey: key)
        }
        FileHandle.standardError.write(Data(
            "codexd: realtime voice backend = live (model=\(model))\n".utf8))
        return backend.makeFactory()
    }

    private static func unixPath(from raw: String, codexHome: String) -> String? {
        let expanded: String
        if raw == "$CODEX_HOME" {
            expanded = codexHome
        } else if raw.hasPrefix("$CODEX_HOME/") {
            expanded = codexHome + raw.dropFirst("$CODEX_HOME".count)
        } else {
            expanded = raw
        }
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
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

    /// Project `ConfigValue` (full sum type from the Config module) onto the
    /// `ConfigValueLite` subset the model provider loader consumes. Mirrors
    /// `RequestRouter.configValueLite(_:)`.
    private static func configValueToLite(_ value: ConfigValue) -> ConfigValueLite {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .int(Int64(d))
        case .string(let s): return .string(s)
        case .array(let values): return .array(values.map(configValueToLite(_:)))
        case .object(let object): return .object(object.mapValues(configValueToLite(_:)))
        }
    }

    private static func openAIClient(apiKey: String, limits: Limits) -> any ModelClient {
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
                    explicitNoZstd: true))
            let http = URLSessionResponsesClient(apiKey: apiKey, endpoint: endpoint, limits: limits)
            return TransportFallbackModelClient(primary: ws, fallback: http, limits: limits)
        }
        return URLSessionResponsesClient(apiKey: apiKey, endpoint: endpoint, limits: limits)
        #else
        return OpenAIResponsesClient(apiKey: apiKey, endpoint: endpoint, limits: limits)
        #endif
    }

    static func main() async {
        let log = Log(category: "codexd")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() + "/.codex")

        // Subcommands short-circuit the daemon: a one-shot routine + exit, BEFORE
        // any socket/ThreadStore. `google-connect` obtains OAuth tokens via the
        // loopback PKCE flow + writes a 0600 token file the worker reads — done
        // out-of-band so the refresh-token secret never streams over the control
        // plane (the reason it is a subcommand, not an RPC).
        if let sub = CommandLine.arguments.dropFirst().first,
           sub == "google-connect" || sub == "google-disconnect" {
            let env = ProcessInfo.processInfo.environment
            let addonConfig = ConfigLoader(codexHome: codexHome).load()
            let emit: @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
            let code: Int32
            if sub == "google-connect" {
                code = await runGoogleConnect(
                    addonConfig: addonConfig, codexHome: codexHome, env: env,
                    openURL: { url in
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        p.arguments = [url.absoluteString]
                        try? p.run()
                    }, emit: emit)
            } else {
                code = await runGoogleDisconnect(
                    addonConfig: addonConfig, codexHome: codexHome, env: env, emit: emit)
            }
            exit(code)
        }

        // Apply optional `$CODEX_HOME/config.toml` overrides (F1).
        let limits = Limits.loadingOverrides(codexHome: codexHome).clamped()

        guard let store = try? ThreadStore(codexHome: codexHome, limits: limits) else {
            log.error("failed to open ThreadStore at \(codexHome)")
            exit(1)
        }

        // codexd is a long-running, multi-session daemon. Env overlay
        // is intentionally NOT applied here for the same reason as
        // codex-broker — see comment there.
        // Resolve the configured credential store mode
        // (`cli_auth_credentials_store`, upstream default File) so the Swift
        // server stays interoperable with the official codex CLI on a shared
        // CODEX_HOME instead of unconditionally using the Keychain.
        let authStoreMode = AuthCredentialsStoreMode.parse(
            ConfigLoader(codexHome: codexHome).load()
                .value("cli_auth_credentials_store")?.stringValue)
        let authManager = AuthManager(
            store: TokenStoreFactory.production(codexHome: codexHome, mode: authStoreMode),
            apiKeyExchanger: CurlAPIKeyExchanger(),
            revoker: CurlTokenRevoker())
        let useMock = ProcessInfo.processInfo.environment["CODEXKIT_MOCK"] == "1"
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        let model: any ModelClient
        let mem0AuthProvider: Mem0SessionAuthProvider?
        let wikiAuthProvider: WikiMemoryAuthProvider?
        // Bearer source for the `computer_use` desktop loop when the session
        // authenticates via a ChatGPT OAuth token (broker / stored auth) rather
        // than a raw OPENAI_API_KEY. nil on the API-key path (the tool falls back
        // to env OPENAI_API_KEY) and when unauthenticated. See ComputerUseTool.
        let computerUseBearer: (@Sendable () async -> String?)?
        if useMock {
            mem0AuthProvider = nil
            wikiAuthProvider = nil
            computerUseBearer = nil
            if ProcessInfo.processInfo.environment["CODEXKIT_MOCK_SCENARIO"] == "tool-loop-compact" {
                model = MockModelClient(MockScenario.toolLoopCompactionSequence(repetitions: 256))
            } else {
                model = MockModelClient(repeating: .hello("Hello from CodexKit (mock)."),
                                        times: 1024)
            }
        } else if let apiKey, !apiKey.isEmpty {
            mem0AuthProvider = .staticToken(apiKey)
            wikiAuthProvider = .staticToken(apiKey)
            computerUseBearer = nil   // env OPENAI_API_KEY path; tool falls back to env
            model = openAIClient(apiKey: apiKey, limits: limits)
            log.info("codexd using OpenAI Responses client from OPENAI_API_KEY")
        } else if let brokerAuth = brokerAuthClient(codexHome: codexHome),
                  let token = await brokerAuth.validAccessToken() {
            mem0AuthProvider = Mem0SessionAuthProvider(
                accessToken: { await brokerAuth.validAccessToken() },
                refreshToken: { await brokerAuth.refreshAccessToken() })
            wikiAuthProvider = WikiMemoryAuthProvider(
                accessToken: { await brokerAuth.validAccessToken() },
                refreshToken: { await brokerAuth.refreshAccessToken() })
            computerUseBearer = { await brokerAuth.validAccessToken() }
            model = AuthRefreshingModelClient(
                initial: openAIClient(apiKey: token, limits: limits),
                refreshToken: { await brokerAuth.refreshAccessToken() },
                makeClient: { openAIClient(apiKey: $0, limits: limits) })
            log.info("codexd using OpenAI Responses client from broker auth with 401 refresh")
        } else if let token = await authManager.validAccessToken() {
            mem0AuthProvider = Mem0SessionAuthProvider(
                accessToken: { await authManager.validAccessToken() },
                refreshToken: { await authManager.refreshAccessToken() })
            wikiAuthProvider = WikiMemoryAuthProvider(
                accessToken: { await authManager.validAccessToken() },
                refreshToken: { await authManager.refreshAccessToken() })
            computerUseBearer = { await authManager.validAccessToken() }
            model = AuthRefreshingModelClient(
                initial: openAIClient(apiKey: token, limits: limits),
                refreshToken: { await authManager.refreshAccessToken() },
                makeClient: { openAIClient(apiKey: $0, limits: limits) })
            log.info("codexd using OpenAI Responses client from stored auth with 401 refresh")
        } else {
            mem0AuthProvider = nil
            wikiAuthProvider = nil
            computerUseBearer = nil
            model = NotConfiguredModelClient()
        }

        let inProcessWorkers =
            ProcessInfo.processInfo.environment["CODEXKIT_IN_PROCESS_WORKERS"] == "1"
        let factory: WorkerFactory
        if inProcessWorkers {
            log.info("codexd using in-process workers (CODEXKIT_IN_PROCESS_WORKERS=1)")
            FileHandle.standardError.write(Data("codexd workerMode=in-process\n".utf8))
            factory = { cfg in
                let link = WorkerLink.make()
                let runtime = WorkerRuntime(link: link) { c in
                    let execPolicy = ExecPolicy.load(codexHome: codexHome)
                    // Honor the client-supplied sandboxMode/writableRoots/
                    // networkAccess rather than hardcoding workspaceWrite.
                    let sb = SessionSandboxBuilder.make(config: c, execPolicy: execPolicy)
                    let router = ToolRouter(limits: limits)
                    // Upstream parity (`ToolsConfig::agent_type_description`):
                    // honour the SessionConfig override for `spawn_agent`'s
                    // `agent_type` JSON-schema description; nil/empty falls
                    // back to the built-in placeholder.
                    var spawnAgentOptions = SpawnAgentToolOptions()
                    if let agentTypeDesc = c.agentTypeDescription, !agentTypeDesc.isEmpty {
                        spawnAgentOptions.agentTypeDescription = agentTypeDesc
                    }
                    // Upstream `spec_plan.rs` gates the shell-tool family on the
                    // model's `shell_type` (`ConfigShellToolType`): exactly one
                    // coherent shell interface is offered. Resolve from the
                    // bundled catalog (falls back to `.shellCommand`).
                    let shellType = ShellToolType.from(
                        rawValue: ModelsCatalog.entry(for: c.model)?.shellType)
                    await DefaultTools.register(on: router, sandbox: sb, limits: limits,
                                                shellType: shellType,
                                                // computer_use drives THIS host's
                                                // desktop — local (non-remote)
                                                // sessions only.
                                                // Never under a mock model (the env
                                                // OPENAI_API_KEY fallback would else
                                                // drive the REAL API/desktop).
                                                computerUseEnabled: c.remoteEnvironment == nil && !useMock,
                                                computerUseTokenProvider: computerUseBearer,
                                                spawnAgentOptions: spawnAgentOptions)
                    // Dynamic workflows: enabled gate (the orchestrator is
                    // wired after the engine exists, so progress can be pushed
                    // over its stream).
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
                    // Upstream parity (H-32 / P4.8): wire the model client
                    // into the memory store so end-of-turn consolidation runs
                    // the Stage-1 structured-output pipeline (raw_memory /
                    // rollout_summary / rollout_slug). Falls back to the
                    // deterministic local summary on any error.
                    await memory.setModelClient(model)
                    if shouldRegisterCoreMemoryTools(config: addonConfig) {
                        await router.register(MemoryTool(store: memory))
                        await router.register(MemoriesListTool(store: memory))
                        await router.register(MemoriesReadTool(store: memory))
                        await router.register(MemoriesSearchTool(store: memory))
                    }
                    let mcp = McpManager()
                    // F8 (MEDIUM): supply the OAuth store so HTTP MCP
                    // servers reuse previously-saved tokens from
                    // `mcp login`. Was hardcoded `nil` before P7.3.
                    let mcpOAuthStore = McpOAuthStore(codexHome: codexHome)
                    await mcp.startAll(McpManager.loadConfigs(codexHome: codexHome),
                                       router: router,
                                       oauthStore: mcpOAuthStore)
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
                    // Extension spine (ARCHITECTURE.md §5.4 / Phase 0): mirror
                    // the codex-session wiring (this is the in-process worker
                    // path). General manifests are feature-gated; memory can
                    // install independently because mem0 is the default
                    // personal-memory path.
                    // Phase 1 (ARCHITECTURE.md §7.1): memory slot candidates.
                    // mem0 is the default personal-memory provider when
                    // `[memory].provider` is unset; "core", "wiki", and "none"
                    // remain explicit choices. Recall+capture wire into the
                    // registry.
                    // The vector "Memory Wiki" candidate is built ONLY when
                    // `[memory].provider == "wiki"` (constructing it opens a
                    // SQLite handle on the wiki DB). It reuses this session's
                    // `ModelClient` for its own text inference (D1) and returns
                    // nil if the DB can't be opened, so a configured-but-
                    // unavailable wiki disables recall rather than crashing.
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
                    // Register the selected provider's tools. Memory is no
                    // longer gated by the general `extensions` feature because
                    // mem0 is the default personal-memory product path.
                    for t in (memoryProvider?.tools() ?? []) { await router.register(t) }
                    // ADDONS Phase 0 #2: addon tool-pack seam. #4 (Google
                    // Workspace), #7 (Push), #8 (Media) construct their packs
                    // with deps and append here; each is gated by
                    // `[features].<pack.id>` and self-prunes when unconfigured.
                    var toolPacks: [any ToolPack] = []
                    // #7 Push: when [features].push is on, wire the durable router
                    // (ntfy + webhook sinks behind the egress chokepoint) so
                    // `push_send` is advertised. Deny-default → off otherwise.
                    if addonConfig.isFeatureEnabled("push") {
                        let pushRouter = await PushRouter.makeDefault(directory: codexHome + "/push")
                        toolPacks.append(PushToolPack(router: pushRouter))
                    }
                    // #4 Google: gated on [features].google + a [connectors.google]
                    // table (deny-default). The pure GoogleWiring.toolPack helper
                    // builds the OAuth connector + REST client; tokens are obtained
                    // out-of-band via the `codexd google-connect` subcommand.
                    if let gpack = GoogleWiring.toolPack(
                        addonConfig: addonConfig, codexHome: codexHome,
                        env: ProcessInfo.processInfo.environment) {
                        toolPacks.append(gpack)
                    }
                    // #8 Media: the daemon (in-process) already built the shared
                    // ledger + poller above and published it on the holder; the
                    // tool just reads it. nil holder (media off) → self-prunes.
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
                    // Dynamic workflows: install the orchestrator on the shared
                    // bus; progress is pushed (16ms-debounced) over this
                    // session's already-relayed event stream.
                    if workflowsEnabled {
                        let wfRunner = WorkflowAgentRunner(
                            store: store, limits: limits, model: model,
                            routerFactory: { _, extra in
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
                        WorkflowHolder.shared.set(orch)
                    }
                    return engine
                }
                let task = Task { await runtime.run() }
                return WorkerHandle(link: link, task: task)
            }
        } else {
            log.info("codexd using spawned codex-session workers")
            FileHandle.standardError.write(Data("codexd workerMode=spawned\n".utf8))
            factory = SpawnWorker.factory(codexHome: codexHome)
        }

        let supervisor = SessionSupervisor(factory: factory,
                                           maxSessions: limits.maxConcurrentSessions)
        var configOverrides: [String: ConfigValue] = [:]
        if let pv2 = profileV2Flag() { configOverrides["profileV2"] = .string(pv2) }
        // codexd is process-global: use the process cwd as the project-local
        // discovery root. Per-session cwds (from the client's
        // `thread/start`) are handled inside the worker.
        let appConfigLoader = ConfigLoader(
            codexHome: codexHome,
            cwdOverride: FileManager.default.currentDirectoryPath)
        let appConfig = appConfigLoader.load(overrides: configOverrides)

        // Startup validation: reject `wire_api = "chat"` (or any unknown
        // `wire_api` value) in `model_providers` so a misconfigured provider
        // fails loud at process start instead of surfacing later as an
        // opaque routing failure. Upstream removed Chat Completions support;
        // codex-swift mirrors that rejection at the throwing entry point.
        do {
            let object = appConfig.configObjectJSON()
            _ = try ModelProviderRegistry.load(
                from: object.mapValues(configValueToLite(_:)))
        } catch let error as ModelProviderConfigError {
            FileHandle.standardError.write(
                Data("codexd: invalid config: \(error.localizedDescription)\n".utf8))
            exit(78)  // EX_CONFIG
        } catch {
            FileHandle.standardError.write(
                Data("codexd: invalid config: \(error)\n".utf8))
            exit(78)
        }

        let appMemory = MemoryStore(codexHome: codexHome)
        // ADDONS #7 owner-path push. When [features].push is on, build the
        // DAEMON-scope durable PushRouter (ntfy + webhook sinks behind the
        // EgressGuard chokepoint) and publish it via the process-global holder
        // so the owner-only `outbound/send` RPC handler (and the #8 Media deliver
        // closure) can reach it WITHOUT a second makeDefault on the same dir.
        // Deny-default: the holder stays nil otherwise and the dispatch arm
        // refuses with "push feature is not enabled".
        if appConfig.isFeatureEnabled("push") {
            let daemonPushRouter = await PushRouter.makeDefault(directory: codexHome + "/push")
            PushRouterHolder.shared.set(daemonPushRouter)
        }
        // #8 Media: in IN-PROCESS worker mode, build the ONE shared ledger
        // eagerly + run the daemon poller. Spawned workers hold their own
        // per-process ledger (the inline stub delivers synchronously there, so
        // no daemon poller is needed; an async provider, which WOULD need one,
        // requires in-process workers). Deny-default: nothing is built when
        // [features].media is off. Bound as a `let` so the shutdown handler can
        // capture it.
        let mediaPoller: MediaPoller? = await {
            guard inProcessWorkers,
                  let ledger = await MediaWiring.makeLedger(
                      addonConfig: appConfig, codexHome: codexHome,
                      env: ProcessInfo.processInfo.environment,
                      inProcessWorkers: inProcessWorkers, deliver: MediaGlue.push)
            else { return nil }
            MediaLedgerHolder.shared.set(ledger)
            let poller = MediaPoller(ledger: ledger)
            await poller.start()
            FileHandle.standardError.write(Data("codexd media poller started\n".utf8))
            return poller
        }()
        // Realtime voice backend: live OpenAI Realtime bridge when opted in,
        // else nil (echo). Shared by the stdio/UDS router and every per-tab web
        // router; the factory builds a fresh session per `thread/realtime/start`.
        let realtimeFactory = Self.realtimeBackendFactory()
        // Read-only Memory Wiki browse surface (deny-default: nil unless
        // CODEXKIT_MEMORY=1 and the SQLite store opens). Built once and shared
        // across the daemon + per-tab web routers (the store actor serializes).
        let wikiHandle = await WikiQueryWiring.make(config: appConfig, modelClient: model,
                                                    authProvider: wikiAuthProvider)
        // OWNER-TRUSTED daemon router: stdio / UDS / loopback socket. Serves
        // owner-only RPCs (outbound/send). allowsOwnerOnlyRPC defaults to true.
        let router = RequestRouter(supervisor: supervisor, store: store,
                                   codexHome: codexHome, auth: authManager,
                                   config: appConfig,
                                   memoryResetHandler: { await appMemory.reset() },
                                   wikiQuery: wikiHandle,
                                   realtimeBackendFactory: realtimeFactory,
                                   allowsOwnerOnlyRPC: true)

        // Automations: persistent store + interval scheduler (fires saved
        // prompts on a schedule). Shared with the RequestRouter handler via the
        // holder so automation/action CRUD + run work.
        let automationStore = AutomationStore(codexHome: codexHome)
        AutomationStoreHolder.shared.set(automationStore)
        let automationScheduler = AutomationScheduler(
            store: automationStore, supervisor: supervisor, threadStore: store,
            defaultCwd: FileManager.default.currentDirectoryPath)
        // #6 Cron: when [features].cron is on, Cron is the SINGLE source of truth
        // — migrate legacy automations ONCE and do NOT also start the
        // AutomationScheduler (else the same job fires via both). Deny-default:
        // nothing built when off; the AutomationScheduler keeps its old behavior.
        let cronEnabled = appConfig.isFeatureEnabled("cron")
        var cronSchedulerVar: CronScheduler?
        if cronEnabled {
            let migrated = CronGlue.migrateAutomationsToCron(codexHome: codexHome)
            if migrated > 0 {
                FileHandle.standardError.write(Data("codexd cron: migrated \(migrated) automations → cron_jobs.json\n".utf8))
            }
            let cronStore = FileCronStore(path: codexHome + "/cron_jobs.json")
            let grace = appConfig.value("cron")?.objectValue?["grace_seconds"]?.intValue ?? 3600
            let runner = CronGlue.makeCronRunner(
                supervisor: supervisor,
                defaultCwd: FileManager.default.currentDirectoryPath,
                defaultModel: appConfig.value("model")?.stringValue ?? "gpt-5.5")
            let scheduler = CronScheduler(store: cronStore, graceSeconds: grace, run: runner)
            await scheduler.loadFromStore()
            CronSchedulerHolder.shared.set(scheduler)
            await scheduler.start()
            cronSchedulerVar = scheduler
            FileHandle.standardError.write(Data("codexd cron scheduler started\n".utf8))
        } else {
            await automationScheduler.start()
        }
        let cronScheduler = cronSchedulerVar   // immutable copy for the @Sendable shutdown closure

        // #1/#2 Channels (Telegram MVP): deny-default behind
        // [channels.telegram].enabled. The TurnRunner bakes the non-owner
        // lockdown into SessionConfig so the owner-gate holds in both worker
        // modes. Stopped on SIGTERM/SIGINT.
        let channelManager = await ChannelsGlue.bootstrap(
            config: appConfig, codexHome: codexHome, supervisor: supervisor,
            defaultModel: appConfig.value("model")?.stringValue ?? "gpt-5.5",
            env: ProcessInfo.processInfo.environment)

        // Web gateway (docs/webgateway/). Started alongside the app-server
        // transport, sharing this process's SessionSupervisor so web tabs and
        // local stdio/UDS clients see the same session pool. Each browser tab
        // gets its OWN per-connection RequestRouter via the factory below.
        let webGatewayConfig = Self.webGatewayConfig(codexHome: codexHome, config: appConfig)
        let webGatewayEnabled = webGatewayConfig != nil
        if let webGatewayConfig {
            let gateway = WebGateway(
                config: webGatewayConfig,
                limits: limits,
                routerFactory: {
                    // UNTRUSTED browser surface: a LOWER trust tier than
                    // owner-local stdio/UDS. allowsOwnerOnlyRPC:false so a web
                    // origin can NOT reach owner-only RPCs (outbound/send) even
                    // though the PushRouterHolder is process-global.
                    RequestRouter(supervisor: supervisor, store: store,
                                  codexHome: codexHome, auth: authManager,
                                  config: appConfig,
                                  memoryResetHandler: { await appMemory.reset() },
                                  wikiQuery: wikiHandle,
                                  realtimeBackendFactory: realtimeFactory,
                                  allowsOwnerOnlyRPC: false)
                })
            Task {
                do { try await gateway.run() }
                catch {
                    FileHandle.standardError.write(
                        Data("codexd: web gateway failed: \(error)\n".utf8))
                }
            }
            let scheme = webGatewayConfig.tls ? "https" : "http"
            FileHandle.standardError.write(
                Data("codexd web gateway \(scheme)://\(webGatewayConfig.host):\(webGatewayConfig.port) (auth=\(webGatewayConfig.requireAuth))\n".utf8))
        }

        // Spawn the host-wide `codex-memory` child when the Memory Wiki is
        // enabled. One process per host (the wiki is global, not per session).
        // The supervisor restarts on crash with capped exponential backoff and
        // terminates cleanly on codexd shutdown.
        let memoryEnabled = ProcessInfo.processInfo.environment["CODEXKIT_MEMORY"] == "1"
        let memorySupervisor = MemorySupervisor(
            config: .bootstrap(enabled: memoryEnabled))
        await memorySupervisor.start()
        // Install SIGTERM / SIGINT handlers so the supervisor's child is
        // sent SIGTERM (then SIGKILL after a grace period) when codexd exits.
        // Without this, codexd dying leaves an orphaned codex-memory holding
        // the SQLite WAL lock; on the next codexd start the new child fights
        // the old for the same file.
        let shutdownSource = DispatchSource.makeSignalSource(
            signal: SIGTERM, queue: .global())
        let interruptSource = DispatchSource.makeSignalSource(
            signal: SIGINT, queue: .global())
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let shutdownHandler: @Sendable () -> Void = {
            FileHandle.standardError.write(
                Data("codexd: shutdown signal received; stopping memory supervisor\n".utf8))
            // Spawn a detached Task so the signal handler returns promptly;
            // the actor's stop() drives child terminate + reap.
            Task.detached { @Sendable in
                await channelManager?.stopAll()
                await cronScheduler?.stop()
                await mediaPoller?.stop()
                await memorySupervisor.stop()
                Foundation.exit(0)
            }
        }
        shutdownSource.setEventHandler(handler: shutdownHandler)
        interruptSource.setEventHandler(handler: shutdownHandler)
        shutdownSource.resume()
        interruptSource.resume()

        let listen: AppServerTransport
        do {
            listen = try AppServerTransport.parse(listenURL())
        } catch {
            FileHandle.standardError.write(Data("invalid --listen: \(error)\n".utf8))
            exit(2)
        }

        switch listen {
        case .stdio:
            let conn = StdioConnection(limits: limits)
            conn.startReading()
            log.info("codexd ready on stdio (mock=\(useMock), codexHome=\(codexHome))")
            // NOTE (audit app-server-registry/finding-5): per-connection messages
            // are dispatched strictly serially in receive order, awaiting each
            // `router.handle` before the next. Upstream instead computes a
            // `serialization_scope()` per request (app-server/src/message_processor.rs:804,
            // 831-840): scope-free requests are `tokio::spawn`ed concurrently and only
            // requests sharing a scope (e.g. global("config"), thread_id(...)) are
            // queued. Wire correctness is preserved here because every handler
            // (thread/start, turn/start, …) returns promptly and runs the actual turn
            // asynchronously in the background — no handler blocks on turn completion —
            // so strict serial dispatch never reorders observable responses. Accepted
            // as a deliberate single-loop concurrency simplification for this port.
            for await message in conn.incoming() {
                await router.handle(message, conn)
            }
            await router.connectionClosed(conn)
            log.info("codexd stdin closed; exiting")
        case .webSocket(let bind):
            guard let port = wsPort(from: bind) else {
                FileHandle.standardError.write(
                    Data("unsupported --listen ws bind: \(bind)\n".utf8))
                exit(2)
            }
            do {
                let listener = try SocketListener(port: port, limits: limits)
                listener.start { conn in
                    Task {
                        // NOTE (audit app-server-registry/finding-5): see the stdio
                        // path above — each connection dispatches its messages serially
                        // in receive order. Upstream's serialization_scope model
                        // (message_processor.rs:804,831-840) spawns scope-free requests
                        // concurrently and queues only scoped ones; the port keeps a single
                        // serial loop per connection. Handlers return promptly and run turns
                        // in the background, so wire ordering stays correct. Deliberate,
                        // accepted divergence.
                        for await message in conn.incoming() {
                            await router.handle(message, conn)
                        }
                        await router.connectionClosed(conn)
                    }
                }
                let line = "codexd listening ws://127.0.0.1:\(listener.port)\n"
                FileHandle.standardError.write(Data(line.utf8))
                while true { try? await Task.sleep(for: .seconds(3600)) }
            } catch {
                FileHandle.standardError.write(
                    Data("failed to listen on \(bind): \(error)\n".utf8))
                exit(1)
            }
        case .unixSocket(let path):
            guard let resolvedPath = unixPath(from: path, codexHome: codexHome) else {
                FileHandle.standardError.write(
                    Data("unsupported --listen unix path: \(path)\n".utf8))
                exit(2)
            }
            do {
                let listener = try UnixSocketListener(path: resolvedPath, limits: limits)
                listener.start { conn in
                    Task {
                        // NOTE (audit app-server-registry/finding-5): serial per-connection
                        // dispatch, same as the stdio/ws paths above. Wire ordering is
                        // preserved because handlers return promptly and run turns in the
                        // background. Deliberate, accepted concurrency divergence.
                        for await message in conn.incoming() {
                            await router.handle(message, conn)
                        }
                        await router.connectionClosed(conn)
                    }
                }
                let line = "codexd listening unix://\(listener.path)\n"
                FileHandle.standardError.write(Data(line.utf8))
                while true { try? await Task.sleep(for: .seconds(3600)) }
            } catch {
                FileHandle.standardError.write(
                    Data("failed to listen on unix://\(resolvedPath): \(error)\n".utf8))
                exit(1)
            }
        case .off:
            if webGatewayEnabled {
                log.info("codexd app-server listen disabled; web gateway running")
                while true { try? await Task.sleep(for: .seconds(3600)) }
            }
            log.info("codexd listen disabled (--listen off)")
            return
        }
    }
}
