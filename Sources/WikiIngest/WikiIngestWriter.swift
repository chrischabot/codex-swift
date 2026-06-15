import Foundation
import MemoryStore
import MemoryProcess
import MemoryIngest

/// Writes a `WikiSourceCandidate` into the store as an immutable raw document +
/// its provenance overlay, going through the ONE index chokepoint
/// (`MemoryProcessor.process`). Content-SHA + source_uri dedupe makes re-ingest a
/// no-op (raw immutability: a changed upstream is a new source_uri revision, never
/// an overwrite).
public struct WikiIngestWriter: Sendable {
    let store: MemoryStore
    let processor: MemoryProcessor

    public init(store: MemoryStore, processor: MemoryProcessor) {
        self.store = store; self.processor = processor
    }

    public struct WriteResult: Sendable, Equatable {
        public var documentID: Int64
        public var chunksWritten: Int
        public var skipped: Bool   // existing doc with identical content_sha
        /// Set to the PRIOR revision's document id when this write supersedes an
        /// already-ingested source at the same canonical URI (an UPDATE: the upstream
        /// changed). `nil` for a first-time ingest (CREATE) or a skipped no-op. Lets a
        /// watch round tell "freshly changed" from "brand new" (the §14.6 repo-watch
        /// `[What changed]` signal), and the new revision's source_meta carries a dated
        /// change marker.
        public var revisionOf: Int64?

        public init(documentID: Int64, chunksWritten: Int, skipped: Bool, revisionOf: Int64? = nil) {
            self.documentID = documentID; self.chunksWritten = chunksWritten
            self.skipped = skipped; self.revisionOf = revisionOf
        }
    }

    /// `extract`: full contextualise+entity/edge extraction (single high-value
    /// ingests) vs the cheap split+embed path (bulk imports).
    @discardableResult
    public func write(_ c: WikiSourceCandidate, extract: Bool = false) async throws -> WriteResult {
        // The SAME normalized content-SHA the processor stamps onto the document,
        // so the dedupe check below matches the stored value exactly.
        let sha = Normaliser.contentSHA(c.bodyMarkdown)
        let shaHex = sha.map { String(format: "%02x", $0) }.joined()

        // Exact dedupe on the canonical URI → no-op.
        if let existing = try await store.document(byURI: c.sourceURI), existing.contentSHA == sha {
            return WriteResult(documentID: existing.id, chunksWritten: 0, skipped: true)
        }
        // Raw immutability: a CHANGED upstream is a NEW source_uri revision, never
        // an overwrite. Reusing the same URI would update the document row but leave
        // the OLD chunks searchable beside the new ones (the processor only inserts).
        // So when the canonical URI already holds different content, write under a
        // content-addressed revision URI — a fresh document with its own chunks; the
        // prior revision stays immutable.
        var effectiveURI = c.sourceURI
        var revisionOf: Int64?           // prior doc id when this supersedes a changed source
        if let existing = try await store.document(byURI: c.sourceURI), existing.contentSHA != sha {
            effectiveURI = c.sourceURI + "#rev=" + String(shaHex.prefix(12))
            revisionOf = existing.id
            if let rev = try await store.document(byURI: effectiveURI), rev.contentSHA == sha {
                return WriteResult(documentID: rev.id, chunksWritten: 0, skipped: true)   // same revision already ingested
            }
        }
        let doc = IngestedDocument(
            sourceName: c.provenance.adapter,
            sourceKind: Self.sourceKind(for: c),
            sourceURI: effectiveURI,
            title: c.title,
            publishedAt: c.provenance.publishedAt,
            fetchedAt: c.fetched,
            canonicalText: c.bodyMarkdown,
            rawBytes: Int64(c.bodyMarkdown.utf8.count),
            contentSHA: sha)
        let report = try await processor.process(doc, extract: extract)

        // §14.6 repo-watch "what changed" marker: when this write supersedes a prior
        // revision of the same source, stamp a dated change note on the new revision's
        // source_meta (the durable, structured form of `[What changed YYYY-MM-DD]`).
        let changeNote = revisionOf.map { prior in
            "{\"changed_on\":\"\(Self.isoDay(c.fetched))\",\"supersedes_doc\":\(prior)}"
        }

        try await store.upsertSourceMeta(SourceMetaRow(
            documentID: report.documentId,
            sourceKind: c.rawType.rawValue,
            ingestedAt: c.fetched,
            author: c.provenance.author,
            publishedAt: c.provenance.publishedAt,
            license: c.provenance.license,
            canonicalURL: c.provenance.canonicalURL,
            collection: c.provenance.collection,
            adapter: c.provenance.adapter,
            upstreamID: c.provenance.upstreamID,
            revision: c.provenance.revision,
            blobSHA: c.provenance.sha,
            frontmatter: changeNote))
        return WriteResult(documentID: report.documentId, chunksWritten: report.chunksWritten,
                           skipped: false, revisionOf: revisionOf)
    }

    /// Deterministic UTC `YYYY-MM-DD` for the change marker (no locale/timezone drift).
    static func isoDay(_ epochSeconds: Int64) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Map a candidate to the store's coarse source kind (the fine-grained llm-wiki
    /// raw bucket lives in source_meta.source_kind = candidate.rawType).
    static func sourceKind(for c: WikiSourceCandidate) -> SourceSpec.Kind {
        switch c.provenance.adapter {
        case "url":     return .web
        case "file":    return .manual
        case "git":     return .github
        case "arxiv":   return .arxiv
        case "feed":    return .rss
        default:        return .web
        }
    }
}
