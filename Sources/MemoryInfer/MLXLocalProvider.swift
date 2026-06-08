import Foundation
import InfraPrimitives

#if CODEXKIT_MLX && canImport(MLX)
import MLX
import MLXNN
#endif
#if CODEXKIT_MLX && canImport(MLXLMCommon)
import MLXLMCommon
#endif
#if CODEXKIT_MLX && canImport(MLXLLM)
import MLXLLM
#endif
#if CODEXKIT_MLX && canImport(MLXEmbedders)
import MLXEmbedders
#endif
#if os(macOS) && canImport(Metal)
import Metal
#endif

public struct LocalChatMessage: Sendable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Apple-only adapter. On macOS, Package.swift enables the `CODEXKIT_MLX`
/// build flag by default unless the build is invoked with `CODEXKIT_MLX=0`.
/// That pulls in `MLX`, `MLXLMCommon`, `MLXLLM`, and `MLXEmbedders`, and this
/// file imports them behind `#if CODEXKIT_MLX`. The result is a real
/// `LocalInferenceProvider` that hosts the extractor + embedder in-process.
/// Without the flag, the stub throws `providerUnavailable` and the assembler
/// downgrades to the remote/mock backend automatically.
///
/// Model defaults (per the design doc):
///   extractor: mlx-community/Qwen3-30B-A3B-4bit-MLX  (30B/3B-active MoE — the
///              on-device triage/extraction lane; `extractorModelID` is a config
///              knob, so any mlx-swift-lm-supported model can be substituted)
///   embedder:  nomic-ai/nomic-embed-text-v1.5
///   reranker:  BAAI/bge-reranker-v2-m3 through a hand-rolled
///              BertForSequenceClassification wrapper over MLXEmbedders.Bert,
///              with cosine fallback when the cross-encoder cannot load.
///
/// NOTE: `mlx-community/gemma-4-26b-a4b-it-4bit` does NOT load on the current
/// mlx-swift-lm pin (its Gemma 4 support is dense-only; the 26B is MoE). Adopting
/// it needs a registered MoE-aware "gemma4" model — full spec + exact weight keys
/// in docs/notes/gemma4-moe-mlx-port.md. Deferred: the Qwen3 MoE above already
/// covers this niche.
public actor MLXLocalProvider: LocalInferenceProvider {
    public struct Config: Sendable {
        public var extractorModelID: String
        public var embedderModelID: String
        public var rerankerModelID: String
        public var rerankerMaxTokens: Int
        public var allowCosineRerankFallback: Bool
        public var generateMaxTokens: Int
        public var temperature: Float
        public var resourceCaps: InferenceResourceCaps

        public init(extractorModelID: String = "mlx-community/Qwen3-30B-A3B-4bit-MLX",
                    embedderModelID: String = "nomic-ai/nomic-embed-text-v1.5",
                    rerankerModelID: String = "BAAI/bge-reranker-v2-m3",
                    rerankerMaxTokens: Int = 8192,
                    allowCosineRerankFallback: Bool = true,
                    generateMaxTokens: Int = 1024,
                    temperature: Float = 0.0,
                    resourceCaps: InferenceResourceCaps = .default) {
            self.extractorModelID = extractorModelID
            self.embedderModelID = embedderModelID
            self.rerankerModelID = rerankerModelID
            self.rerankerMaxTokens = rerankerMaxTokens
            self.allowCosineRerankFallback = allowCosineRerankFallback
            self.generateMaxTokens = generateMaxTokens
            self.temperature = temperature
            self.resourceCaps = resourceCaps
        }
    }

    nonisolated public let embeddingDimension: Int
    public let config: Config

    #if CODEXKIT_MLX
    /// Lazy containers. We only load the weights on first call so a
    /// `codex-memory verify` doesn't pay the full ~17.5 GB residence.
    private var extractor: ModelContainer?
    private var embedder: EmbedderModelContainer?
    private var reranker: EmbedderModelContainer?
    private var rerankerLoadFailure: String?
    private var memoryConfigured = false
    #endif

    public init(embeddingDimension: Int = 1536,
                config: Config = Config()) {
        self.embeddingDimension = embeddingDimension
        self.config = config
    }

    public func extract(_ batch: ChunkBatch,
                        schema: ExtractionSchema,
                        deadline: Deadline) async throws -> ExtractionResult {
        #if CODEXKIT_MLX
        let container = try await loadExtractor()
        let prompt = ExtractionPrompt.render(batch: batch, schema: schema)
        let text = try await generate(container: container, prompt: prompt,
                                       deadline: deadline)
        let perChunk = try ExtractionPrompt.parseJSON(
            text, batch: batch, schema: schema)
        return ExtractionResult(perChunk: perChunk,
                                tokensInput: max(1, prompt.utf8.count / 4),
                                tokensOutput: max(1, text.utf8.count / 4))
        #else
        throw InferenceError.providerUnavailable(
            "MLX Swift LM not linked — rebuild with MLX enabled")
        #endif
    }

    public func contextualize(_ chunk: Chunk,
                              in document: DocumentDigest,
                              deadline: Deadline) async throws -> String {
        #if CODEXKIT_MLX
        let container = try await loadExtractor()
        let prompt = ContextualisePrompt.render(chunk: chunk, document: document)
        let text = try await generate(container: container, prompt: prompt,
                                       deadline: deadline)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw InferenceError.providerUnavailable("MLX not linked")
        #endif
    }

    public func embed(_ texts: [String], deadline: Deadline) async throws -> [Embedding] {
        #if CODEXKIT_MLX
        let container = try await loadEmbedder()
        // Encode every text inside the container's serial executor so the
        // tokenizer/model/pooling lifecycle stays on the embedder's thread.
        let vectors: [[Float]] = await container.perform {
            (context: EmbedderModelContext) -> [[Float]] in
            var output: [[Float]] = []
            let tokenizer = context.tokenizer
            for text in texts {
                if deadline.hasPassed { break }
                let tokenIds = tokenizer.encode(text: text, addSpecialTokens: true)
                let inputIds = MLXArray(tokenIds).expandedDimensions(axis: 0)
                let mask = MLX.ones([tokenIds.count], type: Int32.self)
                    .expandedDimensions(axis: 0)
                let modelOutput = context.model(
                    inputIds, positionIds: nil, tokenTypeIds: nil,
                    attentionMask: mask)
                let pooled = context.pooling(
                    modelOutput, normalize: true, applyLayerNorm: true)
                pooled.eval()
                output.append(EmbeddingDimensions.adapt(
                    pooled[0].asArray(Float.self), to: embeddingDimension))
            }
            return output
        }
        return vectors.map { values -> Embedding in
            var emb = Embedding(values); emb.normalise(); return emb
        }
        #else
        throw InferenceError.providerUnavailable("MLX not linked")
        #endif
    }

    public func rerank(_ query: String,
                       candidates: [String],
                       deadline: Deadline) async throws -> [Float] {
        if candidates.isEmpty { return [] }
        #if CODEXKIT_MLX
        if rerankerLoadFailure == nil {
            do {
                let container = try await loadReranker()
                return try await scoreWithBGEReranker(container: container,
                                                      query: query,
                                                      candidates: candidates,
                                                      deadline: deadline)
            } catch {
                rerankerLoadFailure = String(describing: error)
                if !config.allowCosineRerankFallback { throw error }
            }
        }
        return try await cosineRerank(query: query,
                                      candidates: candidates,
                                      deadline: deadline)
        #else
        return try await cosineRerank(query: query,
                                      candidates: candidates,
                                      deadline: deadline)
        #endif
    }

    public func logprob(_ text: String,
                        given: String?,
                        deadline: Deadline) async throws -> Double {
        // MLXLMCommon doesn't expose per-token logprobs as a public API yet;
        // approximate with token-count as a stable, monotone signal so the
        // info-gain scoring still differentiates between short/dense chunks.
        let tokens = max(1, text.utf8.count / 4)
        return min(8.0, max(0.5, log2(Double(tokens))))
    }

    /// General local chat/text completion for extension-owned utility tasks.
    /// The main agent loop never calls this; mem0 uses it to run extraction on
    /// the same local Qwen model that powers wiki contextualization/extraction.
    public func complete(_ messages: [LocalChatMessage],
                         deadline: Deadline) async throws -> String {
        #if CODEXKIT_MLX
        let container = try await loadExtractor()
        let prompt = Self.renderChat(messages)
        return try await generate(container: container, prompt: prompt,
                                  deadline: deadline)
        #else
        throw InferenceError.providerUnavailable("MLX not linked")
        #endif
    }

    public static var isAvailable: Bool {
        isAvailable(env: ProcessInfo.processInfo.environment)
    }

    public static func isAvailable(env: [String: String]) -> Bool {
        #if CODEXKIT_MLX
        guard runtimeEnabled(env: env) else { return false }
        #if os(macOS) && canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else { return false }
        #endif
        return hasDefaultMetalLibrary(env: env)
        #else
        _ = env
        return false
        #endif
    }

    // MARK: - lazy load

    #if CODEXKIT_MLX
    private func configureMemoryIfNeeded() throws {
        guard !memoryConfigured else { return }
        guard Self.isAvailable else {
            throw InferenceError.providerUnavailable(
                "MLX runtime unavailable: default Metal library not found or disabled")
        }
        // Pin MLX caps lazily so mock/remote modes and provider construction do
        // not touch Metal. The design doc fixes these values for the M3 Max
        // 48 GB tier; raise on M5 Max 128 GB.
        MLX.Memory.cacheLimit = Int(config.resourceCaps.mlxGPUCacheBytes)
        MLX.Memory.memoryLimit = Int(config.resourceCaps.mlxMemoryLimitBytes)
        memoryConfigured = true
    }

    private static func renderChat(_ messages: [LocalChatMessage]) -> String {
        var parts: [String] = []
        for message in messages {
            let role = message.role.lowercased()
            let normalizedRole: String
            switch role {
            case "system", "developer": normalizedRole = "system"
            case "assistant": normalizedRole = "assistant"
            default: normalizedRole = "user"
            }
            parts.append("<|\(normalizedRole)|>\n\(message.content)")
        }
        parts.append("<|assistant|>\n")
        return parts.joined(separator: "\n\n")
    }

    private func loadExtractor() async throws -> ModelContainer {
        if let extractor { return extractor }
        try configureMemoryIfNeeded()
        let configuration = ModelConfiguration(id: config.extractorModelID)
        let factory = LLMModelFactory.shared
        let container = try await factory.loadContainer(
            from: CodexKitHubDownloader(),
            using: CodexKitTokenizerLoader(),
            configuration: configuration)
        self.extractor = container
        return container
    }

    private func loadEmbedder() async throws -> EmbedderModelContainer {
        if let embedder { return embedder }
        try configureMemoryIfNeeded()
        let configuration = ModelConfiguration(id: config.embedderModelID)
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: CodexKitHubDownloader(),
            using: CodexKitTokenizerLoader(),
            configuration: configuration)
        self.embedder = container
        return container
    }

    private func loadReranker() async throws -> EmbedderModelContainer {
        if let reranker { return reranker }
        try configureMemoryIfNeeded()
        let configuration = ModelConfiguration(id: config.rerankerModelID)
        let container = try await BGERerankerFactory.shared.loadContainer(
            from: CodexKitHubDownloader(),
            using: CodexKitTokenizerLoader(),
            configuration: configuration)
        self.reranker = container
        return container
    }

    private func scoreWithBGEReranker(container: EmbedderModelContainer,
                                      query: String,
                                      candidates: [String],
                                      deadline: Deadline) async throws -> [Float] {
        try await container.perform { (context: EmbedderModelContext) throws -> [Float] in
            guard let model = context.model as? BGERerankerModel else {
                throw InferenceError.providerUnavailable("BGE reranker model did not load classifier head")
            }
            var scores: [Float] = []
            scores.reserveCapacity(candidates.count)
            let tokenizer = context.tokenizer
            let bos = tokenizer.bosToken.flatMap { tokenizer.convertTokenToId($0) }
            let eos = tokenizer.eosToken.flatMap { tokenizer.convertTokenToId($0) }
            for candidate in candidates {
                if deadline.hasPassed { throw InferenceError.deadlineExceeded }
                let tokenIds = Self.pairTokenIDs(query: query,
                                                 candidate: candidate,
                                                 tokenizer: tokenizer,
                                                 bosTokenID: bos,
                                                 eosTokenID: eos,
                                                 maxTokens: config.rerankerMaxTokens)
                guard !tokenIds.isEmpty else {
                    scores.append(0)
                    continue
                }
                let inputIds = MLXArray(tokenIds).expandedDimensions(axis: 0)
                let mask = MLX.ones([tokenIds.count], type: Int32.self)
                    .expandedDimensions(axis: 0)
                let logits = model.score(inputIds, attentionMask: mask)
                logits.eval()
                scores.append(logits.asArray(Float.self).first ?? 0)
            }
            return scores
        }
    }

    private func generate(container: ModelContainer,
                          prompt: String,
                          deadline: Deadline) async throws -> String {
        let parameters = GenerateParameters(
            maxTokens: config.generateMaxTokens,
            temperature: config.temperature)
        let result = try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(prompt: .text(prompt)))
            // Modern AsyncStream-based generate. Cancellation/deadline are
            // observed in the for-await loop; the iterator is dropped on
            // break, which tears down the underlying task cleanly.
            let stream = try MLXLMCommon.generate(
                input: input, parameters: parameters, context: context)
            var output = ""
            for await generation in stream {
                if deadline.hasPassed || Task.isCancelled { break }
                switch generation {
                case .chunk(let text): output += text
                case .info, .toolCall: break
                }
            }
            return output
        }
        return result
    }
    #endif

    private func cosineRerank(query: String,
                              candidates: [String],
                              deadline: Deadline) async throws -> [Float] {
        let all = try await embed([query] + candidates, deadline: deadline)
        guard let q = all.first else { return [] }
        return all.dropFirst().map { c in
            var dot: Float = 0
            for i in 0..<q.values.count { dot += q.values[i] * c.values[i] }
            return dot
        }
    }

    #if CODEXKIT_MLX
    static func pairTokenIDs(query: String,
                             candidate: String,
                             tokenizer: any Tokenizer,
                             bosTokenID: Int?,
                             eosTokenID: Int?,
                             maxTokens: Int) -> [Int] {
        let limit = Swift.max(8, maxTokens)
        let queryIds = tokenizer.encode(text: query, addSpecialTokens: false)
        let candidateIds = tokenizer.encode(text: candidate, addSpecialTokens: false)
        guard let bosTokenID, let eosTokenID else {
            return Array(tokenizer.encode(text: "\(query)\n\n\(candidate)",
                                          addSpecialTokens: true).prefix(limit))
        }
        var out = [bosTokenID]
        out.append(contentsOf: queryIds)
        out.append(eosTokenID)
        out.append(eosTokenID)
        out.append(contentsOf: candidateIds)
        out.append(eosTokenID)
        if out.count <= limit { return out }
        let fixedTokens = 4
        let budget = Swift.max(1, limit - fixedTokens)
        let queryBudget = Swift.max(1, budget / 2)
        let candidateBudget = Swift.max(1, budget - queryBudget)
        return [bosTokenID]
            + Array(queryIds.prefix(queryBudget))
            + [eosTokenID, eosTokenID]
            + Array(candidateIds.prefix(candidateBudget))
            + [eosTokenID]
    }
    #endif
}

#if CODEXKIT_MLX
private extension MLXLocalProvider {
    static func runtimeEnabled(env: [String: String]) -> Bool {
        if env["CODEXKIT_MOCK"] == "1" { return false }
        if env["CODEXKIT_MLX"] == "0" { return false }
        if env["CODEXKIT_MLX_RUNTIME"] == "0" { return false }
        if env["CODEXKIT_DISABLE_MLX"] == "1" { return false }
        return true
    }

    static func hasDefaultMetalLibrary(env: [String: String]) -> Bool {
        _ = env
        let fm = FileManager.default

        var candidateDirs: [URL] = []
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidateDirs.append(executableDir)
        }
        if let mainResources = Bundle.main.resourceURL {
            candidateDirs.append(mainResources)
        }
        if let cmlxResources = Bundle(identifier: "mlx-swift_Cmlx")?.resourceURL {
            candidateDirs.append(cmlxResources)
        }
        candidateDirs.append(contentsOf: Bundle.allBundles.compactMap(\.resourceURL))
        candidateDirs.append(contentsOf: Bundle.allFrameworks.compactMap(\.resourceURL))
        candidateDirs.append(URL(fileURLWithPath: fm.currentDirectoryPath))

        var seen = Set<String>()
        for dir in candidateDirs {
            let base = dir.standardizedFileURL.path
            guard seen.insert(base).inserted else { continue }
            let names = [
                "mlx.metallib",
                "Resources/mlx.metallib",
                "default.metallib",
                "Resources/default.metallib",
            ]
            for name in names {
                let path = dir.appendingPathComponent(name).standardizedFileURL.path
                if fm.isReadableFile(atPath: path) { return true }
            }
        }
        return false
    }
}
#endif
