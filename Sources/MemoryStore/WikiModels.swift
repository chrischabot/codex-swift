import Foundation
import InfraPrimitives

// Row structs + enums for the additive Memory-Wiki knowledge model (the §4
// canonical schema). Kept in a dedicated file so Models.swift stays focused on
// the original document/chunk/entity/edge spine.

/// Claim lifecycle (the WikiClaim status machine).
public enum ClaimStatus: String, Sendable, Codable, CaseIterable {
    case draft, active, stale, contradicted, archived
}

/// Freshness-decay tier. Half-lives: hot 30d, warm 90d, cold 365d (WikiFreshness).
public enum Volatility: String, Sendable, Codable, CaseIterable {
    case hot, warm, cold
}

/// Source credibility tier (Phase-2b research rubric).
public enum TrustTier: String, Sendable, Codable, CaseIterable {
    case high, medium, low, reject
}

/// How a claim/page was produced — gates the "sources must resolve" lint (C18).
public enum CompiledFrom: String, Sendable, Codable, CaseIterable {
    case sources, conversation, mixed
}

/// Evidence direction relative to its claim (thesis mode).
public enum EvidenceStance: String, Sendable, Codable, CaseIterable {
    case supports, opposes, nuances
}

/// Evidence relevance (the bloat filter; `tangential` is dropped pre-ingest).
public enum EvidenceRelevance: String, Sendable, Codable, CaseIterable {
    case direct, indirect, tangential
}

/// Replayable-provenance classification used by Audit (which session artifacts exist).
public enum WikiProvenanceState: String, Sendable, Codable, Equatable {
    case replayable   // durable session events exist
    case partial      // only a checkpoint exists
    case missing      // neither
}

// MARK: - Rows

/// Per-document provenance/trust overlay (1:1 with the immutable `document`).
public struct SourceMetaRow: Sendable, Equatable {
    public var documentID: Int64
    public var sourceKind: String
    public var trustTier: TrustTier
    public var credibility: Int
    public var confidence: String?
    public var volatility: Volatility
    public var verifiedAt: Int64?
    public var ingestedAt: Int64
    public var author: String?
    public var publishedAt: Int64?
    public var license: String?
    public var canonicalURL: String?
    public var biasFlags: String?
    public var collection: String?
    public var adapter: String?
    public var upstreamID: String?
    public var revision: String?
    public var blobSHA: String?
    public var compiledFrom: CompiledFrom
    public var frontmatter: String?

    public init(documentID: Int64, sourceKind: String, trustTier: TrustTier = .medium,
                credibility: Int = 0, confidence: String? = nil, volatility: Volatility = .warm,
                verifiedAt: Int64? = nil, ingestedAt: Int64, author: String? = nil,
                publishedAt: Int64? = nil, license: String? = nil, canonicalURL: String? = nil,
                biasFlags: String? = nil, collection: String? = nil, adapter: String? = nil,
                upstreamID: String? = nil, revision: String? = nil, blobSHA: String? = nil,
                compiledFrom: CompiledFrom = .sources, frontmatter: String? = nil) {
        self.documentID = documentID; self.sourceKind = sourceKind; self.trustTier = trustTier
        self.credibility = credibility; self.confidence = confidence; self.volatility = volatility
        self.verifiedAt = verifiedAt; self.ingestedAt = ingestedAt; self.author = author
        self.publishedAt = publishedAt; self.license = license; self.canonicalURL = canonicalURL
        self.biasFlags = biasFlags; self.collection = collection; self.adapter = adapter
        self.upstreamID = upstreamID; self.revision = revision; self.blobSHA = blobSHA
        self.compiledFrom = compiledFrom; self.frontmatter = frontmatter
    }
}

/// A durable atomic claim. `canonicalSHA` is the dedupe key — derive it with
/// `ClaimRow.canonicalSHA(text:)` so identical claims (modulo whitespace/case)
/// collapse and re-compile is idempotent.
public struct ClaimRow: Sendable, Equatable {
    public var id: Int64
    public var text: String
    public var canonicalSHA: Data
    public var status: ClaimStatus
    public var confidence: Double
    public var volatility: Volatility
    public var category: String?
    public var scope: String?
    public var firstSeen: Int64
    public var lastReviewed: Int64?
    public var updatedAt: Int64
    public var compiledFrom: CompiledFrom
    public var edgeID: Int64?

    public init(id: Int64 = 0, text: String, canonicalSHA: Data? = nil,
                status: ClaimStatus = .draft, confidence: Double = 0.5,
                volatility: Volatility = .warm, category: String? = nil, scope: String? = nil,
                firstSeen: Int64, lastReviewed: Int64? = nil, updatedAt: Int64,
                compiledFrom: CompiledFrom = .sources, edgeID: Int64? = nil) {
        self.id = id; self.text = text
        self.canonicalSHA = canonicalSHA ?? ClaimRow.canonicalSHA(text: text)
        self.status = status; self.confidence = confidence; self.volatility = volatility
        self.category = category; self.scope = scope; self.firstSeen = firstSeen
        self.lastReviewed = lastReviewed; self.updatedAt = updatedAt
        self.compiledFrom = compiledFrom; self.edgeID = edgeID
    }

    /// Normalize (lowercase + collapse all runs of whitespace to a single space,
    /// trimmed) then sha256. Two claims differing only in spacing/case dedupe.
    public static func canonicalText(_ text: String) -> String {
        let lowered = text.lowercased()
        let collapsed = lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }

    public static func canonicalSHA(text: String) -> Data {
        Data(Hashing.sha256(Array(canonicalText(text).utf8)))
    }
}

/// claim ⇄ chunk/document evidence span.
public struct ClaimEvidenceRow: Sendable, Equatable {
    public var id: Int64
    public var claimID: Int64
    public var documentID: Int64
    public var chunkID: Int64?
    public var stance: EvidenceStance
    public var relevance: EvidenceRelevance?
    public var strength: Int
    public var spanStart: Int?
    public var spanEnd: Int?

    public init(id: Int64 = 0, claimID: Int64, documentID: Int64, chunkID: Int64? = nil,
                stance: EvidenceStance = .supports, relevance: EvidenceRelevance? = nil,
                strength: Int = 2, spanStart: Int? = nil, spanEnd: Int? = nil) {
        self.id = id; self.claimID = claimID; self.documentID = documentID; self.chunkID = chunkID
        self.stance = stance; self.relevance = relevance; self.strength = strength
        self.spanStart = spanStart; self.spanEnd = spanEnd
    }
}

/// A compiled synthesis/article/thesis/output page (durable row + vault body).
public struct SynthesisRow: Sendable, Equatable {
    public var id: Int64
    public var slug: String
    public var category: String
    public var title: String
    public var bodyPath: String
    public var confidence: String?
    public var volatility: Volatility
    public var verifiedAt: Int64?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var humanBlockSHA: Data?
    public var thesisStatus: String?
    public var verdict: String?
    public var coreClaim: String?
    public var keyVariables: String?
    public var falsification: String?
    public var evidenceFor: Int
    public var evidenceAgainst: Int
    public var format: String?
    public var generatedAt: Int64?
    public var outputType: String?

    public init(id: Int64 = 0, slug: String, category: String, title: String, bodyPath: String,
                confidence: String? = nil, volatility: Volatility = .warm, verifiedAt: Int64? = nil,
                createdAt: Int64, updatedAt: Int64, humanBlockSHA: Data? = nil,
                thesisStatus: String? = nil, verdict: String? = nil, coreClaim: String? = nil,
                keyVariables: String? = nil, falsification: String? = nil,
                evidenceFor: Int = 0, evidenceAgainst: Int = 0,
                format: String? = nil, generatedAt: Int64? = nil, outputType: String? = nil) {
        self.id = id; self.slug = slug; self.category = category; self.title = title
        self.bodyPath = bodyPath; self.confidence = confidence; self.volatility = volatility
        self.verifiedAt = verifiedAt; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.humanBlockSHA = humanBlockSHA; self.thesisStatus = thesisStatus; self.verdict = verdict
        self.coreClaim = coreClaim; self.keyVariables = keyVariables; self.falsification = falsification
        self.evidenceFor = evidenceFor; self.evidenceAgainst = evidenceAgainst
        self.format = format; self.generatedAt = generatedAt; self.outputType = outputType
    }
}

public struct ResearchSessionRow: Sendable, Equatable {
    public var sessionID: String
    public var command: String?
    public var mode: String?
    public var topic: String?
    public var startTime: Int64?
    public var minTimeBudget: Int64?
    public var currentRound: Int?
    public var cumulativeSources: Int?
    public var cumulativeArticles: Int?
    public var status: String?
    public var lastProgressScore: Double?
    public var pathsJSON: String?

    public init(sessionID: String, command: String? = nil, mode: String? = nil, topic: String? = nil,
                startTime: Int64? = nil, minTimeBudget: Int64? = nil, currentRound: Int? = nil,
                cumulativeSources: Int? = nil, cumulativeArticles: Int? = nil, status: String? = nil,
                lastProgressScore: Double? = nil, pathsJSON: String? = nil) {
        self.sessionID = sessionID; self.command = command; self.mode = mode; self.topic = topic
        self.startTime = startTime; self.minTimeBudget = minTimeBudget; self.currentRound = currentRound
        self.cumulativeSources = cumulativeSources; self.cumulativeArticles = cumulativeArticles
        self.status = status; self.lastProgressScore = lastProgressScore; self.pathsJSON = pathsJSON
    }
}

public struct SessionEventRow: Sendable, Equatable {
    public var id: Int64
    public var sessionID: String
    public var ts: Int64
    public var command: String?
    public var phase: String?
    public var event: String
    public var round: Int?
    public var sourcesIngested: Int?
    public var articlesCompiled: Int?
    public var progressScore: Double?
    public var artifactsJSON: String?
    public var notes: String?

    public init(id: Int64 = 0, sessionID: String, ts: Int64, command: String? = nil,
                phase: String? = nil, event: String, round: Int? = nil,
                sourcesIngested: Int? = nil, articlesCompiled: Int? = nil,
                progressScore: Double? = nil, artifactsJSON: String? = nil, notes: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.ts = ts; self.command = command
        self.phase = phase; self.event = event; self.round = round
        self.sourcesIngested = sourcesIngested; self.articlesCompiled = articlesCompiled
        self.progressScore = progressScore; self.artifactsJSON = artifactsJSON; self.notes = notes
    }
}

public struct SessionCheckpointRow: Sendable, Equatable {
    public var sessionID: String
    public var updatedAt: Int64
    public var status: String
    public var summary: String
    public init(sessionID: String, updatedAt: Int64, status: String, summary: String) {
        self.sessionID = sessionID; self.updatedAt = updatedAt; self.status = status; self.summary = summary
    }
}
