import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest/HTTPURLResponse on Linux
#endif
import MemoryStore
import MemoryScore
import MemoryInfer    // ContextSanitizer
import PinnedFetcher
import EgressGuard

// Audit Pass 3 — truth-escalation (§5.D). Pass 2 (drift) flags pages compiled from a
// claim that has since changed; Pass 3 then RE-VERIFIES those pages' claims against
// the CURRENT version of their cited sources: re-fetch the cited URL through
// EgressGuard+PinnedFetcher, then run ONE confirm + ONE disprove frontier query
// (independent, to fight single-prompt bias). Read-only on knowledge — it writes only
// a durable `.audit/verdicts.json`. It DEGRADES: no credential / exhausted budget /
// fetch failure / contentless source → the claim is `insufficient` (or skipped), never
// a fabricated verdict.

/// Per-claim re-verification verdict.
enum AuditVerdict: String, Sendable, Equatable {
    case supported      // the re-fetched source still supports the claim
    case contradicted   // the re-fetched source now contradicts the claim
    case insufficient   // can't tell (no URL, unfetchable, model unsure)
    case mixed          // at the page level: a genuine conflict (one claim supports,
                        // another contradicts) OR partial coverage (some supported,
                        // some insufficient). At the claim level: both confirm AND
                        // disprove fired.
}

struct AuditClaimVerdict: Sendable, Equatable {
    var claimID: Int64
    var verdict: AuditVerdict
    var rationale: String
}

struct AuditPageVerdict: Sendable, Equatable {
    /// The synthesis (wiki PAGE) row id — NOT a `document` id. (Audit operates over
    /// compiled pages; the cited-source documents are reached via claim evidence.)
    var pageID: Int64
    var verdict: AuditVerdict
    var claims: [AuditClaimVerdict]
}

/// Re-fetch port (PinnedFetcher in prod, a mock in tests). Returns the readable
/// markdown of `url`, or nil on any fetch/screen failure.
protocol AuditEvidenceFetcher: Sendable {
    func fetchMarkdown(_ url: URL) async -> String?
}

/// Frontier confirm/disprove adjudication port. Returns nil on no-credential / budget /
/// transport failure (degrade — never fabricate).
protocol ClaimAdjudicator: Sendable {
    func adjudicate(claim: String, evidence: String) async -> (verdict: AuditVerdict, rationale: String)?
}

/// PinnedFetcher → AuditEvidenceFetcher adapter (EgressGuard-screened, redirects
/// disabled inside PinnedFetcher).
struct PinnedAuditFetcher: AuditEvidenceFetcher {
    let fetcher: PinnedFetcher
    func fetchMarkdown(_ url: URL) async -> String? {
        if case .success(let doc) = await fetcher.fetchReadable(url) { return doc.markdown }
        return nil
    }
}

/// Live confirm/disprove adjudicator (OpenAI JSON mode, spend-gated). Two INDEPENDENT
/// calls — a confirm pass and a disprove pass — combined into one verdict.
struct WikiClaimAdjudicator: ClaimAdjudicator {
    let apiKey: String
    let model: String
    let spendGate: SpendGate?
    /// Injectable raw chat transport (default = OpenAI chat-completions). Tests inject
    /// a deterministic stub to exercise the two-call (confirm + disprove) logic — and
    /// its partial-failure semantics — without the network.
    let transport: @Sendable (_ sys: String, _ user: String, _ model: String) async throws
        -> (text: String, tokensIn: Int, tokensOut: Int)

    init(apiKey: String, model: String, spendGate: SpendGate? = nil,
         transport: (@Sendable (_ sys: String, _ user: String, _ model: String) async throws
            -> (text: String, tokensIn: Int, tokensOut: Int))? = nil) {
        self.apiKey = apiKey; self.model = model; self.spendGate = spendGate
        let key = apiKey
        self.transport = transport ?? { sys, user, model in
            try await WikiClaimExtractor.chatCall(
                endpoint: "https://api.openai.com/v1/chat/completions",
                apiKey: key, model: model, sys: sys, user: user)
        }
    }

    func adjudicate(claim: String, evidence: String) async -> (verdict: AuditVerdict, rationale: String)? {
        let c = ContextSanitizer.sanitize(String(claim.prefix(500)))
        let ev = ContextSanitizer.sanitize(String(evidence.prefix(6000)))
        guard let confirm = await ask(
            sys: "You are a meticulous fact-checker. Decide whether the EVIDENCE SUPPORTS the CLAIM. Respond ONLY with JSON {\"supports\": true|false, \"why\": \"one short sentence\"}. \(ContextSanitizer.dataPreamble)",
            boolKey: "supports", claim: c, evidence: ev) else { return nil }
        guard let disprove = await ask(
            sys: "You are a meticulous fact-checker. Decide whether the EVIDENCE CONTRADICTS the CLAIM. Respond ONLY with JSON {\"contradicts\": true|false, \"why\": \"one short sentence\"}. \(ContextSanitizer.dataPreamble)",
            boolKey: "contradicts", claim: c, evidence: ev) else { return nil }
        let verdict = Self.combine(supports: confirm.flag, contradicts: disprove.flag)
        let rationale = String("confirm: \(confirm.why) | disprove: \(disprove.why)".prefix(400))
        return (verdict, rationale)
    }

    /// One boolean classification call. Returns nil if the call fails OR the model
    /// omits the boolean key (a half-answer is not an answer).
    private func ask(sys: String, boolKey: String, claim: String, evidence: String) async -> (flag: Bool, why: String)? {
        let user = "CLAIM: \(claim)\n\nEVIDENCE:\n\(evidence)"
        let t = transport
        let call: SpendGate.TokenCall = { prompt, model, _ in
            try await t(sys, prompt, model)
        }
        let content: String
        if let gate = spendGate {
            guard let outcome = try? await gate.run(prompt: user, model: model, call),
                  case let .ran(r) = outcome else { return nil }
            content = r.text
        } else {
            guard let r = try? await call(user, model, .distantFuture) else { return nil }
            content = r.text
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let flag = Self.parseBool(obj[boolKey]) else { return nil }
        return (flag, String(((obj["why"] as? String) ?? "").prefix(200)))
    }

    static func parseBool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String {
            // Only recognized tokens map; anything else (e.g. "maybe") → nil so the
            // adjudicator treats a non-boolean answer as a failed call (degrade), not
            // a guessed `false`.
            let t = s.lowercased()
            if ["true", "yes", "1"].contains(t) { return true }
            if ["false", "no", "0"].contains(t) { return false }
            return nil
        }
        return nil
    }

    /// confirm × disprove → verdict. Conflicting (both fire) → `.mixed`; neither →
    /// `.insufficient`.
    static func combine(supports: Bool, contradicts: Bool) -> AuditVerdict {
        switch (supports, contradicts) {
        case (true, false): return .supported
        case (false, true): return .contradicted
        case (true, true):  return .mixed
        case (false, false): return .insufficient
        }
    }
}

/// The Pass-3 runner.
enum AuditTruthEscalation {
    /// Total evidence budget (chars) fed to the judge per claim, split across the
    /// claim's cited URLs.
    static let maxEvidenceChars = 6000

    /// Re-verify the drifted pages (capped at `limit`). For each page, re-verify up to
    /// `maxClaimsPerPage` claims by re-fetching up to `maxURLsPerClaim` cited source
    /// URLs and adjudicating. Pages with no re-verifiable claims are dropped (no
    /// fabricated verdict).
    static func escalate(store: MemoryStore, driftedIDs: [Int64],
                         fetcher: any AuditEvidenceFetcher, judge: any ClaimAdjudicator,
                         limit: Int, maxClaimsPerPage: Int = 5, maxURLsPerClaim: Int = 2) async -> [AuditPageVerdict] {
        var out: [AuditPageVerdict] = []
        for pid in driftedIDs.prefix(max(0, limit)) {
            guard let claims = try? await store.claimsForSynthesis(pid), !claims.isEmpty else { continue }
            var verdicts: [AuditClaimVerdict] = []
            for claim in claims.prefix(maxClaimsPerPage) {
                let cited = await citedURLs(store: store, claimID: claim.id, max: maxURLsPerClaim)
                guard !cited.isEmpty else {
                    verdicts.append(AuditClaimVerdict(claimID: claim.id, verdict: .insufficient,
                                                      rationale: "no cited URL to re-fetch")); continue
                }
                // Budget the evidence window ACROSS the cited URLs so a long first
                // source doesn't starve the rest (each gets an equal share, floored).
                let perURLCap = max(800, maxEvidenceChars / cited.count)
                var parts: [String] = []
                for u in cited { if let md = await fetcher.fetchMarkdown(u) { parts.append(String(md.prefix(perURLCap))) } }
                let evidence = parts.joined(separator: "\n\n---\n\n")
                guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    verdicts.append(AuditClaimVerdict(claimID: claim.id, verdict: .insufficient,
                                                      rationale: "cited source(s) could not be re-fetched")); continue
                }
                // Judge unavailable (no key / budget / partial-call failure) → skip this
                // claim (don't fabricate).
                guard let r = await judge.adjudicate(claim: claim.text, evidence: evidence) else { continue }
                verdicts.append(AuditClaimVerdict(claimID: claim.id, verdict: r.verdict, rationale: r.rationale))
            }
            guard !verdicts.isEmpty else { continue }
            out.append(AuditPageVerdict(pageID: pid, verdict: aggregate(verdicts), claims: verdicts))
        }
        return out
    }

    /// Cited http(s) URLs backing a claim (claim → evidence → document.source_uri),
    /// deduped, capped.
    static func citedURLs(store: MemoryStore, claimID: Int64, max: Int) async -> [URL] {
        let ev = (try? await store.evidence(forClaim: claimID)) ?? []
        var seen = Set<String>(); var urls: [URL] = []
        for e in ev {
            guard let doc = try? await store.document(id: e.documentID),
                  let u = URL(string: doc.sourceURI), (u.scheme == "http" || u.scheme == "https"),
                  seen.insert(u.absoluteString).inserted else { continue }
            urls.append(u)
            if urls.count == max { break }
        }
        return urls
    }

    /// Page verdict from its claim verdicts: contradicted dominates, then mixed, then
    /// (all-supported → supported / some-supported → mixed), else insufficient.
    static func aggregate(_ claims: [AuditClaimVerdict]) -> AuditVerdict {
        if claims.isEmpty { return .insufficient }
        if claims.contains(where: { $0.verdict == .contradicted }) { return .contradicted }
        if claims.contains(where: { $0.verdict == .mixed }) { return .mixed }
        let supported = claims.filter { $0.verdict == .supported }.count
        if supported == claims.count { return .supported }
        if supported > 0 { return .mixed }
        return .insufficient
    }

    /// Persist verdicts to `<vaultRoot>/.audit/verdicts.json`. Best-effort.
    @discardableResult
    static func persist(vaultRoot: String, verdicts: [AuditPageVerdict], now: Int64) -> String {
        let rows = verdicts.map { p -> [String: Any] in
            ["pageID": NSNumber(value: p.pageID), "verdict": p.verdict.rawValue,
             "claims": p.claims.map { ["claimID": NSNumber(value: $0.claimID),
                                       "verdict": $0.verdict.rawValue, "rationale": $0.rationale] }]
        }
        let contradicted = verdicts.filter { $0.verdict == .contradicted }.count
        let obj: [String: Any] = ["generated_at": NSNumber(value: now), "pages": verdicts.count,
                                  "contradicted": contradicted, "verdicts": rows]
        let dir = (vaultRoot as NSString).appendingPathComponent(".audit")
        let path = (dir as NSString).appendingPathComponent("verdicts.json")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj,
                            options: [.sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        return path
    }
}
