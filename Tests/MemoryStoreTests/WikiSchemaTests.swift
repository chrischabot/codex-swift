import XCTest
import Foundation
@testable import MemoryStore

/// Severe / adversarial coverage for the M0 Memory-Wiki knowledge model:
/// idempotent dedupe, FK cascade vs the manual document teardown, NULL-aware
/// evidence uniqueness, freshness decay, provenance classification, the
/// single-embedder stamp surviving wiki writes, and injection-resistant binds.
///
/// Note: awaited values are bound to `let` before asserting — XCTest's assert
/// autoclosures are non-async, so `XCTAssertEqual(try await x, y)` won't compile.
final class WikiSchemaTests: XCTestCase {
    private func tmpDB() -> String { NSTemporaryDirectory() + "codex-wiki-\(UUID().uuidString).db" }

    private func makeStore(dim: Int = 8, providerID: String? = nil) throws -> (MemoryStore, String) {
        let path = tmpDB()
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: dim,
                                                      embeddingProviderID: providerID))
        return (store, path)
    }

    @discardableResult
    private func addDoc(_ store: MemoryStore, uri: String, fetched: Int64 = 1) async throws -> Int64 {
        try await store.upsertDocument(DocumentRow(
            source: .web, sourceURI: uri, bodyPath: "rollout:\(uri)", fetchedAt: fetched,
            contentSHA: Data(repeating: 0x11, count: 32), rawBytes: 1))
    }

    // MARK: schema / migration

    func testWikiTablesReopenMigratesIdempotently() async throws {
        let (store, path) = try makeStore(providerID: "nomic-x")
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await addDoc(store, uri: "a")
        let store2 = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8,
                                                       embeddingProviderID: "nomic-x"))
        let c = try await store2.claimsByStatus(.draft)
        XCTAssertEqual(c.count, 0)  // table exists, empty, re-migrated cleanly
    }

    func testProviderStampUntouchedByWikiWrites() async throws {
        let (store, path) = try makeStore(providerID: "nomic-embed-text-v1.5")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let doc = try await addDoc(store, uri: "p")
        _ = try await store.upsertClaim(ClaimRow(text: "x", firstSeen: 1, updatedAt: 1))
        try await store.upsertSourceMeta(SourceMetaRow(documentID: doc, sourceKind: "articles", ingestedAt: 1))
        let store2 = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8,
                                                       embeddingProviderID: "nomic-embed-text-v1.5"))
        let drafts = try await store2.claimsByStatus(.draft)
        XCTAssertEqual(drafts.count, 1)
        // A different provider id on reopen must throw — the invariant holds.
        XCTAssertThrowsError(try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8,
                                                               embeddingProviderID: "openai-3-small")))
    }

    // MARK: claim dedupe

    func testClaimDedupeIdempotentAndNormalized() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let id1 = try await store.upsertClaim(ClaimRow(text: "Agents use tools.", firstSeen: 1, updatedAt: 1))
        let id2 = try await store.upsertClaim(ClaimRow(text: "Agents use tools.", firstSeen: 2, updatedAt: 2))
        let id3 = try await store.upsertClaim(ClaimRow(text: "  agents   USE  tools.  ", firstSeen: 3, updatedAt: 3))
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(id1, id3)
        let oneClaim = try await store.claimsByStatus(.draft)
        XCTAssertEqual(oneClaim.count, 1)
        let id4 = try await store.upsertClaim(ClaimRow(text: "Agents use memory.", firstSeen: 4, updatedAt: 4))
        XCTAssertNotEqual(id1, id4)
        let twoClaims = try await store.claimsByStatus(.draft)
        XCTAssertEqual(twoClaims.count, 2)
    }

    func testCanonicalSHANormalization() {
        XCTAssertEqual(ClaimRow.canonicalSHA(text: "Hello  World"), ClaimRow.canonicalSHA(text: "hello world"))
        XCTAssertEqual(ClaimRow.canonicalSHA(text: "a\n\tb"), ClaimRow.canonicalSHA(text: "a b"))
        XCTAssertNotEqual(ClaimRow.canonicalSHA(text: "a b"), ClaimRow.canonicalSHA(text: "a c"))
        XCTAssertEqual(ClaimRow.canonicalText("  X   Y "), "x y")
    }

    func testClaimUpsertPreservesFirstSeenUpdatesMutableFields() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let id = try await store.upsertClaim(ClaimRow(text: "c", status: .draft, confidence: 0.3,
                                                      firstSeen: 100, updatedAt: 100))
        _ = try await store.upsertClaim(ClaimRow(text: "c", status: .active, confidence: 0.9,
                                                 firstSeen: 999, lastReviewed: 555, updatedAt: 999))
        let got = try await store.claim(id: id)
        XCTAssertEqual(got?.firstSeen, 100)            // preserved
        XCTAssertEqual(got?.status, .active)           // updated
        XCTAssertEqual(got?.confidence ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(got?.lastReviewed, 555)
        XCTAssertEqual(got?.updatedAt, 999)
    }

    // MARK: evidence (NULL-aware idempotence)

    func testEvidenceAttachIdempotentWithNullChunk() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let doc = try await addDoc(store, uri: "d")
        let claim = try await store.upsertClaim(ClaimRow(text: "e", firstSeen: 1, updatedAt: 1))
        let ch1 = try await store.insertChunk(ChunkRow(documentId: doc, idx: 0, text: "t0", rawText: "t0",
                                                       tokenCount: 1, createdAt: 1),
                                              embeddingValues: [Float](repeating: 0, count: 8))
        try await store.attachEvidence(ClaimEvidenceRow(claimID: claim, documentID: doc, chunkID: nil))
        try await store.attachEvidence(ClaimEvidenceRow(claimID: claim, documentID: doc, chunkID: nil))  // dup
        try await store.attachEvidence(ClaimEvidenceRow(claimID: claim, documentID: doc, chunkID: ch1))
        try await store.attachEvidence(ClaimEvidenceRow(claimID: claim, documentID: doc, chunkID: ch1))  // dup
        let ev = try await store.evidence(forClaim: claim)
        // Exactly two distinct rows: one NULL-chunk + one ch1. NULLs must NOT
        // duplicate (the IFNULL expression-unique index is the fix).
        XCTAssertEqual(ev.count, 2)
        XCTAssertEqual(ev.filter { $0.chunkID == nil }.count, 1)
        XCTAssertEqual(ev.filter { $0.chunkID == ch1 }.count, 1)
    }

    // MARK: FK cascade vs the manual document teardown (the reviewer's concern)

    func testDeleteDocumentCascadesSourceMetaAndEvidenceKeepsClaim() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let doc = try await addDoc(store, uri: "x")
        try await store.upsertSourceMeta(SourceMetaRow(documentID: doc, sourceKind: "articles", ingestedAt: 1))
        let claim = try await store.upsertClaim(ClaimRow(text: "k", firstSeen: 1, updatedAt: 1))
        try await store.attachEvidence(ClaimEvidenceRow(claimID: claim, documentID: doc, chunkID: nil))
        let metaBefore = try await store.sourceMeta(documentID: doc)
        let evBefore = try await store.evidence(forClaim: claim)
        XCTAssertNotNil(metaBefore)
        XCTAssertEqual(evBefore.count, 1)

        try await store.deleteDocument(id: doc)

        let metaAfter = try await store.sourceMeta(documentID: doc)
        let evAfter = try await store.evidence(forClaim: claim)
        let claimAfter = try await store.claim(id: claim)
        XCTAssertNil(metaAfter)            // source_meta cascaded
        XCTAssertEqual(evAfter.count, 0)   // claim_evidence cascaded
        XCTAssertNotNil(claimAfter)        // the claim itself has no document FK → survives
    }

    // MARK: contradictions

    func testContradictionBidirectional() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let a = try await store.upsertClaim(ClaimRow(text: "A", firstSeen: 1, updatedAt: 1))
        let b = try await store.upsertClaim(ClaimRow(text: "B", firstSeen: 1, updatedAt: 1))
        try await store.markContradiction(claim: a, contradicts: b, at: 10)
        try await store.markContradiction(claim: a, contradicts: b, at: 10)  // idempotent
        let fromA = try await store.contradictingClaims(of: a).map(\.id)
        let fromB = try await store.contradictingClaims(of: b).map(\.id)
        XCTAssertEqual(fromA, [b])
        XCTAssertEqual(fromB, [a])  // reverse direction too
    }

    // MARK: synthesis

    func testSynthesisUpsertSlugConflictAndClaimLinks() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s1 = try await store.upsertSynthesis(SynthesisRow(slug: "agent-memory", category: "concept",
                                                              title: "T1", bodyPath: "b1", createdAt: 1, updatedAt: 1))
        let s2 = try await store.upsertSynthesis(SynthesisRow(slug: "agent-memory", category: "concept",
                                                              title: "T2", bodyPath: "b2", createdAt: 9, updatedAt: 9))
        XCTAssertEqual(s1, s2)  // slug conflict → same row
        let got = try await store.synthesis(slug: "agent-memory")
        XCTAssertEqual(got?.title, "T2")
        let inCat = try await store.syntheses(category: "concept")
        XCTAssertEqual(inCat.count, 1)

        let c = try await store.upsertClaim(ClaimRow(text: "linked", firstSeen: 1, updatedAt: 1))
        try await store.linkSynthesisClaim(synthesis: s1, claim: c)
        try await store.linkSynthesisClaim(synthesis: s1, claim: c)  // idempotent
        let linked = try await store.claimsForSynthesis(s1).map(\.id)
        XCTAssertEqual(linked, [c])
    }

    // MARK: sessions / provenance

    func testSessionProvenanceStateTransitions() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s0 = try await store.sessionProvenanceState(sessionID: "s")
        XCTAssertEqual(s0, .missing)
        try await store.writeCheckpoint(sessionID: "s", status: "in_progress", summary: "{}", updatedAt: 1)
        let s1 = try await store.sessionProvenanceState(sessionID: "s")
        XCTAssertEqual(s1, .partial)
        _ = try await store.appendSessionEvent(SessionEventRow(sessionID: "s", ts: 2, event: "research_started"))
        let s2 = try await store.sessionProvenanceState(sessionID: "s")
        XCTAssertEqual(s2, .replayable)
    }

    func testSessionEventsAppendOnlyOrderedAndCheckpointUpsert() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await store.appendSessionEvent(SessionEventRow(sessionID: "s", ts: 30, event: "c"))
        _ = try await store.appendSessionEvent(SessionEventRow(sessionID: "s", ts: 10, event: "a"))
        _ = try await store.appendSessionEvent(SessionEventRow(sessionID: "s", ts: 20, event: "b"))
        let events = try await store.sessionEvents(sessionID: "s").map(\.event)
        XCTAssertEqual(events, ["a", "b", "c"])
        try await store.writeCheckpoint(sessionID: "s", status: "in_progress", summary: "{\"v\":1}", updatedAt: 1)
        try await store.writeCheckpoint(sessionID: "s", status: "completed", summary: "{\"v\":2}", updatedAt: 5)
        let cp = try await store.checkpoint(sessionID: "s")
        XCTAssertEqual(cp?.status, "completed")
        XCTAssertEqual(cp?.summary, "{\"v\":2}")
    }

    // MARK: staleness / freshness

    func testStaleClaimsByVolatilityDecay() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now: Int64 = 1_000_000_000
        let sixtyDays: Int64 = 60 * 86_400
        // hot (half-life 30d): reviewed 60d ago → 2 half-lives → 0.25 → STALE
        let hot = try await store.upsertClaim(ClaimRow(text: "hot", status: .active, volatility: .hot,
                                                       firstSeen: 1, lastReviewed: now - sixtyDays, updatedAt: 1))
        // cold (half-life 365d): reviewed 60d ago → ~0.89 → FRESH
        _ = try await store.upsertClaim(ClaimRow(text: "cold", status: .active, volatility: .cold,
                                                 firstSeen: 1, lastReviewed: now - sixtyDays, updatedAt: 1))
        // never reviewed → always stale
        let never = try await store.upsertClaim(ClaimRow(text: "never", status: .active, volatility: .cold,
                                                         firstSeen: 1, lastReviewed: nil, updatedAt: 1))
        let stale = Set(try await store.staleClaims(now: now).map(\.id))
        XCTAssertTrue(stale.contains(hot))
        XCTAssertTrue(stale.contains(never))
        XCTAssertEqual(stale.count, 2)  // cold is fresh
    }

    func testWikiFreshnessPureMath() {
        XCTAssertEqual(WikiFreshness.freshness(ageDays: 30, volatility: .hot), 0.5, accuracy: 1e-9)
        XCTAssertEqual(WikiFreshness.freshness(ageDays: 90, volatility: .warm), 0.5, accuracy: 1e-9)
        XCTAssertEqual(WikiFreshness.freshness(ageDays: 365, volatility: .cold), 0.5, accuracy: 1e-9)
        XCTAssertEqual(WikiFreshness.freshness(ageDays: 0, volatility: .hot), 1.0, accuracy: 1e-12)
        XCTAssertEqual(WikiFreshness.freshness(ageDays: -5, volatility: .hot), 1.0, accuracy: 1e-12)
        XCTAssertGreaterThan(WikiFreshness.freshness(ageDays: 10, volatility: .hot),
                             WikiFreshness.freshness(ageDays: 20, volatility: .hot))
        XCTAssertEqual(WikiFreshness.freshness(lastReviewed: nil, now: 100, volatility: .hot), 0)
        XCTAssertTrue(WikiFreshness.isStale(lastReviewed: nil, now: 100, volatility: .cold))
    }

    // MARK: meta

    func testLastCompiledAtRoundtrip() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let none = try await store.lastCompiledAt()
        XCTAssertNil(none)
        try await store.setLastCompiledAt(1_700_000_000)
        let a = try await store.lastCompiledAt()
        XCTAssertEqual(a, 1_700_000_000)
        try await store.setLastCompiledAt(1_700_000_500)
        let b = try await store.lastCompiledAt()
        XCTAssertEqual(b, 1_700_000_500)
    }

    // MARK: adversarial inputs (binds must defeat injection; large/unicode survive)

    func testAdversarialClaimTextIsBindSafeAndRoundTrips() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let nasty = "Robert'); DROP TABLE claim;-- \"\u{1F600}\" \n tab\there ünïcödé"
        let id = try await store.upsertClaim(ClaimRow(text: nasty, firstSeen: 1, updatedAt: 1))
        XCTAssertGreaterThan(id, 0)
        let got = try await store.claim(id: id)
        XCTAssertEqual(got?.text, nasty)  // stored verbatim, table intact
        let drafts = try await store.claimsByStatus(.draft)
        XCTAssertEqual(drafts.count, 1)   // table still exists / queryable

        let huge = String(repeating: "x", count: 200_000)
        let hugeID = try await store.upsertClaim(ClaimRow(text: huge, firstSeen: 1, updatedAt: 1))
        let hugeGot = try await store.claim(id: hugeID)
        XCTAssertEqual(hugeGot?.text.count, 200_000)  // no silent truncation
    }

    func testClaimsForDocumentJoin() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let d1 = try await addDoc(store, uri: "d1")
        let d2 = try await addDoc(store, uri: "d2")
        let c1 = try await store.upsertClaim(ClaimRow(text: "c1", firstSeen: 1, updatedAt: 1))
        let c2 = try await store.upsertClaim(ClaimRow(text: "c2", firstSeen: 1, updatedAt: 1))
        try await store.attachEvidence(ClaimEvidenceRow(claimID: c1, documentID: d1))
        try await store.attachEvidence(ClaimEvidenceRow(claimID: c2, documentID: d1))
        try await store.attachEvidence(ClaimEvidenceRow(claimID: c2, documentID: d2))
        let forD1 = Set(try await store.claimsForDocument(d1).map(\.id))
        let forD2 = try await store.claimsForDocument(d2).map(\.id)
        XCTAssertEqual(forD1, [c1, c2])
        XCTAssertEqual(forD2, [c2])
    }
}
