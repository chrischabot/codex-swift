import Foundation
import InfraPrimitives

/// Deterministic, dependency-free provider for tests. Embeddings are produced
/// by a stable hash → unit-normalised float vector so equal inputs map to
/// equal embeddings and near-duplicate inputs land close in cosine space.
public actor MockInferenceProvider: LocalInferenceProvider {
    nonisolated public let embeddingDimension: Int
    private let salt: UInt64

    public init(embeddingDimension: Int = 768, salt: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.embeddingDimension = embeddingDimension
        self.salt = salt
    }

    public func extract(_ batch: ChunkBatch,
                        schema: ExtractionSchema,
                        deadline: Deadline) async throws -> ExtractionResult {
        if batch.chunks.isEmpty {
            return ExtractionResult(perChunk: [], tokensInput: 0, tokensOutput: 0)
        }
        let allowedKinds = Set(schema.allowedEntityKinds)
        let allowedRelations = Set(schema.allowedRelations)
        var per: [ExtractedChunk] = []
        per.reserveCapacity(batch.chunks.count)

        for chunk in batch.chunks {
            // Heuristic: every Capitalised word is a "concept" entity, two
            // adjacent capitalised words form a "mentions" edge. This is
            // enough to exercise dedupe, ego-betweenness, graph-novelty.
            let words = chunk.contextualised
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)

            var caps: [String] = []
            for w in words {
                if let first = w.first, first.isUppercase, w.count > 1 {
                    caps.append(w)
                }
            }
            let unique = Array(NSOrderedSet(array: caps)).compactMap { $0 as? String }
            let kind = allowedKinds.contains("concept") ? "concept"
                       : (schema.allowedEntityKinds.first ?? "concept")
            let entities = unique.map { ExtractedEntity(kind: kind, canonical: $0) }
            let relation = allowedRelations.contains("mentions") ? "mentions"
                           : (schema.allowedRelations.first ?? "mentions")
            var edges: [ExtractedEdge] = []
            if entities.count >= 2 {
                for i in 0..<(entities.count - 1) {
                    edges.append(ExtractedEdge(
                        src: entities[i].canonical,
                        dst: entities[i + 1].canonical,
                        relation: relation,
                        evidenceChunkId: chunk.localId))
                }
            }
            per.append(ExtractedChunk(
                localId: chunk.localId,
                entities: entities,
                edges: edges,
                logprobAvgBits: Double(chunk.rawText.utf8.count % 8) + 1.0))
        }
        let inTok = batch.chunks.reduce(0) { $0 + max(1, $1.rawText.utf8.count / 4) }
        let outTok = per.reduce(0) { $0 + $1.entities.count + $1.edges.count }
        return ExtractionResult(perChunk: per, tokensInput: inTok, tokensOutput: outTok)
    }

    public func contextualize(_ chunk: Chunk,
                              in document: DocumentDigest,
                              deadline: Deadline) async throws -> String {
        let title = document.title ?? document.uri
        return "From \"\(title)\" (chunk \(chunk.idx)):"
    }

    public func embed(_ texts: [String], deadline: Deadline) async throws -> [Embedding] {
        return texts.map { Self.deterministicEmbedding($0, dim: embeddingDimension, salt: salt) }
    }

    public func rerank(_ query: String,
                       candidates: [String],
                       deadline: Deadline) async throws -> [Float] {
        // Cosine on the deterministic embeddings is monotone in lexical
        // similarity for the mock, which is good enough for tests.
        let q = Self.deterministicEmbedding(query, dim: embeddingDimension, salt: salt)
        return candidates.map { c in
            let e = Self.deterministicEmbedding(c, dim: embeddingDimension, salt: salt)
            var dot: Float = 0
            for i in 0..<q.values.count { dot += q.values[i] * e.values[i] }
            return dot
        }
    }

    public func logprob(_ text: String, given: String?, deadline: Deadline) async throws -> Double {
        let h = Self.fnv1a64(text + (given ?? ""), salt: salt)
        // Map to a stable [0.5, 6.0] bits/token range — deterministic across runs.
        let mantissa = Double(h % 1100) / 200.0
        return 0.5 + mantissa
    }

    // MARK: - deterministic hashing

    static func fnv1a64(_ s: String, salt: UInt64) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325 &+ salt
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01B3
        }
        return h
    }

    static func deterministicEmbedding(_ s: String, dim: Int, salt: UInt64) -> Embedding {
        var out = [Float](repeating: 0, count: dim)
        var state = fnv1a64(s, salt: salt)
        for i in 0..<dim {
            // xorshift to roll the next pseudo-random float; mapped to [-1,1).
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let u = Float(state & 0xFFFF_FFFF) / Float(UInt32.max)
            out[i] = (u * 2) - 1
        }
        var emb = Embedding(out)
        emb.normalise()
        return emb
    }
}
