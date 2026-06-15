import Foundation

// Refresh (§5.C/§5.D) support — select sources due for re-verification by volatility
// half-life over `source_meta.verified_at`, and stamp a successful re-verify. Pure
// store access; the network re-fetch + change detection lives in the codex-memory
// WikiRefresh runner.
extension MemoryStore {
    /// A source eligible for the refresh pass: its document + provenance, joined.
    public struct RefreshCandidate: Sendable, Equatable {
        public var documentID: Int64
        public var sourceURI: String
        public var canonicalURL: String?
        public var sourceKind: String     // source_meta.source_kind (rawType): articles|papers|repos|notes|data
        public var volatility: Volatility
        public var verifiedAt: Int64?
        public var contentSHA: Data
        public init(documentID: Int64, sourceURI: String, canonicalURL: String?, sourceKind: String,
                    volatility: Volatility, verifiedAt: Int64?, contentSHA: Data) {
            self.documentID = documentID; self.sourceURI = sourceURI
            self.canonicalURL = canonicalURL; self.sourceKind = sourceKind; self.volatility = volatility
            self.verifiedAt = verifiedAt; self.contentSHA = contentSHA
        }
    }

    /// Every document that carries provenance (`source_meta`), with the fields the
    /// refresh pass needs. The due-selection (staleness by volatility half-life) and
    /// the source-kind filter (only readability-comparable kinds re-fetch correctly)
    /// are applied by the caller.
    public func refreshCandidates() throws -> [RefreshCandidate] {
        try run("""
        SELECT d.id AS id, d.source_uri AS source_uri, d.content_sha AS content_sha,
               sm.canonical_url AS canonical_url, sm.source_kind AS source_kind,
               sm.volatility AS volatility, sm.verified_at AS verified_at
        FROM document d JOIN source_meta sm ON sm.document_id = d.id
        ORDER BY d.id;
        """, []).map { r in
            RefreshCandidate(
                documentID: (r["id"] as? Int64) ?? 0,
                sourceURI: (r["source_uri"] as? String) ?? "",
                canonicalURL: r["canonical_url"] as? String,
                sourceKind: (r["source_kind"] as? String) ?? "",
                volatility: Volatility(rawValue: (r["volatility"] as? String) ?? "warm") ?? .warm,
                verifiedAt: r["verified_at"] as? Int64,
                contentSHA: (r["content_sha"] as? Data) ?? Data())
        }
    }

    /// Stamp a source as re-verified at `ts` (only after a successful, UNCHANGED
    /// re-fetch — a changed source is left unverified so it surfaces as out-of-date).
    public func markSourceVerified(documentID: Int64, at ts: Int64) throws {
        try run("UPDATE source_meta SET verified_at=? WHERE document_id=?;", [.int(ts), .int(documentID)])
    }

    /// Mark every claim evidenced by `documentID` as changed at `ts` by bumping its
    /// `updated_at`. Used by the refresh pass when a source's upstream SHA changed:
    /// pushing the dependent claims' `updated_at` past their syntheses' `generated_at`
    /// makes `auditDriftScan` flag those compiled pages as `.drifted` (§5.D Pass 2) —
    /// the precise drift trigger. Does NOT touch `last_reviewed` (the claim was not
    /// re-reviewed, only its source moved) nor `verified_at`. Returns rows bumped.
    @discardableResult
    public func touchClaimsForChangedSource(documentID: Int64, at ts: Int64) throws -> Int {
        let rows = try run("""
        UPDATE claim SET updated_at=?
         WHERE id IN (SELECT DISTINCT claim_id FROM claim_evidence WHERE document_id=?)
        RETURNING id;
        """, [.int(ts), .int(documentID)])
        return rows.count
    }
}
