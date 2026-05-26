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
import Supervisor
import Transport
import Observability
import Auth
import Tokenizer
import Config

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
        #if os(macOS)
        if ProcessInfo.processInfo.environment["CODEXKIT_RESPONSES_WEBSOCKET"] == "1" {
            let ws = WebSocketResponsesClient(
                apiKey: apiKey,
                limits: limits,
                options: .init(
                    prewarm: ProcessInfo.processInfo.environment["CODEXKIT_WS_PREWARM"] != "0",
                    explicitNoZstd: true))
            let http = URLSessionResponsesClient(apiKey: apiKey, limits: limits)
            return TransportFallbackModelClient(primary: ws, fallback: http, limits: limits)
        }
        return URLSessionResponsesClient(apiKey: apiKey, limits: limits)
        #else
        return OpenAIResponsesClient(apiKey: apiKey, limits: limits)
        #endif
    }

    static func main() async {
        let log = Log(category: "codexd")
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() + "/.codex")
        // Apply optional `$CODEX_HOME/config.toml` overrides (F1).
        let limits = Limits.loadingOverrides(codexHome: codexHome).clamped()

        guard let store = try? ThreadStore(codexHome: codexHome, limits: limits) else {
            log.error("failed to open ThreadStore at \(codexHome)")
            exit(1)
        }

        // codexd is a long-running, multi-session daemon. Env overlay
        // is intentionally NOT applied here for the same reason as
        // codex-broker — see comment there.
        let authManager = AuthManager(
            store: TokenStoreFactory.production(codexHome: codexHome),
            apiKeyExchanger: CurlAPIKeyExchanger(),
            revoker: CurlTokenRevoker())
        let useMock = ProcessInfo.processInfo.environment["CODEXKIT_MOCK"] == "1"
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        let model: any ModelClient
        if useMock {
            if ProcessInfo.processInfo.environment["CODEXKIT_MOCK_SCENARIO"] == "tool-loop-compact" {
                model = MockModelClient(MockScenario.toolLoopCompactionSequence(repetitions: 256))
            } else {
                model = MockModelClient(repeating: .hello("Hello from CodexKit (mock)."),
                                        times: 1024)
            }
        } else if let apiKey, !apiKey.isEmpty {
            model = openAIClient(apiKey: apiKey, limits: limits)
            log.info("codexd using OpenAI Responses client from OPENAI_API_KEY")
        } else if let brokerAuth = brokerAuthClient(codexHome: codexHome),
                  let token = await brokerAuth.validAccessToken() {
            model = AuthRefreshingModelClient(
                initial: openAIClient(apiKey: token, limits: limits),
                refreshToken: { await brokerAuth.refreshAccessToken() },
                makeClient: { openAIClient(apiKey: $0, limits: limits) })
            log.info("codexd using OpenAI Responses client from broker auth with 401 refresh")
        } else if let token = await authManager.validAccessToken() {
            model = AuthRefreshingModelClient(
                initial: openAIClient(apiKey: token, limits: limits),
                refreshToken: { await authManager.refreshAccessToken() },
                makeClient: { openAIClient(apiKey: $0, limits: limits) })
            log.info("codexd using OpenAI Responses client from stored auth with 401 refresh")
        } else {
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
                    await DefaultTools.register(on: router, sandbox: sb, limits: limits,
                                                spawnAgentOptions: spawnAgentOptions)
                    if let remote = c.remoteEnvironment {
                        await RemoteExecServerTools.register(
                            on: router,
                            websocketURL: remote.execServerUrl,
                            limits: limits)
                    }
                    let memory = MemoryStore(codexHome: codexHome)
                    // Upstream parity (H-32 / P4.8): wire the model client
                    // into the memory store so end-of-turn consolidation runs
                    // the Stage-1 structured-output pipeline (raw_memory /
                    // rollout_summary / rollout_slug). Falls back to the
                    // deterministic local summary on any error.
                    await memory.setModelClient(model)
                    await router.register(MemoryTool(store: memory))
                    // Upstream parity (H-32 / P4.8): three namespaced memory
                    // tools alongside the legacy `memory` tool. The legacy
                    // tool stays registered for back-compat.
                    await router.register(MemoriesListTool(store: memory))
                    await router.register(MemoriesReadTool(store: memory))
                    await router.register(MemoriesSearchTool(store: memory))
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
                            name: $0.name, description: $0.description, path: $0.path) }
                    let connectors = ConnectorsDiscovery()
                        .discover(codexHome: codexHome)
                        .map { PromptComposer.ConnectorInjection(
                            id: $0.id, name: $0.name, description: $0.description) }
                    let autoCompact = ModelCatalog.default.autoCompactLimit(for: c.model)
                    let approved = ApprovedRuleStore(codexHome: codexHome)
                    return SessionEngine(config: c, model: model, store: store,
                                         router: router, limits: limits,
                                         autoCompactTokens: autoCompact,
                                         memoryStore: memory, sandbox: sb,
                                         skills: skills, connectors: connectors,
                                         approvedStore: approved, execPolicy: execPolicy,
                                         hooks: HookEngine.load(
                                            codexHome: codexHome, cwd: c.cwd,
                                            legacyNotifyArgv: c.notify))
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
        let router = RequestRouter(supervisor: supervisor, store: store,
                                   codexHome: codexHome, auth: authManager,
                                   config: appConfig,
                                   memoryResetHandler: { await appMemory.reset() })

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
            log.info("codexd listen disabled (--listen off)")
            return
        }
    }
}
