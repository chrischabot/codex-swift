import Foundation
import InfraPrimitives
import Mem0Core
import MemoryInfer

public struct Mem0LocalProviderBundle: Sendable {
    public let embedder: any Mem0Embedder
    public let llm: any Mem0LLM
}

public enum Mem0LocalRuntime {
    public static var isAvailable: Bool { MLXLocalProvider.isAvailable }
    public static func isAvailable(env: [String: String]) -> Bool {
        MLXLocalProvider.isAvailable(env: env)
    }

    public static func make(embeddingDimension: Int) -> Mem0LocalProviderBundle {
        let provider = MLXLocalProvider(embeddingDimension: embeddingDimension)
        return Mem0LocalProviderBundle(
            embedder: Mem0LocalEmbedder(provider: provider, dims: embeddingDimension),
            llm: Mem0LocalLLM(provider: provider))
    }
}

public struct Mem0LocalEmbedder: Mem0Embedder {
    let provider: MLXLocalProvider
    public let dims: Int

    public init(provider: MLXLocalProvider, dims: Int) {
        self.provider = provider
        self.dims = dims
    }

    public func embed(_ text: String, _ action: MemoryAction) async throws -> [Float] {
        let values = try await embedBatch([text], action)
        guard let first = values.first else {
            throw Mem0Error.embedding("no embedding returned")
        }
        return first
    }

    public func embedBatch(_ texts: [String], _ action: MemoryAction) async throws -> [[Float]] {
        let embeddings = try await provider.embed(texts, deadline: .fromNow(.seconds(10)))
        return embeddings.map { EmbeddingDimensions.adapt($0.values, to: dims) }
    }
}

public struct Mem0LocalLLM: Mem0LLM {
    let provider: MLXLocalProvider

    public init(provider: MLXLocalProvider) {
        self.provider = provider
    }

    public func generate(_ messages: [Message], _ options: GenerateOptions) async throws -> String {
        var localMessages: [LocalChatMessage] = []
        if options.responseFormatJSON {
            localMessages.append(LocalChatMessage(
                role: "system",
                content: "Return only valid JSON. Do not include markdown fences or prose."))
        }
        localMessages.append(contentsOf: messages.map {
            LocalChatMessage(role: $0.role, content: $0.content)
        })
        return try await provider.complete(localMessages, deadline: .fromNow(.seconds(60)))
    }
}
