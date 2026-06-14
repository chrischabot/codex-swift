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
    }

    /// `extract`: full contextualise+entity/edge extraction (single high-value
    /// ingests) vs the cheap split+embed path (bulk imports).
    @discardableResult
    public func write(_ c: WikiSourceCandidate, extract: Bool = false) async throws -> WriteResult {
        // The SAME normalized content-SHA the processor stamps onto the document,
        // so the dedupe check below matches the stored value exactly.
        let sha = Normaliser.contentSHA(c.bodyMarkdown)
        if let existing = try await store.document(byURI: c.sourceURI), existing.contentSHA == sha {
            return WriteResult(documentID: existing.id, chunksWritten: 0, skipped: true)
        }
        let doc = IngestedDocument(
            sourceName: c.provenance.adapter,
            sourceKind: Self.sourceKind(for: c),
            sourceURI: c.sourceURI,
            title: c.title,
            publishedAt: c.provenance.publishedAt,
            fetchedAt: c.fetched,
            canonicalText: c.bodyMarkdown,
            rawBytes: Int64(c.bodyMarkdown.utf8.count),
            contentSHA: sha)
        let report = try await processor.process(doc, extract: extract)

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
            frontmatter: nil))
        return WriteResult(documentID: report.documentId, chunksWritten: report.chunksWritten, skipped: false)
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
