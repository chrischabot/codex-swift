import Foundation
import InfraPrimitives
import MemoryIngest
import MemoryInfer
import MemoryStore
import Observability

public struct ProcessReport: Sendable, Equatable {
    public var documentId: Int64
    public var chunksWritten: Int
    public var entitiesUpserted: Int
    public var edgesUpserted: Int
    public var newEdgesBetweenKnown: Int
    public init(documentId: Int64, chunksWritten: Int = 0,
                entitiesUpserted: Int = 0, edgesUpserted: Int = 0,
                newEdgesBetweenKnown: Int = 0) {
        self.documentId = documentId
        self.chunksWritten = chunksWritten
        self.entitiesUpserted = entitiesUpserted
        self.edgesUpserted = edgesUpserted
        self.newEdgesBetweenKnown = newEdgesBetweenKnown
    }
}

/// Sequential-per-document, parallel-across-documents processor.
/// Implements the pipeline described in §5: contextualise → embed → extract
/// → dedupe entities/edges → write atomically. The processor is intentionally
/// stateless on the actor side; it composes immutable inputs.
public actor MemoryProcessor {
    public struct Config: Sendable {
        public var splitter: ChunkSplitter
        public var extractionSchema: ExtractionSchema
        public var contextualiseDeadline: Duration
        public var extractDeadline: Duration
        public var embedDeadline: Duration
        /// Embed deadline for the CHEAP path (`extract: false`). The canonical
        /// claude-import path historically allowed 30s per embed batch; the full
        /// path's `embedDeadline` is tighter (10s) because its chunks are already
        /// contextualised. Kept separate so neither mode regresses the other.
        public var cheapEmbedDeadline: Duration
        /// Embeddings are requested in batches of this size so a large document
        /// doesn't become one oversized inference call (the bound the canonical
        /// claude-import path used before it was folded into this pipeline).
        public var embedBatchSize: Int
        public var clock: @Sendable () -> Int64

        public init(splitter: ChunkSplitter = ChunkSplitter(),
                    extractionSchema: ExtractionSchema = .default,
                    contextualiseDeadline: Duration = .seconds(15),
                    extractDeadline: Duration = .seconds(60),
                    embedDeadline: Duration = .seconds(10),
                    cheapEmbedDeadline: Duration = .seconds(30),
                    embedBatchSize: Int = 64,
                    clock: @escaping @Sendable () -> Int64 =
                        { Int64(Date().timeIntervalSince1970) }) {
            self.splitter = splitter
            self.extractionSchema = extractionSchema
            self.contextualiseDeadline = contextualiseDeadline
            self.extractDeadline = extractDeadline
            self.embedDeadline = embedDeadline
            self.cheapEmbedDeadline = cheapEmbedDeadline
            self.embedBatchSize = Swift.max(1, embedBatchSize)
            self.clock = clock
        }
    }

    private let store: MemoryStore
    private let inference: any LocalInferenceProvider
    private let archive: MemoryArchive?
    private let config: Config

    public init(store: MemoryStore,
                inference: any LocalInferenceProvider,
                archive: MemoryArchive? = nil,
                config: Config = Config()) {
        self.store = store
        self.inference = inference
        self.archive = archive
        self.config = config
    }

    /// Run the ingest pipeline for one document. `extract: true` (default) runs
    /// the full contextualise → embed → extract → graph pipeline. `extract: false`
    /// runs the CHEAP path — split + embed RAW chunks only, with NO per-chunk LLM
    /// contextualise and NO entity/edge extraction — which is what the canonical
    /// `import-claude` path uses. Both modes share document upsert, archiving,
    /// chunk indexing, and batched embedding; the flag only gates the LLM
    /// enrichment, so this is the single pipeline both import paths now go through.
    public func process(_ doc: IngestedDocument, extract: Bool = true) async throws -> ProcessReport {
        let span = Span("mem.process", tag: doc.sourceURI,
                        sink: MemoryMetrics.sink, category: "com.codexkit.memory")
        defer { _ = span }
        MemoryMetrics.ingestDoc(source: doc.sourceKind.rawValue,
                                bytes: Int(doc.rawBytes))
        // 1. Compute the deterministic content-addressed body path *before*
        //    the upsert so document.body_path is never left at a placeholder
        //    if the archive write later fails. The path is keyed on the
        //    content SHA, so a retry lands at the same location.
        let resolvedBodyPath: String
        if let archive {
            resolvedBodyPath = archive.bodyPath(
                sourceURI: doc.sourceURI, ts: doc.fetchedAt,
                contentSHA: doc.contentSHA)
        } else {
            resolvedBodyPath = "inline:\(doc.sourceURI)"
        }
        let docRow = DocumentRow(
            source: doc.sourceKind.toMemorySource(),
            sourceURI: doc.sourceURI,
            title: doc.title,
            bodyPath: resolvedBodyPath,
            fetchedAt: doc.fetchedAt,
            publishedAt: doc.publishedAt,
            contentSHA: doc.contentSHA,
            language: nil,
            rawBytes: doc.rawBytes)
        let documentId = try await store.upsertDocument(docRow)
        // Persist the canonical body to the JSONL archive. The body path was
        // pre-computed above; this call may overwrite an existing manifest
        // entry on retry — that's expected and idempotent.
        if let archive {
            _ = try? await archive.writeDocument(
                sourceURI: doc.sourceURI,
                documentID: documentId,
                ts: doc.fetchedAt,
                bodyText: doc.canonicalText,
                contentSHA: doc.contentSHA)
        }

        // 2. Split + contextualise + embed. Each chunk is wrapped in a per-op
        //    deadline so a stuck inference call cannot block the actor.
        let pieces = config.splitter.split(doc.canonicalText)
        guard !pieces.isEmpty else {
            return ProcessReport(documentId: documentId)
        }
        let digest = DocumentDigest(
            title: doc.title,
            uri: doc.sourceURI,
            summary: String(doc.canonicalText.prefix(400)))

        var chunks: [Chunk] = []
        for piece in pieces {
            let chunk = Chunk(localId: "\(documentId)-\(piece.idx)",
                              rawText: piece.text, idx: piece.idx)
            // Contextualise is an LLM call per chunk; the cheap path (extract:
            // false) skips it, leaving context empty so `contextualised` == rawText
            // — exactly the raw text that lands in chunk.text + the embed input.
            let context = extract
                ? ((try? await inference.contextualize(
                    chunk, in: digest,
                    deadline: .fromNow(config.contextualiseDeadline))) ?? "")
                : ""
            chunks.append(Chunk(localId: chunk.localId,
                                rawText: chunk.rawText,
                                context: context, idx: chunk.idx))
        }
        // Embed in bounded batches so a large document doesn't become one
        // oversized inference call; each batch carries its own deadline. The
        // cheap path gets the more forgiving budget the old import-claude path
        // used (raw 64-chunk batches can take longer than the full path's
        // already-contextualised chunks).
        let texts = chunks.map { $0.contextualised }
        let perBatchEmbedDeadline = extract ? config.embedDeadline : config.cheapEmbedDeadline
        var embeddings: [MemoryInfer.Embedding] = []
        embeddings.reserveCapacity(texts.count)
        var embOffset = 0
        while embOffset < texts.count {
            let end = Swift.min(embOffset + config.embedBatchSize, texts.count)
            let slice = Array(texts[embOffset..<end])
            let batchEmb = try await inference.embed(
                slice, deadline: .fromNow(perBatchEmbedDeadline))
            guard batchEmb.count == slice.count else {
                throw InferenceError.malformedResponse(
                    "embedding count \(batchEmb.count) != chunks \(slice.count)")
            }
            embeddings.append(contentsOf: batchEmb)
            embOffset = end
        }

        // 3. Extract entities/edges for the whole batch in one prompt — this
        //    is the single largest token saving the design doc highlights. The
        //    cheap path (extract: false) skips it entirely; the empty result
        //    makes the per-chunk indexing + entity/edge loops below no-op.
        let extraction: ExtractionResult
        if extract {
            let batch = ChunkBatch(documentTitle: doc.title,
                                   documentURI: doc.sourceURI,
                                   chunks: chunks)
            let extractSpan = Span("mem.process.extract", tag: doc.sourceURI,
                                    sink: MemoryMetrics.sink,
                                    category: "com.codexkit.memory")
            extraction = try await inference.extract(
                batch, schema: config.extractionSchema,
                deadline: .fromNow(config.extractDeadline))
            _ = extractSpan
            MemoryMetrics.extractTokens(
                input: extraction.tokensInput,
                output: extraction.tokensOutput,
                model: "extractor")
        } else {
            extraction = ExtractionResult(perChunk: [], tokensInput: 0, tokensOutput: 0)
        }

        // 4. Index per-chunk: insert chunk row + embedding, then write mentions.
        let now = config.clock()
        let extractionByID = Dictionary(uniqueKeysWithValues:
            extraction.perChunk.map { ($0.localId, $0) })
        var chunkIDs: [String: Int64] = [:]
        var report = ProcessReport(documentId: documentId)

        for (i, chunk) in chunks.enumerated() {
            let logprob = extractionByID[chunk.localId]?.logprobAvgBits
            let row = ChunkRow(
                documentId: documentId, idx: chunk.idx,
                text: chunk.contextualised, rawText: chunk.rawText,
                tokenCount: pieces[i].tokens,
                logprobAvg: logprob,
                createdAt: now)
            let chunkId = try await store.insertChunk(
                row, embeddingValues: embeddings[i].values)
            chunkIDs[chunk.localId] = chunkId
            report.chunksWritten += 1
        }
        MemoryMetrics.chunkCreated(count: report.chunksWritten)
        MemoryMetrics.embeddingCreated(count: embeddings.count)

        // 5. Upsert entities + edges + mentions. We record `newEdgesBetweenKnown`
        //    here so MemoryScore can compute the graph-novelty signal without
        //    re-reading the transaction's effects.
        let previouslyKnown: Set<Int64> = try await {
            var s: Set<Int64> = []
            for extracted in extraction.perChunk {
                for ent in extracted.entities {
                    if let kind = EntityKind(rawValue: ent.kind),
                       let row = try await store.entity(kind: kind, canonical: ent.canonical) {
                        s.insert(row.id)
                    }
                }
            }
            return s
        }()

        // PASS 1: upsert every entity from every chunk so the whole-batch
        // canonical→id map is fully populated before any edge is resolved.
        // The earlier per-chunk-interleaved approach dropped any edge whose
        // src/dst was first introduced in a *later* chunk of the same batch
        // — a routine pattern when the extractor surfaces cross-chunk
        // relations (a name introduced on page 2 cited from page 1).
        var canonicalToID: [String: Int64] = [:]
        for extracted in extraction.perChunk {
            for ent in extracted.entities {
                let kind = EntityKind(rawValue: ent.kind) ?? .concept
                let row = EntityRow(
                    kind: kind, canonical: ent.canonical,
                    aliases: ent.aliases,
                    firstSeen: now, lastSeen: now)
                let id = try await store.upsertEntity(row)
                canonicalToID[ent.canonical] = id
            }
        }
        // PASS 2: write per-chunk mentions and edges with the full map in
        // hand. Mentions remain tied to the chunk that surfaced the entity;
        // edges resolve against any entity in the batch.
        for extracted in extraction.perChunk {
            for ent in extracted.entities {
                guard let id = canonicalToID[ent.canonical] else { continue }
                if let chunkId = chunkIDs[extracted.localId] {
                    try await store.insertMention(MentionRow(
                        chunkId: chunkId, entityId: id, salience: ent.salience))
                }
                report.entitiesUpserted += 1
            }
            for edge in extracted.edges {
                guard let s = canonicalToID[edge.src],
                      let d = canonicalToID[edge.dst] else { continue }
                let evidence = chunkIDs[edge.evidenceChunkId ?? ""]
                let row = EdgeRow(
                    src: s, dst: d, relation: edge.relation,
                    firstSeen: now, lastSeen: now,
                    evidenceChunkId: evidence)
                _ = try await store.upsertEdge(row)
                report.edgesUpserted += 1
                if previouslyKnown.contains(s) && previouslyKnown.contains(d) {
                    report.newEdgesBetweenKnown += 1
                }
            }
        }
        // 6. Mirror the extraction into the JSONL archive so replays are
        //    deterministic without re-querying the inference provider. Only the
        //    full path produces an extraction worth archiving.
        if extract, let archive {
            let summary: [String: Any] = [
                "chunks": report.chunksWritten,
                "entities": report.entitiesUpserted,
                "edges": report.edgesUpserted,
                "new_edges_between_known": report.newEdgesBetweenKnown,
                "tokens_in": extraction.tokensInput,
                "tokens_out": extraction.tokensOutput,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: summary),
               let json = String(data: data, encoding: .utf8) {
                try? await archive.writeExtraction(documentID: documentId,
                                                   ts: now, payloadJSON: json)
            }
        }
        return report
    }
}

extension SourceSpec.Kind {
    func toMemorySource() -> MemorySource {
        switch self {
        case .rss:        return .rss
        case .arxiv:      return .arxiv
        case .github:     return .github
        case .newsletter: return .newsletter
        case .x:          return .x
        case .manual:     return .manual
        case .web:        return .web
        case .claude:     return .claude
        }
    }
}
