import Foundation
import Auth
import Config
import InfraPrimitives
import MemoryIngest
import MemoryInfer
import MemoryMCP
import MemoryProcess
import MemoryRetrieve
import MemoryScore
import MemoryStore
import ModelClient
import Observability

private struct MemoryOpenAIAuth {
    let modelClient: any ModelClient
    let embeddingAuthProvider: ModelClientBridge.BearerTokenProvider
}

private enum MemoryInferenceBackend: String {
    case auto
    case local
    case remote
    case mock

    static func parse(_ raw: String?) -> MemoryInferenceBackend {
        guard let raw else { return .auto }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "local", "mlx", "mlx_local": return .local
        case "remote", "openai": return .remote
        case "mock", "offline": return .mock
        default: return .auto
        }
    }
}

private enum ResolvedMemoryInferenceBackend {
    case local
    case remote
    case mock
}

private struct MemoryInferencePlan {
    var backend: ResolvedMemoryInferenceBackend
    var providerID: String
}

/// Daemon glue. Wires the seven Memory* modules together so a single
/// `codex-memory run` (or `codex-memory tick`) drives a coherent end-to-end
/// flow. Configuration is intentionally minimal — the CodexKit `Config` layer
/// is the long-term home for source lists and persona profiles.
public enum CodexMemoryRun {
    public static func tickOnce() async throws {
        let bundle = try await assemble()
        let stats = try await bundle.scheduler.tick()
        // Close the ring so the drain loop terminates when empty rather than
        // blocking on the next sender (no scheduler tick is pending here).
        await bundle.ring.close()
        while let doc = await bundle.ring.dequeue() {
            _ = try await bundle.processor.process(doc)
        }
        let line = "ingest stats: attempted=\(stats.attempted) " +
                   "fresh=\(stats.fresh) unchanged=\(stats.unchanged) " +
                   "failed=\(stats.failed) deduped=\(stats.deduped) " +
                   "enqueued=\(stats.enqueued)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    public static func runForever() async {
        let bundle: AssembledMemory
        do { bundle = try await assemble() } catch {
            FileHandle.standardError.write(Data("assemble failed: \(error)\n".utf8))
            return
        }

        // Power-events glue: pause the scheduler on sleep, kick a catch-up tick
        // on wake. Holding the listener alive for the whole lifetime is the
        // documented IOKit pattern.
        let events = PowerEvents { event in
            switch event {
            case .willSleep:
                FileHandle.standardOutput.write(Data("power: will-sleep\n".utf8))
            case .willWake, .didWake:
                FileHandle.standardOutput.write(Data("power: wake — catch-up tick\n".utf8))
                Task { try? await bundle.scheduler.tick() }
            }
        }
        events.start()
        defer { events.stop() }

        // Memory-pressure handler: shed work in the design doc §9 order —
        // reranker first, embedder second, halt ingestion before the extractor
        // is ever evicted. The handlers here are intentionally observational
        // (the active inference backend isn't MLX-resident yet, so there's
        // nothing to evict); the pressure-monitor wiring is load-bearing
        // because the MLX-bound branch lights up automatically once added.
        let pressure = MemoryPressureMonitor()
        await pressure.start()
        let pressureSub = await pressure.subscribe { level in
            switch level {
            case .normal: break
            case .warning:
                FileHandle.standardError.write(
                    Data("memory: pressure=warning — shed reranker\n".utf8))
            case .critical:
                FileHandle.standardError.write(
                    Data("memory: pressure=critical — halt ingestion\n".utf8))
            }
        }
        defer { Task { await pressure.unsubscribe(pressureSub) } }
        defer { Task { await pressure.stop() } }

        // Nightly snapshot scheduler starts in lockstep with the main loop.
        await bundle.snapshotScheduler.start()
        defer { Task { await bundle.snapshotScheduler.stop() } }

        // OTLP exporter — drains the MemoryMetrics ring every 60s. The
        // collector endpoint comes from $CODEXKIT_OTLP_ENDPOINT; when unset
        // the sink is DisabledOTLPSink (no-op).
        let otlpEndpoint = ProcessInfo.processInfo.environment[
            "CODEXKIT_OTLP_ENDPOINT"]
        let otlpSink: any OTLPSink = otlpEndpoint.map { CurlOTLPSink(endpoint: $0) }
            ?? DisabledOTLPSink()
        let exporter = OTLPMetricsExporter(serviceName: "codex-memory",
                                           sink: otlpSink)
        let exporterTask = Task {
            while !Task.isCancelled {
                _ = await exporter.drainAndExport(MemoryMetrics.sink)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        defer { exporterTask.cancel() }

        // Main loop: tick, drain, sleep. Cooperatively cancellable via signals
        // — the CodexKit harness wraps SIGTERM into Task cancellation upstream.
        let cadence: Duration = .seconds(60)
        while !Task.isCancelled {
            do {
                _ = try await bundle.scheduler.tick()
                // Non-blocking drain: a blocking dequeue() suspends forever
                // when the ring is open + empty, deadlocking the cadence
                // sleep. tryDequeue() returns nil when nothing's buffered so
                // we fall through to the next tick.
                while let doc = await bundle.ring.tryDequeue() {
                    _ = try? await bundle.processor.process(doc)
                }
            } catch {
                FileHandle.standardError.write(Data("tick error: \(error)\n".utf8))
            }
            do { try await Task.sleep(for: cadence) } catch { break }
        }
    }

    // MARK: - assembly

    struct AssembledMemory: Sendable {
        let store: MemoryStore
        let ring: ChunkRing
        let scheduler: SourceScheduler
        let inference: any LocalInferenceProvider
        let processor: MemoryProcessor
        let retriever: MemoryRetriever
        let scorer: Scorer
        let personas: PersonaState
        let toolset: MemoryToolset
        let archive: MemoryArchive
        let snapshotScheduler: SnapshotScheduler
    }

    public static func snapshotOnce() async throws {
        let bundle = try await assemble()
        try await SnapshotScheduler.runOnce(
            store: bundle.store, archive: bundle.archive,
            config: .init())
    }

    static func assemble() async throws -> AssembledMemory {
        let env = ProcessInfo.processInfo.environment
        let codexHome = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")

        // Pick the inference backend. Order: local MLX when available →
        // explicit env API key / broker / stored ChatGPT auth → mock fallback.
        let openAIAuth = await resolveOpenAIAuth(env: env, codexHome: codexHome)
        let embeddingModel = env["CODEX_MEMORY_EMBEDDING_MODEL"] ?? "text-embedding-3-small"
        let embeddingEndpoint = env["CODEX_MEMORY_EMBEDDINGS_URL"]
            ?? "https://api.openai.com/v1/embeddings"
        let plan = resolveInferencePlan(env: env,
                                        openAIAuth: openAIAuth,
                                        embeddingModel: embeddingModel,
                                        embeddingEndpoint: embeddingEndpoint)
        let storeConfig = MemoryStoreConfig(
            path: MemoryStoreConfig.defaultPath(),
            embeddingDimension: memoryEmbeddingDimension,
            embeddingProviderID: plan.providerID)
        let store = try MemoryStore(storeConfig)
        let ring = ChunkRing()
        let inference = makeInference(
            openAIAuth: openAIAuth,
            plan: plan,
            extractorModel: env["CODEX_MEMORY_EXTRACTOR_MODEL"] ?? "gpt-5.4-mini",
            embeddingModel: embeddingModel,
            embeddingEndpoint: embeddingEndpoint,
            storeConfig: storeConfig)

        // Personas read from TOML, falling back to the five defaults.
        let personas = PersonaState.load(codexHome: codexHome)

        // Sources read from TOML; assemble() registers what's found.
        // CompositeFetcher dispatches by source kind so `x` traffic only
        // goes through TwitterAPI.io and HTTP/RSS via curl.
        let scheduler = SourceScheduler(store: store, ring: ring,
                                        fetcher: CompositeFetcher())
        let sources = SourceSpec.load(codexHome: codexHome)
        await scheduler.register(sources)

        // Rollout JSONL archive: every ingested doc + extraction is persisted
        // here, mirroring Persistence/Rollout.swift's "JSONL is the source of
        // truth, SQLite is a deterministically replayable index" stance.
        let archive = MemoryArchive.open(codexHome: codexHome)
        let processor = MemoryProcessor(store: store, inference: inference,
                                        archive: archive)
        let retriever = MemoryRetriever(store: store, inference: inference)
        let scorer = Scorer(store: store)

        // BrainGate is the explicit spend-gated escalation path. It uses the
        // shared OpenAI/ChatGPT auth-backed ModelClient, not local/mock extraction,
        // so the tool cannot label synthetic output as a cloud escalation.
        let gate = BrainGate(store: store, caller: { prompt, model, deadline in
            guard let openAIAuth else {
                throw InferenceError.providerUnavailable("memory escalation requires shared OpenAI auth")
            }
            let bridge = ModelClientBridge(
                modelClient: openAIAuth.modelClient,
                modelName: model,
                embeddings: nil,
                instructions: "Return only a JSON object matching the requested InsightCard schema.")
            let text = try await bridge.textCall()(prompt, deadline)
            return (text: text,
                    tokensIn: Self.estimatedTokenCount(prompt),
                    tokensOut: Self.estimatedTokenCount(text))
        })

        let toolset = MemoryToolset(store: store, retriever: retriever,
                                    inference: inference, personas: personas,
                                    gate: gate)
        let snapshotScheduler = SnapshotScheduler(store: store, archive: archive)
        _ = scorer
        return AssembledMemory(
            store: store, ring: ring, scheduler: scheduler,
            inference: inference, processor: processor,
            retriever: retriever, scorer: scorer,
            personas: personas, toolset: toolset,
            archive: archive, snapshotScheduler: snapshotScheduler)
    }

    private static func makeInference(openAIAuth: MemoryOpenAIAuth?,
                                      plan: MemoryInferencePlan,
                                      extractorModel: String,
                                      embeddingModel: String,
                                      embeddingEndpoint: String,
                                      storeConfig: MemoryStoreConfig)
    -> any LocalInferenceProvider {
        let env = ProcessInfo.processInfo.environment
        // Concurrent in-flight extract calls. Default 4 (on-device GPU); raise
        // for the remote/split path where overlapping network calls is the win.
        let extractInFlight = env["CODEX_MEMORY_EXTRACT_INFLIGHT"].flatMap(Int.init) ?? 4
        let inferenceConfig = MemoryInferConfig(
            embeddingDimension: storeConfig.embeddingDimension,
            extractInFlight: max(1, extractInFlight))
        switch plan.backend {
        case .local:
            let localProvider = BoundedInferenceProvider(
                MLXLocalProvider(embeddingDimension: storeConfig.embeddingDimension),
                config: inferenceConfig)
            // Split: keep nomic embeddings LOCAL (store stays consistent) but
            // run extraction/contextualise on the faster REMOTE provider.
            if env["CODEX_MEMORY_SPLIT_REMOTE_EXTRACT"] == "1", let openAIAuth {
                let bridge = ModelClientBridge(
                    modelClient: openAIAuth.modelClient,
                    modelName: extractorModel,
                    embeddings: ModelClientBridge.EmbeddingsEndpoint(
                        url: embeddingEndpoint, apiKey: "",
                        authProvider: openAIAuth.embeddingAuthProvider,
                        model: embeddingModel, dimensions: storeConfig.embeddingDimension))
                let remoteExtractor = BoundedInferenceProvider(
                    bridge.makeProvider(embeddingDimension: storeConfig.embeddingDimension),
                    config: inferenceConfig)
                return SplitInferenceProvider(embedder: localProvider, extractor: remoteExtractor)
            }
            return localProvider
        case .remote:
            guard let openAIAuth else {
                return BoundedInferenceProvider(
                    MockInferenceProvider(embeddingDimension: storeConfig.embeddingDimension),
                    config: inferenceConfig)
            }
            let bridge = ModelClientBridge(
                modelClient: openAIAuth.modelClient,
                modelName: extractorModel,
                embeddings: ModelClientBridge.EmbeddingsEndpoint(
                    url: embeddingEndpoint,
                    apiKey: "",
                    authProvider: openAIAuth.embeddingAuthProvider,
                    model: embeddingModel,
                    dimensions: storeConfig.embeddingDimension))
            return BoundedInferenceProvider(
                bridge.makeProvider(embeddingDimension: storeConfig.embeddingDimension),
                config: inferenceConfig)
        case .mock:
            return BoundedInferenceProvider(
                MockInferenceProvider(embeddingDimension: storeConfig.embeddingDimension),
                config: inferenceConfig)
        }
    }

    private static func resolveInferencePlan(env: [String: String],
                                             openAIAuth: MemoryOpenAIAuth?,
                                             embeddingModel: String,
                                             embeddingEndpoint: String) -> MemoryInferencePlan {
        let requested = MemoryInferenceBackend.parse(env["CODEX_MEMORY_INFERENCE_BACKEND"])
        func local() -> MemoryInferencePlan {
            MemoryInferencePlan(
                backend: .local,
                providerID: "local-mlx:qwen3-30b-a3b+nomic-embed-text-v1.5:padded-\(memoryEmbeddingDimension)")
        }
        func remote() -> MemoryInferencePlan {
            MemoryInferencePlan(
                backend: .remote,
                providerID: "remote-openai-compatible:\(embeddingModel):\(memoryEmbeddingDimension):\(embeddingEndpoint)")
        }
        func mock() -> MemoryInferencePlan {
            MemoryInferencePlan(backend: .mock, providerID: "mock:\(memoryEmbeddingDimension)")
        }

        switch requested {
        case .mock:
            return mock()
        case .remote:
            return openAIAuth != nil ? remote() : (MLXLocalProvider.isAvailable(env: env) ? local() : mock())
        case .local:
            return MLXLocalProvider.isAvailable(env: env) ? local() : mock()
        case .auto:
            return MLXLocalProvider.isAvailable(env: env) ? local() : (openAIAuth != nil ? remote() : mock())
        }
    }

    private static func estimatedTokenCount(_ text: String) -> Int {
        max(1, (text.utf8.count + 3) / 4)
    }

    private static func resolveOpenAIAuth(env: [String: String],
                                          codexHome: String) async -> MemoryOpenAIAuth? {
        let limits = Limits()
        if let apiKey = env["OPENAI_API_KEY"], !apiKey.isEmpty {
            return MemoryOpenAIAuth(
                modelClient: OpenAIResponsesClient(apiKey: apiKey, limits: limits),
                embeddingAuthProvider: .staticToken(apiKey))
        }
        if let brokerAuth = brokerAuthClient(codexHome: codexHome),
           let token = await brokerAuth.validAccessToken() {
            return MemoryOpenAIAuth(
                modelClient: AuthRefreshingModelClient(
                    initial: OpenAIResponsesClient(apiKey: token, limits: limits),
                    refreshToken: { await brokerAuth.refreshAccessToken() },
                    makeClient: { OpenAIResponsesClient(apiKey: $0, limits: limits) }),
                embeddingAuthProvider: ModelClientBridge.BearerTokenProvider(
                    accessToken: { await brokerAuth.validAccessToken() },
                    refreshToken: { await brokerAuth.refreshAccessToken() }))
        }
        let authStoreMode = AuthCredentialsStoreMode.parse(
            ConfigLoader(codexHome: codexHome).load()
                .value("cli_auth_credentials_store")?.stringValue)
        let authManager = AuthManager(
            store: TokenStoreFactory.production(codexHome: codexHome, mode: authStoreMode),
            apiKeyExchanger: CurlAPIKeyExchanger(),
            revoker: CurlTokenRevoker())
        guard let token = await authManager.validAccessToken() else { return nil }
        return MemoryOpenAIAuth(
            modelClient: AuthRefreshingModelClient(
                initial: OpenAIResponsesClient(apiKey: token, limits: limits),
                refreshToken: { await authManager.refreshAccessToken() },
                makeClient: { OpenAIResponsesClient(apiKey: $0, limits: limits) }),
            embeddingAuthProvider: ModelClientBridge.BearerTokenProvider(
                accessToken: { await authManager.validAccessToken() },
                refreshToken: { await authManager.refreshAccessToken() }))
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
}
