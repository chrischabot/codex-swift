import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MemoryStore
import MemoryScore   // SpendGate
import MemoryInfer   // ContextSanitizer

// Frontier GENERATION of plan/output bodies (§5.B/5.C). The `file` verb takes a
// pre-written body; `generate` assembles grounding evidence from the KB (real
// synthesis slugs + claim ids), asks a frontier model to write a body that cites
// ONLY those ids, then files it through the SAME grounded + project pipeline
// (CodexMemoryWikiArtifact.file) — so a generated plan is held to the identical
// grounding-lint bar as a hand-written one. Generation DEGRADES: no key / exhausted
// budget / transport failure → a clear error, never a fabricated (ungrounded) page.

/// One piece of grounding evidence: a real synthesis page + a few of its claims, with
/// the exact ids the model must cite (`[[slug]]`, `claim:<id>`).
struct EvidenceItem: Sendable, Equatable {
    var slug: String
    var title: String
    var claims: [(id: Int64, text: String)]

    static func == (a: EvidenceItem, b: EvidenceItem) -> Bool {
        a.slug == b.slug && a.title == b.title && a.claims.map(\.id) == b.claims.map(\.id)
    }
}

/// Assembles grounding evidence for a topic by lexical relevance over existing synthesis
/// pages — purely local, no model. The ranking is intentionally simple (token overlap on
/// title/slug, recency tie-break): its only job is to surface REAL ids the generator can
/// cite, so the body is grounded rather than hallucinated.
enum WikiEvidenceAssembler {
    /// Tokens: lowercased alnum runs ≥3 chars (drops noise words like "a"/"of" cheaply).
    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count >= 3 })
    }

    static func assemble(store: MemoryStore, topic: String,
                         maxPages: Int = 6, maxClaimsPerPage: Int = 6) async throws -> [EvidenceItem] {
        let want = tokens(topic)
        guard !want.isEmpty else { return [] }
        let pages = try await store.syntheses(limit: 5000)
        // Score by token overlap on title+slug; keep only pages that match at all.
        let ranked = pages.map { p -> (SynthesisRow, Int) in
            (p, want.intersection(tokens(p.title + " " + p.slug)).count)
        }
        .filter { $0.1 > 0 }
        .sorted { ($0.1, $0.0.updatedAt) > ($1.1, $1.0.updatedAt) }   // overlap desc, then recency
        .prefix(max(0, maxPages))

        var out: [EvidenceItem] = []
        for (p, _) in ranked {
            let claims = (try? await store.claimsForSynthesis(p.id)) ?? []
            out.append(EvidenceItem(slug: p.slug, title: p.title,
                                    claims: claims.prefix(max(0, maxClaimsPerPage)).map { ($0.id, $0.text) }))
        }
        return out
    }

    /// Render evidence into a compact prompt block the model can cite verbatim.
    static func render(_ evidence: [EvidenceItem]) -> String {
        var lines: [String] = []
        for e in evidence {
            lines.append("[[\(e.slug)]] — \(e.title)")
            for c in e.claims { lines.append("  claim:\(c.id) — \(c.text)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// The generation port — injectable so tests drive a deterministic mock and the CLI wires
/// the live frontier model. Returns the generated markdown body, or `nil` on degrade.
protocol ArtifactGenerating: Sendable {
    func generate(kind: String, format: String, title: String, topic: String, evidence: [EvidenceItem]) async -> String?
}

/// Live frontier generator. Reuses `WikiClaimExtractor.chatCall` + the shared `SpendGate`
/// (its OWN `wiki-frontier` bucket) + `ContextSanitizer` (evidence is partly web-derived).
struct WikiFrontierGenerator: ArtifactGenerating {
    let apiKey: String
    let model: String
    let spendGate: SpendGate?
    let endpoint = "https://api.openai.com/v1/chat/completions"

    func generate(kind: String, format: String, title: String, topic: String, evidence: [EvidenceItem]) async -> String? {
        guard !evidence.isEmpty else { return nil }   // nothing to ground against → refuse to generate
        let sys = """
        You are writing a wiki-grounded \(kind) (format: \(format)). Produce a markdown \
        document. Structure it as `## ` sections — for a plan, each section is a decision \
        or phase. EVERY `## ` section MUST end with a line exactly of the form \
        `Wiki grounding: [[slug]]` or `Wiki grounding: claim:N`, citing ONE OR MORE ids \
        taken ONLY from the EVIDENCE below. Do NOT invent slugs or claim ids — cite only \
        ids that appear verbatim in the evidence. Keep it tight and factual; no preamble \
        before the first heading. \(ContextSanitizer.dataPreamble)
        """
        let user = ContextSanitizer.sanitize(String((
            "Title: \(title.prefix(200))\nTopic: \(topic.prefix(400))\n\nEVIDENCE (cite these ids):\n"
            + WikiEvidenceAssembler.render(evidence)).prefix(12_000)))
        let key = apiKey, ep = endpoint
        let call: SpendGate.TokenCall = { prompt, model, _ in
            try await WikiClaimExtractor.chatCall(endpoint: ep, apiKey: key, model: model, sys: sys, user: prompt, jsonMode: false)
        }
        let body: String
        if let gate = spendGate {
            guard let outcome = try? await gate.run(prompt: user, model: model, call),
                  case let .ran(receipt) = outcome else { return nil }
            body = receipt.text
        } else {
            guard let r = try? await call(user, model, .distantFuture) else { return nil }
            body = r.text
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension CodexMemoryWikiArtifact {
    /// `wiki-plan generate` / `wiki-output generate` — assemble KB evidence → frontier
    /// generate a grounded body → file it through the existing grounded + project
    /// pipeline. Shared by both; `kind`/`category` differ. Strict plans still refuse if
    /// the generated body fails grounding (so an off-evidence generation is rejected, not
    /// silently filed). `generator` is injected (mock in tests, frontier in the CLI).
    static func generateAndFile(store: MemoryStore, vaultRoot: String, now: Int64,
                                kind: String, category: String, format: String?, outputType: String?,
                                slug: String, title: String, topic: String,
                                generator: any ArtifactGenerating, strict: Bool, enforceGrounding: Bool,
                                project: String?) async throws -> (String, Bool) {
        let evidence = try await WikiEvidenceAssembler.assemble(store: store, topic: topic)
        guard !evidence.isEmpty else {
            return ("wiki-\(category): REFUSED — no KB evidence matches topic '\(topic)' (ingest/compile first)\n", false)
        }
        guard let body = await generator.generate(kind: kind, format: format ?? outputType ?? kind,
                                                  title: title, topic: topic, evidence: evidence) else {
            return ("wiki-\(category): generation unavailable (no OPENAI_API_KEY, budget exhausted, or transport error)\n", false)
        }
        return try await file(store: store, vaultRoot: vaultRoot, now: now, slug: slug, title: title,
                              category: category, format: format, outputType: outputType, body: body,
                              strict: strict, enforceGrounding: enforceGrounding, project: project)
    }

    /// Build the live frontier generator from the environment, or nil when no key is set
    /// (the caller surfaces a clear "set OPENAI_API_KEY" message → graceful degrade).
    static func liveGenerator(store: MemoryStore) -> (any ArtifactGenerating)? {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["OPENAI_API_KEY"], !key.isEmpty else { return nil }
        let model = env["CODEXKIT_WIKI_FRONTIER_MODEL"] ?? "gpt-4o"
        // Frontier generation is the heavy lane → its own higher-ceiling bucket, kept
        // separate from the librarian/audit quick buckets.
        let gate = SpendGate(store: store, config: SpendGate.Config(
            monthlyCeilingUSD: 50, bucket: "wiki-frontier",
            inputUSDPerMTok: 2.50, outputUSDPerMTok: 10.0, reservationUSD: 0.10))
        return WikiFrontierGenerator(apiKey: key, model: model, spendGate: gate)
    }
}
