import XCTest
import Config
import ModelClient
import Tools
@testable import MemoryExtension
@testable import HarnessCore

/// DEFERRED ITEM 4 wiring tests: `makeWikiMemoryProvider` (composition-root
/// factory) + the candidate-selection logic the two roots use to pick the
/// active `MemoryProvider`. Fully deterministic — the wiki stack is built over
/// a temp SQLite DB and a `MockModelClient` (no network, no embeddings
/// endpoint, so inference falls back to the deterministic mock provider).
///
/// NOTE: this file deliberately does NOT `import MemoryStore` (the module),
/// because `@testable import HarnessCore` already brings a *type* named
/// `MemoryStore` (the `.md` keyword store) into scope, and the two would
/// clash. The factory owns the SQLite store internally; the test only needs a
/// temp `dbPath` string.
final class WikiMemoryCompositionTests: XCTestCase {

    private func tempDBPath() -> String {
        NSTemporaryDirectory() + "wiki-comp-\(UUID().uuidString).db"
    }

    private func cleanup(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// A `MockModelClient` is sufficient for the wiki's text inference — with
    /// no embeddings endpoint the factory uses the mock inference provider, so
    /// the model client is never actually called during these tests.
    private func mockModel() -> any ModelClient {
        MockModelClient(repeating: .hello("ok"), times: 8)
    }

    // MARK: - factory: builds a provider with the MemoryToolset

    func testFactoryBuildsProviderWithToolsetAndWikiId() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        // No embeddingsURL → mock inference backend (deterministic, no network).
        let cfg = WikiMemoryConfig(dbPath: db, inferenceBackend: .mock)
        guard let provider = makeWikiMemoryProvider(wiki: cfg, modelClient: mockModel()) else {
            return XCTFail("makeWikiMemoryProvider returned nil for a fresh temp DB")
        }
        // Slot id must match the selection key.
        XCTAssertEqual(provider.id, "wiki")
        // The wiki MCP tools must be surfaced through tools().
        XCTAssertEqual(provider.tools().count, 11,
                       "wiki provider must expose the full MemoryToolset")
        // Every tool has a non-empty name (sanity — they are registered on the
        // router by name at the composition root).
        for t in provider.tools() {
            XCTAssertFalse(t.name.isEmpty)
        }
    }

    /// Recall on a fresh (empty) wiki DB returns no snippets, and crucially
    /// never throws into the engine (the degrade-to-empty contract on the turn
    /// hot path).
    func testRecallOnEmptyDBDegradesToEmpty() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        guard let provider = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db, inferenceBackend: .mock),
                                                    modelClient: mockModel()) else {
            return XCTFail("factory returned nil")
        }
        let snippets = await provider.recall("anything at all", limit: 5)
        XCTAssertTrue(snippets.isEmpty)
    }

    /// An empty query short-circuits inside the retriever (no embedding call,
    /// no FTS MATCH) and returns empty — exercised through the provider.
    func testRecallEmptyQueryReturnsEmpty() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        guard let provider = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db, inferenceBackend: .mock),
                                                    modelClient: mockModel()) else {
            return XCTFail("factory returned nil")
        }
        let snippets = await provider.recall("   ", limit: 5)
        XCTAssertTrue(snippets.isEmpty)
    }

    func testExplicitLocalBackendDoesNotFallThroughToRemoteWhenUnavailable() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        let cfg = WikiMemoryConfig(
            dbPath: db,
            embeddingsURL: "http://127.0.0.1:9/v1/embeddings",
            embeddingsAPIKey: "sk-should-not-be-used",
            inferenceBackend: .local)
        guard let provider = makeWikiMemoryProvider(
            wiki: cfg,
            modelClient: mockModel(),
            env: ["CODEXKIT_MLX": "0"]) else {
            return XCTFail("factory returned nil")
        }
        let tool = try XCTUnwrap(provider.tools().first { $0.name == "memory_hybrid_search" })
        let result = try await tool.run(
            ToolCall(callId: "hybrid", name: tool.name,
                     argumentsJSON: #"{"query":"agent memory","k":3}"#),
            cwd: "/")
        XCTAssertTrue(result.success, result.output)
    }

    func testEscalationDoesNotFabricateSyntheticInsightFromMockInference() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        guard let provider = makeWikiMemoryProvider(
            wiki: WikiMemoryConfig(dbPath: db, inferenceBackend: .mock),
            modelClient: mockModel()) else {
            return XCTFail("factory returned nil")
        }
        let tool = try XCTUnwrap(provider.tools().first { $0.name == "memory_escalate_to_brain" })
        let result = try await tool.run(
            ToolCall(callId: "brain", name: tool.name,
                     argumentsJSON: #"{"question":"what changed?","reason":"test"}"#),
            cwd: "/")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("unparseable") || result.output.contains("admitted\":false"),
                      result.output)
    }

    // MARK: - candidate selection (the exact composition-root logic)

    private func configWith(provider: String?) -> Config {
        var memory: [String: ConfigValue] = [:]
        if let provider { memory["provider"] = .string(provider) }
        let layer = ConfigLayer(name: "test", values: ["memory": .object(memory)])
        return Config(layers: [layer])
    }

    /// When `[memory].provider == "wiki"`, the wiki candidate wins the slot.
    func testSelectionPicksWikiWhenConfigured() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        guard let wiki = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db, inferenceBackend: .mock),
                                                modelClient: mockModel()) else {
            return XCTFail("factory returned nil")
        }
        let core = CoreMemoriesProvider(store: MemoryStore(codexHome: NSTemporaryDirectory()))
        let chosen = selectMemoryProvider(config: configWith(provider: "wiki"),
                                          candidates: [core, wiki])
        XCTAssertEqual(chosen?.id, "wiki")
    }

    /// When `[memory].provider == "core"`, the core candidate wins even though
    /// the wiki candidate is present (mirrors the root's candidate list order).
    func testSelectionPicksCoreWhenConfigured() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        guard let wiki = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db, inferenceBackend: .mock),
                                                modelClient: mockModel()) else {
            return XCTFail("factory returned nil")
        }
        let core = CoreMemoriesProvider(store: MemoryStore(codexHome: NSTemporaryDirectory()))
        let chosen = selectMemoryProvider(config: configWith(provider: "core"),
                                          candidates: [core, wiki])
        XCTAssertEqual(chosen?.id, "core")
    }

    /// "none" disables recall; an absent provider now means "mem0 default",
    /// with core fallback if the mem0 candidate is not available.
    func testSelectionNoneDisablesAndAbsentFallsBackToCore() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        guard let wiki = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db, inferenceBackend: .mock),
                                                modelClient: mockModel()) else {
            return XCTFail("factory returned nil")
        }
        let core = CoreMemoriesProvider(store: MemoryStore(codexHome: NSTemporaryDirectory()))
        XCTAssertNil(selectMemoryProvider(config: configWith(provider: "none"),
                                          candidates: [core, wiki]))
        XCTAssertEqual(selectMemoryProvider(config: configWith(provider: nil),
                                            candidates: [core, wiki])?.id, "core")
    }

    /// An unknown provider id selects nothing (no surprise activation).
    func testSelectionUnknownProviderDisables() async throws {
        let core = CoreMemoriesProvider(store: MemoryStore(codexHome: NSTemporaryDirectory()))
        XCTAssertNil(selectMemoryProvider(config: configWith(provider: "does-not-exist"),
                                          candidates: [core]))
    }

    // MARK: - config parsing

    func testFromConfigParsesMemoryTable() {
        let layer = ConfigLayer(name: "test", values: ["memory": .object([
            "provider": .string("wiki"),
            "db_path": .string("/tmp/custom.db"),
            "embedding_dimension": .int(1536),
            "extractor_model": .string("local-extractor"),
            "embedding_model": .string("local-embed"),
            "embeddings_url": .string("http://localhost:11434/v1/embeddings"),
            "embeddings_api_key": .string("local-key"),
            "inference_backend": .string("local"),
        ])])
        // Pass an empty env so env fallbacks don't shadow the TOML values
        // (e.g. a real OPENAI_API_KEY in the test runner's environment).
        let wiki = WikiMemoryConfig.fromConfig(Config(layers: [layer]), env: [:])
        XCTAssertEqual(wiki.dbPath, "/tmp/custom.db")
        XCTAssertEqual(wiki.embeddingDimension, 1536)
        XCTAssertEqual(wiki.extractorModel, "local-extractor")
        XCTAssertEqual(wiki.embeddingModel, "local-embed")
        XCTAssertEqual(wiki.embeddingsURL, "http://localhost:11434/v1/embeddings")
        XCTAssertEqual(wiki.embeddingsAPIKey, "local-key")
        XCTAssertEqual(wiki.inferenceBackend, .local)
    }

    /// Defaults hold when `[memory]` carries only `provider`, and env supplies
    /// the embeddings endpoint/key (the keep-secrets-out-of-TOML path).
    func testFromConfigEnvFallbacksForEmbeddings() {
        let layer = ConfigLayer(name: "test",
                                values: ["memory": .object(["provider": .string("wiki")])])
        let env = [
            "CODEX_MEMORY_EMBEDDINGS_URL": "https://api.example/v1/embeddings",
            "OPENAI_API_KEY": "sk-from-env",
        ]
        let wiki = WikiMemoryConfig.fromConfig(Config(layers: [layer]), env: env)
        XCTAssertNil(wiki.dbPath)                              // default DB path
        // Default embedding dimension is preserved (compare to the type's own
        // default so the test needn't import the `MemoryStore` module — which
        // would clash with HarnessCore's `MemoryStore` type).
        XCTAssertEqual(wiki.embeddingDimension, WikiMemoryConfig().embeddingDimension)
        XCTAssertEqual(wiki.embeddingsURL, "https://api.example/v1/embeddings")
        XCTAssertEqual(wiki.embeddingsAPIKey, "sk-from-env")
        XCTAssertEqual(wiki.inferenceBackend, .auto)
    }

    /// TOML values take precedence over env for the embeddings endpoint/key.
    func testFromConfigTOMLBeatsEnvForEmbeddings() {
        let layer = ConfigLayer(name: "test", values: ["memory": .object([
            "provider": .string("wiki"),
            "embeddings_url": .string("https://toml/v1/embeddings"),
            "embeddings_api_key": .string("toml-key"),
        ])])
        let env = [
            "CODEX_MEMORY_EMBEDDINGS_URL": "https://env/v1/embeddings",
            "OPENAI_API_KEY": "sk-env",
        ]
        let wiki = WikiMemoryConfig.fromConfig(Config(layers: [layer]), env: env)
        XCTAssertEqual(wiki.embeddingsURL, "https://toml/v1/embeddings")
        XCTAssertEqual(wiki.embeddingsAPIKey, "toml-key")
    }
}
