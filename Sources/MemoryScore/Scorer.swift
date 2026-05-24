import Foundation
import InfraPrimitives
import MemoryStore
import MemoryInfer

/// Inputs to the gate: a chunk row already committed to MemoryStore plus the
/// extraction signals MemoryProcess accumulated. Used both immediately after
/// processing (the "live" gate path) and during retrieval reranking.
public struct ScoreInputs: Sendable, Equatable {
    public var chunkId: Int64
    public var documentId: Int64
    public var embedding: [Float]
    public var entityIds: [Int64]
    public var newEdgesBetweenKnown: Int
    public var totalEdgesInDoc: Int
    public var logprobAvgBits: Double?
    public init(chunkId: Int64, documentId: Int64, embedding: [Float],
                entityIds: [Int64], newEdgesBetweenKnown: Int,
                totalEdgesInDoc: Int, logprobAvgBits: Double?) {
        self.chunkId = chunkId
        self.documentId = documentId
        self.embedding = embedding
        self.entityIds = entityIds
        self.newEdgesBetweenKnown = newEdgesBetweenKnown
        self.totalEdgesInDoc = totalEdgesInDoc
        self.logprobAvgBits = logprobAvgBits
    }
}

public actor Scorer {
    public struct Config: Sendable {
        public var topKNeighbours: Int
        public var infoGainMaxBits: Double
        public var nearestNeighbourSearchK: Int
        public init(topKNeighbours: Int = 25,
                    infoGainMaxBits: Double = 8.0,
                    nearestNeighbourSearchK: Int = 25) {
            self.topKNeighbours = topKNeighbours
            self.infoGainMaxBits = infoGainMaxBits
            self.nearestNeighbourSearchK = nearestNeighbourSearchK
        }
    }

    private let store: MemoryStore
    private let config: Config

    public init(store: MemoryStore, config: Config = Config()) {
        self.store = store
        self.config = config
    }

    /// Score one chunk against the live store. Higher = more interesting.
    public func score(_ inputs: ScoreInputs, persona: Persona) async throws -> ScoreBreakdown {
        let novelty = try await embeddingNovelty(inputs)
        let graphNov = graphNovelty(inputs)
        let bridge = try await bridgeCentrality(entities: inputs.entityIds)
        let infoGain = informationGain(inputs)
        let bonus = try await entityKindBonus(entities: inputs.entityIds, persona: persona)
        let total =
            persona.weightEmbeddingNovelty * novelty +
            persona.weightGraphNovelty     * graphNov +
            persona.weightBridgeCentrality * bridge +
            persona.weightInformationGain  * infoGain +
            bonus
        return ScoreBreakdown(
            chunkId: inputs.chunkId,
            embeddingNovelty: novelty,
            graphNovelty: graphNov,
            bridgeCentrality: bridge,
            informationGain: infoGain,
            entityBonus: bonus,
            total: total)
    }

    // MARK: - signals

    /// `1 - max_cosine_to_top_K_neighbours` against the store. Excludes the
    /// chunk being scored (its own embedding would land at distance 0).
    func embeddingNovelty(_ inputs: ScoreInputs) async throws -> Double {
        let hits = try await store.searchVectorValues(
            inputs.embedding, k: config.nearestNeighbourSearchK + 1)
        // Distance 0 = identical; we want the smallest non-self distance.
        var smallest = Double.infinity
        for h in hits where h.chunkId != inputs.chunkId {
            if h.distance < smallest { smallest = h.distance }
        }
        if smallest == .infinity { return 1.0 }     // first chunk ever
        // Cosine distance is already in [0,2]; clamp into [0,1] for combination.
        return Swift.min(1, Swift.max(0, smallest))
    }

    /// Fraction of edges produced by this doc that connect two already-known
    /// entities. The processor records the count so we don't re-scan SQL here.
    func graphNovelty(_ inputs: ScoreInputs) -> Double {
        guard inputs.totalEdgesInDoc > 0 else { return 0 }
        return Double(inputs.newEdgesBetweenKnown) / Double(inputs.totalEdgesInDoc)
    }

    /// Mean of cached `ego_betweenness_cached` over the chunk's entities; if
    /// the cache is cold for any entity, compute Brandes on its 2-hop ego
    /// subgraph and persist the result.
    func bridgeCentrality(entities: [Int64]) async throws -> Double {
        guard !entities.isEmpty else { return 0 }
        var values: [Double] = []
        for entId in entities {
            if let cached = try await store.entity(id: entId)?.egoBetweennessCached {
                values.append(cached)
                continue
            }
            // Build 2-hop ego subgraph adjacency and run Brandes.
            let nodes = try await store.twoHopNeighbours(seed: entId, depth: 2)
            let nodeSet = Set(nodes.map(\.0))
            var adj = [Int64: Set<Int64>]()
            for n in nodeSet { adj[n] = [] }
            for n in nodeSet {
                let edges = try await store.edges(fromOrTo: n)
                for e in edges where nodeSet.contains(e.src) && nodeSet.contains(e.dst) {
                    adj[e.src, default: []].insert(e.dst)
                    adj[e.dst, default: []].insert(e.src)
                }
            }
            let b = EgoBetweenness.compute(adjacency: adj)
            let mine = b[entId] ?? 0
            try await store.setEgoBetweenness(entityId: entId, value: mine)
            values.append(mine)
        }
        // Average — the design doc spells `s_b` as a normalised ego-betweenness.
        return values.reduce(0, +) / Double(values.count)
    }

    /// Information gain proxy. The extractor emits mean bits-per-token; we
    /// map that linearly into [0, 1] using `infoGainMaxBits` as the ceiling.
    func informationGain(_ inputs: ScoreInputs) -> Double {
        guard let bits = inputs.logprobAvgBits else { return 0 }
        return Swift.min(1, Swift.max(0, bits / config.infoGainMaxBits))
    }

    func entityKindBonus(entities: [Int64], persona: Persona) async throws -> Double {
        guard !entities.isEmpty else { return 0 }
        var bonus: Double = 0
        for entId in entities {
            guard let row = try await store.entity(id: entId) else { continue }
            if let b = persona.entityKindBonuses[row.kind.rawValue] {
                bonus += b
            }
        }
        return bonus
    }
}
