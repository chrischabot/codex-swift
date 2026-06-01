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

    // MARK: - factory: builds a provider with the 7-tool MemoryToolset

    func testFactoryBuildsProviderWithToolsetAndWikiId() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        // No embeddingsURL → mock inference backend (deterministic, no network).
        let cfg = WikiMemoryConfig(dbPath: db)
        guard let provider = makeWikiMemoryProvider(wiki: cfg, modelClient: mockModel()) else {
            return XCTFail("makeWikiMemoryProvider returned nil for a fresh temp DB")
        }
        // Slot id must match the selection key.
        XCTAssertEqual(provider.id, "wiki")
        // The seven `memory.*` MCP tools must be surfaced through tools().
        XCTAssertEqual(provider.tools().count, 7,
                       "wiki provider must expose the full MemoryToolset (7 tools)")
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
        guard let provider = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db),
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
        guard let provider = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db),
                                                    modelClient: mockModel()) else {
            return XCTFail("factory returned nil")
        }
        let snippets = await provider.recall("   ", limit: 5)
        XCTAssertTrue(snippets.isEmpty)
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
        guard let wiki = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db),
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
        guard let wiki = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db),
                                                modelClient: mockModel()) else {
            return XCTFail("factory returned nil")
        }
        let core = CoreMemoriesProvider(store: MemoryStore(codexHome: NSTemporaryDirectory()))
        let chosen = selectMemoryProvider(config: configWith(provider: "core"),
                                          candidates: [core, wiki])
        XCTAssertEqual(chosen?.id, "core")
    }

    /// "none" and an absent provider both disable recall (nil), even with both
    /// candidates registered.
    func testSelectionNoneAndAbsentDisable() async throws {
        let db = tempDBPath()
        defer { cleanup(db) }
        guard let wiki = makeWikiMemoryProvider(wiki: WikiMemoryConfig(dbPath: db),
                                                modelClient: mockModel()) else {
            return XCTFail("factory returned nil")
        }
        let core = CoreMemoriesProvider(store: MemoryStore(codexHome: NSTemporaryDirectory()))
        XCTAssertNil(selectMemoryProvider(config: configWith(provider: "none"),
                                          candidates: [core, wiki]))
        XCTAssertNil(selectMemoryProvider(config: configWith(provider: nil),
                                          candidates: [core, wiki]))
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
