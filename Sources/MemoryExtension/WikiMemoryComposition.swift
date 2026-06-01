import Foundation
import Config
import MemoryInfer
import MemoryMCP
import MemoryRetrieve
import MemoryScore
import MemoryStore
import ModelClient
import Tools
// NOTE: deliberately NOT `import HarnessCore` here. HarnessCore also exports a
// type named `MemoryStore` (the `.md` keyword store), which would clash with
// the `MemoryStore` *module* (the SQLite wiki store) and make every
// `MemoryStore.MemoryStoreConfig` qualified reference ambiguous. This file only
// constructs `WikiMemoryProvider` (same module) + the Memory* read stack, none
// of which needs HarnessCore directly.

// Phase 1, impl #1 wiring (docs/extensions/ARCHITECTURE.md §7.1 + §12 deferred):
// the composition-root factory for the vector "Memory Wiki" `MemoryProvider`.
//
// `WikiMemoryProvider` already exists and maps `RetrievedHit → MemorySnippet`;
// what was deferred is the *construction* of its read stack at the executable
// root. This file lifts the store/inference/retriever/gate/toolset assembly
// from `codex-memory`'s `Run.swift` `assemble()`/`makeInference()` WITHOUT the
// curation pieces (SourceScheduler / CompositeFetcher / SnapshotScheduler /
// MemoryProcessor / MemoryArchive) — those belong to the host-wide
// `codex-memory` daemon, not to an agent session. The session only needs the
// *read* path (recall) plus the seven `memory.*` tools.
//
// Per D1 (§7.4): the wiki's own inference (BrainGate insight / extractor /
// embedder) is the first intended consumer of a *local* model rather than the
// agent's provider tokens. So `makeWikiMemoryProvider` accepts the session's
// `ModelClient` and routes BrainGate's escalation `caller` (and the extractor)
// through it via `ModelClientBridge`. The composition root may pass a local
// SmallModel-backed client here instead of the provider client to honour D1;
// the seam is the injected `ModelClient`, so this file stays endpoint-agnostic.

/// Configuration knobs for the wiki provider, read from `[memory]` (TOML/JSON
/// `Config`). Everything is optional with sane defaults; the only thing that
/// changes recall *quality* is whether a real embeddings endpoint is reachable
/// (see `embeddingsURL` / `embeddingsAPIKey`). Absent an endpoint the provider
/// still builds and answers — it falls back to `MockInferenceProvider`, whose
/// embeddings are deterministic but semantically weak (documented blocker).
public struct WikiMemoryConfig: Sendable, Equatable {
    /// SQLite DB path. Defaults to `MemoryStoreConfig.defaultPath()` (the same
    /// host-global DB the `codex-memory` daemon writes), so an agent session
    /// recalls against the curated wiki rather than a private empty DB.
    public var dbPath: String?
    /// Embedding vector dimensionality (must match the stored vectors).
    public var embeddingDimension: Int
    /// Model id used for the BrainGate/extractor text calls (through the
    /// injected `ModelClient`).
    public var extractorModel: String
    /// Embeddings model id sent to `embeddingsURL`.
    public var embeddingModel: String
    /// OpenAI-compatible `/v1/embeddings` endpoint. When nil the inference
    /// backend falls back to the deterministic mock (no network).
    public var embeddingsURL: String?
    /// API key for `embeddingsURL`. When nil but `embeddingsURL` is set, the
    /// endpoint is assumed key-less (e.g. a local server); the bridge sends an
    /// empty bearer.
    public var embeddingsAPIKey: String?

    public init(dbPath: String? = nil,
                embeddingDimension: Int = memoryEmbeddingDimension,
                extractorModel: String = "gpt-5.4-mini",
                embeddingModel: String = "text-embedding-3-small",
                embeddingsURL: String? = nil,
                embeddingsAPIKey: String? = nil) {
        self.dbPath = dbPath
        self.embeddingDimension = embeddingDimension
        self.extractorModel = extractorModel
        self.embeddingModel = embeddingModel
        self.embeddingsURL = embeddingsURL
        self.embeddingsAPIKey = embeddingsAPIKey
    }

    /// Parse the `[memory]` table for the wiki knobs. Recognises:
    ///   [memory]
    ///   provider = "wiki"
    ///   db_path = "/path/to/memory.db"          # optional
    ///   embedding_dimension = 768               # optional
    ///   extractor_model = "gpt-5.4-mini"        # optional
    ///   embedding_model = "text-embedding-3-small"
    ///   embeddings_url = "https://.../v1/embeddings"   # enables real recall
    ///   embeddings_api_key = "sk-..."           # optional (env may override)
    /// Falls back to env (`CODEX_MEMORY_*`, `OPENAI_API_KEY`) for the
    /// embeddings endpoint/key so an operator can keep secrets out of the TOML,
    /// mirroring `codex-memory`'s `assemble()`.
    public static func fromConfig(_ config: Config,
                                  env: [String: String] = ProcessInfo.processInfo.environment)
    -> WikiMemoryConfig {
        let mem = config.value("memory")?.objectValue ?? [:]
        var out = WikiMemoryConfig()
        if let p = mem["db_path"]?.stringValue, !p.isEmpty { out.dbPath = p }
        else if let p = env["CODEX_MEMORY_DB"], !p.isEmpty { out.dbPath = p }
        if let d = mem["embedding_dimension"]?.intValue, d > 0 { out.embeddingDimension = Int(d) }
        if let m = mem["extractor_model"]?.stringValue, !m.isEmpty { out.extractorModel = m }
        else if let m = env["CODEX_MEMORY_EXTRACTOR_MODEL"], !m.isEmpty { out.extractorModel = m }
        if let m = mem["embedding_model"]?.stringValue, !m.isEmpty { out.embeddingModel = m }
        else if let m = env["CODEX_MEMORY_EMBEDDING_MODEL"], !m.isEmpty { out.embeddingModel = m }
        if let u = mem["embeddings_url"]?.stringValue, !u.isEmpty { out.embeddingsURL = u }
        else if let u = env["CODEX_MEMORY_EMBEDDINGS_URL"], !u.isEmpty { out.embeddingsURL = u }
        if let k = mem["embeddings_api_key"]?.stringValue, !k.isEmpty { out.embeddingsAPIKey = k }
        else if let k = env["OPENAI_API_KEY"], !k.isEmpty { out.embeddingsAPIKey = k }
        return out
    }
}

/// Build the wiki `MemoryProvider` for the composition root, or `nil` when the
/// SQLite store cannot be opened (degrade to the next candidate — the root must
/// never crash a session because the optional wiki DB is missing/corrupt).
///
/// - Parameters:
///   - config: the session `Config` (the `[memory]` table is parsed here).
///   - modelClient: the session's `ModelClient`, reused for the wiki's text
///     inference (BrainGate / extractor) per D1. Pass a local SmallModel-backed
///     client to keep those calls off provider tokens.
///   - env: process environment (injectable for tests).
public func makeWikiMemoryProvider(config: Config,
                                   modelClient: any ModelClient,
                                   env: [String: String] = ProcessInfo.processInfo.environment)
-> WikiMemoryProvider? {
    let wiki = WikiMemoryConfig.fromConfig(config, env: env)
    return makeWikiMemoryProvider(wiki: wiki, modelClient: modelClient)
}

/// Construction core, factored out so tests can drive it with an explicit
/// `WikiMemoryConfig` (e.g. a temp DB path) without going through TOML parsing.
public func makeWikiMemoryProvider(wiki: WikiMemoryConfig,
                                   modelClient: any ModelClient) -> WikiMemoryProvider? {
    // Open the SQLite store. A missing/locked/corrupt DB must NOT crash the
    // session — return nil so `selectMemoryProvider` (or the caller's
    // compactMap) falls through to the next candidate.
    let storeConfig = MemoryStoreConfig(
        path: wiki.dbPath ?? MemoryStoreConfig.defaultPath(),
        embeddingDimension: wiki.embeddingDimension)
    guard let store = try? MemoryStore(storeConfig) else { return nil }

    let inference = makeInference(wiki: wiki, modelClient: modelClient,
                                  storeConfig: storeConfig)
    let retriever = MemoryRetriever(store: store, inference: inference)
    // Personas live in `[memory.personas.*]`; fall back to the five defaults.
    let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? (NSHomeDirectory() + "/.codex")
    let personas = PersonaState.load(codexHome: codexHome)

    // BrainGate escalation routes through the same inference backend (so a
    // local model can serve insight per D1). When the backend is the mock, the
    // call still succeeds with a synthetic card rather than failing the tool —
    // matching `codex-memory`'s `assemble()` shape.
    let gate = BrainGate(store: store, caller: { prompt, _, deadline in
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
    return WikiMemoryProvider(retriever: retriever, tools: toolset.tools())
}

/// Pick the inference backend. When an embeddings endpoint is configured we
/// wrap the injected `ModelClient` (text) + a curl `/v1/embeddings` bridge
/// (vectors) in a `RemoteOpenAICompatibleProvider`; otherwise we fall back to
/// `MockInferenceProvider` (deterministic but semantically weak — see the
/// `externallyBlocked` note). Both are wrapped in `BoundedInferenceProvider`
/// so deadlines/cancellation are honoured on the turn hot path.
private func makeInference(wiki: WikiMemoryConfig,
                           modelClient: any ModelClient,
                           storeConfig: MemoryStoreConfig)
-> any LocalInferenceProvider {
    let inferenceConfig = MemoryInferConfig(
        embeddingDimension: storeConfig.embeddingDimension)
    if let url = wiki.embeddingsURL, !url.isEmpty {
        let bridge = ModelClientBridge(
            modelClient: modelClient,
            modelName: wiki.extractorModel,
            embeddings: ModelClientBridge.EmbeddingsEndpoint(
                url: url,
                apiKey: wiki.embeddingsAPIKey ?? "",
                model: wiki.embeddingModel,
                dimensions: storeConfig.embeddingDimension))
        return BoundedInferenceProvider(
            bridge.makeProvider(embeddingDimension: storeConfig.embeddingDimension),
            config: inferenceConfig)
    }
    return BoundedInferenceProvider(
        MockInferenceProvider(embeddingDimension: storeConfig.embeddingDimension),
        config: inferenceConfig)
}
