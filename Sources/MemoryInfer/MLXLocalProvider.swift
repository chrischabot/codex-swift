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

/// Apple-only adapter. When the SwiftPM build is invoked with
/// `CODEXKIT_MLX=1` in the environment, Package.swift pulls in `MLX`,
/// `MLXLMCommon`, `MLXLLM`, and `MLXEmbedders` and this file imports them
/// behind `#if CODEXKIT_MLX`. The result is a real `LocalInferenceProvider`
/// that hosts the extractor + embedder in-process. Without the flag, the
/// stub throws `providerUnavailable` and the assembler downgrades to the
/// remote/mock backend automatically.
///
/// Model defaults (per the design doc):
///   extractor: mlx-community/Qwen3-30B-A3B-4bit-MLX  (30B/3B-active MoE — the
///              on-device triage/extraction lane; `extractorModelID` is a config
///              knob, so any mlx-swift-lm-supported model can be substituted)
///   embedder:  nomic-ai/nomic-embed-text-v1.5
///   reranker:  not yet — see MLXLocalProvider+Reranker for the planned
///              hand-rolled BertForSequenceClassification head.
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
        public var generateMaxTokens: Int
        public var temperature: Float
        public var resourceCaps: InferenceResourceCaps

        public init(extractorModelID: String = "mlx-community/Qwen3-30B-A3B-4bit-MLX",
                    embedderModelID: String = "nomic-ai/nomic-embed-text-v1.5",
                    generateMaxTokens: Int = 1024,
                    temperature: Float = 0.0,
                    resourceCaps: InferenceResourceCaps = .default) {
            self.extractorModelID = extractorModelID
            self.embedderModelID = embedderModelID
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
    #endif

    public init(embeddingDimension: Int = 768,
                config: Config = Config()) {
        self.embeddingDimension = embeddingDimension
        self.config = config
        #if CODEXKIT_MLX
        // Pin MLX caps on first instantiation. The design doc fixes these
        // values for the M3 Max 48 GB tier; raise on M5 Max 128 GB.
        // Uses the modern `Memory.cacheLimit` / `Memory.memoryLimit` property
        // API; the static `GPU.set(...)` setters are deprecated.
        MLX.Memory.cacheLimit = Int(config.resourceCaps.mlxGPUCacheBytes)
        MLX.Memory.memoryLimit = Int(config.resourceCaps.mlxMemoryLimitBytes)
        #endif
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
            "MLX Swift LM not linked — rebuild with CODEXKIT_MLX=1")
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
                output.append(pooled[0].asArray(Float.self))
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
        // First-stage rerank: cosine over freshly-computed embeddings. The
        // documented BGE-reranker-v2-m3 cross-encoder head is a follow-up
        // (design doc §12: "we ship a hand-rolled
        // BertForSequenceClassification on top of MLXEmbedders.Bert").
        let all = try await embed([query] + candidates, deadline: deadline)
        guard let q = all.first else { return [] }
        return all.dropFirst().map { c in
            var dot: Float = 0
            for i in 0..<q.values.count { dot += q.values[i] * c.values[i] }
            return dot
        }
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

    public static let isAvailable: Bool = {
        #if CODEXKIT_MLX
        return true
        #else
        return false
        #endif
    }()

    // MARK: - lazy load

    #if CODEXKIT_MLX
    private func loadExtractor() async throws -> ModelContainer {
        if let extractor { return extractor }
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
        let configuration = ModelConfiguration(id: config.embedderModelID)
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: CodexKitHubDownloader(),
            using: CodexKitTokenizerLoader(),
            configuration: configuration)
        self.embedder = container
        return container
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
}
