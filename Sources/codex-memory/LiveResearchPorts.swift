import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest/HTTPURLResponse on Linux
#endif
import WikiResearch
import WikiIngest
import MemoryStore
import MemoryRetrieve
import MemoryInfer
import MemoryScore
import PinnedFetcher
import Tools

// Live implementations of the WikiResearch ports (§6), wiring the deterministic
// orchestrator to real web search + the model + the pinned fetcher + the ingest
// writer. The web_search backend (OpenAI/Perplexity) does the search reasoning;
// PinnedFetcher pulls the cited pages; CredibilityScorer (LOCAL) assigns the trust
// points from URL signals — keeping credibility independent of the searcher.

/// Phase 1 — existing-knowledge check via local hybrid retrieval over the corpus.
struct LiveKnowledgeProbe: KnowledgeProbe {
    let retriever: MemoryRetriever
    func existing(topic: String, mode: ResearchMode) async throws -> ExistingKnowledge {
        let hits = (try? await retriever.search(topic, k: 8, rerank: false)) ?? []
        return ExistingKnowledge(knownFacts: hits.map(\.snippet), gaps: [], searchAngles: [])
    }
}

/// Phase 2-3 — the swarm: one web_search per angle → cited (title,url) sources →
/// LOCAL credibility scoring. Does NOT fetch here (only the selected survivors are
/// fetched, by the compiler) so a round is cheap.
struct LiveResearchSwarm: ResearchSwarm {
    let webSearch: any WebSearchBackend
    let perAngle: Int
    /// Budget admission control shared with the rest of the wiki-research lane.
    /// nil → ungated (tests / offline). Each web_search is a real paid query, so it
    /// is metered as a flat per-call token-equivalent against the wiki-research bucket.
    var spendGate: SpendGate? = nil

    func gather(topic: String, mode: ResearchMode, angles: [SwarmAngle],
                round: Int, gaps: [Gap]) async throws -> [RankedSource] {
        var out: [RankedSource] = []
        var domainCount: [String: Int] = [:]
        for angle in angles {
            let query = "\(topic) — \(angle.focus)"
            guard let answer = await Self.gatedSearch(webSearch, query: query, gate: spendGate) else { continue }
            for (title, url) in Self.extractSources(answer).prefix(perAngle) {
                let host = URL(string: url)?.host?.lowercased() ?? ""
                domainCount[host, default: 0] += 1
                let signals = Self.signals(host: host, corroboration: domainCount[host] ?? 1)
                let cred = CredibilityScorer.score(signals)
                out.append(RankedSource(url: url, title: title.isEmpty ? url : title,
                                        credibility: cred.points,
                                        agentQuality: Int(angle.weight * 3) + 1))
            }
        }
        return out
    }

    /// One budgeted web_search. When a gate is present the call is reserved+recorded
    /// against the lane's monthly ceiling; a rate-limited or failed search yields nil
    /// (the caller skips that angle/round — the loop winds down rather than overspends).
    /// web_search exposes NO token usage, so we charge a flat per-call estimate (1000
    /// input tokens) purely as a volume meter — this is intentional, not a real count.
    static func gatedSearch(_ backend: any WebSearchBackend, query: String,
                            gate: SpendGate?) async -> String? {
        guard let gate else {
            guard case .success(let a) = await backend.search(query) else { return nil }
            return a
        }
        let call: SpendGate.TokenCall = { q, _, _ in
            guard case .success(let a) = await backend.search(q) else {
                throw WikiClaimExtractor.ExtractorError(message: "web_search failed")
            }
            return (a, 1000, 0)   // flat per-search meter; no spend recorded on failure
        }
        guard let outcome = try? await gate.run(prompt: query, model: "web_search", call),
              case let .ran(receipt) = outcome else { return nil }
        return receipt.text
    }

    /// Parse the "Sources:\n- <title> <url>" block (and any bare URLs) the
    /// web_search backend appends.
    static func extractSources(_ answer: String) -> [(title: String, url: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s)\]>"']+"#) else { return [] }
        for rawLine in answer.split(separator: "\n") {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: range), let r = Range(m.range, in: line) else { continue }
            var url = String(line[r])
            while let last = url.last, ".,;:".contains(last) { url.removeLast() }   // strip trailing punctuation
            guard seen.insert(url).inserted else { continue }
            // title = the line minus the URL, minus a leading bullet
            var title = line.replacingOccurrences(of: String(line[r]), with: "")
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t"))
            out.append((title, url))
        }
        return out
    }

    /// Heuristic credibility signals from a domain (no fetch, no model — the points
    /// math stays local + independent of the searcher).
    static func signals(host: String, corroboration: Int) -> CredibilitySignals {
        let peer = host.contains("arxiv.org") || host.contains("doi.org") || host.hasSuffix(".edu")
            || host.contains("pubmed") || host.contains("ncbi.nlm") || host.contains("acm.org")
            || host.contains("ieee.org") || host.contains("nature.com") || host.contains("springer")
        let known = peer || host.contains("github.com") || host.contains("openai.com")
            || host.contains("anthropic.com") || host.contains("deepmind") || host.contains("wikipedia.org")
        return CredibilitySignals(peerReviewed: peer, recent: false, veryOld: false,
                                  knownAuthor: known, biasDetected: false, vendorPrimary: false,
                                  corroboratingAgents: max(0, corroboration - 1))
    }
}

/// Phase 4-5 — fetch each selected survivor (pinned) and ingest it (local embed,
/// matching the store stamp) so it's queryable; extract grounded CLAIMS from each
/// (model) and link them to a synthesis page for the round. Returns the wiki-size
/// signals the progress score needs.
struct LiveResearchCompiler: ResearchCompiler {
    let writer: WikiIngestWriter
    let store: MemoryStore
    let fetcher: PinnedFetcher
    let fetchedAt: Int64
    let vaultRoot: String
    let claimExtractor: WikiClaimExtractor?    // nil → skip claim extraction

    func compile(topic: String, sources: [RankedSource], round: Int) async throws -> CompileOutcome {
        var written = 0
        var ingestedDocs: [(uri: String, docID: Int64)] = []
        var uriCredibility: [String: Int] = [:]   // source URL → CredibilityResult.points
        for s in sources {
            uriCredibility[s.url] = s.credibility
            guard let u = URL(string: s.url) else { continue }
            guard case .success(let doc) = await fetcher.fetchReadable(u) else { continue }
            let cand = WikiSourceCandidate(
                sourceURI: s.url, rawType: .articles, title: s.title, bodyMarkdown: doc.markdown,
                contentFormat: .html,
                provenance: CollectionProvenance(adapter: "research", collection: topic, canonicalURL: s.url),
                fetched: fetchedAt, extractionStatus: "ok")
            if let r = try? await writer.write(cand, extract: false) {
                // Keep ALL resolved docs (including dedup-skipped existing ones) so a
                // rerun / overlapping topic still gets a synthesis page + claim links;
                // only count genuinely-new writes toward the progress score.
                ingestedDocs.append((s.url, r.documentID))
                if !r.skipped { written += 1 }
            }
        }
        var claimsLinked = 0
        if !ingestedDocs.isEmpty {
            // Phase 1: extract + persist claims from each source FIRST (claims are
            // independent knowledge — they attach to their source doc, not the page),
            // collecting the ids to link. Counting before the page is written lets the
            // write gate REFUSE an ungrounded page up front, with no post-hoc rollback.
            var linkableClaims: [Int64] = []
            if let extractor = claimExtractor {
                for (uri, docID) in ingestedDocs {
                    let chunks = (try? await store.chunks(forDocument: docID)) ?? []
                    let text = chunks.prefix(8).map(\.text).joined(separator: "\n")
                    guard !text.isEmpty else { continue }
                    // Per-claim confidence comes from the SOURCE's credibility tier
                    // (the extractor emits verifiable claims but no per-claim score),
                    // then routes through the three-bucket write policy: high→active,
                    // mid→draft (review queue), low→skip+log. No more hardcoded 0.7.
                    // (gbrain.md Wave 0.3.)
                    let conf = ClaimWritePolicy.confidence(forCredibilityPoints: uriCredibility[uri] ?? 0)
                    let bucket = ClaimWritePolicy.bucket(forConfidence: conf)
                    let claims = await extractor.extract(text: text, maxClaims: 4)
                    for claimText in claims {
                        guard let status = bucket.claimStatus else {
                            ClaimWritePolicy.logSkipped(vaultRoot: vaultRoot, claim: claimText,
                                                        url: uri, confidence: conf, at: fetchedAt)
                            continue
                        }
                        guard let cid = try? await store.upsertClaim(ClaimRow(
                            text: claimText, status: status, confidence: conf,
                            firstSeen: fetchedAt, updatedAt: fetchedAt)) else { continue }
                        try? await store.attachEvidence(ClaimEvidenceRow(
                            claimID: cid, documentID: docID, chunkID: chunks.first?.id,
                            stance: .supports, relevance: .direct, strength: 2))
                        if status == .draft {
                            ClaimWritePolicy.logReview(vaultRoot: vaultRoot, claim: claimText,
                                                       url: uri, confidence: conf, at: fetchedAt)
                        }
                        linkableClaims.append(cid)
                    }
                }
            }
            // Phase 2: write gate (gbrain.md Wave 0.2). Validate BEFORE writing — an
            // ungrounded synthesis (zero linked claims) is logged in lint mode and
            // BLOCKED in strict mode. A blocked page is simply never written (claims
            // already persisted stand on their own evidence), so strict mode actually
            // refuses the write instead of leaving the bad page behind.
            let synthSlug = "research-" + Self.slugify(topic) + "-r\(round)"
            // Prior rounds of THIS topic are the only real PAGE slugs we can link to
            // (external sources are documents, not pages → linking them = brokenLink). We
            // collect them so the emitted [[See Also]] edges resolve (else strict mode
            // would false-block every research page).
            let priorSlugs = ((try? await store.syntheses(category: "synthesis")) ?? [])
                .map(\.slug)
                .filter { $0.hasPrefix("research-" + Self.slugify(topic) + "-r") && $0 != synthSlug }
            // Build the body ONCE — the same string the linter validates AND the writer
            // persists (the old body:"" made brokenLink/seeAlso loops a structural no-op).
            let synthBody = Self.renderSynthesisBody(topic: topic, round: round,
                                                     sources: ingestedDocs.map(\.uri), seeAlso: priorSlugs)
            var validSlugs = Set(priorSlugs); validSlugs.insert(synthSlug)
            let gate = WikiWriteGate(mode: await WikiWriteGate.resolveMode(store: store),
                                     vaultRoot: vaultRoot)
            let verdict = gate.validate(WikiLintPage(slug: synthSlug, body: synthBody, category: "synthesis",
                                                     claimLinkCount: linkableClaims.count),
                                        validSlugs: validSlugs)
            // Phase 3: write the page + link its claims, only when not blocked.
            if !verdict.block,
               let synthID = try? await writeSynthesis(slug: synthSlug, topic: topic, body: synthBody) {
                for cid in linkableClaims {
                    try? await store.linkSynthesisClaim(synthesis: synthID, claim: cid)
                    claimsLinked += 1
                }
            }
        }
        let pageCount = (try? await store.documentCount()) ?? 0
        return CompileOutcome(articlesCreatedOrUpdated: written, crossRefsAdded: claimsLinked,
                              existingArticles: pageCount, crossRefDensity: claimsLinked > 0 ? 0.7 : 0.2)
    }

    /// Render the synthesis page body ONCE so the write gate and the on-disk file are
    /// byte-identical. External sources stay plain `- <url>` citations (they are
    /// documents, not pages → linking them would be a brokenLink). The `## See Also`
    /// block carries `[[prior-round-slug]]` edges — the only real page slugs in the graph
    /// — so the link-graph linter has links to validate (was structurally empty before).
    static func renderSynthesisBody(topic: String, round: Int, sources: [String], seeAlso: [String]) -> String {
        var body = "# \(topic)\n\n_Compiled by research round \(round)._\n\n## Sources\n"
        for s in sources { body += "- \(s)\n" }
        if !seeAlso.isEmpty {
            body += "\n## See Also\n"
            for slug in seeAlso { body += "- [[\(slug)]]\n" }
        }
        return body
    }

    private func writeSynthesis(slug: String, topic: String, body: String) async throws -> Int64 {
        let dir = vaultRoot + "/wiki/synthesis"
        // Let file failures throw BEFORE upserting — never register a synthesis row
        // pointing at a body file that doesn't exist.
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(slug).md"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return try await store.upsertSynthesis(SynthesisRow(
            slug: slug, category: "synthesis", title: topic, bodyPath: path,
            confidence: "medium", volatility: .warm, verifiedAt: fetchedAt,
            createdAt: fetchedAt, updatedAt: fetchedAt, generatedAt: fetchedAt))
    }

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: " ", with: "-")
        return String(lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }).prefix(48).description
    }
}

/// Three-bucket confidence write policy for LLM-extracted claims (gbrain.md
/// Wave 0.3). Replaces the old hardcoded `confidence: 0.7, status: .active`:
/// a claim's confidence is derived from its SOURCE's credibility tier, then
/// routed — high-confidence claims become ground-truth (`.active`), mid become a
/// reviewable `.draft`, and low are skipped (logged, never written). Pure +
/// testable.
enum ClaimWritePolicy {
    /// Confidence ≥ this → `.active`.
    static let autoThreshold = 0.8
    /// Confidence in `[draftThreshold, autoThreshold)` → `.draft`; below → skip.
    static let draftThreshold = 0.5

    /// Map a source's `CredibilityResult.points` to a claim confidence in [0,1]
    /// via its trust tier.
    static func confidence(forCredibilityPoints points: Int) -> Double {
        switch CredibilityScorer.tier(points: points) {
        case .high:   return 0.85
        case .medium: return 0.65
        case .low:    return 0.55
        case .reject: return 0.30
        }
    }

    enum Bucket: Equatable {
        case active, draft, skip
        /// `nil` for `.skip` (the claim is not written).
        var claimStatus: ClaimStatus? {
            switch self {
            case .active: return .active
            case .draft:  return .draft
            case .skip:   return nil
            }
        }
    }

    static func bucket(forConfidence c: Double) -> Bucket {
        if c >= autoThreshold { return .active }
        if c >= draftThreshold { return .draft }
        return .skip
    }

    static func logSkipped(vaultRoot: String, claim: String, url: String,
                           confidence: Double, at ts: Int64) {
        appendJSONL(path: vaultRoot + "/research/low-confidence-claims.jsonl",
                    obj: ["claim": claim, "url": url, "confidence": confidence,
                          "ts": ts, "disposition": "skipped"])
    }

    static func logReview(vaultRoot: String, claim: String, url: String,
                          confidence: Double, at ts: Int64) {
        appendJSONL(path: vaultRoot + "/research/draft-claims-review.jsonl",
                    obj: ["claim": claim, "url": url, "confidence": confidence,
                          "ts": ts, "disposition": "draft"])
    }

    /// Best-effort append of one JSON line. Creates the parent dir + file if absent.
    static func appendJSONL(path: String, obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)   // '\n'
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path), let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: line)
        } else {
            try? line.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Extracts atomic, verifiable claims from a source's text via the OpenAI chat API
/// (JSON mode). The missing producer for the wiki claim layer — research links each
/// returned claim to its source (evidence) and the round's synthesis page.
struct WikiClaimExtractor: Sendable {
    let apiKey: String
    let model: String
    /// Budget admission control. When present, every claim-extraction call is
    /// reserved+recorded against a monthly USD ceiling (the documented
    /// "remote extraction has real dollar cost with no ceiling" hole, gbrain.md
    /// Wave 0.1). When `nil`, the call runs ungated (back-compat for tests).
    let spendGate: SpendGate?
    let endpoint = "https://api.openai.com/v1/chat/completions"

    init(apiKey: String, model: String, spendGate: SpendGate? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.spendGate = spendGate
    }

    struct ExtractorError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Version stamp for the held-out scoring harness (gbrain.md §9.6 #2): tie a
    /// scoring receipt to this prompt revision; a drift gate (PromptVersionGateTests)
    /// catches a silent edit. BUMP when `systemPrompt` changes.
    static let promptVersion = "wiki-claim-v1"

    /// The claim-extraction system prompt. `maxClaims` is the only dynamic field, so
    /// the gate hashes a fixed-`maxClaims` render.
    static func systemPrompt(maxClaims: Int) -> String {
        """
        You extract atomic, verifiable factual claims from the provided text. Each \
        claim is ONE self-contained declarative sentence that could be independently \
        fact-checked. Skip opinions, questions, hedging, and navigation/boilerplate. \
        Respond ONLY with JSON of the form {"claims": ["claim 1", "claim 2"]} with at \
        most \(maxClaims) claims. \(ContextSanitizer.dataPreamble)
        """
    }

    func extract(text: String, maxClaims: Int) async -> [String] {
        let sys = Self.systemPrompt(maxClaims: maxClaims)
        // The text is arbitrary fetched web content — neutralize injection vectors
        // before it enters the prompt.
        let userContent = ContextSanitizer.sanitize(String(text.prefix(8000)))
        let key = apiKey, ep = endpoint
        // The raw chat call returns (content, tokensIn, tokensOut) and THROWS on
        // transport/HTTP failure so a no-op never records spend.
        let call: SpendGate.TokenCall = { prompt, model, _ in
            try await Self.chatCall(endpoint: ep, apiKey: key, model: model,
                                    sys: sys, user: prompt)
        }
        let content: String
        if let gate = spendGate {
            // .rateLimited (ceiling reached) or any error → no claims this round.
            guard let outcome = try? await gate.run(prompt: userContent, model: model, call),
                  case let .ran(receipt) = outcome
            else { return [] }
            content = receipt.text
        } else {
            guard let r = try? await call(userContent, model, .distantFuture) else { return [] }
            content = r.text
        }
        return Self.parseClaims(content)
    }

    /// One OpenAI chat-completions call. Throws on transport/non-2xx/parse
    /// failure. Returns the message content plus token usage (from the response
    /// `usage` block, falling back to a 4-chars/token estimate).
    static func chatCall(endpoint: String, apiKey: String, model: String,
                         sys: String, user: String, jsonMode: Bool = true) async throws
        -> (text: String, tokensIn: Int, tokensOut: Int) {
        // jsonMode forces `response_format: json_object` (extraction/scoring/adjudication).
        // Prose generation (plan/output bodies) turns it OFF to get markdown.
        var body: [String: Any] = [
            "model": model, "temperature": 0,
            "messages": [
                ["role": "system", "content": sys],
                ["role": "user", "content": user],
            ],
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: endpoint) else {
            throw ExtractorError(message: "could not encode request")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExtractorError(message: "non-2xx claim-extraction response")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
        else { throw ExtractorError(message: "malformed claim-extraction response") }
        let usage = obj["usage"] as? [String: Any]
        let tokensIn = (usage?["prompt_tokens"] as? Int)
            ?? max(1, (sys.utf8.count + user.utf8.count) / 4)
        let tokensOut = (usage?["completion_tokens"] as? Int)
            ?? max(1, content.utf8.count / 4)
        return (content, tokensIn, tokensOut)
    }

    static func parseClaims(_ content: String) -> [String] {
        guard let inner = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let claims = inner["claims"] as? [String]
        else { return [] }
        return claims.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 12 }
    }
}

/// Between-round reflection — ask the model for the open questions, parse them into
/// scored gaps. Cheap (one search/round); returns [] on failure (→ the loop winds
/// down rather than spinning).
struct LiveGapReflector: GapReflector {
    let webSearch: any WebSearchBackend
    /// Shared wiki-research budget; nil → ungated (back-compat). One search/round.
    var spendGate: SpendGate? = nil
    func reflect(topic: String, rounds: [RoundRecord]) async throws -> [Gap] {
        let q = "List 3 specific, still-unanswered research questions about: \(topic). One per line."
        guard let answer = await LiveResearchSwarm.gatedSearch(webSearch, query: q, gate: spendGate) else { return [] }
        var gaps: [Gap] = []
        for raw in answer.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-•*0123456789. \t"))
            guard line.count > 12, line.contains(" "), !line.lowercased().hasPrefix("source") else { continue }
            gaps.append(Gap(description: String(line.prefix(160)), impact: 3, feasibility: 3, specificity: 3))
            if gaps.count == 3 { break }
        }
        return gaps
    }
}
