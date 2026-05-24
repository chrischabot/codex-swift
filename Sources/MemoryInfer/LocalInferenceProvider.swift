import Foundation
import InfraPrimitives

/// The protocol seam described in §2 of the design doc. All inference flows
/// (extraction, embedding, reranking, contextualisation, logprob lookup) cross
/// this boundary; the rest of the memory subsystem is provider-agnostic.
///
/// Two concrete impls ship:
/// - `MLXLocalProvider` on macOS once the MLX Swift LM package is added.
/// - `RemoteOpenAICompatibleProvider` everywhere else (CI on Linux, Apple
///   Silicon hosts running an external llama.cpp/vLLM endpoint, etc.).
public protocol LocalInferenceProvider: Sendable {
    /// Best-effort `Embedding` dimension reported by this provider. The store
    /// asserts equality with `MemoryStoreConfig.embeddingDimension` on init.
    var embeddingDimension: Int { get }

    /// Extract entities/edges from a chunk batch. Implementations must respect
    /// the schema's allowed kind/relation lists; downstream code throws on
    /// out-of-schema values.
    func extract(_ batch: ChunkBatch,
                 schema: ExtractionSchema,
                 deadline: Deadline) async throws -> ExtractionResult

    /// Produce the Anthropic-style situating prefix for a single chunk inside
    /// a larger document. Returns plain text; the contextualiser layer
    /// prepends it to the raw chunk before embed/index.
    func contextualize(_ chunk: Chunk,
                       in document: DocumentDigest,
                       deadline: Deadline) async throws -> String

    /// Bulk embed; results are L2-normalised by the provider.
    func embed(_ texts: [String], deadline: Deadline) async throws -> [Embedding]

    /// Cross-encoder rerank scores; same length as `candidates`.
    func rerank(_ query: String,
                candidates: [String],
                deadline: Deadline) async throws -> [Float]

    /// Mean bits-per-token under the local extractor for `text` conditioned on
    /// `given`. Used as the information-gain signal in MemoryScore.
    func logprob(_ text: String,
                 given: String?,
                 deadline: Deadline) async throws -> Double
}

/// Light-weight `Embedding` value mirrored from MemoryStore so MemoryInfer
/// has no MemoryStore dependency. The two structs are isomorphic by design;
/// MemoryStore re-imports `MemoryInfer.Embedding` indirectly through the
/// shared shape (Float32, L2-normalised).
public struct Embedding: Sendable, Equatable {
    public var values: [Float]
    public init(_ values: [Float]) { self.values = values }
    public var dimension: Int { values.count }

    public mutating func normalise() {
        var sum: Float = 0
        for v in values { sum += v * v }
        let n = sum.squareRoot()
        guard n > 0 else { return }
        for i in 0..<values.count { values[i] /= n }
    }
    public func normalised() -> Embedding {
        var copy = self; copy.normalise(); return copy
    }
}

public enum InferenceError: Error, Sendable, CustomStringConvertible {
    case schemaViolation(String)
    case providerUnavailable(String)
    case malformedResponse(String)
    case deadlineExceeded
    public var description: String {
        switch self {
        case .schemaViolation(let s):    return "schema violation: \(s)"
        case .providerUnavailable(let s):return "provider unavailable: \(s)"
        case .malformedResponse(let s):  return "malformed response: \(s)"
        case .deadlineExceeded:          return "deadline exceeded"
        }
    }
}
