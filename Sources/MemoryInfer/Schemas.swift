import Foundation

/// Stable end-to-end schema for one document or chunk batch handed to the
/// inference seam. The pipeline shape mirrors the design doc verbatim: a doc
/// is split into ~512-token chunks; each chunk is contextualised then
/// extracted (entities/edges) and embedded.
public struct Chunk: Sendable, Equatable {
    /// Stable identity inside one extraction request; not a DB rowid.
    public var localId: String
    public var rawText: String
    /// Anthropic-style situating prefix produced by the contextualiser.
    /// `nil` before contextualisation; the same value lands in `chunk.text`
    /// in MemoryStore.
    public var context: String?
    public var idx: Int

    public init(localId: String, rawText: String, context: String? = nil, idx: Int) {
        self.localId = localId
        self.rawText = rawText
        self.context = context
        self.idx = idx
    }

    public var contextualised: String {
        if let context, !context.isEmpty {
            return context + "\n\n" + rawText
        }
        return rawText
    }
}

public struct ChunkBatch: Sendable, Equatable {
    public var documentTitle: String?
    public var documentURI: String
    public var chunks: [Chunk]
    public init(documentTitle: String?, documentURI: String, chunks: [Chunk]) {
        self.documentTitle = documentTitle
        self.documentURI = documentURI
        self.chunks = chunks
    }
}

public struct DocumentDigest: Sendable, Equatable {
    public var title: String?
    public var uri: String
    public var summary: String
    public init(title: String?, uri: String, summary: String) {
        self.title = title
        self.uri = uri
        self.summary = summary
    }
}

public struct ExtractedEntity: Sendable, Equatable {
    public var kind: String
    public var canonical: String
    public var aliases: [String]
    public var salience: Double?
    public init(kind: String, canonical: String, aliases: [String] = [],
                salience: Double? = nil) {
        self.kind = kind; self.canonical = canonical
        self.aliases = aliases; self.salience = salience
    }
}

public struct ExtractedEdge: Sendable, Equatable {
    public var src: String   // canonical name of the source entity
    public var dst: String
    public var relation: String
    public var evidenceChunkId: String?
    public init(src: String, dst: String, relation: String,
                evidenceChunkId: String? = nil) {
        self.src = src; self.dst = dst; self.relation = relation
        self.evidenceChunkId = evidenceChunkId
    }
}

public struct ExtractedChunk: Sendable, Equatable {
    public var localId: String
    public var entities: [ExtractedEntity]
    public var edges: [ExtractedEdge]
    /// Mean bits-per-token under the extractor; serves as the info-gain proxy
    /// in MemoryScore. `nil` when the provider didn't emit logprobs.
    public var logprobAvgBits: Double?

    public init(localId: String, entities: [ExtractedEntity],
                edges: [ExtractedEdge], logprobAvgBits: Double? = nil) {
        self.localId = localId
        self.entities = entities
        self.edges = edges
        self.logprobAvgBits = logprobAvgBits
    }
}

public struct ExtractionResult: Sendable, Equatable {
    public var perChunk: [ExtractedChunk]
    public var tokensInput: Int
    public var tokensOutput: Int
    public init(perChunk: [ExtractedChunk], tokensInput: Int, tokensOutput: Int) {
        self.perChunk = perChunk
        self.tokensInput = tokensInput
        self.tokensOutput = tokensOutput
    }
}

/// Profile that shapes the extraction prompt (which entity kinds to look for,
/// which JSON sub-schema to enforce). Persona-aware extraction is a v2 item;
/// for now this is a single static schema.
public struct ExtractionSchema: Sendable, Equatable {
    public var allowedEntityKinds: [String]
    public var allowedRelations: [String]
    public init(allowedEntityKinds: [String] =
                ["person","org","product","paper","repo","concept","tag"],
                allowedRelations: [String] =
                ["works_at","wrote","cites","mentions","builds","uses"]) {
        self.allowedEntityKinds = allowedEntityKinds
        self.allowedRelations = allowedRelations
    }
    public static let `default` = ExtractionSchema()
}

/// Insight card produced by the gated GPT-5.5 call. The model is held to this
/// JSON schema by the prompt template; on parse failure the gate logs a
/// `BrainGateError.unparseable` and refunds the budget.
public struct InsightCard: Sendable, Equatable, Codable {
    public var headline: String
    public var summary: String
    public var entities: [String]
    public var rationale: String
    public var summaryOnly: Bool
    public init(headline: String, summary: String, entities: [String],
                rationale: String, summaryOnly: Bool = false) {
        self.headline = headline
        self.summary = summary
        self.entities = entities
        self.rationale = rationale
        self.summaryOnly = summaryOnly
    }
}
