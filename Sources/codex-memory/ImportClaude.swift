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
        return await importDocuments(text: text, extractMode: extractMode,
                                     store: bundle.store, processor: bundle.processor)
    }

    /// The per-document import loop, factored out so it depends ONLY on the store
    /// + processor (not a full AssembledMemory bundle) and can be driven directly
    /// in tests. Decodes one ClaudeImportDocument per line, drops any prior
    /// version of the source (idempotent re-import — process() upserts the
    /// document but does NOT clear its old chunks, so re-importing without this
    /// would duplicate every chunk), then runs the one shared pipeline with LLM
    /// extraction toggled by --extract: default = cheap (split + embed raw
    /// chunks); --extract = full (contextualise + entity/edge graph).
    static func importDocuments(text: String, extractMode: Bool,
                                store: MemoryStore,
                                processor: MemoryProcessor) async -> String {
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
                if let existing = try await store.document(byURI: ingestDoc.sourceURI) {
                    try await store.deleteDocument(id: existing.id)
                }
                let report = try await processor.process(ingestDoc, extract: extractMode)
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
}
