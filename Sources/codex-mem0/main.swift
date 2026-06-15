import Foundation
import Auth
import Config
import Mem0Core
import Mem0Local
import Mem0Store
#if os(macOS)
import EmbeddedPG
import Mem0PgStore
#endif

// codex-mem0 — the self-contained native mem0 server (analogous to the wiki's
// codex-memory daemon). Runs the in-project mem0 engine over a SQLite store and
// serves the mem0 REST API (parity with the Rust mem0-server) on a plain HTTP
// listener. Configuration is mostly via environment variables; shared Codex auth
// is consulted for remote fallback when explicit API-key env vars are absent:
//
//   CODEX_MEM0_DB              SQLite path (default $CODEX_HOME/mem0/mem0.db; ":memory:" ok)
//   CODEX_MEM0_HOST            bind host (default 127.0.0.1)
//   PORT / CODEX_MEM0_PORT     bind port (default 8080)
//   CODEX_MEM0_BASE_URL        OpenAI-compatible base (default https://api.openai.com/v1)
//   CODEX_MEM0_API_KEY / OPENAI_API_KEY   remote auth override
//   CODEX_MEM0_EMBEDDING_MODEL / _LLM_MODEL / _EMBEDDING_DIM
//   CODEX_MEM0_EMBEDDING_BACKEND          auto/local/remote/mock (default auto)
//   CODEX_MEM0_LLM_BACKEND                auto/local/remote/mock (default auto)
//
// Subcommands:  serve (default) | verify | import-jsonl <path>

@main
struct CodexMem0 {
    static func defaultDB(_ env: [String: String]) -> String {
        let home = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        return home + "/mem0/mem0.db"
    }

    /// Resolve the store backend (sqlite-vec default | embedded Postgres opt-in).
    /// Always degrades to the SQLite fallback on any unavailability/failure so the
    /// daemon never hard-fails on a misconfigured `CODEX_MEM0_STORE_BACKEND`.
    static func resolveStore(env: [String: String], dims: Int,
                             fallback: Mem0SQLiteStore) async -> any Mem0VectorStore & Mem0HistoryStore {
        let request = Mem0StoreBackendRequest.parse(env["CODEX_MEM0_STORE_BACKEND"])
        #if os(macOS)
        let pgAvailable = PGPaths.isAvailable(env: env)
        #else
        let pgAvailable = false
        #endif
        let resolved = Mem0StoreBackendResolver.resolve(request, postgresAvailable: pgAvailable)
        if Mem0StoreBackendResolver.didFallBack(request, resolved) {
            FileHandle.standardError.write(Data(
                "codex-mem0: store backend '\(request.rawValue)' unavailable; using sqlite-vec\n".utf8))
        }
        #if os(macOS)
        if resolved == .postgres, let paths = PGPaths.resolveDefault(env: env) {
            do {
                let lifecycle = PostgresLifecycle(paths: paths)
                let pg = try await Mem0PgVectorStore.open(paths: paths, dims: dims, lifecycle: lifecycle)
                FileHandle.standardError.write(Data(
                    "codex-mem0: embedded Postgres store ready (PGDATA \(paths.dataDir))\n".utf8))
                return pg
            } catch {
                FileHandle.standardError.write(Data(
                    "codex-mem0: embedded Postgres unavailable (\(error)); using sqlite-vec\n".utf8))
                return fallback
            }
        }
        #endif
        return fallback
    }

    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let sub = CommandLine.arguments.dropFirst().first ?? "serve"

        let dbPath = env["CODEX_MEM0_DB"] ?? defaultDB(env)
        if dbPath != ":memory:" {
            let dir = (dbPath as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
        let dims = Int(env["CODEX_MEM0_EMBEDDING_DIM"] ?? "") ?? 1536

        // SQLite + sqlite-vec is the default and the always-available fallback.
        // Select the embedded-Postgres (pgvector) store with
        // CODEX_MEM0_STORE_BACKEND=postgres (macOS only; pglite.md).
        guard let sqliteStore = try? Mem0SQLiteStore(path: dbPath) else {
            FileHandle.standardError.write(Data("codex-mem0: cannot open store at \(dbPath)\n".utf8))
            exit(1)
        }
        let store: any Mem0VectorStore & Mem0HistoryStore =
            await Self.resolveStore(env: env, dims: dims, fallback: sqliteStore)

        let baseURL = env["CODEX_MEM0_BASE_URL"] ?? "https://api.openai.com/v1"
        let apiKey = env["CODEX_MEM0_API_KEY"] ?? env["OPENAI_API_KEY"]
        let codexHome = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        let authProvider = await resolveOpenAIAuth(env: env, codexHome: codexHome)
        let remoteAvailable = (apiKey?.isEmpty == false)
            || authProvider != nil
            || baseURL != "https://api.openai.com/v1"
        let localAvailable = Mem0LocalRuntime.isAvailable(env: env)
        let embeddingBackend = Mem0BackendResolver.resolve(
            Mem0BackendRequest.parse(env["CODEX_MEM0_EMBEDDING_BACKEND"]),
            localAvailable: localAvailable,
            remoteAvailable: remoteAvailable)
        let llmBackend = Mem0BackendResolver.resolve(
            Mem0BackendRequest.parse(env["CODEX_MEM0_LLM_BACKEND"]),
            localAvailable: localAvailable,
            remoteAvailable: remoteAvailable)
        let localProviders = (embeddingBackend == .local || llmBackend == .local)
            ? Mem0LocalRuntime.make(embeddingDimension: dims)
            : nil

        let embedder: any Mem0Embedder
        switch embeddingBackend {
        case .local:
            embedder = localProviders?.embedder ?? MockEmbedder(dims: dims)
        case .remote:
            embedder = Mem0OpenAIEmbedder(
                baseURL: baseURL,
                apiKey: apiKey,
                model: env["CODEX_MEM0_EMBEDDING_MODEL"] ?? "text-embedding-3-small",
                dims: dims,
                sendDimensions: dims != 1536,
                authProvider: (apiKey?.isEmpty == false) ? nil : authProvider)
        case .mock:
            embedder = MockEmbedder(dims: dims)
        }

        let llm: any Mem0LLM
        switch llmBackend {
        case .local:
            llm = localProviders?.llm ?? MockLLM()
        case .remote:
            llm = Mem0OpenAILLM(
                baseURL: baseURL,
                apiKey: apiKey,
                model: env["CODEX_MEM0_LLM_MODEL"] ?? "gpt-4o-mini",
                authProvider: (apiKey?.isEmpty == false) ? nil : authProvider)
        case .mock:
            llm = MockLLM()
        }

        let engine = Mem0Engine(config: Mem0Config(historyDbPath: dbPath),
                                embedder: embedder, llm: llm,
                                vectorStore: store, historyStore: store)

        switch sub {
        case "import-jsonl":
            do {
                let opts = try ImportOptions.parse(Array(CommandLine.arguments.dropFirst(2)))
                let summary = try await importJSONL(path: opts.path, options: opts,
                                                    store: store, embedder: embedder)
                print(summary.line)
                if summary.failed > 0 || summary.historyFailed > 0 {
                    exit(1)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("codex-mem0 import-jsonl: \(error)\n".utf8))
                FileHandle.standardError.write(Data(importUsage.utf8))
                exit(2)
            }
        case "verify":
            let storeKind = (store is Mem0SQLiteStore) ? "sqlite-vec (\(dbPath))" : "embedded-postgres"
            print("codex-mem0 verify: store=\(storeKind); " +
                  "embeddings=\(describe(embeddingBackend, baseURL: baseURL, dims: dims)); " +
                  "llm=\(describe(llmBackend, baseURL: baseURL, dims: dims))")
            exit(0)
        case "serve":
            let host = env["CODEX_MEM0_HOST"] ?? "127.0.0.1"
            let port = UInt16(env["PORT"] ?? env["CODEX_MEM0_PORT"] ?? "8080") ?? 8080
            let server = Mem0HTTPServer(engine: engine)
            do {
                let bound = try server.start(host: host, port: port)
                FileHandle.standardError.write(Data("codex-mem0 listening http://\(host):\(bound)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("codex-mem0: failed to bind: \(error)\n".utf8))
                exit(1)
            }
            while true { try? await Task.sleep(for: .seconds(3600)) }
        default:
            FileHandle.standardError.write(Data("usage: codex-mem0 [serve|verify|import-jsonl <path>]\n".utf8))
            exit(2)
        }
    }

    private static func describe(_ backend: Mem0ResolvedBackend,
                                 baseURL: String,
                                 dims: Int) -> String {
        switch backend {
        case .local:
            return "local-mlx(qwen+nomic,padded-\(dims))"
        case .remote:
            return "openai-compatible(\(baseURL))"
        case .mock:
            return "mock"
        }
    }

    static func resolveOpenAIAuth(env: [String: String], codexHome: String) async -> Mem0AuthProvider? {
        if let apiKey = env["CODEX_MEM0_API_KEY"] ?? env["OPENAI_API_KEY"], !apiKey.isEmpty {
            return .staticToken(apiKey)
        }
        if let brokerAuth = brokerAuthClient(codexHome: codexHome),
           await brokerAuth.validAccessToken() != nil {
            return Mem0AuthProvider(
                accessToken: { await brokerAuth.validAccessToken() },
                refreshToken: { await brokerAuth.refreshAccessToken() })
        }
        let authStoreMode = AuthCredentialsStoreMode.parse(
            ConfigLoader(codexHome: codexHome).load()
                .value("cli_auth_credentials_store")?.stringValue)
        let authManager = AuthManager(
            store: TokenStoreFactory.production(codexHome: codexHome, mode: authStoreMode),
            apiKeyExchanger: CurlAPIKeyExchanger(),
            revoker: CurlTokenRevoker())
        guard await authManager.validAccessToken() != nil else { return nil }
        return Mem0AuthProvider(
            accessToken: { await authManager.validAccessToken() },
            refreshToken: { await authManager.refreshAccessToken() })
    }

    static func brokerAuthClient(codexHome: String) -> BrokerAuthClient? {
        let env = ProcessInfo.processInfo.environment
        let raw = env["CODEXKIT_AUTH_BROKER"]
            ?? env["CODEX_BROKER_LISTEN"]
            ?? "unix://\(BrokerAuthClient.defaultSocketPath(codexHome: codexHome))"
        guard raw.hasPrefix("unix://") else { return nil }
        let path = String(raw.dropFirst("unix://".count))
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return BrokerAuthClient(socketPath: path)
    }

    static let importUsage = """

usage: codex-mem0 import-jsonl <path> [--user-id id] [--agent-id id] [--run-id id] [--batch-size n] [--limit n] [--dry-run]

Imports JSONL rows shaped like:
  {"memory":"...","memory_id":"...","metadata":{...},"user_id":"..."}

Rows are upserted by memory_id, so rerunning the same export skips unchanged rows.

"""

    struct ImportOptions {
        var path: String
        var userID: String?
        var agentID: String?
        var runID: String?
        var batchSize: Int = 64
        var limit: Int?
        var dryRun: Bool = false

        static func parse(_ args: [String]) throws -> ImportOptions {
            guard let first = args.first, !first.hasPrefix("-") else {
                throw Mem0Error.validation("import-jsonl requires a JSONL path")
            }
            var opts = ImportOptions(path: first)
            var i = 1
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--user-id":
                    i += 1
                    guard i < args.count else { throw Mem0Error.validation("--user-id requires a value") }
                    opts.userID = args[i]
                case "--agent-id":
                    i += 1
                    guard i < args.count else { throw Mem0Error.validation("--agent-id requires a value") }
                    opts.agentID = args[i]
                case "--run-id":
                    i += 1
                    guard i < args.count else { throw Mem0Error.validation("--run-id requires a value") }
                    opts.runID = args[i]
                case "--batch-size":
                    i += 1
                    guard i < args.count, let n = Int(args[i]), n > 0 else {
                        throw Mem0Error.validation("--batch-size requires a positive integer")
                    }
                    opts.batchSize = n
                case "--limit":
                    i += 1
                    guard i < args.count, let n = Int(args[i]), n >= 0 else {
                        throw Mem0Error.validation("--limit requires a non-negative integer")
                    }
                    opts.limit = n
                case "--dry-run":
                    opts.dryRun = true
                default:
                    throw Mem0Error.validation("unknown import-jsonl argument: \(arg)")
                }
                i += 1
            }
            return opts
        }
    }

    struct ImportSummary {
        var read = 0
        var inserted = 0
        var updated = 0
        var skipped = 0
        var failed = 0
        var historyFailed = 0
        var dryRun = false

        var line: String {
            "import-jsonl summary: read=\(read) inserted=\(inserted) updated=\(updated) " +
            "skipped=\(skipped) failed=\(failed) history_failed=\(historyFailed) dry_run=\(dryRun)"
        }
    }

    struct PendingImport {
        var line: Int
        var id: String
        var memory: String
        var payload: JSONObject
        var oldMemory: String?
        var event: String

        var history: NewHistory {
            let createdAt = payload["created_at"]?.stringValue
            let updatedAt = payload["updated_at"]?.stringValue
            return NewHistory(memoryID: id, oldMemory: oldMemory, newMemory: memory,
                              event: event, createdAt: createdAt, updatedAt: updatedAt,
                              isDeleted: 0,
                              actorID: payload["actor_id"]?.stringValue,
                              role: payload["role"]?.stringValue,
                              userID: payload["user_id"]?.stringValue,
                              agentID: payload["agent_id"]?.stringValue,
                              runID: payload["run_id"]?.stringValue)
        }
    }

    static func importJSONL(path: String, options: ImportOptions,
                            store: any Mem0VectorStore & Mem0HistoryStore,
                            embedder: any Mem0Embedder) async throws -> ImportSummary {
        guard FileManager.default.fileExists(atPath: path) else {
            throw Mem0Error.validation("input file does not exist: \(path)")
        }
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        var summary = ImportSummary(dryRun: options.dryRun)
        var pending: [PendingImport] = []
        var seenIDs = Set<String>()

        for (idx, rawLine) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if let limit = options.limit, summary.read >= limit { break }
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            summary.read += 1

            guard let object = JSONValue.parse(String(trimmed))?.objectValue,
                  let memory = object["memory"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !memory.isEmpty else {
                summary.failed += 1
                FileHandle.standardError.write(Data("import-jsonl: line \(idx + 1) is missing non-empty memory\n".utf8))
                continue
            }

            let id = object["memory_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "import_\(md5Hex(memory))"
            guard !id.isEmpty else {
                summary.failed += 1
                FileHandle.standardError.write(Data("import-jsonl: line \(idx + 1) has an empty memory_id\n".utf8))
                continue
            }
            guard seenIDs.insert(id).inserted else {
                summary.failed += 1
                FileHandle.standardError.write(Data("import-jsonl: duplicate memory_id in input: \(id)\n".utf8))
                continue
            }

            let metadata = stripClaudeSourceURIs(.object(object["metadata"]?.objectValue ?? [:])).objectValue ?? [:]
            let rowUserID = object["user_id"]?.stringValue ?? metadata["user_id"]?.stringValue
            let rowAgentID = object["agent_id"]?.stringValue ?? metadata["agent_id"]?.stringValue
            let rowRunID = object["run_id"]?.stringValue ?? metadata["run_id"]?.stringValue
            let scopeUserID = options.userID ?? rowUserID ?? "codex"
            let scopeAgentID = options.agentID ?? rowAgentID
            let scopeRunID = options.runID ?? rowRunID

            do {
                _ = try Mem0Filters.buildFiltersAndMetadata(userID: scopeUserID,
                                                            agentID: scopeAgentID,
                                                            runID: scopeRunID)
            } catch {
                summary.failed += 1
                FileHandle.standardError.write(Data("import-jsonl: line \(idx + 1) has invalid scope: \(error)\n".utf8))
                continue
            }

            let textHash = md5Hex(memory)
            let existing = try await store.get(id)
            if existing?.payload["hash"]?.stringValue == textHash,
               existing?.payload["data"]?.stringValue == memory,
               !containsClaudeURI(.object(existing?.payload ?? [:])) {
                summary.skipped += 1
                continue
            }

            let now = nowUTCRFC3339()
            var payload = metadata
            payload["data"] = .string(memory)
            payload["hash"] = .string(textHash)
            payload["text_lemmatized"] = .string(Mem0NLP.lemmatizeForBM25(memory))
            payload["user_id"] = .string(scopeUserID)
            if let scopeAgentID, !scopeAgentID.isEmpty { payload["agent_id"] = .string(scopeAgentID) }
            else { payload["agent_id"] = nil }
            if let scopeRunID, !scopeRunID.isEmpty { payload["run_id"] = .string(scopeRunID) }
            else { payload["run_id"] = nil }
            payload["source_memory_id"] = .string(id)
            payload["import_format"] = .string("claude-history-export/mem0-jsonl")
            payload["created_at"] = existing?.payload["created_at"] ?? metadata["created_at"] ?? .string(now)
            payload["updated_at"] = .string(now)

            let event = existing == nil ? "ADD" : "UPDATE"
            pending.append(PendingImport(line: idx + 1, id: id, memory: memory, payload: payload,
                                         oldMemory: existing?.payload["data"]?.stringValue,
                                         event: event))
        }

        guard !pending.isEmpty else { return summary }
        if options.dryRun {
            summary.inserted += pending.filter { $0.event == "ADD" }.count
            summary.updated += pending.filter { $0.event == "UPDATE" }.count
            return summary
        }

        var offset = 0
        while offset < pending.count {
            let end = min(offset + options.batchSize, pending.count)
            let batch = Array(pending[offset..<end])
            let embeddings = await embeddingsForBatch(batch, embedder: embedder)
            var records: [VectorRecord] = []
            var history: [NewHistory] = []
            for item in batch {
                guard let vector = embeddings[item.id] else {
                    summary.failed += 1
                    FileHandle.standardError.write(Data("import-jsonl: embedding failed for line \(item.line) id \(item.id)\n".utf8))
                    continue
                }
                records.append(VectorRecord(id: item.id, vector: vector, payload: item.payload))
                history.append(item.history)
            }

            // Track which records actually landed, so history is recorded ONLY for
            // memories that were inserted (a per-record fallback failure must not leave
            // ADD/UPDATE history for an id that was never stored — esp. on the Postgres
            // path where a vector can be rejected after embedding).
            var insertedIDs = Set<String>()
            do {
                try await store.insert(records)
                insertedIDs = Set(records.map(\.id))
                summary.inserted += batch.filter { $0.event == "ADD" && embeddings[$0.id] != nil }.count
                summary.updated += batch.filter { $0.event == "UPDATE" && embeddings[$0.id] != nil }.count
            } catch {
                for record in records {
                    do {
                        try await store.insert([record])
                        insertedIDs.insert(record.id)
                        if let item = batch.first(where: { $0.id == record.id }) {
                            if item.event == "ADD" { summary.inserted += 1 }
                            else { summary.updated += 1 }
                        }
                    } catch {
                        summary.failed += 1
                        FileHandle.standardError.write(Data("import-jsonl: insert failed for id \(record.id): \(error)\n".utf8))
                    }
                }
            }

            // Only the successfully-inserted memories get history rows.
            let okHistory = history.filter { insertedIDs.contains($0.memoryID) }
            do {
                try await store.batchAddHistory(okHistory)
            } catch {
                for h in okHistory {
                    do {
                        try await store.addHistory(memoryID: h.memoryID, oldMemory: h.oldMemory,
                                                   newMemory: h.newMemory, event: h.event,
                                                   createdAt: h.createdAt, updatedAt: h.updatedAt,
                                                   isDeleted: h.isDeleted, actorID: h.actorID,
                                                   role: h.role, userID: h.userID,
                                                   agentID: h.agentID, runID: h.runID)
                    } catch {
                        summary.historyFailed += 1
                        FileHandle.standardError.write(Data("import-jsonl: history insert failed for id \(h.memoryID): \(error)\n".utf8))
                    }
                }
            }

            offset = end
        }
        return summary
    }

    static func stripClaudeSourceURIs(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var cleaned: JSONObject = [:]
            for (key, nested) in object {
                if key == "source_uri",
                   let uri = nested.stringValue,
                   uri.hasPrefix("claude://") {
                    continue
                }
                cleaned[key] = stripClaudeSourceURIs(nested)
            }
            return .object(cleaned)
        case .array(let array):
            return .array(array.map { stripClaudeSourceURIs($0) })
        default:
            return value
        }
    }

    static func containsClaudeURI(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let string):
            return string.contains("claude://")
        case .array(let array):
            return array.contains { containsClaudeURI($0) }
        case .object(let object):
            return object.values.contains { containsClaudeURI($0) }
        default:
            return false
        }
    }

    static func embeddingsForBatch(_ batch: [PendingImport],
                                   embedder: any Mem0Embedder) async -> [String: [Float]] {
        let texts = batch.map(\.memory)
        if let vectors = try? await embedder.embedBatch(texts, .add), vectors.count == batch.count {
            var out: [String: [Float]] = [:]
            for (item, vector) in zip(batch, vectors) { out[item.id] = vector }
            return out
        }

        var out: [String: [Float]] = [:]
        for item in batch {
            if let vector = try? await embedder.embed(item.memory, .add) {
                out[item.id] = vector
            }
        }
        return out
    }
}
