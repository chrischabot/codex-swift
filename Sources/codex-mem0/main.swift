import Foundation
import Auth
import Config
import Mem0Core
import Mem0Local
import Mem0Store

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
// Subcommands:  serve (default) | verify

private enum StandaloneMem0Backend: String {
    case auto
    case local
    case remote
    case mock

    static func parse(_ raw: String?) -> StandaloneMem0Backend {
        guard let raw else { return .auto }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "local", "mlx", "mlx_local": return .local
        case "remote", "openai": return .remote
        case "mock", "offline": return .mock
        default: return .auto
        }
    }
}

private enum ResolvedStandaloneMem0Backend: String {
    case local
    case remote
    case mock
}

@main
struct CodexMem0 {
    static func defaultDB(_ env: [String: String]) -> String {
        let home = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        return home + "/mem0/mem0.db"
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
        guard let store = try? Mem0SQLiteStore(path: dbPath) else {
            FileHandle.standardError.write(Data("codex-mem0: cannot open store at \(dbPath)\n".utf8))
            exit(1)
        }

        let baseURL = env["CODEX_MEM0_BASE_URL"] ?? "https://api.openai.com/v1"
        let apiKey = env["CODEX_MEM0_API_KEY"] ?? env["OPENAI_API_KEY"]
        let dims = Int(env["CODEX_MEM0_EMBEDDING_DIM"] ?? "") ?? 1536
        let codexHome = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        let authProvider = await resolveOpenAIAuth(env: env, codexHome: codexHome)
        let remoteAvailable = (apiKey?.isEmpty == false)
            || authProvider != nil
            || baseURL != "https://api.openai.com/v1"
        let localAvailable = Mem0LocalRuntime.isAvailable(env: env)
        let embeddingBackend = resolveBackend(
            StandaloneMem0Backend.parse(env["CODEX_MEM0_EMBEDDING_BACKEND"]),
            localAvailable: localAvailable,
            remoteAvailable: remoteAvailable)
        let llmBackend = resolveBackend(
            StandaloneMem0Backend.parse(env["CODEX_MEM0_LLM_BACKEND"]),
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
        case "verify":
            print("codex-mem0 verify: store OK at \(dbPath); " +
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
            FileHandle.standardError.write(Data("usage: codex-mem0 [serve|verify]\n".utf8))
            exit(2)
        }
    }

    private static func resolveBackend(_ requested: StandaloneMem0Backend,
                                       localAvailable: Bool,
                                       remoteAvailable: Bool)
    -> ResolvedStandaloneMem0Backend {
        switch requested {
        case .mock:
            return .mock
        case .remote:
            if remoteAvailable { return .remote }
            return localAvailable ? .local : .mock
        case .local:
            if localAvailable { return .local }
            return remoteAvailable ? .remote : .mock
        case .auto:
            if localAvailable { return .local }
            return remoteAvailable ? .remote : .mock
        }
    }

    private static func describe(_ backend: ResolvedStandaloneMem0Backend,
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
}
