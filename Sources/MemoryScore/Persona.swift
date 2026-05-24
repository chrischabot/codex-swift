import Foundation

/// Persona profile — a config-driven set of signal weights and entity-kind
/// preferences. The design doc lists five: cto/cmo/designer/researcher/editor.
/// Personas are pure data; persistence lives in `Config` profiles.
public struct Persona: Sendable, Equatable, Codable {
    public var name: String
    public var weightEmbeddingNovelty: Double
    public var weightGraphNovelty: Double
    public var weightBridgeCentrality: Double
    public var weightInformationGain: Double
    public var entityKindBonuses: [String: Double]
    public var timeDecayHalfLifeDays: Double
    public var pinnedTopics: [String]

    public init(name: String,
                weightEmbeddingNovelty: Double = 0.25,
                weightGraphNovelty: Double = 0.25,
                weightBridgeCentrality: Double = 0.25,
                weightInformationGain: Double = 0.25,
                entityKindBonuses: [String: Double] = [:],
                timeDecayHalfLifeDays: Double = 30,
                pinnedTopics: [String] = []) {
        self.name = name
        self.weightEmbeddingNovelty = weightEmbeddingNovelty
        self.weightGraphNovelty = weightGraphNovelty
        self.weightBridgeCentrality = weightBridgeCentrality
        self.weightInformationGain = weightInformationGain
        self.entityKindBonuses = entityKindBonuses
        self.timeDecayHalfLifeDays = timeDecayHalfLifeDays
        self.pinnedTopics = pinnedTopics
    }

    public static let cto = Persona(
        name: "cto",
        weightEmbeddingNovelty: 0.20,
        weightGraphNovelty: 0.35,
        weightBridgeCentrality: 0.35,
        weightInformationGain: 0.10,
        entityKindBonuses: ["org": 0.10, "product": 0.10, "repo": 0.05])

    public static let cmo = Persona(
        name: "cmo",
        weightEmbeddingNovelty: 0.30,
        weightGraphNovelty: 0.25,
        weightBridgeCentrality: 0.20,
        weightInformationGain: 0.25,
        entityKindBonuses: ["org": 0.15, "product": 0.15])

    public static let designer = Persona(
        name: "designer",
        weightEmbeddingNovelty: 0.40,
        weightGraphNovelty: 0.20,
        weightBridgeCentrality: 0.15,
        weightInformationGain: 0.25,
        entityKindBonuses: ["product": 0.10, "concept": 0.10])

    public static let researcher = Persona(
        name: "researcher",
        weightEmbeddingNovelty: 0.30,
        weightGraphNovelty: 0.10,
        weightBridgeCentrality: 0.15,
        weightInformationGain: 0.45,
        entityKindBonuses: ["paper": 0.20, "person": 0.10])

    public static let editor = Persona(
        name: "editor",
        weightEmbeddingNovelty: 0.30,
        weightGraphNovelty: 0.25,
        weightBridgeCentrality: 0.20,
        weightInformationGain: 0.25,
        entityKindBonuses: ["person": 0.05, "org": 0.05, "concept": 0.05])

    public static let defaults: [String: Persona] = [
        "cto": .cto, "cmo": .cmo, "designer": .designer,
        "researcher": .researcher, "editor": .editor,
    ]
}

/// One scored chunk: the underlying signals are surfaced separately for
/// debugging and for the `why:` field of MCP search results.
public struct ScoreBreakdown: Sendable, Equatable {
    public var chunkId: Int64
    public var embeddingNovelty: Double
    public var graphNovelty: Double
    public var bridgeCentrality: Double
    public var informationGain: Double
    public var entityBonus: Double
    public var total: Double
    public init(chunkId: Int64, embeddingNovelty: Double, graphNovelty: Double,
                bridgeCentrality: Double, informationGain: Double,
                entityBonus: Double, total: Double) {
        self.chunkId = chunkId
        self.embeddingNovelty = embeddingNovelty
        self.graphNovelty = graphNovelty
        self.bridgeCentrality = bridgeCentrality
        self.informationGain = informationGain
        self.entityBonus = entityBonus
        self.total = total
    }
}
