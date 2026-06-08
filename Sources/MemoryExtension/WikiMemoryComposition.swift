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

/// Session-level auth source for the wiki's OpenAI-compatible embeddings path.
/// Text inference already routes through the injected `ModelClient`; this keeps
/// the embeddings bridge on the same API-key/ChatGPT-login credential source.
public struct WikiMemoryAuthProvider: Sendable {
    let bridge: ModelClientBridge.BearerTokenProvider

    public init(accessToken: @escaping @Sendable () async -> String?,
                refreshToken: @escaping @Sendable () async -> String?) {
        self.bridge = ModelClientBridge.BearerTokenProvider(
            accessToken: accessToken,
            refreshToken: refreshToken)
    }

    public static func staticToken(_ token: String) -> WikiMemoryAuthProvider {
        WikiMemoryAuthProvider(accessToken: { token }, refreshToken: { token })
    }
}

public enum WikiInferenceBackend: String, Sendable, Equatable {
    case auto
    case local
    case remote
    case mock

    static func parse(_ raw: String?) -> WikiInferenceBackend? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto": return .auto
        case "local", "mlx", "mlx_local": return .local
        case "remote", "openai": return .remote
        case "mock", "offline": return .mock
        default: return nil
        }
    }
}

/// Configuration knobs for the wiki provider, read from `[memory]` (TOML/JSON
/// `Config`). Everything is optional with sane defaults; the only thing that
/// changes recall *quality* is whether a real embeddings endpoint is reachable
/// (see `embeddingsURL` / `embeddingsAPIKey`) or the composition root passes a
/// shared OpenAI auth provider. Absent either, the provider still builds and
/// answers — it falls back to `MockInferenceProvider`, whose embeddings are
/// deterministic but semantically weak (documented blocker).
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
    /// Inference backend policy. `auto` prefers local MLX (Qwen + Nomic), then
    /// remote OpenAI-compatible, then mock. Explicit `local` never falls through
    /// to remote; if MLX is unavailable it uses mock so private memory stays
    /// local/offline.
    public var inferenceBackend: WikiInferenceBackend

    public init(dbPath: String? = nil,
                embeddingDimension: Int = memoryEmbeddingDimension,
                extractorModel: String = "gpt-5.4-mini",
                embeddingModel: String = "text-embedding-3-small",
                embeddingsURL: String? = nil,
                embeddingsAPIKey: String? = nil,
                inferenceBackend: WikiInferenceBackend = .auto) {
        self.dbPath = dbPath
        self.embeddingDimension = embeddingDimension
        self.extractorModel = extractorModel
        self.embeddingModel = embeddingModel
        self.embeddingsURL = embeddingsURL
        self.embeddingsAPIKey = embeddingsAPIKey
        self.inferenceBackend = inferenceBackend
    }

    /// Parse the `[memory]` table for the wiki knobs. Recognises:
    ///   [memory]
    ///   provider = "wiki"
    ///   db_path = "/path/to/memory.db"          # optional
    ///   embedding_dimension = 1536              # optional
    ///   extractor_model = "gpt-5.4-mini"        # optional
    ///   embedding_model = "text-embedding-3-small"
    ///   embeddings_url = "https://.../v1/embeddings"   # enables real recall
    ///   embeddings_api_key = "sk-..."           # optional (env may override)
    ///   inference_backend = "auto"              # auto/local/remote/mock
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
        if let b = WikiInferenceBackend.parse(mem["inference_backend"]?.stringValue) {
            out.inferenceBackend = b
        } else if let b = WikiInferenceBackend.parse(env["CODEX_MEMORY_INFERENCE_BACKEND"]) {
            out.inferenceBackend = b
        }
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
                                   env: [String: String] = ProcessInfo.processInfo.environment,
                                   authProvider: WikiMemoryAuthProvider? = nil)
-> WikiMemoryProvider? {
    let wiki = WikiMemoryConfig.fromConfig(config, env: env)
    return makeWikiMemoryProvider(wiki: wiki,
                                  modelClient: modelClient,
                                  env: env,
                                  authProvider: authProvider)
}

/// Construction core, factored out so tests can drive it with an explicit
/// `WikiMemoryConfig` (e.g. a temp DB path) without going through TOML parsing.
public func makeWikiMemoryProvider(wiki: WikiMemoryConfig,
                                   modelClient: any ModelClient,
                                   env: [String: String] = ProcessInfo.processInfo.environment,
                                   authProvider: WikiMemoryAuthProvider? = nil) -> WikiMemoryProvider? {
    let plan = resolveInferencePlan(wiki: wiki, authProvider: authProvider, env: env)
    // Open the SQLite store. A missing/locked/corrupt DB must NOT crash the
    // session — return nil so `selectMemoryProvider` (or the caller's
    // compactMap) falls through to the next candidate.
    let storeConfig = MemoryStoreConfig(
        path: wiki.dbPath ?? MemoryStoreConfig.defaultPath(),
        embeddingDimension: wiki.embeddingDimension,
        embeddingProviderID: plan.providerID)
    guard let store = try? MemoryStore(storeConfig) else { return nil }

    let inference = makeInference(wiki: wiki, plan: plan, modelClient: modelClient,
                                  storeConfig: storeConfig,
                                  authProvider: authProvider)
    let retriever = MemoryRetriever(store: store, inference: inference)
    // Personas live in `[memory.personas.*]`; fall back to the five defaults.
    let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? (NSHomeDirectory() + "/.codex")
    let personas = PersonaState.load(codexHome: codexHome)

    // BrainGate is the explicit spend-gated escalation path. It must not pretend
    // local/mock extraction is a GPT escalation, so it asks the shared session
    // ModelClient for the exact model BrainGate admitted and lets BrainGate fail
    // closed on unparseable output.
    let gate = BrainGate(store: store, caller: { prompt, model, deadline in
        let bridge = ModelClientBridge(
            modelClient: modelClient,
            modelName: model,
            embeddings: nil,
            instructions: "Return only a JSON object matching the requested InsightCard schema.")
        let text = try await bridge.textCall()(prompt, deadline)
        return (text: text,
                tokensIn: estimatedTokenCount(prompt),
                tokensOut: estimatedTokenCount(text))
    })

    let toolset = MemoryToolset(store: store, retriever: retriever,
                                inference: inference, personas: personas,
                                gate: gate)
    return WikiMemoryProvider(retriever: retriever, tools: toolset.tools())
}

private enum ResolvedWikiInferenceBackend {
    case local
    case remote(url: String)
    case mock
}

private struct WikiInferencePlan {
    var backend: ResolvedWikiInferenceBackend
    var providerID: String
}

private func resolveInferencePlan(wiki: WikiMemoryConfig,
                                  authProvider: WikiMemoryAuthProvider?,
                                  env: [String: String]) -> WikiInferencePlan {
    let defaultEmbeddingsURL = "https://api.openai.com/v1/embeddings"
    let configuredAPIKey = !(wiki.embeddingsAPIKey?.isEmpty ?? true)
    let remoteURL = wiki.embeddingsURL
        ?? ((authProvider != nil || configuredAPIKey) ? defaultEmbeddingsURL : nil)
    let canUseRemote = remoteURL != nil

    func localPlan() -> WikiInferencePlan {
        WikiInferencePlan(
            backend: .local,
            providerID: "local-mlx:qwen3-30b-a3b+nomic-embed-text-v1.5:padded-\(wiki.embeddingDimension)")
    }
    func remotePlan(_ url: String) -> WikiInferencePlan {
        WikiInferencePlan(
            backend: .remote(url: url),
            providerID: "remote-openai-compatible:\(wiki.embeddingModel):\(wiki.embeddingDimension):\(url)")
    }
    func mockPlan() -> WikiInferencePlan {
        WikiInferencePlan(backend: .mock, providerID: "mock:\(wiki.embeddingDimension)")
    }

    switch wiki.inferenceBackend {
    case .mock:
        return mockPlan()
    case .remote:
        if let remoteURL { return remotePlan(remoteURL) }
        return MLXLocalProvider.isAvailable(env: env) ? localPlan() : mockPlan()
    case .local:
        if MLXLocalProvider.isAvailable(env: env) { return localPlan() }
        return mockPlan()
    case .auto:
        if MLXLocalProvider.isAvailable(env: env) { return localPlan() }
        if let remoteURL, canUseRemote { return remotePlan(remoteURL) }
        return mockPlan()
    }
}

private func estimatedTokenCount(_ text: String) -> Int {
    max(1, (text.utf8.count + 3) / 4)
}

/// Pick the inference backend. `auto` resolves to local MLX first (Qwen text
/// tasks + dedicated Nomic embeddings), then remote OpenAI-compatible, then
/// mock. Both real and mock providers are wrapped in `BoundedInferenceProvider`
/// so deadlines/cancellation are honoured on the turn hot path.
private func makeInference(wiki: WikiMemoryConfig,
                           plan: WikiInferencePlan,
                           modelClient: any ModelClient,
                           storeConfig: MemoryStoreConfig,
                           authProvider: WikiMemoryAuthProvider?)
-> any LocalInferenceProvider {
    let inferenceConfig = MemoryInferConfig(
        embeddingDimension: storeConfig.embeddingDimension)
    switch plan.backend {
    case .local:
        return BoundedInferenceProvider(
            MLXLocalProvider(embeddingDimension: storeConfig.embeddingDimension),
            config: inferenceConfig)
    case .remote(let url):
        let bridge = ModelClientBridge(
            modelClient: modelClient,
            modelName: wiki.extractorModel,
            embeddings: ModelClientBridge.EmbeddingsEndpoint(
                url: url,
                apiKey: wiki.embeddingsAPIKey ?? "",
                authProvider: authProvider?.bridge,
                model: wiki.embeddingModel,
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
