import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore
import MemoryScore

/// Severe coverage for Librarian Tier-2 (§5.D). Properties under test:
/// 1. Tier-2 scores ONLY the Tier-1-flagged subset (cost tracks problem density).
/// 2. `--limit` caps the model pass at the stalest pages.
/// 3. An unscorable page is skipped (Tier-2 degrades, never blocks).
/// 4. JSON parsing clamps to 1...5 and rejects half-answers.
/// 5. The SpendGate ceiling short-circuits the live scorer BEFORE any network call.
/// 6. The persisted artifact has the expected shape.
/// All tests are hermetic — the mock scorer never touches the network, and the
/// ceiling=0 path short-circuits the live scorer before URLSession is reached.
final class WikiLibrarianTier2Tests: XCTestCase {

    // A deterministic in-memory scorer that records the titles it saw and can be told
    // to fail (return nil) for specific titles.
    private final class MockScorer: CoherenceScoring, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seen: [String] = []
        let result: (coherence: Int, utility: Int, rationale: String)?
        let failTitles: Set<String>
        init(result: (coherence: Int, utility: Int, rationale: String)? = (4, 3, "ok"),
             failTitles: Set<String> = []) {
            self.result = result; self.failTitles = failTitles
        }
        func score(title: String, body: String) async -> (coherence: Int, utility: Int, rationale: String)? {
            lock.withLock { seen.append(title) }
            return failTitles.contains(title) ? nil : result
        }
    }

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "librtier2-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }

    private let now: Int64 = 1_000_000_000
    private let day: Int64 = 86_400

    /// Insert a synthesis page + `claims` linked claims; returns its id.
    @discardableResult
    private func page(_ store: MemoryStore, _ slug: String, _ vol: Volatility,
                      stamp: Int64, claims: Int) async throws -> Int64 {
        let sid = try await store.upsertSynthesis(SynthesisRow(
            slug: slug, category: "topic", title: slug, bodyPath: "inline:\(slug)",
            volatility: vol, verifiedAt: stamp, createdAt: stamp, updatedAt: stamp))
        for i in 0..<claims {
            let cid = try await store.upsertClaim(ClaimRow(text: "\(slug) claim \(i) about the topic",
                                                          firstSeen: stamp, updatedAt: stamp))
            try await store.linkSynthesisClaim(synthesis: sid, claim: cid)
        }
        return sid
    }

    func testReviewScoresOnlyFlaggedSubset() async throws {
        let store = try makeStore()
        let freshID = try await page(store, "fresh", .cold, stamp: now, claims: 5)         // not flagged
        let staleID = try await page(store, "stale", .warm, stamp: now - 800 * day, claims: 1) // flagged
        let hotID   = try await page(store, "hot", .hot, stamp: now, claims: 3)            // flagged

        let scores = try await store.librarianScan(now: now)
        let scorer = MockScorer()
        let tier2 = await LibrarianTier2.review(store: store, scores: scores, scorer: scorer, limit: 10)

        let scoredIDs = Set(tier2.map(\.documentID))
        XCTAssertEqual(scoredIDs, [staleID, hotID], "only the flagged pages are scored")
        XCTAssertFalse(scoredIDs.contains(freshID), "the fresh/deep/cold page is never sent to the model")
        XCTAssertEqual(Set(scorer.seen), ["stale", "hot"], "the scorer only saw the flagged titles")
        XCTAssertTrue(tier2.allSatisfy { $0.coherence == 4 && $0.utility == 3 })
    }

    func testReviewRespectsLimitKeepingStalest() async throws {
        let store = try makeStore()
        // Three flagged pages of increasing staleness; stalest-first ordering means
        // limit:1 must keep the oldest one.
        _ = try await page(store, "old1", .warm, stamp: now - 300 * day, claims: 1)
        _ = try await page(store, "old2", .warm, stamp: now - 600 * day, claims: 1)
        let oldestID = try await page(store, "old3", .warm, stamp: now - 900 * day, claims: 1)

        let scores = try await store.librarianScan(now: now)
        let scorer = MockScorer()
        let tier2 = await LibrarianTier2.review(store: store, scores: scores, scorer: scorer, limit: 1)
        XCTAssertEqual(tier2.count, 1, "limit caps the model pass")
        // librarianScan sorts by lowest staleness SCORE first; with identical
        // volatility, lowest score == oldest, so the cap keeps old3.
        XCTAssertEqual(tier2.first?.documentID, oldestID, "the cap keeps the lowest-staleness-score page")
    }

    func testReviewLimitZeroScoresNothing() async throws {
        let store = try makeStore()
        _ = try await page(store, "hot", .hot, stamp: now, claims: 2)
        let scores = try await store.librarianScan(now: now)
        let scorer = MockScorer()
        let tier2 = await LibrarianTier2.review(store: store, scores: scores, scorer: scorer, limit: 0)
        XCTAssertTrue(tier2.isEmpty, "limit:0 scores nothing")
        XCTAssertTrue(scorer.seen.isEmpty, "limit:0 never calls the model")
    }

    func testReviewSkipsEmptyTextPages() async throws {
        let store = try makeStore()
        // Both flagged (hot). "empty" has zero claims + an inline: body → no
        // substantive text → must be skipped (no title-only fabrication).
        _ = try await page(store, "empty", .hot, stamp: now, claims: 0)
        let realID = try await page(store, "real", .hot, stamp: now, claims: 2)
        let scores = try await store.librarianScan(now: now)
        let scorer = MockScorer()
        let tier2 = await LibrarianTier2.review(store: store, scores: scores, scorer: scorer, limit: 10)
        XCTAssertEqual(tier2.map(\.documentID), [realID], "the contentless page is skipped, not scored from its title")
        XCTAssertEqual(Set(scorer.seen), ["real"], "the model never saw the contentless page")
    }

    func testPageTextReadsFileResolvesRelativeAndSkipsInline() async throws {
        let store = try makeStore()
        let dir = NSTemporaryDirectory() + "ptvault-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // absolute bodyPath → read directly
        let absPath = dir + "/abs.md"
        try "ABSOLUTE BODY CONTENT".write(toFile: absPath, atomically: true, encoding: .utf8)
        let absID = try await store.upsertSynthesis(SynthesisRow(
            slug: "abs", category: "topic", title: "abs", bodyPath: absPath,
            volatility: .warm, createdAt: now, updatedAt: now))
        let absSyn = try await store.synthesis(id: absID)
        let absText = await LibrarianTier2.pageText(store: store, syn: try XCTUnwrap(absSyn), vaultRoot: nil)
        XCTAssertTrue(absText.contains("ABSOLUTE BODY CONTENT"))

        // relative bodyPath → resolved against vaultRoot
        try "RELATIVE BODY CONTENT".write(toFile: dir + "/rel.md", atomically: true, encoding: .utf8)
        let relID = try await store.upsertSynthesis(SynthesisRow(
            slug: "rel", category: "topic", title: "rel", bodyPath: "rel.md",
            volatility: .warm, createdAt: now, updatedAt: now))
        let relSyn = try await store.synthesis(id: relID)
        let relText = await LibrarianTier2.pageText(store: store, syn: try XCTUnwrap(relSyn), vaultRoot: dir)
        XCTAssertTrue(relText.contains("RELATIVE BODY CONTENT"))

        // inline: scheme → file read skipped; claims still folded in
        let inlID = try await page(store, "inl", .warm, stamp: now, claims: 2)
        let inlSyn = try await store.synthesis(id: inlID)
        let inlText = await LibrarianTier2.pageText(store: store, syn: try XCTUnwrap(inlSyn), vaultRoot: dir)
        XCTAssertTrue(inlText.contains("inl claim 0"), "claims are always included")
        XCTAssertFalse(inlText.contains("inline:"), "the inline: scheme token is never read as a file")
    }

    func testPersistEmptyTier2WritesZeroCounts() async throws {
        let store = try makeStore()
        _ = try await page(store, "hot", .hot, stamp: now, claims: 1)
        let scores = try await store.librarianScan(now: now)
        let dir = NSTemporaryDirectory() + "pe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = LibrarianTier2.persist(vaultRoot: dir, scores: scores, tier2: [], now: now)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(obj["tier2_scored"] as? Int, 0)
        XCTAssertEqual((obj["tier2"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(obj["flagged"] as? Int, 1)
    }

    func testFormatSurfacesTier2NoteInBothModes() async throws {
        let store = try makeStore()
        _ = try await page(store, "hot", .hot, stamp: now, claims: 1)
        let scores = try await store.librarianScan(now: now)
        var opt = CodexMemoryWikiLibrarian.Options(); opt.tier2 = true
        let note = "Tier-2 skipped: set OPENAI_API_KEY to score the flagged subset"
        let human = CodexMemoryWikiLibrarian.format(scores, tier2: [], tier2Note: note, opt: opt)
        XCTAssertTrue(human.contains("Tier-2 skipped"), "human report surfaces the no-key note")
        opt.json = true
        let json = CodexMemoryWikiLibrarian.format(scores, tier2: [], tier2Note: note, opt: opt)
        XCTAssertTrue(json.contains("tier2_note"), "json report carries tier2_note")
        XCTAssertEqual(try (JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["tier2_scored"] as? Int, 0)
    }

    func testReviewSkipsUnscorablePages() async throws {
        let store = try makeStore()
        let staleID = try await page(store, "stale", .warm, stamp: now - 800 * day, claims: 1)
        _ = try await page(store, "hot", .hot, stamp: now, claims: 3)

        let scores = try await store.librarianScan(now: now)
        let scorer = MockScorer(failTitles: ["hot"])   // model refuses the "hot" page
        let tier2 = await LibrarianTier2.review(store: store, scores: scores, scorer: scorer, limit: 10)
        XCTAssertEqual(tier2.map(\.documentID), [staleID], "a page the model can't score is skipped, not faked")
    }

    func testParseClampsAndRejects() {
        // in-range
        let a = WikiCoherenceScorer.parse(#"{"coherence":4,"utility":3,"rationale":"good"}"#)
        XCTAssertEqual(a?.coherence, 4); XCTAssertEqual(a?.utility, 3); XCTAssertEqual(a?.rationale, "good")
        // out-of-range clamps to [1,5]
        let b = WikiCoherenceScorer.parse(#"{"coherence":7,"utility":0,"rationale":"x"}"#)
        XCTAssertEqual(b?.coherence, 5); XCTAssertEqual(b?.utility, 1)
        // string-encoded ints + missing rationale
        let c = WikiCoherenceScorer.parse(#"{"coherence":"2","utility":"5"}"#)
        XCTAssertEqual(c?.coherence, 2); XCTAssertEqual(c?.utility, 5); XCTAssertEqual(c?.rationale, "")
        // half-answer / malformed → nil
        XCTAssertNil(WikiCoherenceScorer.parse(#"{"coherence":3}"#), "missing utility → nil")
        XCTAssertNil(WikiCoherenceScorer.parse("not json"))
        XCTAssertNil(WikiCoherenceScorer.parse("{}"))
    }

    func testSpendGateCeilingShortCircuitsLiveScorer() async throws {
        let store = try makeStore()
        let gate = SpendGate(store: store, config: .init(monthlyCeilingUSD: 0, bucket: "wiki-librarian"))
        let scorer = WikiCoherenceScorer(apiKey: "unused-because-rate-limited",
                                         model: "gpt-4o-mini", spendGate: gate)
        let r = await scorer.score(title: "Topic", body: "Some article body to assess.")
        XCTAssertNil(r, "ceiling=0 must short-circuit before any network call")
        let spent = try await gate.monthlySpentUSD()
        XCTAssertEqual(spent, 0, accuracy: 1e-9, "a rate-limited score records no spend")
    }

    func testPersistWritesArtifact() async throws {
        let store = try makeStore()
        let staleID = try await page(store, "stale", .warm, stamp: now - 800 * day, claims: 1)
        _ = try await page(store, "fresh", .cold, stamp: now, claims: 5)
        let scores = try await store.librarianScan(now: now)
        let tier2 = [LibrarianTier2Score(documentID: staleID, coherence: 2, utility: 1, rationale: "thin")]

        let dir = NSTemporaryDirectory() + "librvault-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = LibrarianTier2.persist(vaultRoot: dir, scores: scores, tier2: tier2, now: now)

        XCTAssertTrue(path.hasSuffix(".librarian/scan-results.json"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["pages"] as? Int, 2)
        XCTAssertEqual(obj["flagged"] as? Int, 1)
        XCTAssertEqual(obj["tier2_scored"] as? Int, 1)
        let t2 = try XCTUnwrap(obj["tier2"] as? [[String: Any]])
        XCTAssertEqual(t2.first?["coherence"] as? Int, 2)
        XCTAssertEqual(t2.first?["utility"] as? Int, 1)
    }
}
