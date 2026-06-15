import Foundation

// Row types for the M8 curation tables (§4/§5): Inventory, Datasets, Collect. These
// carry NO embeddings — they are durable record tables projected to compact-table
// views, never read as document bodies. List/array-shaped columns (tags, sources,
// found_in_context, …) are stored as opaque JSON/CSV TEXT and shaped at the boundary.

/// A durable inventory record: items / ingest-candidates / entities / corpora /
/// open-questions / tasks / artifacts / watch-items.
public struct InventoryRecordRow: Sendable, Equatable {
    public var id: Int64
    public var slug: String
    public var kind: String        // item|ingest-candidate|entity|corpus|question|task|artifact|watch
    public var status: String      // proposed|active|blocked|ingested|superseded|archived
    public var priority: String    // p0..p4
    public var title: String
    public var summary: String?
    public var nextAction: String?
    public var tags: String?
    public var sources: String?
    public var origin: String?
    public var confidence: String?
    public var bodyMd: String?
    public var quantity: Int64?
    public var unit: String?
    public var itemState: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var lastChecked: Int64?
    public var lifecycleStatus: String

    public init(id: Int64 = 0, slug: String, kind: String, status: String, priority: String,
                title: String, summary: String? = nil, nextAction: String? = nil, tags: String? = nil,
                sources: String? = nil, origin: String? = nil, confidence: String? = nil, bodyMd: String? = nil,
                quantity: Int64? = nil, unit: String? = nil, itemState: String? = nil,
                createdAt: Int64, updatedAt: Int64, lastChecked: Int64? = nil, lifecycleStatus: String = "active") {
        self.id = id; self.slug = slug; self.kind = kind; self.status = status; self.priority = priority
        self.title = title; self.summary = summary; self.nextAction = nextAction; self.tags = tags
        self.sources = sources; self.origin = origin; self.confidence = confidence; self.bodyMd = bodyMd
        self.quantity = quantity; self.unit = unit; self.itemState = itemState
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lastChecked = lastChecked
        self.lifecycleStatus = lifecycleStatus
    }
}

/// A saved inventory view (a named filter over the compact table).
public struct InventoryViewRow: Sendable, Equatable {
    public var id: Int64
    public var slug: String
    public var title: String
    public var filters: String?    // opaque JSON filter spec
    public var updatedAt: Int64
    public init(id: Int64 = 0, slug: String, title: String, filters: String? = nil, updatedAt: Int64) {
        self.id = id; self.slug = slug; self.title = title; self.filters = filters; self.updatedAt = updatedAt
    }
}

/// A dataset manifest: indexes large/external/mutable data (the wiki is the interface;
/// the data stays put).
public struct DatasetManifestRow: Sendable, Equatable {
    public var id: Int64
    public var datasetID: String
    public var title: String
    public var status: String      // proposed|active|external|archived|unavailable
    public var storage: String     // local|remote|external|hybrid
    public var locations: String?
    public var formats: String?
    public var schemaStatus: String? // unknown|inferred|declared|validated
    public var sizeBytes: Int64?
    public var recordCount: Int64?
    public var inventoryLinks: String?
    public var rawSources: String?
    public var license: String?
    public var access: String?
    public var checksum: String?
    public var refreshCadence: String?
    public var summary: String?
    public var bodyMd: String?
    public var origin: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var lifecycleStatus: String

    public init(id: Int64 = 0, datasetID: String, title: String, status: String, storage: String,
                locations: String? = nil, formats: String? = nil, schemaStatus: String? = nil,
                sizeBytes: Int64? = nil, recordCount: Int64? = nil, inventoryLinks: String? = nil,
                rawSources: String? = nil, license: String? = nil, access: String? = nil, checksum: String? = nil,
                refreshCadence: String? = nil, summary: String? = nil, bodyMd: String? = nil, origin: String? = nil,
                createdAt: Int64, updatedAt: Int64, lifecycleStatus: String = "active") {
        self.id = id; self.datasetID = datasetID; self.title = title; self.status = status; self.storage = storage
        self.locations = locations; self.formats = formats; self.schemaStatus = schemaStatus
        self.sizeBytes = sizeBytes; self.recordCount = recordCount; self.inventoryLinks = inventoryLinks
        self.rawSources = rawSources; self.license = license; self.access = access; self.checksum = checksum
        self.refreshCadence = refreshCadence; self.summary = summary; self.bodyMd = bodyMd; self.origin = origin
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.lifecycleStatus = lifecycleStatus
    }
}

/// A dataset note: a sample / profile / query-recipe attached to a manifest.
public struct DatasetNoteRow: Sendable, Equatable {
    public var id: Int64
    public var manifestID: Int64
    public var noteKind: String    // sample|profile|query
    public var title: String
    public var bodyMd: String
    public var createdAt: Int64
    public init(id: Int64 = 0, manifestID: Int64, noteKind: String, title: String, bodyMd: String, createdAt: Int64) {
        self.id = id; self.manifestID = manifestID; self.noteKind = noteKind
        self.title = title; self.bodyMd = bodyMd; self.createdAt = createdAt
    }
}

/// A collect-catalog item: a discovered artifact / media / entity with provenance,
/// hashes, and an optional locally-downloaded asset path.
public struct CollectItemRow: Sendable, Equatable {
    public var id: Int64
    public var catalogSlug: String
    public var rowNumber: Int64
    public var title: String
    public var aliases: String?
    public var collectKind: String?
    public var canonicalURL: String?
    public var mediaURL: String?
    public var sourceURL: String?
    public var originPlatform: String?
    public var creator: String?
    public var firstSeen: String?
    public var description: String?
    public var evidence: String?
    public var foundInContext: String?  // JSON array of sightings
    public var provenanceConfidence: String?
    public var rightsOrLicense: String?
    public var mediaFormat: String?
    public var localMediaPath: String?
    public var mediaBytes: Int64?
    public var sha256: String?
    public var perceptualHash: String?
    public var downloadStatus: String?
    public var downloadedAt: Int64?
    public var nextAction: String?
    public var createdAt: Int64

    public init(id: Int64 = 0, catalogSlug: String, rowNumber: Int64, title: String, aliases: String? = nil,
                collectKind: String? = nil, canonicalURL: String? = nil, mediaURL: String? = nil,
                sourceURL: String? = nil, originPlatform: String? = nil, creator: String? = nil,
                firstSeen: String? = nil, description: String? = nil, evidence: String? = nil,
                foundInContext: String? = nil, provenanceConfidence: String? = nil, rightsOrLicense: String? = nil,
                mediaFormat: String? = nil, localMediaPath: String? = nil, mediaBytes: Int64? = nil,
                sha256: String? = nil, perceptualHash: String? = nil, downloadStatus: String? = nil,
                downloadedAt: Int64? = nil, nextAction: String? = nil, createdAt: Int64) {
        self.id = id; self.catalogSlug = catalogSlug; self.rowNumber = rowNumber; self.title = title
        self.aliases = aliases; self.collectKind = collectKind; self.canonicalURL = canonicalURL
        self.mediaURL = mediaURL; self.sourceURL = sourceURL; self.originPlatform = originPlatform
        self.creator = creator; self.firstSeen = firstSeen; self.description = description; self.evidence = evidence
        self.foundInContext = foundInContext; self.provenanceConfidence = provenanceConfidence
        self.rightsOrLicense = rightsOrLicense; self.mediaFormat = mediaFormat; self.localMediaPath = localMediaPath
        self.mediaBytes = mediaBytes; self.sha256 = sha256; self.perceptualHash = perceptualHash
        self.downloadStatus = downloadStatus; self.downloadedAt = downloadedAt; self.nextAction = nextAction
        self.createdAt = createdAt
    }
}
