import Foundation
import InfraPrimitives
import MemoryIngest
import MemoryInfer
import MemoryProcess
import MemoryStore

struct ClaudeImportDocument: Decodable {
    var sourceName: String?
    var sourceURI: String
    var title: String?
    var publishedAt: Int64?
    var fetchedAt: Int64?
    var canonicalText: String

    enum CodingKeys: String, CodingKey {
        case sourceName = "source_name"
        case sourceURI = "source_uri"
        case title
        case publishedAt = "published_at"
        case fetchedAt = "fetched_at"
        case canonicalText = "canonical_text"
    }
}

public enum CodexMemoryClaudeImport {
    public static func run(args: [String]) async throws -> String {
        let extractMode = args.contains("--extract")
        let positional = args.filter { !$0.hasPrefix("--") }
        guard let path = positional.first, !path.isEmpty else {
            return "FAIL import-claude requires a JSONL path\n"
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            return "FAIL import-claude input is not UTF-8: \(path)\n"
        }

        let bundle = try await CodexMemoryRun.assemble()
        let decoder = JSONDecoder()
        var imported = 0
        var failed = 0
        var linesOut: [String] = []

        for (idx, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            do {
                let doc = try decoder.decode(ClaudeImportDocument.self,
                                             from: Data(line.utf8))
                let canonical = Normaliser.plainText(from: doc.canonicalText)
                let sha = Normaliser.contentSHA(canonical)
                let now = Int64(Date().timeIntervalSince1970)
                let ingestDoc = IngestedDocument(
                    sourceName: doc.sourceName ?? "claude-export",
                    sourceKind: .claude,
                    sourceURI: doc.sourceURI,
                    title: doc.title,
                    publishedAt: doc.publishedAt,
                    fetchedAt: doc.fetchedAt ?? now,
                    canonicalText: canonical,
                    rawBytes: Int64(canonical.utf8.count),
                    contentSHA: sha)
                let report: ProcessReport
                if extractMode {
                    report = try await bundle.processor.process(ingestDoc)
                } else {
                    report = try await importCanonical(doc: ingestDoc, bundle: bundle)
                }
                imported += 1
                linesOut.append("OK \(idx + 1) document_id=\(report.documentId) chunks=\(report.chunksWritten) uri=\(doc.sourceURI)")
            } catch {
                failed += 1
                linesOut.append("FAIL \(idx + 1) \(error)")
            }
        }

        linesOut.append("import-claude summary: imported=\(imported) failed=\(failed)")
        return linesOut.joined(separator: "\n") + "\n"
    }

    private static func importCanonical(doc: IngestedDocument,
                                        bundle: CodexMemoryRun.AssembledMemory) async throws -> ProcessReport {
        if let existing = try await bundle.store.document(byURI: doc.sourceURI) {
            try await bundle.store.deleteDocument(id: existing.id)
        }

        let bodyPath = bundle.archive.bodyPath(
            sourceURI: doc.sourceURI,
            ts: doc.fetchedAt,
            contentSHA: doc.contentSHA)
        let row = DocumentRow(
            source: .claude,
            sourceURI: doc.sourceURI,
            title: doc.title,
            bodyPath: bodyPath,
            fetchedAt: doc.fetchedAt,
            publishedAt: doc.publishedAt,
            contentSHA: doc.contentSHA,
            rawBytes: doc.rawBytes)
        let documentId = try await bundle.store.upsertDocument(row)
        _ = try? await bundle.archive.writeDocument(
            sourceURI: doc.sourceURI,
            documentID: documentId,
            ts: doc.fetchedAt,
            bodyText: doc.canonicalText,
            contentSHA: doc.contentSHA)

        let splitter = ChunkSplitter()
        let pieces = splitter.split(doc.canonicalText)
        guard !pieces.isEmpty else {
            return ProcessReport(documentId: documentId)
        }

        var report = ProcessReport(documentId: documentId)
        let now = Int64(Date().timeIntervalSince1970)
        let embedBatchSize = 64
        var offset = 0
        while offset < pieces.count {
            let end = min(offset + embedBatchSize, pieces.count)
            let batch = Array(pieces[offset..<end])
            let embeddings = try await bundle.inference.embed(
                batch.map(\.text),
                deadline: .fromNow(.seconds(30)))
            guard embeddings.count == batch.count else {
                throw InferenceError.malformedResponse(
                    "embedding count \(embeddings.count) != chunks \(batch.count)")
            }

            for (piece, embedding) in zip(batch, embeddings) {
                let chunk = ChunkRow(
                    documentId: documentId,
                    idx: piece.idx,
                    text: piece.text,
                    rawText: piece.text,
                    tokenCount: piece.tokens,
                    createdAt: now)
                _ = try await bundle.store.insertChunk(
                    chunk,
                    embeddingValues: embedding.values)
                report.chunksWritten += 1
            }
            offset = end
        }
        return report
    }
}
