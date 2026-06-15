import Foundation

// Same-actor CRUD for the additive Memory-Wiki knowledge model (the §4 canonical
// schema). Lives in a separate file so the ~1.3k-line core actor doesn't grow,
// while preserving the single-writer/WAL atomicity that makes claim+chunk writes
// transactional (a second actor would break that). All methods are actor-isolated
// on `MemoryStore` and reuse its internal `run`/`execRaw`/`Bind` helpers.

extension MemoryStore {

    // MARK: - source provenance/trust overlay

    public func upsertSourceMeta(_ m: SourceMetaRow) throws {
        try run("""
        INSERT INTO source_meta(document_id,source_kind,trust_tier,credibility,confidence,
                                volatility,verified_at,ingested_at,author,published_at,license,
                                canonical_url,bias_flags,collection,adapter,upstream_id,revision,
                                blob_sha,compiled_from,frontmatter)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(document_id) DO UPDATE SET
          source_kind=excluded.source_kind, trust_tier=excluded.trust_tier,
          credibility=excluded.credibility, confidence=excluded.confidence,
          volatility=excluded.volatility, verified_at=excluded.verified_at,
          author=COALESCE(excluded.author,source_meta.author),
          published_at=COALESCE(excluded.published_at,source_meta.published_at),
          license=COALESCE(excluded.license,source_meta.license),
          canonical_url=COALESCE(excluded.canonical_url,source_meta.canonical_url),
          bias_flags=excluded.bias_flags, collection=COALESCE(excluded.collection,source_meta.collection),
          adapter=COALESCE(excluded.adapter,source_meta.adapter),
          upstream_id=COALESCE(excluded.upstream_id,source_meta.upstream_id),
          revision=COALESCE(excluded.revision,source_meta.revision),
          blob_sha=COALESCE(excluded.blob_sha,source_meta.blob_sha),
          compiled_from=excluded.compiled_from,
          frontmatter=COALESCE(excluded.frontmatter,source_meta.frontmatter);
        """, [
            .int(m.documentID), .text(m.sourceKind), .text(m.trustTier.rawValue),
            .int(Int64(m.credibility)), m.confidence.map(Bind.text) ?? .null,
            .text(m.volatility.rawValue), m.verifiedAt.map(Bind.int) ?? .null, .int(m.ingestedAt),
            m.author.map(Bind.text) ?? .null, m.publishedAt.map(Bind.int) ?? .null,
            m.license.map(Bind.text) ?? .null, m.canonicalURL.map(Bind.text) ?? .null,
            m.biasFlags.map(Bind.text) ?? .null, m.collection.map(Bind.text) ?? .null,
            m.adapter.map(Bind.text) ?? .null, m.upstreamID.map(Bind.text) ?? .null,
            m.revision.map(Bind.text) ?? .null, m.blobSHA.map(Bind.text) ?? .null,
            .text(m.compiledFrom.rawValue), m.frontmatter.map(Bind.text) ?? .null,
        ])
    }

    public func sourceMeta(documentID: Int64) throws -> SourceMetaRow? {
        try run("SELECT * FROM source_meta WHERE document_id=?;", [.int(documentID)]).first.map(wikiParseSourceMeta)
    }

    // MARK: - claims

    /// Insert or refresh a claim, deduped by `canonical_sha`. Returns the row id.
    /// On conflict the original `first_seen` is preserved; status/confidence/
    /// volatility/last_reviewed/updated_at are refreshed — so re-compiling the
    /// same source produces zero duplicate claims (idempotent recompile).
    @discardableResult
    public func upsertClaim(_ c: ClaimRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO claim(text,canonical_sha,status,confidence,volatility,category,scope,
                          first_seen,last_reviewed,updated_at,compiled_from,edge_id)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(canonical_sha) DO UPDATE SET
          text=excluded.text, status=excluded.status, confidence=excluded.confidence,
          volatility=excluded.volatility,
          category=COALESCE(excluded.category,claim.category),
          scope=COALESCE(excluded.scope,claim.scope),
          last_reviewed=excluded.last_reviewed, updated_at=excluded.updated_at,
          compiled_from=excluded.compiled_from,
          edge_id=COALESCE(excluded.edge_id,claim.edge_id)
        RETURNING id;
        """, [
            .text(c.text), .blob(c.canonicalSHA), .text(c.status.rawValue), .real(c.confidence),
            .text(c.volatility.rawValue), c.category.map(Bind.text) ?? .null,
            c.scope.map(Bind.text) ?? .null, .int(c.firstSeen),
            c.lastReviewed.map(Bind.int) ?? .null, .int(c.updatedAt),
            .text(c.compiledFrom.rawValue), c.edgeID.map(Bind.int) ?? .null,
        ])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func claim(id: Int64) throws -> ClaimRow? {
        try run("SELECT * FROM claim WHERE id=?;", [.int(id)]).first.map(wikiParseClaim)
    }

    public func claim(canonicalSHA: Data) throws -> ClaimRow? {
        try run("SELECT * FROM claim WHERE canonical_sha=?;", [.blob(canonicalSHA)]).first.map(wikiParseClaim)
    }

    public func claimsByStatus(_ status: ClaimStatus, limit: Int = 10_000) throws -> [ClaimRow] {
        try run("SELECT * FROM claim WHERE status=? ORDER BY updated_at DESC LIMIT ?;",
                [.text(status.rawValue), .int(Int64(limit))]).map(wikiParseClaim)
    }

    public func claimsForDocument(_ documentID: Int64) throws -> [ClaimRow] {
        try run("""
        SELECT DISTINCT c.* FROM claim c
          JOIN claim_evidence e ON e.claim_id=c.id
         WHERE e.document_id=?
         ORDER BY c.id;
        """, [.int(documentID)]).map(wikiParseClaim)
    }

    /// Active claims that have decayed below `threshold` freshness for their
    /// volatility (pure `WikiFreshness` math, evaluated in Swift over the rows).
    public func staleClaims(now: Int64, threshold: Double = 0.5, limit: Int = 10_000) throws -> [ClaimRow] {
        let active = try run("SELECT * FROM claim WHERE status=? LIMIT ?;",
                             [.text(ClaimStatus.active.rawValue), .int(Int64(limit))]).map(wikiParseClaim)
        return active.filter {
            WikiFreshness.isStale(lastReviewed: $0.lastReviewed, now: now,
                                  volatility: $0.volatility, threshold: threshold)
        }
    }

    public func setClaimStatus(_ id: Int64, _ status: ClaimStatus, updatedAt: Int64) throws {
        try run("UPDATE claim SET status=?, updated_at=? WHERE id=?;",
                [.text(status.rawValue), .int(updatedAt), .int(id)])
    }

    public func markClaimReviewed(_ id: Int64, at ts: Int64) throws {
        try run("UPDATE claim SET last_reviewed=?, updated_at=? WHERE id=?;", [.int(ts), .int(ts), .int(id)])
    }

    // MARK: - evidence

    /// Attach evidence idempotently — re-attaching the same (claim, document,
    /// chunk) triple is a no-op (the expression-unique index dedupes, NULL chunk
    /// included).
    public func attachEvidence(_ e: ClaimEvidenceRow) throws {
        try run("""
        INSERT OR IGNORE INTO claim_evidence(claim_id,document_id,chunk_id,stance,relevance,strength,span_start,span_end)
        VALUES(?,?,?,?,?,?,?,?);
        """, [
            .int(e.claimID), .int(e.documentID), e.chunkID.map(Bind.int) ?? .null,
            .text(e.stance.rawValue), e.relevance.map { Bind.text($0.rawValue) } ?? .null,
            .int(Int64(e.strength)), e.spanStart.map { Bind.int(Int64($0)) } ?? .null,
            e.spanEnd.map { Bind.int(Int64($0)) } ?? .null,
        ])
    }

    public func evidence(forClaim claimID: Int64) throws -> [ClaimEvidenceRow] {
        try run("SELECT * FROM claim_evidence WHERE claim_id=? ORDER BY id;", [.int(claimID)]).map(wikiParseEvidence)
    }

    // MARK: - contradictions

    public func markContradiction(claim claimID: Int64, contradicts otherID: Int64, at ts: Int64) throws {
        try run("INSERT OR IGNORE INTO claim_contradiction(claim_id,contradicts,detected_at) VALUES(?,?,?);",
                [.int(claimID), .int(otherID), .int(ts)])
    }

    /// Claims that contradict `claimID`, in either stored direction.
    public func contradictingClaims(of claimID: Int64) throws -> [ClaimRow] {
        try run("""
        SELECT DISTINCT c.* FROM claim c
         WHERE c.id IN (SELECT contradicts FROM claim_contradiction WHERE claim_id=?)
            OR c.id IN (SELECT claim_id   FROM claim_contradiction WHERE contradicts=?)
         ORDER BY c.id;
        """, [.int(claimID), .int(claimID)]).map(wikiParseClaim)
    }

    // MARK: - synthesis

    @discardableResult
    public func upsertSynthesis(_ s: SynthesisRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO synthesis(slug,category,title,body_path,confidence,volatility,verified_at,
                              created_at,updated_at,human_block_sha,thesis_status,verdict,core_claim,
                              key_variables,falsification,evidence_for,evidence_against,format,generated_at,output_type)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(slug) DO UPDATE SET
          category=excluded.category, title=excluded.title, body_path=excluded.body_path,
          confidence=excluded.confidence, volatility=excluded.volatility,
          verified_at=excluded.verified_at, updated_at=excluded.updated_at,
          human_block_sha=excluded.human_block_sha, thesis_status=excluded.thesis_status,
          verdict=excluded.verdict, core_claim=excluded.core_claim, key_variables=excluded.key_variables,
          falsification=excluded.falsification, evidence_for=excluded.evidence_for,
          evidence_against=excluded.evidence_against, format=excluded.format,
          generated_at=excluded.generated_at, output_type=excluded.output_type
        RETURNING id;
        """, [
            .text(s.slug), .text(s.category), .text(s.title), .text(s.bodyPath),
            s.confidence.map(Bind.text) ?? .null, .text(s.volatility.rawValue),
            s.verifiedAt.map(Bind.int) ?? .null, .int(s.createdAt), .int(s.updatedAt),
            s.humanBlockSHA.map(Bind.blob) ?? .null, s.thesisStatus.map(Bind.text) ?? .null,
            s.verdict.map(Bind.text) ?? .null, s.coreClaim.map(Bind.text) ?? .null,
            s.keyVariables.map(Bind.text) ?? .null, s.falsification.map(Bind.text) ?? .null,
            .int(Int64(s.evidenceFor)), .int(Int64(s.evidenceAgainst)),
            s.format.map(Bind.text) ?? .null, s.generatedAt.map(Bind.int) ?? .null,
            s.outputType.map(Bind.text) ?? .null,
        ])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func synthesis(id: Int64) throws -> SynthesisRow? {
        try run("SELECT * FROM synthesis WHERE id=?;", [.int(id)]).first.map(wikiParseSynthesis)
    }

    public func synthesis(slug: String) throws -> SynthesisRow? {
        try run("SELECT * FROM synthesis WHERE slug=?;", [.text(slug)]).first.map(wikiParseSynthesis)
    }

    public func syntheses(category: String? = nil, limit: Int = 10_000) throws -> [SynthesisRow] {
        if let category {
            return try run("SELECT * FROM synthesis WHERE category=? ORDER BY updated_at DESC LIMIT ?;",
                           [.text(category), .int(Int64(limit))]).map(wikiParseSynthesis)
        }
        return try run("SELECT * FROM synthesis ORDER BY updated_at DESC LIMIT ?;",
                       [.int(Int64(limit))]).map(wikiParseSynthesis)
    }

    public func linkSynthesisClaim(synthesis synthesisID: Int64, claim claimID: Int64) throws {
        try run("INSERT OR IGNORE INTO synthesis_claim(synthesis_id,claim_id) VALUES(?,?);",
                [.int(synthesisID), .int(claimID)])
    }

    public func claimsForSynthesis(_ synthesisID: Int64) throws -> [ClaimRow] {
        try run("""
        SELECT c.* FROM claim c
          JOIN synthesis_claim sc ON sc.claim_id=c.id
         WHERE sc.synthesis_id=? ORDER BY c.id;
        """, [.int(synthesisID)]).map(wikiParseClaim)
    }

    // MARK: - research-session provenance (query cache mirroring the wiki-root files)

    public func upsertResearchSession(_ r: ResearchSessionRow) throws {
        try run("""
        INSERT INTO research_session(session_id,command,mode,topic,start_time,min_time_budget,
                                     current_round,cumulative_sources,cumulative_articles,status,
                                     last_progress_score,paths_json)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
          command=excluded.command, mode=excluded.mode, topic=excluded.topic,
          min_time_budget=excluded.min_time_budget, current_round=excluded.current_round,
          cumulative_sources=excluded.cumulative_sources, cumulative_articles=excluded.cumulative_articles,
          status=excluded.status, last_progress_score=excluded.last_progress_score, paths_json=excluded.paths_json;
        """, [
            .text(r.sessionID), r.command.map(Bind.text) ?? .null, r.mode.map(Bind.text) ?? .null,
            r.topic.map(Bind.text) ?? .null, r.startTime.map(Bind.int) ?? .null,
            r.minTimeBudget.map(Bind.int) ?? .null, r.currentRound.map { Bind.int(Int64($0)) } ?? .null,
            r.cumulativeSources.map { Bind.int(Int64($0)) } ?? .null,
            r.cumulativeArticles.map { Bind.int(Int64($0)) } ?? .null, r.status.map(Bind.text) ?? .null,
            r.lastProgressScore.map(Bind.real) ?? .null, r.pathsJSON.map(Bind.text) ?? .null,
        ])
    }

    public func researchSession(id sessionID: String) throws -> ResearchSessionRow? {
        try run("SELECT * FROM research_session WHERE session_id=?;", [.text(sessionID)]).first.map(wikiParseResearchSession)
    }

    public func researchSessions(limit: Int = 100) throws -> [ResearchSessionRow] {
        try run("SELECT * FROM research_session ORDER BY start_time DESC LIMIT ?;",
                [.int(Int64(limit))]).map(wikiParseResearchSession)
    }

    @discardableResult
    public func appendSessionEvent(_ e: SessionEventRow) throws -> Int64 {
        let rows = try run("""
        INSERT INTO session_event(session_id,ts,command,phase,event,round,sources_ingested,
                                  articles_compiled,progress_score,artifacts_json,notes)
        VALUES(?,?,?,?,?,?,?,?,?,?,?) RETURNING id;
        """, [
            .text(e.sessionID), .int(e.ts), e.command.map(Bind.text) ?? .null,
            e.phase.map(Bind.text) ?? .null, .text(e.event), e.round.map { Bind.int(Int64($0)) } ?? .null,
            e.sourcesIngested.map { Bind.int(Int64($0)) } ?? .null,
            e.articlesCompiled.map { Bind.int(Int64($0)) } ?? .null,
            e.progressScore.map(Bind.real) ?? .null, e.artifactsJSON.map(Bind.text) ?? .null,
            e.notes.map(Bind.text) ?? .null,
        ])
        return (rows.first?["id"] as? Int64) ?? 0
    }

    public func sessionEvents(sessionID: String) throws -> [SessionEventRow] {
        try run("SELECT * FROM session_event WHERE session_id=? ORDER BY ts, id;", [.text(sessionID)]).map(wikiParseSessionEvent)
    }

    public func writeCheckpoint(sessionID: String, status: String, summary: String, updatedAt: Int64) throws {
        try run("""
        INSERT INTO session_checkpoint(session_id,updated_at,status,summary) VALUES(?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET updated_at=excluded.updated_at,status=excluded.status,summary=excluded.summary;
        """, [.text(sessionID), .int(updatedAt), .text(status), .text(summary)])
    }

    public func checkpoint(sessionID: String) throws -> SessionCheckpointRow? {
        try run("SELECT * FROM session_checkpoint WHERE session_id=?;", [.text(sessionID)]).first.map(wikiParseCheckpoint)
    }

    /// Audit provenance classification: durable events ⇒ replayable; only a
    /// checkpoint ⇒ partial; neither ⇒ missing.
    public func sessionProvenanceState(sessionID: String) throws -> WikiProvenanceState {
        let events = try run("SELECT COUNT(*) AS n FROM session_event WHERE session_id=?;", [.text(sessionID)])
        if let n = events.first?["n"] as? Int64, n > 0 { return .replayable }
        let cp = try run("SELECT 1 FROM session_checkpoint WHERE session_id=? LIMIT 1;", [.text(sessionID)])
        return cp.isEmpty ? .missing : .partial
    }

    // MARK: - meta (compile cutoff etc.)

    public func metaValue(_ key: String) throws -> String? {
        try run("SELECT value FROM meta WHERE key=?;", [.text(key)]).first?["value"] as? String
    }

    public func setMetaValue(_ key: String, _ value: String) throws {
        try run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                [.text(key), .text(value)])
    }

    /// Prefix scan over the durable `meta` queue. Returns every (key,value) whose key
    /// begins with `prefix`, ordered by key. The maintenance/dream cycle writes review
    /// markers here (`synthesis_review:<id>`, `librarian_tier2:<id>`); this is the READER
    /// the audit found missing — consuming the cycle's committed transitions instead of
    /// recomputing the scanners live. The prefix is escaped (`%` `_` `\` → ESCAPE clause)
    /// so a caller-supplied prefix can never wildcard.
    public func metaEntries(prefix: String) throws -> [(key: String, value: String)] {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let rows = try run("SELECT key, value FROM meta WHERE key LIKE ? ESCAPE '\\' ORDER BY key;",
                           [.text(escaped + "%")])
        return rows.compactMap { r in
            guard let k = r["key"] as? String, let v = r["value"] as? String else { return nil }
            return (k, v)
        }
    }

    /// Count of durable `meta` keys with `prefix` (the cycle's review-marker queue size).
    public func metaCount(prefix: String) throws -> Int {
        try metaEntries(prefix: prefix).count
    }

    /// Incremental-compile cutoff (mirrors llm-wiki's "Last compiled"): only
    /// documents fetched after this stamp are recompiled by default.
    public func lastCompiledAt() throws -> Int64? {
        (try metaValue("last_compiled_at")).flatMap(Int64.init)
    }

    public func setLastCompiledAt(_ ts: Int64) throws {
        try setMetaValue("last_compiled_at", String(ts))
    }

    // MARK: - librarian Tier-1 scan

    /// Librarian Tier-1 scan over the compiled wiki pages (synthesis rows): pure
    /// DB data → LibrarianScorer (no model, no file I/O). `depthProxy` is bucketed
    /// from the page's cited-source count; the source-freshness / source-chain
    /// dimensions use the page's created/verified stamps as proxies. Returns the
    /// scores stalest-first — the review queue.
    public func librarianScan(now: Int64, tier2Threshold: Double = 50) throws -> [LibrarianPageScore] {
        let rows = try run("""
            SELECT s.id AS id, s.volatility AS volatility, s.verified_at AS verified_at,
                   s.created_at AS created_at, s.updated_at AS updated_at,
                   (SELECT COUNT(*) FROM synthesis_claim sc WHERE sc.synthesis_id = s.id) AS source_count
            FROM synthesis s;
            """, [])
        let signals: [LibrarianScorer.PageSignals] = rows.map { r in
            let vol = Volatility(rawValue: (r["volatility"] as? String) ?? "warm") ?? .warm
            let count = Int((r["source_count"] as? Int64) ?? 0)
            return LibrarianScorer.PageSignals(
                documentID: (r["id"] as? Int64) ?? 0, volatility: vol,
                sourceFetchedAt: r["created_at"] as? Int64, verifiedAt: r["verified_at"] as? Int64,
                compiledAt: r["updated_at"] as? Int64, sourceChainValidatedAt: r["verified_at"] as? Int64,
                sourceCount: count, avgCredibility: 0,
                depthProxy: Self.librarianDepthBucket(sourceCount: count), hasSeeAlso: false)
        }
        return LibrarianScorer.scan(signals, now: now, tier2Threshold: tier2Threshold)
    }

    // MARK: - audit drift scan (Pass 2)

    /// Audit output-drift over the compiled pages: a synthesis is drifted when a
    /// claim it was compiled from changed after the page was generated (§5.D Pass 2).
    /// Pure timestamps via AuditDriftDetector. Returns (synthesis id, status),
    /// drifted/indirect first.
    public func auditDriftScan() throws -> [(id: Int64, status: DriftStatus)] {
        let claimRows = try run("SELECT id, updated_at FROM claim;", [])
        let nodes = AuditDriftDetector.index(claimRows.map {
            AuditNode(id: ($0["id"] as? Int64) ?? 0, updatedAt: ($0["updated_at"] as? Int64) ?? 0)
        })
        var deps: [Int64: [Int64]] = [:]
        for r in try run("SELECT synthesis_id, claim_id FROM synthesis_claim;", []) {
            let sid = (r["synthesis_id"] as? Int64) ?? 0
            deps[sid, default: []].append((r["claim_id"] as? Int64) ?? 0)
        }
        let outputs = try run("SELECT id, generated_at, updated_at FROM synthesis;", []).map { r in
            AuditOutput(id: (r["id"] as? Int64) ?? 0,
                        generatedAt: (r["generated_at"] as? Int64) ?? (r["updated_at"] as? Int64) ?? 0,
                        dependsOn: deps[(r["id"] as? Int64) ?? 0] ?? [])
        }
        let result = AuditDriftDetector.scan(outputs: outputs, nodes: nodes)
        // drifted + indirectly-drifted first (the actionable set), then current.
        return outputs.map { ($0.id, result[$0.id] ?? .current) }
            .sorted { a, b in rank(a.status) < rank(b.status) }
    }
    private func rank(_ s: DriftStatus) -> Int {
        switch s { case .drifted: return 0; case .indirectlyDrifted: return 1; case .current: return 2 }
    }

    /// Depth proxy 1-5 from a page's cited-source count (thin → escalate).
    static func librarianDepthBucket(sourceCount: Int) -> Int {
        switch sourceCount {
        case 0:    return 1
        case 1:    return 2
        case 2...3: return 3
        case 4...6: return 4
        default:    return 5
        }
    }
}

// MARK: - row parsers (file-private; tolerate Int64-or-Double numerics)

private func wikiNum(_ row: [String: Any], _ k: String) -> Double? {
    if let d = row[k] as? Double { return d }
    if let i = row[k] as? Int64 { return Double(i) }
    return nil
}
private func wikiInt(_ row: [String: Any], _ k: String) -> Int64? {
    if let i = row[k] as? Int64 { return i }
    if let d = row[k] as? Double { return Int64(d) }
    return nil
}

private func wikiParseSourceMeta(_ r: [String: Any]) -> SourceMetaRow {
    SourceMetaRow(
        documentID: wikiInt(r, "document_id") ?? 0,
        sourceKind: (r["source_kind"] as? String) ?? "",
        trustTier: TrustTier(rawValue: (r["trust_tier"] as? String) ?? "") ?? .medium,
        credibility: Int(wikiInt(r, "credibility") ?? 0),
        confidence: r["confidence"] as? String,
        volatility: Volatility(rawValue: (r["volatility"] as? String) ?? "") ?? .warm,
        verifiedAt: wikiInt(r, "verified_at"), ingestedAt: wikiInt(r, "ingested_at") ?? 0,
        author: r["author"] as? String, publishedAt: wikiInt(r, "published_at"),
        license: r["license"] as? String, canonicalURL: r["canonical_url"] as? String,
        biasFlags: r["bias_flags"] as? String, collection: r["collection"] as? String,
        adapter: r["adapter"] as? String, upstreamID: r["upstream_id"] as? String,
        revision: r["revision"] as? String, blobSHA: r["blob_sha"] as? String,
        compiledFrom: CompiledFrom(rawValue: (r["compiled_from"] as? String) ?? "") ?? .sources,
        frontmatter: r["frontmatter"] as? String)
}

private func wikiParseClaim(_ r: [String: Any]) -> ClaimRow {
    ClaimRow(
        id: wikiInt(r, "id") ?? 0, text: (r["text"] as? String) ?? "",
        canonicalSHA: (r["canonical_sha"] as? Data) ?? Data(),
        status: ClaimStatus(rawValue: (r["status"] as? String) ?? "") ?? .draft,
        confidence: wikiNum(r, "confidence") ?? 0.5,
        volatility: Volatility(rawValue: (r["volatility"] as? String) ?? "") ?? .warm,
        category: r["category"] as? String, scope: r["scope"] as? String,
        firstSeen: wikiInt(r, "first_seen") ?? 0, lastReviewed: wikiInt(r, "last_reviewed"),
        updatedAt: wikiInt(r, "updated_at") ?? 0,
        compiledFrom: CompiledFrom(rawValue: (r["compiled_from"] as? String) ?? "") ?? .sources,
        edgeID: wikiInt(r, "edge_id"))
}

private func wikiParseEvidence(_ r: [String: Any]) -> ClaimEvidenceRow {
    ClaimEvidenceRow(
        id: wikiInt(r, "id") ?? 0, claimID: wikiInt(r, "claim_id") ?? 0,
        documentID: wikiInt(r, "document_id") ?? 0, chunkID: wikiInt(r, "chunk_id"),
        stance: EvidenceStance(rawValue: (r["stance"] as? String) ?? "") ?? .supports,
        relevance: (r["relevance"] as? String).flatMap(EvidenceRelevance.init(rawValue:)),
        strength: Int(wikiInt(r, "strength") ?? 2),
        spanStart: wikiInt(r, "span_start").map(Int.init), spanEnd: wikiInt(r, "span_end").map(Int.init))
}

private func wikiParseSynthesis(_ r: [String: Any]) -> SynthesisRow {
    SynthesisRow(
        id: wikiInt(r, "id") ?? 0, slug: (r["slug"] as? String) ?? "",
        category: (r["category"] as? String) ?? "", title: (r["title"] as? String) ?? "",
        bodyPath: (r["body_path"] as? String) ?? "", confidence: r["confidence"] as? String,
        volatility: Volatility(rawValue: (r["volatility"] as? String) ?? "") ?? .warm,
        verifiedAt: wikiInt(r, "verified_at"), createdAt: wikiInt(r, "created_at") ?? 0,
        updatedAt: wikiInt(r, "updated_at") ?? 0, humanBlockSHA: r["human_block_sha"] as? Data,
        thesisStatus: r["thesis_status"] as? String, verdict: r["verdict"] as? String,
        coreClaim: r["core_claim"] as? String, keyVariables: r["key_variables"] as? String,
        falsification: r["falsification"] as? String,
        evidenceFor: Int(wikiInt(r, "evidence_for") ?? 0), evidenceAgainst: Int(wikiInt(r, "evidence_against") ?? 0),
        format: r["format"] as? String, generatedAt: wikiInt(r, "generated_at"),
        outputType: r["output_type"] as? String)
}

private func wikiParseResearchSession(_ r: [String: Any]) -> ResearchSessionRow {
    ResearchSessionRow(
        sessionID: (r["session_id"] as? String) ?? "", command: r["command"] as? String,
        mode: r["mode"] as? String, topic: r["topic"] as? String, startTime: wikiInt(r, "start_time"),
        minTimeBudget: wikiInt(r, "min_time_budget"), currentRound: wikiInt(r, "current_round").map(Int.init),
        cumulativeSources: wikiInt(r, "cumulative_sources").map(Int.init),
        cumulativeArticles: wikiInt(r, "cumulative_articles").map(Int.init),
        status: r["status"] as? String, lastProgressScore: wikiNum(r, "last_progress_score"),
        pathsJSON: r["paths_json"] as? String)
}

private func wikiParseSessionEvent(_ r: [String: Any]) -> SessionEventRow {
    SessionEventRow(
        id: wikiInt(r, "id") ?? 0, sessionID: (r["session_id"] as? String) ?? "",
        ts: wikiInt(r, "ts") ?? 0, command: r["command"] as? String, phase: r["phase"] as? String,
        event: (r["event"] as? String) ?? "", round: wikiInt(r, "round").map(Int.init),
        sourcesIngested: wikiInt(r, "sources_ingested").map(Int.init),
        articlesCompiled: wikiInt(r, "articles_compiled").map(Int.init),
        progressScore: wikiNum(r, "progress_score"), artifactsJSON: r["artifacts_json"] as? String,
        notes: r["notes"] as? String)
}

private func wikiParseCheckpoint(_ r: [String: Any]) -> SessionCheckpointRow {
    SessionCheckpointRow(
        sessionID: (r["session_id"] as? String) ?? "", updatedAt: wikiInt(r, "updated_at") ?? 0,
        status: (r["status"] as? String) ?? "", summary: (r["summary"] as? String) ?? "")
}
