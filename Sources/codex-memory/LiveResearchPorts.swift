import Foundation
import WikiResearch
import WikiIngest
import MemoryStore
import MemoryRetrieve
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

    func gather(topic: String, mode: ResearchMode, angles: [SwarmAngle],
                round: Int, gaps: [Gap]) async throws -> [RankedSource] {
        var out: [RankedSource] = []
        var domainCount: [String: Int] = [:]
        for angle in angles {
            let query = "\(topic) — \(angle.focus)"
            guard case .success(let answer) = await webSearch.search(query) else { continue }
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
/// matching the store stamp) so it's queryable; then write a synthesis page for the
/// round. Returns the wiki-size signals the progress score needs.
struct LiveResearchCompiler: ResearchCompiler {
    let writer: WikiIngestWriter
    let store: MemoryStore
    let fetcher: PinnedFetcher
    let fetchedAt: Int64
    let vaultRoot: String

    func compile(topic: String, sources: [RankedSource], round: Int) async throws -> CompileOutcome {
        var written = 0
        var ingestedURIs: [String] = []
        for s in sources {
            guard let u = URL(string: s.url) else { continue }
            guard case .success(let doc) = await fetcher.fetchReadable(u) else { continue }
            let cand = WikiSourceCandidate(
                sourceURI: s.url, rawType: .articles, title: s.title, bodyMarkdown: doc.markdown,
                contentFormat: .html,
                provenance: CollectionProvenance(adapter: "research", collection: topic, canonicalURL: s.url),
                fetched: fetchedAt, extractionStatus: "ok")
            if let r = try? await writer.write(cand, extract: false), !r.skipped {
                written += 1; ingestedURIs.append(s.url)
            }
        }
        // A synthesis page for the round: the topic + the cited sources, so the wiki
        // gains a real page (and the trust layer has something to score).
        if written > 0 {
            try? await writeSynthesis(topic: topic, round: round, sources: ingestedURIs)
        }
        let pageCount = (try? await store.documentCount()) ?? 0
        return CompileOutcome(articlesCreatedOrUpdated: written, crossRefsAdded: ingestedURIs.count,
                              existingArticles: pageCount, crossRefDensity: 0.3)
    }

    private func writeSynthesis(topic: String, round: Int, sources: [String]) async throws {
        let slug = "research-" + Self.slugify(topic) + "-r\(round)"
        var body = "# \(topic)\n\n_Compiled by research round \(round)._\n\n## Sources\n"
        for s in sources { body += "- \(s)\n" }
        let dir = vaultRoot + "/wiki/synthesis"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(slug).md"
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        _ = try await store.upsertSynthesis(SynthesisRow(
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

/// Between-round reflection — ask the model for the open questions, parse them into
/// scored gaps. Cheap (one search/round); returns [] on failure (→ the loop winds
/// down rather than spinning).
struct LiveGapReflector: GapReflector {
    let webSearch: any WebSearchBackend
    func reflect(topic: String, rounds: [RoundRecord]) async throws -> [Gap] {
        let q = "List 3 specific, still-unanswered research questions about: \(topic). One per line."
        guard case .success(let answer) = await webSearch.search(q) else { return [] }
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
