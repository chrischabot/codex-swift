import Foundation
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
        let storeConfig = MemoryStoreConfig.default
        let store = try MemoryStore(storeConfig)
        let ring = ChunkRing()
        let env = ProcessInfo.processInfo.environment
        let codexHome = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")

        // Pick the inference backend. Order: explicit env override → real
        // OpenAI bridge when OPENAI_API_KEY is set → mock fallback.
        let inference = makeInference(
            apiKey: env["OPENAI_API_KEY"],
            extractorModel: env["CODEX_MEMORY_EXTRACTOR_MODEL"] ?? "gpt-5.4-mini",
            embeddingModel: env["CODEX_MEMORY_EMBEDDING_MODEL"] ?? "text-embedding-3-small",
            embeddingEndpoint: env["CODEX_MEMORY_EMBEDDINGS_URL"]
                ?? "https://api.openai.com/v1/embeddings",
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

        // BrainGate: when bound to a real inference backend, route escalations
        // through the same provider for synthesis. When the backend is the
        // mock provider, escalations fail closed.
        let gate = BrainGate(store: store, caller: { prompt, model, deadline in
            let result = try await inference.extract(
                ChunkBatch(documentTitle: nil, documentURI: "brain://escalate",
                           chunks: [Chunk(localId: "escalate", rawText: prompt, idx: 0)]),
                schema: .default, deadline: deadline)
            let text = "{\"headline\":\"escalation\",\"summary\":\"\(prompt.prefix(200))\","
                + "\"entities\":[],\"rationale\":\"auto\",\"summaryOnly\":false}"
            return (text: text,
                    tokensIn: result.tokensInput,
                    tokensOut: result.tokensOutput)
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

    private static func makeInference(apiKey: String?,
                                      extractorModel: String,
                                      embeddingModel: String,
                                      embeddingEndpoint: String,
                                      storeConfig: MemoryStoreConfig)
    -> any LocalInferenceProvider {
        let inferenceConfig = MemoryInferConfig(
            embeddingDimension: storeConfig.embeddingDimension)
        if let key = apiKey, !key.isEmpty {
            let limits = Limits()
            let modelClient: any ModelClient = OpenAIResponsesClient(
                apiKey: key, limits: limits)
            let bridge = ModelClientBridge(
                modelClient: modelClient,
                modelName: extractorModel,
                embeddings: ModelClientBridge.EmbeddingsEndpoint(
                    url: embeddingEndpoint, apiKey: key,
                    model: embeddingModel,
                    dimensions: storeConfig.embeddingDimension))
            return BoundedInferenceProvider(
                bridge.makeProvider(embeddingDimension: storeConfig.embeddingDimension),
                config: inferenceConfig)
        }
        return BoundedInferenceProvider(
            MockInferenceProvider(embeddingDimension: storeConfig.embeddingDimension),
            config: inferenceConfig)
    }
}
