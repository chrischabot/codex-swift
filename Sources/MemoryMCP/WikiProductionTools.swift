import Foundation
import MemoryStore
import Tools

public struct WikiBriefTool: Tool {
    public let name = "wiki_brief"
    public let parallelSafe = true
    public let toolDescription = "Create a citation-first brief from Memory Wiki lexical evidence. Local only; no cloud spend."
    public let jsonSchema = """
    {"type":"object","required":["topic"],"properties":{
      "topic":{"type":"string"},
      "query":{"type":"string"},
      "audience":{"type":"string"},
      "k":{"type":"integer","minimum":1,"maximum":20,"default":8},
      "include_compiled":{"type":"boolean","default":false}}}
    """
    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable {
            var topic: String?
            var query: String?
            var audience: String?
            var k: Int?
            var include_compiled: Bool?
        }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        let topic = firstNonEmpty(args.topic, args.query)
        guard !topic.isEmpty,
              let k = MCPJSON.boundedInt(args.k, defaultValue: 8, min: 1, max: 20) else {
            return ToolResult(callId: call.callId,
                              output: "invalid wiki_brief arguments",
                              success: false, truncated: false)
        }
        let evidence = try await lexicalEvidence(store: store,
                                                 query: topic,
                                                 k: k,
                                                 includeCompiled: args.include_compiled ?? false)
        let status = statusForEvidence(evidence)
        let payload = WikiBriefPayload(
            status: status,
            topic: topic,
            audience: args.audience,
            summary: status == .insufficientEvidence
                ? "Insufficient cited Memory Wiki evidence for a brief."
                : "Brief grounded in \(evidence.count) lexical Memory Wiki citations.",
            key_points: status == .ok ? citedPoints(evidence, prefix: "Evidence") : [],
            citations: evidence,
            confidence: confidence(evidence),
            novelty_rationale: status == .ok ? noveltyRationale(evidence) : [],
            what_would_change_my_mind: changeMyMind(topic: topic, evidence: evidence),
            limitations: limitations(evidence),
            uncited_claims: [],
            retrieval: .lexical)
        return ToolResult(callId: call.callId, output: MCPJSON.encode(payload),
                          success: true, truncated: false)
    }
}

public struct WikiCompareTool: Tool {
    public let name = "wiki_compare"
    public let parallelSafe = true
    public let toolDescription = "Compare a subject against cited Memory Wiki prior art using lexical evidence. Local only; no cloud spend."
    public let jsonSchema = """
    {"type":"object","required":["subject"],"properties":{
      "subject":{"type":"string"},
      "item":{"type":"string"},
      "baseline_query":{"type":"string"},
      "against":{"type":"string"},
      "dimensions":{"type":"array","items":{"type":"string"}},
      "k":{"type":"integer","minimum":1,"maximum":30,"default":12},
      "include_compiled":{"type":"boolean","default":false}}}
    """
    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable {
            var subject: String?
            var item: String?
            var baseline_query: String?
            var against: String?
            var dimensions: [String]?
            var k: Int?
            var include_compiled: Bool?
        }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        let subject = firstNonEmpty(args.subject, args.item)
        guard !subject.isEmpty,
              let k = MCPJSON.boundedInt(args.k, defaultValue: 12, min: 1, max: 30) else {
            return ToolResult(callId: call.callId,
                              output: "invalid wiki_compare arguments",
                              success: false, truncated: false)
        }
        let query = joinedQuery([subject, args.baseline_query, args.against] + (args.dimensions ?? []))
        let evidence = try await lexicalEvidence(store: store,
                                                 query: query,
                                                 k: k,
                                                 includeCompiled: args.include_compiled ?? false)
        let status = statusForEvidence(evidence)
        let payload = WikiComparePayload(
            status: status,
            subject: subject,
            baseline_query: args.baseline_query ?? args.against,
            summary: status == .insufficientEvidence
                ? "Insufficient cited prior-art evidence for comparison."
                : "Comparison grounded in \(evidence.count) lexical prior-art citations.",
            prior_art: status == .ok ? citedPoints(evidence, prefix: "Prior art") : [],
            likely_new_or_interesting: status == .ok ? interestingSignals(subject: subject, evidence: evidence) : [],
            risks_or_regressions: status == .ok ? riskSignals(evidence) : [],
            citations: evidence,
            confidence: confidence(evidence),
            novelty_rationale: status == .ok ? noveltyRationale(evidence) : [],
            what_would_change_my_mind: changeMyMind(topic: subject, evidence: evidence),
            limitations: limitations(evidence),
            uncited_claims: [],
            retrieval: .lexical)
        return ToolResult(callId: call.callId, output: MCPJSON.encode(payload),
                          success: true, truncated: false)
    }
}

public struct WikiAngleTool: Tool {
    public let name = "wiki_angle"
    public let parallelSafe = true
    public let toolDescription = "Generate cited blog, video, product, or market angles from Memory Wiki lexical evidence. Local only; no cloud spend."
    public let jsonSchema = """
    {"type":"object","required":["topic"],"properties":{
      "topic":{"type":"string"},
      "audience":{"type":"string","enum":["builder","devrel","product","executive","editor"]},
      "format":{"type":"string","enum":["blog","video","product","market","any"],"default":"any"},
      "angle_count":{"type":"integer","minimum":1,"maximum":8,"default":4},
      "k":{"type":"integer","minimum":1,"maximum":30,"default":12},
      "include_compiled":{"type":"boolean","default":false}}}
    """
    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable {
            var topic: String
            var audience: String?
            var format: String?
            var angle_count: Int?
            var k: Int?
            var include_compiled: Bool?
        }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        guard let k = MCPJSON.boundedInt(args.k, defaultValue: 12, min: 1, max: 30),
              let angleCount = MCPJSON.boundedInt(args.angle_count, defaultValue: 4, min: 1, max: 8) else {
            return ToolResult(callId: call.callId,
                              output: "invalid wiki_angle arguments",
                              success: false, truncated: false)
        }
        let evidence = try await lexicalEvidence(store: store,
                                                 query: args.topic,
                                                 k: k,
                                                 includeCompiled: args.include_compiled ?? false)
        let status = statusForEvidence(evidence)
        let angles = status == .ok
            ? makeAngles(topic: args.topic,
                         audience: args.audience,
                         format: args.format ?? "any",
                         count: angleCount,
                         evidence: evidence)
            : []
        let payload = WikiAnglePayload(
            status: status,
            topic: args.topic,
            audience: args.audience,
            format: args.format ?? "any",
            angles: angles,
            citations: evidence,
            confidence: confidence(evidence),
            novelty_rationale: status == .ok ? noveltyRationale(evidence) : [],
            what_would_change_my_mind: changeMyMind(topic: args.topic, evidence: evidence),
            limitations: limitations(evidence),
            uncited_claims: [],
            retrieval: .lexical)
        return ToolResult(callId: call.callId, output: MCPJSON.encode(payload),
                          success: true, truncated: false)
    }
}

public struct WikiPMFitTool: Tool {
    public let name = "wiki_pmfit"
    public let parallelSafe = true
    public let toolDescription = "Analyze product-market-fit from cited Memory Wiki lexical evidence. Local only; no cloud spend."
    public let jsonSchema = """
    {"type":"object","required":["product_idea"],"properties":{
      "product_idea":{"type":"string"},
      "idea":{"type":"string"},
      "market":{"type":"string"},
      "target_user":{"type":"string"},
      "persona":{"type":"string"},
      "k":{"type":"integer","minimum":1,"maximum":30,"default":12},
      "include_compiled":{"type":"boolean","default":false}}}
    """
    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable {
            var product_idea: String?
            var idea: String?
            var market: String?
            var target_user: String?
            var persona: String?
            var k: Int?
            var include_compiled: Bool?
        }
        guard let args = MCPJSON.decode(call.argumentsJSON, as: Args.self) else {
            return ToolResult(callId: call.callId, output: "bad arguments",
                              success: false, truncated: false)
        }
        let idea = firstNonEmpty(args.product_idea, args.idea)
        guard !idea.isEmpty,
              let k = MCPJSON.boundedInt(args.k, defaultValue: 12, min: 1, max: 30) else {
            return ToolResult(callId: call.callId,
                              output: "invalid wiki_pmfit arguments",
                              success: false, truncated: false)
        }
        let query = joinedQuery([idea, args.market, args.target_user, args.persona])
        let evidence = try await lexicalEvidence(store: store,
                                                 query: query,
                                                 k: k,
                                                 includeCompiled: args.include_compiled ?? false)
        let status = statusForEvidence(evidence)
        let payload = WikiPMFitPayload(
            status: status,
            product_idea: idea,
            market: args.market,
            target_user: args.target_user ?? args.persona,
            verdict: status == .insufficientEvidence
                ? "insufficient_evidence"
                : "evidence_needed_before_commitment",
            evidence_for: status == .ok
                ? citedPoints(Array(evidence.prefix(max(1, evidence.count / 2))), prefix: "Supports")
                : [],
            evidence_against_or_risks: status == .ok ? riskSignals(evidence) : [],
            adoption_hypotheses: status == .ok ? adoptionHypotheses(idea: idea, evidence: evidence) : [],
            citations: evidence,
            confidence: confidence(evidence),
            novelty_rationale: status == .ok ? noveltyRationale(evidence) : [],
            what_would_change_my_mind: changeMyMind(topic: idea, evidence: evidence),
            limitations: limitations(evidence),
            uncited_claims: [],
            retrieval: .lexical)
        return ToolResult(callId: call.callId, output: MCPJSON.encode(payload),
                          success: true, truncated: false)
    }
}

private enum WikiProductionStatus: String, Encodable {
    case ok
    case insufficientEvidence = "insufficient_evidence"
}

private struct WikiRetrievalInfo: Encodable, Equatable {
    var mode: String
    var cloud_spend_usd: Double

    static let lexical = WikiRetrievalInfo(mode: "lexical", cloud_spend_usd: 0)
}

private struct WikiCitation: Encodable, Equatable {
    var id: String
    var chunk_id: Int64
    var doc_uri: String
    var source_kind: String
    var score: Double
    var snippet: String
}

private struct CitedPoint: Encodable, Equatable {
    var text: String
    var citation_ids: [String]
}

private struct WikiBriefPayload: Encodable {
    var status: WikiProductionStatus
    var topic: String
    var audience: String?
    var summary: String
    var key_points: [CitedPoint]
    var citations: [WikiCitation]
    var confidence: String
    var novelty_rationale: [CitedPoint]
    var what_would_change_my_mind: [String]
    var limitations: [String]
    var uncited_claims: [String]
    var retrieval: WikiRetrievalInfo
}

private struct WikiComparePayload: Encodable {
    var status: WikiProductionStatus
    var subject: String
    var baseline_query: String?
    var summary: String
    var prior_art: [CitedPoint]
    var likely_new_or_interesting: [CitedPoint]
    var risks_or_regressions: [CitedPoint]
    var citations: [WikiCitation]
    var confidence: String
    var novelty_rationale: [CitedPoint]
    var what_would_change_my_mind: [String]
    var limitations: [String]
    var uncited_claims: [String]
    var retrieval: WikiRetrievalInfo
}

private struct WikiAnglePayload: Encodable {
    var status: WikiProductionStatus
    var topic: String
    var audience: String?
    var format: String
    var angles: [WikiAngle]
    var citations: [WikiCitation]
    var confidence: String
    var novelty_rationale: [CitedPoint]
    var what_would_change_my_mind: [String]
    var limitations: [String]
    var uncited_claims: [String]
    var retrieval: WikiRetrievalInfo
}

private struct WikiAngle: Encodable, Equatable {
    var title: String
    var rationale: String
    var citation_ids: [String]
}

private struct WikiPMFitPayload: Encodable {
    var status: WikiProductionStatus
    var product_idea: String
    var market: String?
    var target_user: String?
    var verdict: String
    var evidence_for: [CitedPoint]
    var evidence_against_or_risks: [CitedPoint]
    var adoption_hypotheses: [CitedPoint]
    var citations: [WikiCitation]
    var confidence: String
    var novelty_rationale: [CitedPoint]
    var what_would_change_my_mind: [String]
    var limitations: [String]
    var uncited_claims: [String]
    var retrieval: WikiRetrievalInfo
}

private func lexicalEvidence(store: MemoryStore,
                             query: String,
                             k: Int,
                             includeCompiled: Bool) async throws -> [WikiCitation] {
    let trimmed = boundedQuery(query)
    guard !trimmed.isEmpty else { return [] }
    let outputLimit = min(max(k, 1), 30)
    let fetchLimit = min(outputLimit * 3, 90)
    let lexical = try await store.searchLexical(trimmed, k: fetchLimit)
    var seenChunks = Set<Int64>()
    var citations: [WikiCitation] = []
    for hit in lexical {
        guard seenChunks.insert(hit.chunkId).inserted else { continue }
        guard let evidence = try await store.chunkEvidence(id: hit.chunkId),
              let document = evidence.document else { continue }
        if !includeCompiled, document.sourceURI.hasPrefix("wiki://compiled/") {
            continue
        }
        citations.append(WikiCitation(
            id: "c\(citations.count + 1)",
            chunk_id: hit.chunkId,
            doc_uri: document.sourceURI,
            source_kind: document.source.rawValue,
            score: hit.score,
            snippet: cleanSnippet(evidence.chunk.text)))
        if citations.count >= outputLimit { break }
    }
    return citations
}

private func statusForEvidence(_ evidence: [WikiCitation]) -> WikiProductionStatus {
    evidence.count >= 2 ? .ok : .insufficientEvidence
}

private func citedPoints(_ evidence: [WikiCitation], prefix: String) -> [CitedPoint] {
    evidence.prefix(6).map {
        CitedPoint(text: "\(prefix): \($0.snippet)", citation_ids: [$0.id])
    }
}

private func interestingSignals(subject: String, evidence: [WikiCitation]) -> [CitedPoint] {
    let subjectTerms = Set(tokens(subject))
    return evidence.prefix(5).map { citation in
        let overlap = subjectTerms.intersection(tokens(citation.snippet)).sorted().prefix(5)
        let terms = overlap.isEmpty ? "retrieved baseline evidence" : overlap.joined(separator: ", ")
        return CitedPoint(text: "Potentially interesting where the subject touches \(terms).",
                          citation_ids: [citation.id])
    }
}

private func riskSignals(_ evidence: [WikiCitation]) -> [CitedPoint] {
    let riskWords: Set<String> = [
        "risk", "problem", "challenge", "limitation", "cost", "slow",
        "latency", "privacy", "security", "adoption", "migration",
    ]
    let flagged = evidence.filter { !riskWords.intersection(tokens($0.snippet)).isEmpty }
    let selected = flagged.isEmpty ? Array(evidence.prefix(3)) : Array(flagged.prefix(5))
    return selected.map {
        CitedPoint(text: "Risk or caveat to inspect: \($0.snippet)",
                   citation_ids: [$0.id])
    }
}

private func makeAngles(topic: String,
                        audience: String?,
                        format: String,
                        count: Int,
                        evidence: [WikiCitation]) -> [WikiAngle] {
    let clamped = min(max(count, 1), 8)
    let label = [audience, format == "any" ? nil : format].compactMap { $0 }.joined(separator: " ")
    return evidence.prefix(clamped).enumerated().map { index, citation in
        let title = label.isEmpty
            ? "\(topic): evidence angle \(index + 1)"
            : "\(topic): \(label) angle \(index + 1)"
        return WikiAngle(title: title,
                         rationale: citation.snippet,
                         citation_ids: [citation.id])
    }
}

private func adoptionHypotheses(idea: String, evidence: [WikiCitation]) -> [CitedPoint] {
    evidence.prefix(4).map {
        CitedPoint(
            text: "Hypothesis for \(idea): adoption depends on the need or behavior evidenced here: \($0.snippet)",
            citation_ids: [$0.id])
    }
}

private func noveltyRationale(_ evidence: [WikiCitation]) -> [CitedPoint] {
    evidence.prefix(4).map {
        CitedPoint(text: "Treat as interesting only relative to this retrieved baseline: \($0.snippet)",
                   citation_ids: [$0.id])
    }
}

private func changeMyMind(topic: String, evidence: [WikiCitation]) -> [String] {
    if evidence.isEmpty {
        return [
            "Import or cite primary sources directly about \(topic).",
            "Add release notes, repository evidence, user signals, or dated market analysis.",
        ]
    }
    return [
        "More recent primary sources that contradict the retrieved citations.",
        "Evidence that the retrieved examples are not representative of \(topic).",
        "User, adoption, revenue, or retention data tied to the same audience.",
    ]
}

private func limitations(_ evidence: [WikiCitation]) -> [String] {
    var out = [
        "Retrieval mode is lexical-only to guarantee zero hidden embedding or model spend.",
        "Outputs are extractive/templates over retrieved chunks, not LLM synthesis.",
        "Durable claim records are not implemented yet; graph-edge claim pages are secondary evidence.",
    ]
    if evidence.count < 2 {
        out.append("Fewer than two usable citations were retrieved, so creative analysis is withheld.")
    }
    return out
}

private func confidence(_ evidence: [WikiCitation]) -> String {
    if evidence.count >= 8 { return "medium" }
    if evidence.count >= 2 { return "low" }
    return "none"
}

private func firstNonEmpty(_ preferred: String?, _ fallback: String?) -> String {
    for value in [preferred, fallback] {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    return ""
}

private func joinedQuery(_ parts: [String?]) -> String {
    parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

private func boundedQuery(_ query: String) -> String {
    let clean = query
        .filter { !$0.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        } }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.count <= 512 { return clean }
    let end = clean.index(clean.startIndex, offsetBy: 512)
    return String(clean[..<end])
}

private func cleanSnippet(_ snippet: String) -> String {
    let singleLine = snippet
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if singleLine.count <= 240 { return singleLine }
    let end = singleLine.index(singleLine.startIndex, offsetBy: 240)
    return String(singleLine[..<end]) + "..."
}

private func tokens(_ text: String) -> Set<String> {
    let scalars = text.lowercased().unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
    }
    return Set(String(scalars)
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
        .filter { $0.count >= 4 })
}
