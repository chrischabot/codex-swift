import Foundation
import InfraPrimitives
import MemoryInfer
import MemoryStore

public struct RetrievedHit: Sendable, Equatable {
    public var chunkId: Int64
    public var documentId: Int64
    public var documentURI: String
    public var snippet: String
    public var score: Double
    public var why: Why

    public struct Why: Sendable, Equatable {
        public var bm25: Double
        public var vec: Double
        public var rerank: Double
        public init(bm25: Double = 0, vec: Double = 0, rerank: Double = 0) {
            self.bm25 = bm25; self.vec = vec; self.rerank = rerank
        }
    }
    public init(chunkId: Int64, documentId: Int64, documentURI: String,
                snippet: String, score: Double, why: Why) {
        self.chunkId = chunkId
        self.documentId = documentId
        self.documentURI = documentURI
        self.snippet = snippet
        self.score = score
        self.why = why
    }
}

/// Hybrid search: FTS5 BM25 + sqlite-vec cosine → RRF fuse → optional rerank.
/// Implements the §6 pipeline. The reranker is the BGE-reranker-v2-m3 cross
/// encoder when MLX is wired in; the remote fallback reduces to cosine on
/// fresh embeddings (a one-stage rerank).
public actor MemoryRetriever {
    public struct Config: Sendable {
        public var bm25TopK: Int
        public var vecTopK: Int
        public var fuseTopK: Int
        public var finalTopK: Int
        public var rrfK: Double
        public var embedDeadline: Duration
        public var rerankDeadline: Duration
        /// Post-fusion boosts (recency, …) apply only to candidates whose base
        /// score is ≥ floorRatio·topBaseScore — the gbrain floor-ratio gate that
        /// stops weak pages leapfrogging strong hits. `nil` disables the gate.
        /// Defaulted at the property level so the init signature stays stable.
        public var floorRatio: Double? = 0.85
        public init(bm25TopK: Int = 200, vecTopK: Int = 200,
                    fuseTopK: Int = 50, finalTopK: Int = 10,
                    rrfK: Double = 60,
                    embedDeadline: Duration = .seconds(5),
                    rerankDeadline: Duration = .seconds(3)) {
            self.bm25TopK = bm25TopK
            self.vecTopK = vecTopK
            self.fuseTopK = fuseTopK
            self.finalTopK = finalTopK
            self.rrfK = rrfK
            self.embedDeadline = embedDeadline
            self.rerankDeadline = rerankDeadline
        }
    }

    private let store: MemoryStore
    private let inference: any LocalInferenceProvider
    private let config: Config
    private let embedCache: QueryEmbeddingCache

    public init(store: MemoryStore,
                inference: any LocalInferenceProvider,
                config: Config = Config(),
                embedCacheCapacity: Int = 128,
                embedCacheModelId: String = "default") {
        self.store = store
        self.inference = inference
        self.config = config
        self.embedCache = QueryEmbeddingCache(capacity: embedCacheCapacity,
                                              modelId: embedCacheModelId)
    }

    // MARK: - embed-cache surface (used by tests; also exposed to callers
    //         that want to invalidate after a model swap)
    public nonisolated var embedCacheHitCount: Int { embedCache.hitCount }
    public nonisolated var embedCacheMissCount: Int { embedCache.missCount }
    public nonisolated func invalidateEmbedCache() { embedCache.invalidateAll() }
    /// The cross-model cache discriminator actually in force (the resolved embedding
    /// provider id when wired correctly; "default" if a caller forgot to pass it).
    public nonisolated var embedCacheModelId: String { embedCache.modelId }

    /// Run the full pipeline. `rerank` defaults to true; tests and the
    /// `ask_local_brain` MCP tool can flip it off to skip the cross-encoder.
    public func search(_ query: String, k: Int? = nil,
                       rerank: Bool = true) async throws -> [RetrievedHit] {
        // An empty query has no meaningful BM25 / vec hit; short-circuit so
        // we don't bill an embedding call or send an empty MATCH expression
        // to FTS5 (which would crash with a parse error).
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        // Zero-LLM intent classification reshapes the final blend (gbrain.md
        // Wave 2.16). `.general` reproduces the historical 0.7/0.2/0.1 weights, so
        // an ordinary query is byte-for-byte unchanged.
        let weights = QueryIntentClassifier.resolve(trimmed).weights
        // Pre-normalize the query once for the title exact-match bonus (gbrain Wave 2.18).
        // entity intent carries exactMatchBonus=0.15; every other intent carries 0.0, so
        // this is a no-op off the entity lane.
        let exactKeys = Self.exactMatchKeys(trimmed)
        let topK = Self.clampedPositive(k ?? config.finalTopK, defaultValue: 10, max: 100)
        let fuseTopK = Self.clampedPositive(config.fuseTopK, defaultValue: 50, max: 1_000)
        async let bm25Task = bm25TopHits(query)
        async let vecTask  = vecTopHits(query)
        let (bm25, vec) = try await (bm25Task, vecTask)
        let fused = ReciprocalRankFusion.fuse(
            [bm25.map(\.chunkId), vec.map(\.chunkId)],
            kConstant: config.rrfK)
            .prefix(fuseTopK)
            .map { $0 }
        let bm25Scores = Dictionary(uniqueKeysWithValues: bm25.map { ($0.chunkId, $0.score) })
        let vecScores  = Dictionary(uniqueKeysWithValues: vec.map { ($0.chunkId, 1 - $0.distance) })

        // Hydrate chunk + document records for the fused candidates.
        var hydrated: [(ChunkRow, DocumentRow)] = []
        for cid in fused {
            guard let chunk = try await store.chunk(id: cid),
                  let doc = try await store.document(id: chunk.documentId) else { continue }
            hydrated.append((chunk, doc))
        }
        guard !hydrated.isEmpty else { return [] }

        // Cross-encoder rerank (or cosine fallback) when requested.
        var rerankScores: [Float] = Array(repeating: 0, count: hydrated.count)
        if rerank {
            let candidates = hydrated.map { $0.0.text }
            // Only adopt the reranker's scores if it returned EXACTLY one per
            // candidate. A short/long result (some providers truncate) would
            // otherwise index `rerankScores[i]` out of range below — keep the
            // all-zero array so rerank simply contributes nothing.
            if let scores = try? await inference.rerank(
                query, candidates: candidates, deadline: .fromNow(config.rerankDeadline)),
               scores.count == hydrated.count {
                rerankScores = scores
            }
        }

        // Compose the final ranked list. We weight by:
        //   final = 0.7 * rerank + 0.2 * (1 - vec_dist) + 0.1 * bm25
        // When rerank is disabled (or all-zero) the second/third terms remain.
        // Pass 1: intent-weighted base score per candidate.
        var base: [(chunk: ChunkRow, doc: DocumentRow,
                    bm25: Double, vec: Double, rerank: Double, score: Double)] = []
        base.reserveCapacity(hydrated.count)
        for (i, pair) in hydrated.enumerated() {
            let (chunk, doc) = pair
            let bm25Score = bm25Scores[chunk.id] ?? 0
            let vecScore  = vecScores[chunk.id]  ?? 0
            let rerankScore = Double(rerankScores[i])
            var s = weights.rerank * rerankScore
                  + weights.vec * vecScore
                  + weights.bm25 * bm25Score
            // Entity-intent exact-title bonus (gbrain Wave 2.18): a document whose title
            // literally equals the query gets weights.exactMatchBonus added to its BASE
            // score, so it participates in the floor-ratio gate and isn't gated out by a
            // near-tie weak page. Gated to entity intent (bonus 0.0 elsewhere) + a strict
            // normalized match, so general/temporal/event ranking is byte-for-byte unchanged.
            if weights.exactMatchBonus > 0,
               let title = doc.title,
               Self.titleExactlyMatches(title, keys: exactKeys) {
                s += weights.exactMatchBonus
            }
            base.append((chunk, doc, bm25Score, vecScore, rerankScore, s))
        }
        // Floor-ratio gate: one threshold computed on the BASE scores before any
        // boost (gbrain.md Wave 2.17). Candidates below it are not boosted.
        let topBase = base.map(\.score).max() ?? 0
        let floor = config.floorRatio.map { $0 * topBase } ?? -.infinity
        let now = Int64(Date().timeIntervalSince1970)
        // Pass 2: recency boost — temporal intent only, above the floor. For a
        // general query (recencyOn == false) total == base, i.e. unchanged.
        var ranked: [RetrievedHit] = []
        ranked.reserveCapacity(base.count)
        for b in base {
            var total = b.score
            if weights.recencyOn, b.score >= floor {
                total *= RecencyDecay.factor(source: b.doc.source, publishedAt: b.doc.publishedAt,
                                             fetchedAt: b.doc.fetchedAt, now: now)
            }
            ranked.append(RetrievedHit(
                chunkId: b.chunk.id, documentId: b.doc.id,
                documentURI: b.doc.sourceURI,
                snippet: Self.snippet(from: b.chunk.text, query: query),
                score: total,
                why: .init(bm25: b.bm25, vec: b.vec, rerank: b.rerank)))
        }
        ranked.sort { $0.score > $1.score }
        return Array(ranked.prefix(topK))
    }

    /// Normalized forms of the query used for the title exact-match bonus: the
    /// lowercased/whitespace-collapsed query plus, when the classifier's entity wrappers
    /// are present, the query with surrounding double-quotes and a single leading '@'
    /// stripped — so quoted spans and @handles still match a plainly-titled document.
    static func exactMatchKeys(_ query: String) -> Set<String> {
        func norm(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        var keys: Set<String> = []
        let base = norm(query)
        if !base.isEmpty { keys.insert(base) }
        var stripped = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("\""), stripped.hasSuffix("\""), stripped.count >= 2 {
            stripped = String(stripped.dropFirst().dropLast())
        }
        if stripped.hasPrefix("@") { stripped = String(stripped.dropFirst()) }
        let s2 = norm(stripped)
        if !s2.isEmpty { keys.insert(s2) }
        return keys
    }

    /// Strict normalized equality of a candidate title against any query key.
    static func titleExactlyMatches(_ title: String, keys: Set<String>) -> Bool {
        guard !keys.isEmpty else { return false }
        let t = title.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return !t.isEmpty && keys.contains(t)
    }

    private static func clampedPositive(_ value: Int,
                                        defaultValue: Int,
                                        max: Int) -> Int {
        guard value > 0 else { return defaultValue }
        return Swift.min(value, max)
    }

    func bm25TopHits(_ query: String) async throws -> [LexicalHit] {
        try await store.searchLexical(query, k: config.bm25TopK)
    }

    func vecTopHits(_ query: String) async throws -> [VectorHit] {
        let values: [Float]
        if let cached = embedCache.get(query) {
            values = cached
        } else {
            let embeddings = try await inference.embed(
                [query], deadline: .fromNow(config.embedDeadline))
            guard let q = embeddings.first else { return [] }
            values = q.values
            embedCache.put(query, values)
        }
        return try await store.searchVectorValues(values, k: config.vecTopK)
    }

    static func snippet(from text: String, query: String, max: Int = 280) -> String {
        if text.count <= max { return text }
        let lower = text.lowercased()
        let lowerQuery = query.lowercased()
        // Find the first query-term hit and centre the snippet on it. The
        // hit index lives in `lower`'s storage, so we resolve it to an
        // integer character offset *within `lower`* and then re-derive
        // both indices off `text` — never crossing storage boundaries.
        // Cross-string index arithmetic is undefined and can trap on
        // strings whose lowercase form has a different grapheme count
        // (e.g. German ß → "ss", Turkish dotted/dotless I).
        var centerOffset = 0
        for token in lowerQuery.split(whereSeparator: { $0.isWhitespace }) {
            if let r = lower.range(of: token) {
                centerOffset = lower.distance(from: lower.startIndex, to: r.lowerBound)
                break
            }
        }
        // Clamp into [0, text.count) since lower and text may not have the
        // exact same character count for some unicode inputs.
        centerOffset = Swift.min(Swift.max(0, centerOffset), text.count)
        let halfSpan = max / 2
        let start = Swift.max(0, centerOffset - halfSpan)
        let end = Swift.min(text.count, start + max)
        let si = text.index(text.startIndex, offsetBy: start)
        let ei = text.index(text.startIndex, offsetBy: end)
        return (start > 0 ? "…" : "") + String(text[si..<ei]) + (end < text.count ? "…" : "")
    }
}

/// Reciprocal Rank Fusion — the canonical hybrid-retrieval combiner. Applied
/// to two or more ranked lists; the fused score for `id` is `Σ 1 / (k + r_i)`
/// where `r_i` is the 1-based rank of `id` in list `i`.
public enum ReciprocalRankFusion {
    public static func fuse(_ rankings: [[Int64]], kConstant: Double = 60) -> [Int64] {
        var score: [Int64: Double] = [:]
        for list in rankings {
            for (rank, id) in list.enumerated() {
                score[id, default: 0] += 1.0 / (kConstant + Double(rank + 1))
            }
        }
        return score.sorted { $0.value > $1.value }.map { $0.key }
    }
}
