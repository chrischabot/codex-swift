import Foundation

/// The eight+ llm-wiki source types (+ the watch-feed kinds from §14). The kind
/// is auto-detected from the input (or forced by the caller).
public enum WikiSourceKind: String, Sendable, Codable, CaseIterable {
    case url, file, pdf, inbox, git
    case mediawikiDump = "mediawiki-dump"
    case mediawikiAPI = "mediawiki-api"
    case messageArchive = "csv-messages"
    case waybackCDX = "wayback-cdx"
    case feed, arxiv
    case githubOwner = "github-owner"
}

/// The llm-wiki raw bucket a source lands in.
public enum RawType: String, Sendable, Codable, CaseIterable {
    case articles, papers, repos, notes, data
}

/// The wire/content shape of the fetched body (for provenance + downstream choices).
public enum ContentFormat: String, Sendable, Codable, CaseIterable {
    case markdown, html, pdf, text, json, csv, xml
}

/// Collection/upstream provenance carried with every candidate (rendered into the
/// raw-source frontmatter / source_meta on write).
public struct CollectionProvenance: Sendable, Equatable, Codable {
    public var adapter: String
    public var collection: String?
    public var upstreamID: String?
    public var revision: String?
    public var sha: String?
    public var canonicalURL: String?
    public var license: String?
    public var author: String?
    public var publishedAt: Int64?
    public init(adapter: String, collection: String? = nil, upstreamID: String? = nil,
                revision: String? = nil, sha: String? = nil, canonicalURL: String? = nil,
                license: String? = nil, author: String? = nil, publishedAt: Int64? = nil) {
        self.adapter = adapter; self.collection = collection; self.upstreamID = upstreamID
        self.revision = revision; self.sha = sha; self.canonicalURL = canonicalURL
        self.license = license; self.author = author; self.publishedAt = publishedAt
    }
}

/// One candidate child source produced by an adapter BEFORE any store write (the
/// `--dry-run` stream IS this, written nowhere).
public struct WikiSourceCandidate: Sendable, Equatable {
    public var sourceURI: String        // dedupe key (→ document.source_uri)
    public var rawType: RawType
    public var title: String?
    public var bodyMarkdown: String     // already-extracted text/markdown
    public var contentFormat: ContentFormat
    public var provenance: CollectionProvenance
    public var fetched: Int64
    public var extractionStatus: String?   // ok | ocr-needed | truncated | failed

    public init(sourceURI: String, rawType: RawType, title: String? = nil, bodyMarkdown: String,
                contentFormat: ContentFormat, provenance: CollectionProvenance, fetched: Int64,
                extractionStatus: String? = nil) {
        self.sourceURI = sourceURI; self.rawType = rawType; self.title = title
        self.bodyMarkdown = bodyMarkdown; self.contentFormat = contentFormat
        self.provenance = provenance; self.fetched = fetched; self.extractionStatus = extractionStatus
    }
}

/// One ingest request (the params an adapter reads; filters are best-effort).
public struct IngestRequest: Sendable, Equatable {
    public var input: String
    public var adapter: WikiSourceKind?   // forced kind (nil → auto-detect)
    public var rawType: RawType?          // forced raw bucket
    public var title: String?
    public var limit: Int?
    public var include: String?
    public var exclude: String?
    public var from: String?
    public var to: String?
    public var namespace: Int?
    public var dryRun: Bool
    public var fetchedAt: Int64           // injected (no Date() in adapters → testable/deterministic)

    public init(input: String, adapter: WikiSourceKind? = nil, rawType: RawType? = nil,
                title: String? = nil, limit: Int? = nil, include: String? = nil, exclude: String? = nil,
                from: String? = nil, to: String? = nil, namespace: Int? = nil,
                dryRun: Bool = false, fetchedAt: Int64) {
        self.input = input; self.adapter = adapter; self.rawType = rawType; self.title = title
        self.limit = limit; self.include = include; self.exclude = exclude; self.from = from
        self.to = to; self.namespace = namespace; self.dryRun = dryRun; self.fetchedAt = fetchedAt
    }
}

public enum WikiIngestError: Error, Sendable, Equatable {
    case fetchFailed(String)
    case unreadable(String)
    case unsupported(String)
    case notImplemented(WikiSourceKind)
}

/// A source adapter enumerates candidate child sources for an input. `enumerate`
/// is also the dry-run path (it yields candidates without writing). Adapters are
/// `Sendable` value types holding the (Sendable) fetcher/decoder they need.
public protocol SourceAdapter: Sendable {
    var kind: WikiSourceKind { get }
    func enumerate(_ req: IngestRequest) -> AsyncThrowingStream<WikiSourceCandidate, any Error>
}
