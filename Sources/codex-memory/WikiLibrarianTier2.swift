import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest/HTTPURLResponse on Linux
#endif
import MemoryStore
import MemoryScore
import MemoryInfer   // ContextSanitizer

// Librarian Tier-2 (§5.D). Tier-1 (LibrarianScorer, pure date arithmetic) flags a
// subset of pages; Tier-2 then scores ONLY that subset for coherence + utility via an
// OpenAI-quick *classification* pass (not synthesis), spend-gated. So model cost
// scales with problem density, not corpus size. Tier-2 DEGRADES — a missing key, an
// exhausted budget, or a transport failure leaves the page Tier-1-flagged; it never
// blocks or fabricates a score.

/// One page's Tier-2 model assessment. `coherence` and `utility` are integers 1...5
/// (5 = best).
struct LibrarianTier2Score: Sendable, Equatable {
    var documentID: Int64
    var coherence: Int
    var utility: Int
    var rationale: String
}

/// The Tier-2 scoring port — injectable so tests use a deterministic mock and the CLI
/// wires the live OpenAI scorer.
protocol CoherenceScoring: Sendable {
    /// Score one page, or return `nil` on no-credential / budget-exhausted / transport
    /// failure (Tier-2 degrades; the page stays Tier-1-flagged).
    func score(title: String, body: String) async -> (coherence: Int, utility: Int, rationale: String)?
}

/// Live OpenAI-quick coherence/utility scorer. Reuses `WikiClaimExtractor.chatCall`
/// (JSON mode) + the shared `SpendGate` admission control.
struct WikiCoherenceScorer: CoherenceScoring {
    let apiKey: String
    let model: String
    let spendGate: SpendGate?
    let endpoint = "https://api.openai.com/v1/chat/completions"

    init(apiKey: String, model: String, spendGate: SpendGate? = nil) {
        self.apiKey = apiKey; self.model = model; self.spendGate = spendGate
    }

    func score(title: String, body: String) async -> (coherence: Int, utility: Int, rationale: String)? {
        let sys = """
        You are a wiki librarian assessing ONE knowledge article during a maintenance \
        review. Rate it on two axes, each an INTEGER from 1 to 5:
        - coherence: is it internally consistent, well-structured, and free of \
        contradictions and filler? (5 = tight & consistent, 1 = rambling/contradictory)
        - utility: how useful and information-dense is it for someone researching this \
        topic? (5 = highly useful, 1 = empty/boilerplate)
        Respond ONLY with JSON {"coherence":N,"utility":M,"rationale":"one short sentence"}. \
        \(ContextSanitizer.dataPreamble)
        """
        // Page content is partly derived from fetched web text → sanitize before
        // prompt. Cap the title so a pathological (huge) title can't starve the body
        // out of the 8000-char window.
        let user = ContextSanitizer.sanitize(String(("Title: \(title.prefix(200))\n\n\(body)").prefix(8000)))
        let key = apiKey, ep = endpoint
        let call: SpendGate.TokenCall = { prompt, model, _ in
            try await WikiClaimExtractor.chatCall(endpoint: ep, apiKey: key, model: model, sys: sys, user: prompt)
        }
        let content: String
        if let gate = spendGate {
            // .rateLimited (ceiling reached) or any thrown error → no score this page.
            guard let outcome = try? await gate.run(prompt: user, model: model, call),
                  case let .ran(receipt) = outcome else { return nil }
            content = receipt.text
        } else {
            guard let r = try? await call(user, model, .distantFuture) else { return nil }
            content = r.text
        }
        return Self.parse(content)
    }

    /// Parse + clamp the model's JSON. Returns `nil` if EITHER score is absent or
    /// unparseable (a half-answer is not a score).
    static func parse(_ content: String) -> (coherence: Int, utility: Int, rationale: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] else { return nil }
        func clamp(_ v: Any?) -> Int? {
            let n: Int?
            if let i = v as? Int { n = i }
            else if let d = v as? Double { n = Int(d.rounded()) }
            else if let s = v as? String {
                // Accept "4" and "3.5" alike (the latter rounds), matching the
                // numeric Int/Double handling above.
                let t = s.trimmingCharacters(in: .whitespaces)
                if let i = Int(t) { n = i }
                else if let d = Double(t) { n = Int(d.rounded()) }
                else { n = nil }
            }
            else { n = nil }
            return n.map { min(5, max(1, $0)) }
        }
        guard let c = clamp(obj["coherence"]), let u = clamp(obj["utility"]) else { return nil }
        let r = (obj["rationale"] as? String).map { String($0.prefix(280)) } ?? ""
        return (c, u, r)
    }
}

/// Tier-2 runner: select the Tier-1-flagged subset, assemble each page's content from
/// the DB, score it through the model port, and persist the combined report.
enum LibrarianTier2 {
    /// The text scored for one page: its linked claims (always DB-available and
    /// scheme-independent), enriched with the on-disk body when `bodyPath` is a
    /// readable file (skips the wiki-compile `inline:` scheme). The title is supplied
    /// to `score` separately, so it is not duplicated here.
    static func pageText(store: MemoryStore, syn: SynthesisRow, vaultRoot: String?) async -> String {
        var parts: [String] = []
        if let claims = try? await store.claimsForSynthesis(syn.id), !claims.isEmpty {
            parts.append("## Claims")
            parts.append(contentsOf: claims.prefix(40).map { "- \($0.text)" })
        }
        if !syn.bodyPath.isEmpty, !syn.bodyPath.hasPrefix("inline:") {
            let path = (syn.bodyPath as NSString).isAbsolutePath
                ? syn.bodyPath
                : (vaultRoot.map { ($0 as NSString).appendingPathComponent(syn.bodyPath) } ?? syn.bodyPath)
            if let body = try? String(contentsOfFile: path, encoding: .utf8) { parts.append(body) }
        }
        return parts.joined(separator: "\n")
    }

    /// Score the flagged subset (capped at `limit`; `scores` is already stalest-first,
    /// so the cap keeps the most-stale pages). Pages that fail to score are skipped.
    static func review(store: MemoryStore, scores: [LibrarianPageScore],
                       scorer: any CoherenceScoring, limit: Int, vaultRoot: String? = nil) async -> [LibrarianTier2Score] {
        let flagged = scores.filter(\.needsTier2).prefix(max(0, limit))
        var out: [LibrarianTier2Score] = []
        for s in flagged {
            guard let syn = try? await store.synthesis(id: s.documentID) else { continue }
            let text = await pageText(store: store, syn: syn, vaultRoot: vaultRoot)
            // No substantive content (no claims + no readable body, e.g. an `inline:`
            // page with zero linked claims) → skip rather than have the model invent a
            // score from the title alone. The page stays Tier-1-flagged.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let r = await scorer.score(title: syn.title, body: text) else { continue }
            out.append(LibrarianTier2Score(documentID: s.documentID, coherence: r.coherence,
                                           utility: r.utility, rationale: r.rationale))
        }
        return out
    }

    /// Persist Tier-1 + Tier-2 to `<vaultRoot>/.librarian/scan-results.json` (the §5.D
    /// durable artifact). Best-effort; returns the path it wrote (or attempted).
    @discardableResult
    static func persist(vaultRoot: String, scores: [LibrarianPageScore],
                        tier2: [LibrarianTier2Score], now: Int64) -> String {
        let tier1JSON = scores.map { s -> [String: Any] in
            ["documentID": NSNumber(value: s.documentID), "volatility": s.volatility.rawValue,
             "staleness": (s.staleness.score * 100).rounded() / 100, "needsTier2": s.needsTier2,
             "sourceCount": s.quality.sourceCount, "depthProxy": s.quality.depthProxy]
        }
        let tier2JSON = tier2.map { t -> [String: Any] in
            ["documentID": NSNumber(value: t.documentID), "coherence": t.coherence,
             "utility": t.utility, "rationale": t.rationale]
        }
        let obj: [String: Any] = ["generated_at": NSNumber(value: now), "pages": scores.count,
                                  "flagged": scores.filter(\.needsTier2).count,
                                  "tier2_scored": tier2.count, "tier1": tier1JSON, "tier2": tier2JSON]
        let dir = (vaultRoot as NSString).appendingPathComponent(".librarian")
        let path = (dir as NSString).appendingPathComponent("scan-results.json")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj,
                            options: [.sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        return path
    }
}
