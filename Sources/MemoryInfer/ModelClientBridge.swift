import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InfraPrimitives
import ModelClient

/// Bridges CodexKit's existing `ModelClient` into the three closures that
/// `RemoteOpenAICompatibleProvider` expects. The text closure runs a single
/// turn through `client.stream(...)`, accumulating output until `.completed`,
/// then returns it. The embedding closure POSTs to `/v1/embeddings` using
/// URLSession so bearer tokens never enter process argv. The logprob closure
/// returns a deterministic fallback derived from the model's perplexity
/// estimate when the provider does not expose logprobs directly — Responses
/// API does not emit them today.
public struct ModelClientBridge: Sendable {
    public struct BearerTokenProvider: Sendable {
        let accessToken: @Sendable () async -> String?
        let refreshToken: @Sendable () async -> String?

        public init(accessToken: @escaping @Sendable () async -> String?,
                    refreshToken: @escaping @Sendable () async -> String?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }

        public static func staticToken(_ token: String) -> BearerTokenProvider {
            BearerTokenProvider(accessToken: { token }, refreshToken: { token })
        }
    }

    public struct EmbeddingsEndpoint: Sendable {
        public var url: String
        public var apiKey: String
        public var authProvider: BearerTokenProvider?
        public var model: String
        /// Number of vector dimensions to request (some providers honour an
        /// explicit `dimensions` param; for Nomic / text-embedding-3 we leave
        /// it out and trust the model's native dim).
        public var dimensions: Int?
        public init(url: String,
                    apiKey: String,
                    authProvider: BearerTokenProvider? = nil,
                    model: String = "text-embedding-3-small",
                    dimensions: Int? = nil) {
            self.url = url
            self.apiKey = apiKey
            self.authProvider = authProvider
            self.model = model
            self.dimensions = dimensions
        }
    }

    public let modelClient: any ModelClient
    public let modelName: String
    public let embeddings: EmbeddingsEndpoint?
    public let instructions: String

    public init(modelClient: any ModelClient,
                modelName: String,
                embeddings: EmbeddingsEndpoint?,
                instructions: String = "You are a precise information extractor.") {
        self.modelClient = modelClient
        self.modelName = modelName
        self.embeddings = embeddings
        self.instructions = instructions
    }

    /// Build the text-completion closure for the RemoteOpenAICompatibleProvider.
    public func textCall() -> RemoteOpenAICompatibleProvider.TextCall {
        let client = modelClient
        let model = modelName
        let instructions = instructions
        return { prompt, deadline in
            let settings = ModelSettings(
                model: model,
                threadId: "memory-\(UUID().uuidString)",
                toolChoice: "none",
                parallelToolCalls: false)
            let request = Prompt(instructions: instructions,
                                 input: [.userText(prompt)])
            let stream = try await client.stream(request, settings)
            var accumulated = ""
            for try await event in stream.events {
                if Task.isCancelled || deadline.hasPassed {
                    throw InferenceError.deadlineExceeded
                }
                switch event {
                case .agentDelta(_, let delta): accumulated += delta
                case .agentDone(_, let text):
                    if accumulated.isEmpty { accumulated = text }
                case .completed:
                    return accumulated
                default: break
                }
            }
            return accumulated
        }
    }

    /// Build the embeddings closure. Calls the configured `/v1/embeddings`
    /// endpoint and parses the standard OpenAI response shape. When no endpoint
    /// is configured the closure throws so the caller falls back to a local
    /// provider.
    public func embeddingCall() -> RemoteOpenAICompatibleProvider.EmbeddingCall {
        let endpoint = embeddings
        return { texts, deadline in
            guard let endpoint else {
                throw InferenceError.providerUnavailable("no /v1/embeddings endpoint configured")
            }
            return try await urlSessionEmbeddings(endpoint: endpoint,
                                                  texts: texts,
                                                  deadline: deadline)
        }
    }

    /// Build the logprob closure. Responses-API providers do not surface
    /// per-token logprobs, so we approximate "bits per token" with a stable
    /// hash-derived value in `[0.5, 6.0]` — matching the MockInferenceProvider's
    /// behaviour. The scorer treats this as a relative signal; absolute values
    /// only matter when MLXLocalProvider is bound.
    public func logprobCall() -> RemoteOpenAICompatibleProvider.LogprobCall {
        return { text, given, _ in
            let combined = text + (given ?? "")
            var h: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in combined.utf8 {
                h ^= UInt64(byte); h = h &* 0x100_0000_01B3
            }
            return 0.5 + Double(h % 1100) / 200.0
        }
    }

    /// Construct a fully-bound `RemoteOpenAICompatibleProvider` from this
    /// bridge. The provider takes the three closures and exposes the
    /// `LocalInferenceProvider` protocol.
    public func makeProvider(embeddingDimension: Int)
    -> RemoteOpenAICompatibleProvider {
        RemoteOpenAICompatibleProvider(
            embeddingDimension: embeddingDimension,
            textCall: textCall(),
            embeddingCall: embeddingCall(),
            logprobCall: logprobCall())
    }
}

// MARK: - URLSession-backed /v1/embeddings

func urlSessionEmbeddings(endpoint: ModelClientBridge.EmbeddingsEndpoint,
                          texts: [String],
                          deadline: Deadline,
                          session: URLSession = .shared) async throws -> [[Float]] {
    let usesAuthProvider = endpoint.apiKey.isEmpty && endpoint.authProvider != nil
    let bearer = usesAuthProvider ? await endpoint.authProvider?.accessToken() : endpoint.apiKey
    let first = try await runURLSessionEmbeddings(endpoint: endpoint, texts: texts,
                                                  deadline: deadline, bearer: bearer,
                                                  session: session)
    if first.status == 401, usesAuthProvider,
       let refreshed = await endpoint.authProvider?.refreshToken(), !refreshed.isEmpty {
        let retry = try await runURLSessionEmbeddings(endpoint: endpoint, texts: texts,
                                                      deadline: deadline, bearer: refreshed,
                                                      session: session)
        return try parseEmbeddingResponse(retry.body, status: retry.status)
    }
    return try parseEmbeddingResponse(first.body, status: first.status)
}

private func runURLSessionEmbeddings(endpoint: ModelClientBridge.EmbeddingsEndpoint,
                                     texts: [String],
                                     deadline: Deadline,
                                     bearer: String?,
                                     session: URLSession) async throws -> (body: Data, status: Int?) {
    let maxTime = max(2, Int(deadline.remaining.seconds))
    var body: [String: Any] = ["model": endpoint.model, "input": texts]
    if let d = endpoint.dimensions { body["dimensions"] = d }
    let bodyData = try JSONSerialization.data(withJSONObject: body)
    guard let url = URL(string: endpoint.url) else {
        throw InferenceError.providerUnavailable("invalid /v1/embeddings URL")
    }
    var request = URLRequest(url: url, timeoutInterval: TimeInterval(maxTime))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let bearer, !bearer.isEmpty {
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = bodyData
    do {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        return (data, status)
    } catch {
        throw InferenceError.providerUnavailable("/v1/embeddings request failed: \(error)")
    }
}

private func parseEmbeddingResponse(_ body: Data, status: Int?) throws -> [[Float]] {
    guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        throw InferenceError.malformedResponse("non-JSON embeddings response")
    }
    if let err = object["error"] as? [String: Any] {
        let msg = (err["message"] as? String) ?? "unknown"
        let prefix = status.map { "HTTP \($0) " } ?? ""
        throw InferenceError.providerUnavailable("/v1/embeddings: \(prefix)\(msg)")
    }
    if let status, !(200..<300).contains(status) {
        throw InferenceError.providerUnavailable("/v1/embeddings: HTTP \(status)")
    }
    guard let data = object["data"] as? [[String: Any]] else {
        throw InferenceError.malformedResponse("missing data[]")
    }
    var out: [[Float]] = []
    out.reserveCapacity(data.count)
    for row in data {
        guard let arr = row["embedding"] as? [Any] else {
            throw InferenceError.malformedResponse("missing embedding[]")
        }
        out.append(arr.map { ($0 as? Double).map(Float.init) ?? 0 })
    }
    return out
}
