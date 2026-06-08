import Foundation

/// Source kind for an ingested document (see schema §3 of the design doc).
public enum MemorySource: String, Sendable, Codable, CaseIterable {
    case rss, arxiv, github, newsletter, x, manual, web, claude
}

public struct DocumentRow: Sendable, Equatable {
    public var id: Int64
    public var source: MemorySource
    public var sourceURI: String
    public var title: String?
    public var bodyPath: String
    public var fetchedAt: Int64
    public var publishedAt: Int64?
    public var contentSHA: Data
    public var language: String?
    public var rawBytes: Int64

    public init(id: Int64 = 0, source: MemorySource, sourceURI: String,
                title: String? = nil, bodyPath: String,
                fetchedAt: Int64, publishedAt: Int64? = nil,
                contentSHA: Data, language: String? = nil, rawBytes: Int64) {
        self.id = id
        self.source = source
        self.sourceURI = sourceURI
        self.title = title
        self.bodyPath = bodyPath
        self.fetchedAt = fetchedAt
        self.publishedAt = publishedAt
        self.contentSHA = contentSHA
        self.language = language
        self.rawBytes = rawBytes
    }
}

public struct ChunkRow: Sendable, Equatable {
    public var id: Int64
    public var documentId: Int64
    public var idx: Int
    public var text: String
    public var rawText: String
    public var tokenCount: Int
    public var logprobAvg: Double?
    public var createdAt: Int64

    public init(id: Int64 = 0, documentId: Int64, idx: Int,
                text: String, rawText: String, tokenCount: Int,
                logprobAvg: Double? = nil, createdAt: Int64) {
        self.id = id
        self.documentId = documentId
        self.idx = idx
        self.text = text
        self.rawText = rawText
        self.tokenCount = tokenCount
        self.logprobAvg = logprobAvg
        self.createdAt = createdAt
    }
}

public enum EntityKind: String, Sendable, Codable, CaseIterable {
    case person, org, product, paper, repo, concept, tag
}

public struct EntityRow: Sendable, Equatable {
    public var id: Int64
    public var kind: EntityKind
    public var canonical: String
    public var aliases: [String]
    public var firstSeen: Int64
    public var lastSeen: Int64
    public var degree: Int
    public var egoBetweennessCached: Double?

    public init(id: Int64 = 0, kind: EntityKind, canonical: String,
                aliases: [String] = [], firstSeen: Int64, lastSeen: Int64,
                degree: Int = 0, egoBetweennessCached: Double? = nil) {
        self.id = id
        self.kind = kind
        self.canonical = canonical
        self.aliases = aliases
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.degree = degree
        self.egoBetweennessCached = egoBetweennessCached
    }
}

public struct EdgeRow: Sendable, Equatable {
    public var id: Int64
    public var src: Int64
    public var dst: Int64
    public var relation: String
    public var firstSeen: Int64
    public var lastSeen: Int64
    public var weight: Double
    public var evidenceChunkId: Int64?

    public init(id: Int64 = 0, src: Int64, dst: Int64, relation: String,
                firstSeen: Int64, lastSeen: Int64,
                weight: Double = 1.0, evidenceChunkId: Int64? = nil) {
        self.id = id
        self.src = src
        self.dst = dst
        self.relation = relation
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.weight = weight
        self.evidenceChunkId = evidenceChunkId
    }
}

public struct MentionRow: Sendable, Equatable {
    public var chunkId: Int64
    public var entityId: Int64
    public var spanStart: Int?
    public var spanEnd: Int?
    public var salience: Double?

    public init(chunkId: Int64, entityId: Int64,
                spanStart: Int? = nil, spanEnd: Int? = nil, salience: Double? = nil) {
        self.chunkId = chunkId
        self.entityId = entityId
        self.spanStart = spanStart
        self.spanEnd = spanEnd
        self.salience = salience
    }
}

public struct InsightRow: Sendable, Equatable {
    public var id: Int64
    public var triggerChunkId: Int64
    public var model: String
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cachedInputTokens: Int64
    public var costUSD: Double
    public var score: Double
    public var cardMD: String
    public var createdAt: Int64

    public init(id: Int64 = 0, triggerChunkId: Int64, model: String,
                inputTokens: Int64, outputTokens: Int64,
                cachedInputTokens: Int64 = 0, costUSD: Double,
                score: Double, cardMD: String, createdAt: Int64) {
        self.id = id
        self.triggerChunkId = triggerChunkId
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.costUSD = costUSD
        self.score = score
        self.cardMD = cardMD
        self.createdAt = createdAt
    }
}

public struct SourceCursorRow: Sendable, Equatable {
    public var source: String
    public var lastETag: String?
    public var lastModified: Int64?
    public var highWatermarkID: String?
    public var nextEligibleAt: Int64
    /// Running count of consecutive `failed` outcomes for this source. Reset
    /// to 0 on any non-failed outcome. Used by the SourceScheduler to drive
    /// exponential backoff via `Backoff.delay(forAttempt:)` so persistent
    /// outages don't retry every minute forever.
    public var consecutiveFailures: Int

    public init(source: String, lastETag: String? = nil,
                lastModified: Int64? = nil, highWatermarkID: String? = nil,
                nextEligibleAt: Int64,
                consecutiveFailures: Int = 0) {
        self.source = source
        self.lastETag = lastETag
        self.lastModified = lastModified
        self.highWatermarkID = highWatermarkID
        self.nextEligibleAt = nextEligibleAt
        self.consecutiveFailures = consecutiveFailures
    }
}

public struct SpendRow: Sendable, Equatable {
    public var ts: Int64
    public var bucket: String
    public var units: Double
    public var unitKind: String
    public var costUSD: Double

    public init(ts: Int64, bucket: String, units: Double, unitKind: String, costUSD: Double) {
        self.ts = ts
        self.bucket = bucket
        self.units = units
        self.unitKind = unitKind
        self.costUSD = costUSD
    }
}

public struct DocumentChunkSummary: Sendable, Equatable {
    public var document: DocumentRow
    public var chunkCount: Int

    public init(document: DocumentRow, chunkCount: Int) {
        self.document = document
        self.chunkCount = chunkCount
    }
}

public struct ChunkEvidenceRow: Sendable, Equatable {
    public var chunk: ChunkRow
    public var document: DocumentRow?

    public init(chunk: ChunkRow, document: DocumentRow?) {
        self.chunk = chunk
        self.document = document
    }
}

public struct MemoryStoreIndexHealth: Sendable, Equatable {
    public var documentCount: Int
    public var chunkCount: Int
    public var entityCount: Int
    public var edgeCount: Int
    public var zeroChunkDocumentIds: [Int64]
    public var orphanChunkIds: [Int64]
    public var chunksMissingVector: [Int64]
    public var staleVectorRowIds: [Int64]
    public var ftsIntegrityOK: Bool
    public var ftsIntegrityError: String?

    public init(documentCount: Int,
                chunkCount: Int,
                entityCount: Int,
                edgeCount: Int,
                zeroChunkDocumentIds: [Int64] = [],
                orphanChunkIds: [Int64] = [],
                chunksMissingVector: [Int64] = [],
                staleVectorRowIds: [Int64] = [],
                ftsIntegrityOK: Bool = true,
                ftsIntegrityError: String? = nil) {
        self.documentCount = documentCount
        self.chunkCount = chunkCount
        self.entityCount = entityCount
        self.edgeCount = edgeCount
        self.zeroChunkDocumentIds = zeroChunkDocumentIds
        self.orphanChunkIds = orphanChunkIds
        self.chunksMissingVector = chunksMissingVector
        self.staleVectorRowIds = staleVectorRowIds
        self.ftsIntegrityOK = ftsIntegrityOK
        self.ftsIntegrityError = ftsIntegrityError
    }
}

/// Result of a vector search: chunk id + cosine distance (0 = identical).
public struct VectorHit: Sendable, Equatable {
    public var chunkId: Int64
    public var distance: Double
    public init(chunkId: Int64, distance: Double) {
        self.chunkId = chunkId
        self.distance = distance
    }
}

/// Result of a BM25 / FTS search.
public struct LexicalHit: Sendable, Equatable {
    public var chunkId: Int64
    public var score: Double
    public init(chunkId: Int64, score: Double) {
        self.chunkId = chunkId
        self.score = score
    }
}
