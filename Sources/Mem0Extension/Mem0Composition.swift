import Foundation
import Config
import Mem0Local
import Tools
import Mem0Core
import Mem0Store

// Composition-root factory for the native mem0 `MemoryProvider`, mirroring
// `makeWikiMemoryProvider`. Builds the self-contained engine (SQLite store +
// local, OpenAI-compatible, or mock providers) in-process for recall/capture.
// Returns `nil` when the SQLite store cannot be opened, so the root degrades to
// the next candidate rather than crashing a session.

/// Default host-global mem0 DB path under `$CODEX_HOME` (or `~/.codex`).
public func defaultMem0DBPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let home = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
    return home + "/mem0/mem0.db"
}

/// Build the mem0 provider from the session `Config` (parses `[memory.mem0]`).
public func makeMem0MemoryProvider(config: Config,
                                   env: [String: String] = ProcessInfo.processInfo.environment,
                                   authProvider: Mem0SessionAuthProvider? = nil)
-> Mem0MemoryProvider? {
    makeMem0MemoryProvider(mem0: Mem0ProviderConfig.fromConfig(config, env: env),
                           env: env,
                           authProvider: authProvider)
}

/// Construction core, factored out so tests can drive it with an explicit
/// `Mem0ProviderConfig` (e.g. a temp DB + mock providers).
public func makeMem0MemoryProvider(mem0: Mem0ProviderConfig,
                                   env: [String: String] = ProcessInfo.processInfo.environment,
                                   authProvider: Mem0SessionAuthProvider? = nil)
-> Mem0MemoryProvider? {
    let dbPath = mem0.dbPath ?? defaultMem0DBPath(env: env)
    if dbPath != ":memory:" {
        let dir = (dbPath as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
    // A missing/locked/corrupt DB must NOT crash the session — degrade to nil.
    guard let store = try? Mem0SQLiteStore(path: dbPath) else { return nil }

    let embedder: any Mem0Embedder
    let llm: any Mem0LLM

    let localAvailable = Mem0LocalRuntime.isAvailable(env: env)
    let remoteAvailable = mem0.useRealProviders || authProvider != nil
    let embeddingBackend = resolveBackend(mem0.embeddingBackend,
                                          localAvailable: localAvailable,
                                          remoteAvailable: remoteAvailable)
    let llmBackend = resolveBackend(mem0.llmBackend,
                                    localAvailable: localAvailable,
                                    remoteAvailable: remoteAvailable)
    let localProviders = (embeddingBackend == .local || llmBackend == .local)
        ? Mem0LocalRuntime.make(embeddingDimension: mem0.embeddingDimension)
        : nil

    switch embeddingBackend {
    case .local:
        if let localProviders {
            embedder = localProviders.embedder
        } else {
            embedder = MockEmbedder(dims: mem0.embeddingDimension)
        }
    case .remote:
        embedder = Mem0OpenAIEmbedder(baseURL: mem0.baseURL, apiKey: mem0.apiKey,
                                      model: mem0.embeddingModel, dims: mem0.embeddingDimension,
                                      sendDimensions: mem0.embeddingDimension != 1536,
                                      authProvider: authProvider?.core)
    case .mock:
        embedder = MockEmbedder(dims: mem0.embeddingDimension)
    }

    switch llmBackend {
    case .local:
        if let localProviders {
            llm = localProviders.llm
        } else {
            llm = MockLLM()
        }
    case .remote:
        llm = Mem0OpenAILLM(baseURL: mem0.baseURL, apiKey: mem0.apiKey, model: mem0.llmModel,
                            authProvider: authProvider?.core)
    case .mock:
        llm = MockLLM()
    }

    let engine = Mem0Engine(config: Mem0Config(historyDbPath: dbPath),
                            embedder: embedder, llm: llm,
                            vectorStore: store, historyStore: store)
    let scope = mem0.scope
    let tools: [any Tool] = [
        Mem0SearchTool(engine: engine, scope: scope, defaultLimit: mem0.topK),
        Mem0AddTool(engine: engine, scope: scope, infer: mem0.infer),
        Mem0ListTool(engine: engine, scope: scope, defaultLimit: mem0.topK),
        Mem0UpdateTool(engine: engine, scope: scope),
        Mem0DeleteTool(engine: engine, scope: scope),
        Mem0HistoryTool(engine: engine, scope: scope),
        Mem0PrivacyTool(engine: engine, scope: scope),
    ]
    return Mem0MemoryProvider(engine: engine, scope: scope, topK: mem0.topK, infer: mem0.infer, tools: tools)
}

private enum ResolvedMem0Backend: Equatable {
    case local
    case remote
    case mock
}

private func resolveBackend(_ requested: Mem0InferenceBackend,
                            localAvailable: Bool,
                            remoteAvailable: Bool) -> ResolvedMem0Backend {
    switch requested {
    case .mock:
        return .mock
    case .remote:
        if remoteAvailable { return .remote }
        return localAvailable ? .local : .mock
    case .local:
        if localAvailable { return .local }
        return .mock
    case .auto:
        if localAvailable { return .local }
        return remoteAvailable ? .remote : .mock
    }
}
