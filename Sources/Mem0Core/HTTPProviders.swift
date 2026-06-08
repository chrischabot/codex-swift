import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Refreshable bearer-token source for OpenAI-compatible mem0 providers.
///
/// Codex session roots use this to pass the same credential source used by the
/// core model client (API key, broker auth, or stored ChatGPT auth) into mem0.
public struct Mem0AuthProvider: Sendable {
    let accessToken: @Sendable () async -> String?
    let refreshToken: @Sendable () async -> String?

    public init(accessToken: @escaping @Sendable () async -> String?,
                refreshToken: @escaping @Sendable () async -> String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public static func staticToken(_ token: String) -> Mem0AuthProvider {
        Mem0AuthProvider(accessToken: { token }, refreshToken: { token })
    }
}

/// Portable HTTP transport for the OpenAI-compatible providers. Uses a
/// continuation-wrapped `dataTask` so it works across Darwin/Linux URLSession
/// and URLProtocol stubs (unlike the async `data(for:)` whose availability
/// varies by platform).
enum Mem0HTTP {
    static func postJSON(_ session: URLSession, _ url: URL, apiKey: String?, body: Data,
                         authProvider: Mem0AuthProvider? = nil,
                         extraHeaders: [String: String] = [:]) async throws -> Data {
        let usesAuthProvider = (apiKey?.isEmpty ?? true) && authProvider != nil
        let bearer = usesAuthProvider ? await authProvider?.accessToken() : apiKey
        let (data, http) = try await perform(session, makeRequest(url, body: body,
                                                                  bearer: bearer,
                                                                  extraHeaders: extraHeaders))
        if http.statusCode == 401, usesAuthProvider,
           let refreshed = await authProvider?.refreshToken(), !refreshed.isEmpty {
            let retry = try await perform(session, makeRequest(url, body: body,
                                                               bearer: refreshed,
                                                               extraHeaders: extraHeaders))
            return try validated(retry.0, retry.1)
        }
        return try validated(data, http)
    }

    private static func makeRequest(_ url: URL, body: Data, bearer: String?,
                                    extraHeaders: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer, !bearer.isEmpty {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    private static func validated(_ data: Data, _ http: HTTPURLResponse) throws -> Data {
        guard (200..<300).contains(http.statusCode) else {
            throw Mem0Error.network("HTTP \(http.statusCode): \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }

    static func perform(_ session: URLSession, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<(Data, HTTPURLResponse), any Error>) in
            let task = session.dataTask(with: request) { data, resp, err in
                if let err { cont.resume(throwing: err); return }
                guard let data, let http = resp as? HTTPURLResponse else {
                    cont.resume(throwing: Mem0Error.network("malformed HTTP response")); return
                }
                cont.resume(returning: (data, http))
            }
            task.resume()
        }
    }

    static func makeSession(timeoutMs: Int) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        let t = max(0.2, Double(timeoutMs) / 1000.0)
        cfg.timeoutIntervalForRequest = t
        cfg.timeoutIntervalForResource = t
        return URLSession(configuration: cfg)
    }
}

/// Whether a model id is a reasoning / GPT-5 model that rejects sampling
/// params. Port of `is_reasoning_model`.
public func mem0IsReasoningModel(_ model: String) -> Bool {
    let lower = model.lowercased()
    let base = lower.split(separator: "/").last.map(String.init) ?? lower
    let reasoning: Set<String> = ["o1", "o1-preview", "o3-mini", "o3", "gpt-5", "gpt-5o", "gpt-5o-mini", "gpt-5o-micro"]
    if reasoning.contains(base) { return true }
    for p in ["o1-", "o1.", "o3-", "o3."] where base.hasPrefix(p) { return true }
    return false
}

/// OpenAI-compatible embedder over `{base}/embeddings`. Port of the Rust
/// OpenAI embedder. `@unchecked Sendable`: members are immutable values + a
/// thread-safe `URLSession`.
public struct Mem0OpenAIEmbedder: Mem0Embedder, @unchecked Sendable {
    let session: URLSession
    let baseURL: String
    let apiKey: String?
    let authProvider: Mem0AuthProvider?
    let model: String
    public let dims: Int
    let sendDimensions: Bool

    public init(baseURL: String = "https://api.openai.com/v1", apiKey: String? = nil,
                model: String = "text-embedding-3-small", dims: Int = 1536,
                sendDimensions: Bool = false, timeoutMs: Int = 30000, session: URLSession? = nil,
                authProvider: Mem0AuthProvider? = nil) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.authProvider = authProvider
        self.model = model
        self.dims = dims
        self.sendDimensions = sendDimensions
        self.session = session ?? Mem0HTTP.makeSession(timeoutMs: timeoutMs)
    }

    public func embed(_ text: String, _ action: MemoryAction) async throws -> [Float] {
        let v = try await embedBatch([text], action)
        guard let first = v.first else { throw Mem0Error.embedding("no embedding returned") }
        return first
    }

    public func embedBatch(_ texts: [String], _ action: MemoryAction) async throws -> [[Float]] {
        let maxBatch = 100
        guard let url = URL(string: baseURL + "/embeddings") else {
            throw Mem0Error.configuration("invalid embeddings URL")
        }
        var out: [[Float]] = []
        var i = 0
        while i < texts.count {
            let chunk = Array(texts[i..<min(i + maxBatch, texts.count)])
            var obj: JSONObject = [
                "input": .array(chunk.map { .string($0.replacingOccurrences(of: "\n", with: " ")) }),
                "model": .string(model),
                "encoding_format": .string("float"),
            ]
            if sendDimensions { obj["dimensions"] = .int(Int64(dims)) }
            let body = try JSONEncoder().encode(JSONValue.object(obj))
            let data = try await Mem0HTTP.postJSON(session, url, apiKey: apiKey, body: body,
                                                   authProvider: authProvider)
            guard let arr = JSONValue.parse(data)?.objectValue?["data"]?.arrayValue else {
                throw Mem0Error.embedding("malformed embeddings response")
            }
            let indexed: [(Int, [Float])] = arr.map { item in
                let idx = Int(item.objectValue?["index"]?.intValue ?? 0)
                let vec = (item.objectValue?["embedding"]?.arrayValue ?? []).map { Float($0.doubleValue ?? 0) }
                return (idx, vec)
            }.sorted { $0.0 < $1.0 }
            out.append(contentsOf: indexed.map { $0.1 })
            i += maxBatch
        }
        return out
    }
}

/// OpenAI-compatible chat LLM over `{base}/chat/completions`. Port of the Rust
/// OpenAI LLM (incl. reasoning-model param filtering + json response_format).
public struct Mem0OpenAILLM: Mem0LLM, @unchecked Sendable {
    let session: URLSession
    let baseURL: String
    let apiKey: String?
    let authProvider: Mem0AuthProvider?
    let model: String
    let temperature: Double
    let maxTokens: Int
    let topP: Double
    let reasoningEffort: String?

    public init(baseURL: String = "https://api.openai.com/v1", apiKey: String? = nil,
                model: String = "gpt-4o-mini", temperature: Double = 0.1, maxTokens: Int = 2000,
                topP: Double = 0.1, reasoningEffort: String? = nil,
                timeoutMs: Int = 60000, session: URLSession? = nil,
                authProvider: Mem0AuthProvider? = nil) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.authProvider = authProvider
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.reasoningEffort = reasoningEffort
        self.session = session ?? Mem0HTTP.makeSession(timeoutMs: timeoutMs)
    }

    public func generate(_ messages: [Message], _ options: GenerateOptions) async throws -> String {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw Mem0Error.configuration("invalid chat URL")
        }
        var obj: JSONObject = [
            "model": .string(model),
            "messages": .array(messages.map {
                .object(["role": .string($0.role), "content": .string($0.content)])
            }),
        ]
        if mem0IsReasoningModel(model) {
            if let re = reasoningEffort { obj["reasoning_effort"] = .string(re) }
        } else {
            obj["temperature"] = .double(options.temperature ?? temperature)
            obj["max_tokens"] = .int(Int64(options.maxTokens ?? maxTokens))
            obj["top_p"] = .double(options.topP ?? topP)
        }
        if options.responseFormatJSON {
            obj["response_format"] = .object(["type": .string("json_object")])
        }
        let body = try JSONEncoder().encode(JSONValue.object(obj))
        let data = try await Mem0HTTP.postJSON(session, url, apiKey: apiKey, body: body,
                                               authProvider: authProvider)
        let content = JSONValue.parse(data)?.objectValue?["choices"]?.arrayValue?.first?
            .objectValue?["message"]?.objectValue?["content"]?.stringValue
        return content ?? ""
    }
}
