import Foundation
import InfraPrimitives
import ModelClient

/// Portable, non-MLX fallback. Targets an OpenAI-compatible Responses or
/// Chat-Completions endpoint via CodexKit's existing `ModelClient` plumbing.
///
/// This implementation is intentionally minimal: it accepts a closure that
/// the caller wires up to a real ModelClient (so we don't pull a strong
/// dependency on a specific endpoint or auth provider into MemoryInfer). The
/// closure receives a prompt + token budget and returns the raw response text;
/// the provider then parses entity/edge JSON and embedding vectors.
///
/// On a host with both MLX *and* a configured remote endpoint, `MemoryInfer`
/// composes the two: extractor/embedder/reranker stay local; only the
/// `BrainGate` insight calls cross the network. The seam is intentionally
/// thin so the same `LocalInferenceProvider` shape carries both routes.
public actor RemoteOpenAICompatibleProvider: LocalInferenceProvider {
    public typealias TextCall = @Sendable (
        _ prompt: String,
        _ deadline: Deadline) async throws -> String

    public typealias EmbeddingCall = @Sendable (
        _ texts: [String],
        _ deadline: Deadline) async throws -> [[Float]]

    public typealias LogprobCall = @Sendable (
        _ text: String,
        _ given: String?,
        _ deadline: Deadline) async throws -> Double

    nonisolated public let embeddingDimension: Int

    private let textCall: TextCall
    private let embeddingCall: EmbeddingCall
    private let logprobCall: LogprobCall

    public init(embeddingDimension: Int,
                textCall: @escaping TextCall,
                embeddingCall: @escaping EmbeddingCall,
                logprobCall: @escaping LogprobCall) {
        self.embeddingDimension = embeddingDimension
        self.textCall = textCall
        self.embeddingCall = embeddingCall
        self.logprobCall = logprobCall
    }

    public func extract(_ batch: ChunkBatch,
                        schema: ExtractionSchema,
                        deadline: Deadline) async throws -> ExtractionResult {
        // Don't burn a model call on an empty batch — return the natural
        // empty result so the caller's flow stays simple.
        if batch.chunks.isEmpty {
            return ExtractionResult(perChunk: [], tokensInput: 0, tokensOutput: 0)
        }
        let prompt = ExtractionPrompt.render(batch: batch, schema: schema)
        let response = try await textCall(prompt, deadline)
        let perChunk = try ExtractionPrompt.parseJSON(
            response, batch: batch, schema: schema)
        // The remote endpoint may not surface token-counts; approximate from
        // sizes so the spend ledger has a credible number.
        let inTok = max(1, prompt.utf8.count / 4)
        let outTok = max(1, response.utf8.count / 4)
        return ExtractionResult(perChunk: perChunk,
                                tokensInput: inTok, tokensOutput: outTok)
    }

    public func contextualize(_ chunk: Chunk,
                              in document: DocumentDigest,
                              deadline: Deadline) async throws -> String {
        let prompt = ContextualisePrompt.render(chunk: chunk, document: document)
        let raw = try await textCall(prompt, deadline)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func embed(_ texts: [String], deadline: Deadline) async throws -> [Embedding] {
        // Short-circuit: most embedding endpoints reject `input: []` with HTTP
        // 400, but the natural answer is "no embeddings for no inputs".
        if texts.isEmpty { return [] }
        let raw = try await embeddingCall(texts, deadline)
        guard raw.count == texts.count else {
            throw InferenceError.malformedResponse(
                "embedding count \(raw.count) != input \(texts.count)")
        }
        // Validate every vector's dimensionality. A silent zero-vector
        // substitution makes the affected chunks permanently invisible to
        // vector search with no error surface — much worse than throwing
        // here and letting the processor record a recoverable failure.
        var out: [Embedding] = []
        out.reserveCapacity(raw.count)
        for (i, values) in raw.enumerated() {
            guard values.count == embeddingDimension else {
                throw InferenceError.malformedResponse(
                    "embedding dim mismatch at index \(i): got \(values.count) want \(embeddingDimension)")
            }
            var e = Embedding(values); e.normalise(); out.append(e)
        }
        return out
    }

    public func rerank(_ query: String,
                       candidates: [String],
                       deadline: Deadline) async throws -> [Float] {
        if candidates.isEmpty { return [] }
        // Without a cross-encoder endpoint, fall back to cosine of separate
        // embeddings. This is correctness-equivalent (a "stage-1 only" rerank)
        // and avoids the BGE-reranker-v2-m3 dependency when running portable.
        let all = try await embed([query] + candidates, deadline: deadline)
        guard let q = all.first else { return [] }
        return all.dropFirst().map { c in
            var dot: Float = 0
            for i in 0..<q.values.count { dot += q.values[i] * c.values[i] }
            return dot
        }
    }

    public func logprob(_ text: String,
                        given: String?,
                        deadline: Deadline) async throws -> Double {
        try await logprobCall(text, given, deadline)
    }
}

// MARK: - prompt templates + JSON parser

enum ExtractionPrompt {
    /// Version stamp for the held-out scoring harness (gbrain.md §9.6 #2): tie a
    /// scoring receipt to this exact prompt revision, and let a drift gate
    /// (PromptVersionGateTests) catch a silent edit. BUMP THIS whenever the
    /// instruction scaffold below changes (the gate fails until you do).
    static let promptVersion = "extract-graph-v1"

    static func render(batch: ChunkBatch, schema: ExtractionSchema) -> String {
        // Compact, deterministic prompt that asks for one JSON object per
        // chunk under top-level keys "chunks". A real GPT-5.5 deployment
        // would use the Responses API json_schema field; the same shape is
        // accepted here for cross-provider portability.
        var lines: [String] = []
        lines.append("You are a strict information extractor. For each chunk emit")
        lines.append("a JSON object of the form:")
        lines.append("{ \"chunks\": [ { \"id\": <id>,")
        lines.append("    \"entities\": [ { \"kind\": <one of \(schema.allowedEntityKinds)>,")
        lines.append("       \"canonical\": <string>, \"aliases\": [<string>...] } ],")
        lines.append("    \"edges\": [ { \"src\": <canonical>, \"dst\": <canonical>,")
        lines.append("       \"relation\": <one of \(schema.allowedRelations)> } ] } ] }")
        lines.append("")
        lines.append(ContextSanitizer.dataPreamble)
        lines.append("")
        // Title/URI/chunk text all originate from untrusted fetched content.
        lines.append("Title: \(ContextSanitizer.sanitize(batch.documentTitle ?? "(untitled)"))")
        lines.append("URI: \(ContextSanitizer.sanitize(batch.documentURI))")
        lines.append("")
        for c in batch.chunks {
            lines.append("--- chunk \(c.localId) ---")
            lines.append(ContextSanitizer.sanitize(c.contextualised))
        }
        lines.append("")
        lines.append("Return JSON only, no prose.")
        return lines.joined(separator: "\n")
    }

    /// Pull a JSON object out of a raw model response: drop reasoning-model
    /// `<think>…</think>` blocks and ```fences```, then take the span from the
    /// first `{` to the last `}`. Robust to a preamble/epilogue of prose.
    static func sanitizeJSONResponse(_ raw: String) -> String {
        var s = raw
        // Strip <think>…</think> reasoning blocks (Qwen3 etc.).
        while let open = s.range(of: "<think>"),
              let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // A dangling/unterminated <think> with no JSON after → nothing usable.
        s = s.replacingOccurrences(of: "```json", with: "```")
        s = s.replacingOccurrences(of: "```", with: "")
        guard let first = s.firstIndex(of: "{"), let last = s.lastIndex(of: "}"),
              first <= last else {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(s[first...last])
    }

    static func parseJSON(_ raw: String,
                          batch: ChunkBatch,
                          schema: ExtractionSchema) throws -> [ExtractedChunk] {
        let cleaned = sanitizeJSONResponse(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw InferenceError.malformedResponse("non-utf8 response")
        }
        let object: [String: Any]
        do {
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            throw InferenceError.malformedResponse("not JSON: \(error)")
        }
        guard let chunks = object["chunks"] as? [[String: Any]] else {
            throw InferenceError.malformedResponse("missing chunks[]")
        }
        let allowedKinds = Set(schema.allowedEntityKinds)
        let allowedRelations = Set(schema.allowedRelations)
        var out: [ExtractedChunk] = []
        for c in chunks {
            guard let id = c["id"] as? String else { continue }
            let entitiesRaw = c["entities"] as? [[String: Any]] ?? []
            var entities: [ExtractedEntity] = []
            for e in entitiesRaw {
                let kind = (e["kind"] as? String) ?? ""
                let canonical = (e["canonical"] as? String) ?? ""
                guard allowedKinds.contains(kind), !canonical.isEmpty else { continue }
                let aliases = (e["aliases"] as? [String]) ?? []
                entities.append(ExtractedEntity(kind: kind, canonical: canonical,
                                                aliases: aliases))
            }
            let edgesRaw = c["edges"] as? [[String: Any]] ?? []
            var edges: [ExtractedEdge] = []
            for e in edgesRaw {
                let src = (e["src"] as? String) ?? ""
                let dst = (e["dst"] as? String) ?? ""
                let rel = (e["relation"] as? String) ?? ""
                guard !src.isEmpty, !dst.isEmpty, allowedRelations.contains(rel) else { continue }
                edges.append(ExtractedEdge(src: src, dst: dst, relation: rel,
                                           evidenceChunkId: id))
            }
            out.append(ExtractedChunk(localId: id, entities: entities, edges: edges,
                                      logprobAvgBits: c["logprob_bits"] as? Double))
        }
        return out
    }
}

enum ContextualisePrompt {
    /// Version stamp (gbrain.md §9.6 #2) — see `ExtractionPrompt.promptVersion`.
    static let promptVersion = "contextualise-v1"

    static func render(chunk: Chunk, document: DocumentDigest) -> String {
        """
        Produce a single sentence (≤30 words) that situates the following chunk
        inside its source document. Do not summarise the chunk; orient it.
        \(ContextSanitizer.dataPreamble)

        Source title: \(ContextSanitizer.sanitize(document.title ?? "(none)"))
        Source URI:   \(ContextSanitizer.sanitize(document.uri))
        Source summary: \(ContextSanitizer.sanitize(document.summary))

        Chunk \(chunk.idx) text:
        \(ContextSanitizer.sanitize(chunk.rawText))

        Return the situating sentence with no quotes, no preamble.
        """
    }
}
