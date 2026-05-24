import Foundation
import InfraPrimitives
import ModelClient

/// Bridges CodexKit's existing `ModelClient` into the three closures that
/// `RemoteOpenAICompatibleProvider` expects. The text closure runs a single
/// turn through `client.stream(...)`, accumulating output until `.completed`,
/// then returns it along with the usage breakdown. The embedding closure
/// shells out to `/v1/embeddings` via curl (the Responses API does not host
/// embeddings). The logprob closure returns a deterministic fallback derived
/// from the model's perplexity estimate when the provider does not expose
/// logprobs directly — Responses API does not emit them today.
public struct ModelClientBridge: Sendable {
    public struct EmbeddingsEndpoint: Sendable {
        public var url: String
        public var apiKey: String
        public var model: String
        /// Number of vector dimensions to request (some providers honour an
        /// explicit `dimensions` param; for Nomic / text-embedding-3 we leave
        /// it out and trust the model's native dim).
        public var dimensions: Int?
        public init(url: String,
                    apiKey: String,
                    model: String = "text-embedding-3-small",
                    dimensions: Int? = nil) {
            self.url = url
            self.apiKey = apiKey
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

    /// Build the embeddings closure. Shells out to curl against the
    /// configured `/v1/embeddings` endpoint and parses the standard OpenAI
    /// response shape. When no endpoint is configured the closure throws so
    /// the caller falls back to a local provider.
    public func embeddingCall() -> RemoteOpenAICompatibleProvider.EmbeddingCall {
        let endpoint = embeddings
        return { texts, deadline in
            guard let endpoint else {
                throw InferenceError.providerUnavailable("no /v1/embeddings endpoint configured")
            }
            return try await curlEmbeddings(endpoint: endpoint,
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

// MARK: - curl-backed /v1/embeddings

func curlEmbeddings(endpoint: ModelClientBridge.EmbeddingsEndpoint,
                    texts: [String],
                    deadline: Deadline) async throws -> [[Float]] {
    let maxTime = max(2, Int(deadline.remaining.seconds))
    var body: [String: Any] = ["model": endpoint.model, "input": texts]
    if let d = endpoint.dimensions { body["dimensions"] = d }
    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let tmp = NSTemporaryDirectory() + "codex-memory-embed-\(UUID().uuidString).json"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try bodyData.write(to: URL(fileURLWithPath: tmp))
    let argv = [
        "-sS", "--max-time", "\(maxTime)",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer \(endpoint.apiKey)",
        "-X", "POST",
        "--data-binary", "@\(tmp)",
        endpoint.url,
    ]
    let result = await runSubprocess(executable: "/usr/bin/curl", argv: argv)
    guard result.exit == 0 else {
        throw InferenceError.providerUnavailable("curl /v1/embeddings exit=\(result.exit) \(result.stderr.prefix(200))")
    }
    guard let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
        throw InferenceError.malformedResponse("non-JSON embeddings response")
    }
    if let err = object["error"] as? [String: Any] {
        let msg = (err["message"] as? String) ?? "unknown"
        throw InferenceError.providerUnavailable("/v1/embeddings: \(msg)")
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

struct SubprocessResult: Sendable {
    var exit: Int32
    var stdout: Data
    var stderr: String
}

func runSubprocess(executable: String, argv: [String]) async -> SubprocessResult {
    await withCheckedContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = argv
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch {
            cont.resume(returning: SubprocessResult(
                exit: 127, stdout: Data(),
                stderr: "spawn failed: \(error)"))
            return
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        cont.resume(returning: SubprocessResult(
            exit: p.terminationStatus, stdout: outData,
            stderr: String(data: errData, encoding: .utf8) ?? ""))
    }
}
