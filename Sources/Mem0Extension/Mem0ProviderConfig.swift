import Foundation
import Config
import Mem0Core

/// Session-level auth source for mem0 providers.
///
/// This wrapper keeps the extension boundary small while allowing codex-session
/// and codexd to pass the same API-key/ChatGPT-login credential source used by
/// the core `ModelClient` into mem0's embeddings and LLM providers.
public struct Mem0SessionAuthProvider: Sendable {
    let core: Mem0AuthProvider

    public init(accessToken: @escaping @Sendable () async -> String?,
                refreshToken: @escaping @Sendable () async -> String?) {
        self.core = Mem0AuthProvider(accessToken: accessToken, refreshToken: refreshToken)
    }

    public static func staticToken(_ token: String) -> Mem0SessionAuthProvider {
        Mem0SessionAuthProvider(accessToken: { token }, refreshToken: { token })
    }
}

public enum Mem0InferenceBackend: String, Sendable, Equatable {
    case auto
    case local
    case remote
    case mock

    static func parse(_ raw: String?) -> Mem0InferenceBackend? {
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

/// The scope a mem0 session memory belongs to (at least `userId`).
public struct Mem0Scope: Sendable, Equatable {
    public var userId: String
    public var agentId: String?
    public var runId: String?
    public init(userId: String, agentId: String? = nil, runId: String? = nil) {
        self.userId = userId; self.agentId = agentId; self.runId = runId
    }

    /// The scope as engine filters.
    public var filters: JSONObject {
        var f: JSONObject = ["user_id": .string(userId)]
        if let a = agentId { f["agent_id"] = .string(a) }
        if let r = runId { f["run_id"] = .string(r) }
        return f
    }
}

/// Configuration for the native mem0 `MemoryProvider`, read from `[memory.mem0]`
/// (with `CODEX_MEM0_*` / `OPENAI_API_KEY` env fallbacks), mirroring
/// `WikiMemoryConfig.fromConfig`. Real OpenAI-compatible embeddings/LLM are used
/// when an `api_key` (or a custom `base_url`) is configured; otherwise the
/// engine falls back to the deterministic mock providers (semantically weak but
/// dependency-free), exactly like the wiki's mock fallback.
///
/// ```toml
/// [memory]
/// provider = "mem0"
///
/// [memory.mem0]
/// db_path             = "/var/lib/codex/mem0.db"   # optional; defaults under $CODEX_HOME
/// user_id             = "alex"                      # scope (default "codex")
/// agent_id            = "coding-agent"              # optional
/// run_id              = "session-1"                 # optional
/// top_k               = 5
/// infer               = true                        # capture uses LLM extraction
/// base_url            = "https://api.openai.com/v1" # OpenAI-compatible base
/// api_key             = "sk-..."                    # optional explicit override
/// embedding_model     = "text-embedding-3-small"
/// embedding_dimension = 1536
/// llm_model           = "gpt-4o-mini"
/// embedding_backend   = "auto"                      # auto/local/remote/mock
/// llm_backend         = "auto"                      # auto/local/remote/mock
/// ```
public struct Mem0ProviderConfig: Sendable, Equatable {
    public var dbPath: String?
    public var userId: String
    public var agentId: String?
    public var runId: String?
    public var topK: Int
    public var infer: Bool
    public var baseURL: String
    public var apiKey: String?
    public var embeddingModel: String
    public var embeddingDimension: Int
    public var llmModel: String
    public var embeddingBackend: Mem0InferenceBackend
    public var llmBackend: Mem0InferenceBackend
    /// Enable the reconcile/supersede pass on add (TOML reconcile_on_add / env
    /// CODEX_MEM0_RECONCILE). Default false here; the session path threads this into
    /// Mem0Config.reconcileOnAdd.
    public var reconcileOnAdd: Bool = false

    public init(dbPath: String? = nil, userId: String = "codex", agentId: String? = nil,
                runId: String? = nil, topK: Int = 5, infer: Bool = true,
                baseURL: String = "https://api.openai.com/v1", apiKey: String? = nil,
                embeddingModel: String = "text-embedding-3-small", embeddingDimension: Int = 1536,
                llmModel: String = "gpt-4o-mini",
                embeddingBackend: Mem0InferenceBackend = .auto,
                llmBackend: Mem0InferenceBackend = .auto,
                reconcileOnAdd: Bool = false) {
        self.dbPath = dbPath
        self.userId = userId
        self.agentId = agentId
        self.runId = runId
        self.topK = topK
        self.infer = infer
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.embeddingModel = embeddingModel
        self.embeddingDimension = embeddingDimension
        self.llmModel = llmModel
        self.embeddingBackend = embeddingBackend
        self.llmBackend = llmBackend
        self.reconcileOnAdd = reconcileOnAdd
    }

    public var scope: Mem0Scope { Mem0Scope(userId: userId, agentId: agentId, runId: runId) }

    /// Whether real OpenAI-compatible providers should be used (an API key is
    /// present, or a non-default base URL — e.g. a local keyless server).
    public var useRealProviders: Bool {
        if let k = apiKey, !k.isEmpty { return true }
        return baseURL != "https://api.openai.com/v1"
    }

    public static func fromConfig(_ config: Config,
                                  env: [String: String] = ProcessInfo.processInfo.environment)
    -> Mem0ProviderConfig {
        let mem = config.value("memory.mem0")?.objectValue ?? [:]
        var out = Mem0ProviderConfig()
        if let v = mem["db_path"]?.stringValue, !v.isEmpty { out.dbPath = v }
        else if let v = env["CODEX_MEM0_DB"], !v.isEmpty { out.dbPath = v }
        if let v = mem["user_id"]?.stringValue, !v.isEmpty { out.userId = v }
        else if let v = env["CODEX_MEM0_USER_ID"], !v.isEmpty { out.userId = v }
        if let v = mem["agent_id"]?.stringValue, !v.isEmpty { out.agentId = v }
        if let v = mem["run_id"]?.stringValue, !v.isEmpty { out.runId = v }
        if let v = mem["top_k"]?.intValue, v > 0 { out.topK = Int(v) }
        if let v = mem["infer"]?.boolValue { out.infer = v }
        if let v = mem["base_url"]?.stringValue, !v.isEmpty { out.baseURL = v }
        else if let v = env["CODEX_MEM0_BASE_URL"], !v.isEmpty { out.baseURL = v }
        if let v = mem["api_key"]?.stringValue, !v.isEmpty { out.apiKey = v }
        else if let v = env["CODEX_MEM0_API_KEY"], !v.isEmpty { out.apiKey = v }
        else if let v = env["OPENAI_API_KEY"], !v.isEmpty { out.apiKey = v }
        if let v = mem["embedding_model"]?.stringValue, !v.isEmpty { out.embeddingModel = v }
        if let v = mem["embedding_dimension"]?.intValue, v > 0 { out.embeddingDimension = Int(v) }
        if let v = mem["llm_model"]?.stringValue, !v.isEmpty { out.llmModel = v }
        if let v = Mem0InferenceBackend.parse(mem["embedding_backend"]?.stringValue) {
            out.embeddingBackend = v
        } else if let v = Mem0InferenceBackend.parse(env["CODEX_MEM0_EMBEDDING_BACKEND"]) {
            out.embeddingBackend = v
        }
        if let v = Mem0InferenceBackend.parse(mem["llm_backend"]?.stringValue) {
            out.llmBackend = v
        } else if let v = Mem0InferenceBackend.parse(env["CODEX_MEM0_LLM_BACKEND"]) {
            out.llmBackend = v
        }
        // Reconcile/supersede on add: TOML reconcile_on_add first, env CODEX_MEM0_RECONCILE fallback.
        if let v = mem["reconcile_on_add"]?.boolValue {
            out.reconcileOnAdd = v
        } else if let v = env["CODEX_MEM0_RECONCILE"] {
            out.reconcileOnAdd = (v == "1")
        }
        return out
    }
}
