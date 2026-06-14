import XCTest
@testable import WikiResearch

final class WikiResearchTests: XCTestCase {

    // MARK: mode detection

    func testModeDetection() {
        func d(_ s: String) -> ResearchMode { ResearchModeDetector.detect(s) }
        // thesis signal words win (even over question shape)
        XCTAssertEqual(d("Prove that RAG beats fine-tuning"), .thesis)
        XCTAssertEqual(d("Is it true that transformers can't extrapolate?"), .thesis)  // thesis beats '?'
        XCTAssertEqual(d("verify the claim that MoE scales better"), .thesis)
        XCTAssertEqual(d("debunk the myth of emergent abilities"), .thesis)
        // question shapes
        XCTAssertEqual(d("What is retrieval-augmented generation"), .question)
        XCTAssertEqual(d("How do diffusion models work"), .question)
        XCTAssertEqual(d("Are agents production-ready?"), .question)
        XCTAssertEqual(d("does speculative decoding help"), .question)
        // topic (no signal, no question shape)
        XCTAssertEqual(d("mixture of experts architectures"), .topic)
        XCTAssertEqual(d("history of the transformer"), .topic)
        // forced wins
        XCTAssertEqual(ResearchModeDetector.detect("anything", forced: .thesis), .thesis)
    }

    // MARK: credibility

    func testCredibilityPoints() {
        // peer-reviewed + recent + known author + 2 corroborations = +6 → High
        let top = CredibilityScorer.score(.init(peerReviewed: true, recent: true, knownAuthor: true,
                                                corroboratingAgents: 3))   // capped at +2
        XCTAssertEqual(top.points, 6)
        XCTAssertEqual(top.tier, .high)
        // non-stacking: bias AND vendor → only -1 (not -2)
        let biased = CredibilityScorer.score(.init(peerReviewed: true, biasDetected: true, vendorPrimary: true))
        XCTAssertEqual(biased.points, 1)   // +2 - 1
        XCTAssertEqual(biased.tier, .low)
        // very old foundational minus
        let old = CredibilityScorer.score(.init(recent: false, veryOld: true))
        XCTAssertEqual(old.points, -1)
        XCTAssertEqual(old.tier, .reject)
        // corroboration cap
        XCTAssertEqual(CredibilityScorer.score(.init(corroboratingAgents: 5)).points, 2)
    }

    func testCredibilityTierBoundaries() {
        XCTAssertEqual(CredibilityScorer.tier(points: 6), .high)
        XCTAssertEqual(CredibilityScorer.tier(points: 4), .high)
        XCTAssertEqual(CredibilityScorer.tier(points: 3), .medium)
        XCTAssertEqual(CredibilityScorer.tier(points: 2), .medium)
        XCTAssertEqual(CredibilityScorer.tier(points: 1), .low)
        XCTAssertEqual(CredibilityScorer.tier(points: 0), .low)
        XCTAssertEqual(CredibilityScorer.tier(points: -1), .reject)
        // ingestion floors
        XCTAssertTrue(TrustTier.low.ingested(retardmax: false))
        XCTAssertFalse(TrustTier.low.ingested(retardmax: true))    // retardmax: Medium and above
        XCTAssertFalse(TrustTier.reject.ingested(retardmax: false))
    }

    // MARK: dedup

    func testExactURLDedupeKeepsHigherCredibility() {
        let a = RankedSource(url: "https://ex.com/x", title: "lo", credibility: 2, agentQuality: 3)
        let b = RankedSource(url: "http://www.ex.com/x/", title: "hi", credibility: 5, agentQuality: 3) // same canonical
        let out = SourceDedup.dedupe([a, b])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].credibility, 5)        // higher-credibility member kept
        XCTAssertEqual(out[0].title, "hi")
    }

    func testCanonicalURL() {
        XCTAssertEqual(SourceDedup.canonicalURL("https://www.Example.com/Path/"), "example.com/Path")
        XCTAssertEqual(SourceDedup.canonicalURL("http://example.com/a#frag"), "example.com/a")
        XCTAssertEqual(SourceDedup.canonicalURL("HTTPS://EXAMPLE.COM"), "example.com")
    }

    func testCosineDedupeKeepsHigherRank() {
        let hi = RankedSource(url: "https://a.com", title: "A", credibility: 5, agentQuality: 5, embedding: [1, 0, 0])
        let dup = RankedSource(url: "https://b.com", title: "B", credibility: 2, agentQuality: 2, embedding: [0.99, 0.01, 0]) // ~parallel
        let diff = RankedSource(url: "https://c.com", title: "C", credibility: 4, agentQuality: 3, embedding: [0, 1, 0])
        let out = SourceDedup.dedupe([dup, hi, diff], threshold: 0.8)
        XCTAssertEqual(out.count, 2)                  // dup folded into hi
        XCTAssertTrue(out.contains { $0.url == "https://a.com" })
        XCTAssertTrue(out.contains { $0.url == "https://c.com" })
        XCTAssertFalse(out.contains { $0.url == "https://b.com" })
        XCTAssertEqual(out.first?.url, "https://a.com")   // ranked first (5×5)
    }

    func testDedupeKeepN() {
        let s = (0..<5).map { RankedSource(url: "https://x.com/\($0)", title: "\($0)",
                                           credibility: $0, agentQuality: 1) }
        let out = SourceDedup.dedupe(s, keep: 2)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].credibility, 4)        // top-ranked first
        XCTAssertEqual(out[1].credibility, 3)
    }

    // MARK: gaps

    func testGapCompositeAndTop3() {
        let gaps = [
            Gap(description: "B", impact: 5, feasibility: 4, specificity: 5),  // 100
            Gap(description: "C", impact: 4, feasibility: 5, specificity: 4),  // 80
            Gap(description: "D", impact: 3, feasibility: 3, specificity: 4),  // 36
            Gap(description: "E", impact: 2, feasibility: 2, specificity: 2),  // 8
        ]
        let top = GapScorer.topGaps(gaps)
        XCTAssertEqual(top.map(\.description), ["B", "C", "D"])
        XCTAssertEqual(top[0].composite, 100)
        XCTAssertTrue(GapScorer.anyHighImpact(gaps))             // B has impact 5
        XCTAssertFalse(GapScorer.anyHighImpact([gaps[2], gaps[3]]))
    }

    // MARK: progress score

    func testProgressScoreComponentsAndCaps() {
        // sources 10×3=30(cap), articles 6×5=30(cap), crossrefs 100×2 cap to max(20,0)=20,
        // credibility 5×4=20 → 100
        let full = ProgressScorer.score(.init(sourcesIngested: 10, articlesCreatedOrUpdated: 6,
                                              crossRefsAdded: 100, existingArticles: 0, avgCredibility: 5))
        XCTAssertEqual(full, 100)
        // small round: 2 src (6) + 1 art (5) + 0 xref + cred 3×4=12 → 23
        let small = ProgressScorer.score(.init(sourcesIngested: 2, articlesCreatedOrUpdated: 1,
                                               crossRefsAdded: 0, existingArticles: 0, avgCredibility: 3))
        XCTAssertEqual(small, 23)
        // cross-ref cap scales with maturity: 15 existing → cap 30
        let mature = ProgressScorer.score(.init(sourcesIngested: 0, articlesCreatedOrUpdated: 0,
                                                crossRefsAdded: 20, existingArticles: 15, avgCredibility: 0))
        XCTAssertEqual(mature, 30)               // min(40, 30)
        // negative avg credibility clamps the component to 0 (not negative)
        let neg = ProgressScorer.score(.init(sourcesIngested: 1, articlesCreatedOrUpdated: 0,
                                             crossRefsAdded: 0, existingArticles: 0, avgCredibility: -2))
        XCTAssertEqual(neg, 3)
    }

    func testProgressBands() {
        XCTAssertEqual(ProgressScorer.band(20), .minimal)
        XCTAssertEqual(ProgressScorer.band(55), .moderate)
        XCTAssertEqual(ProgressScorer.band(85), .strong)
        XCTAssertEqual(ProgressScorer.band(95), .comprehensive)
    }

    // MARK: termination decision tree

    func testDecisionTree() {
        // >=80 with a high-impact gap → continue (high quality)
        XCTAssertEqual(ProgressScorer.assess(history: [85], anyHighImpactGaps: true,
                       crossRefDensity: 0.2, newHighImpactGaps: false).decision, .continueHighQuality)
        // >=80, no gaps, dense cross-refs → early completion
        XCTAssertEqual(ProgressScorer.assess(history: [85], anyHighImpactGaps: false,
                       crossRefDensity: 0.7, newHighImpactGaps: false).decision, .earlyCompletion)
        // >=80, no gaps, sparse cross-refs → one more round on connections
        XCTAssertEqual(ProgressScorer.assess(history: [85], anyHighImpactGaps: false,
                       crossRefDensity: 0.3, newHighImpactGaps: false).decision, .oneMoreRoundConnections)
        // <40 → low-yield warning
        XCTAssertEqual(ProgressScorer.assess(history: [35], anyHighImpactGaps: true,
                       crossRefDensity: 0.0, newHighImpactGaps: true).decision, .lowYieldWarning)
        // 40-79 → continue normally
        XCTAssertEqual(ProgressScorer.assess(history: [60], anyHighImpactGaps: false,
                       crossRefDensity: 0.0, newHighImpactGaps: true).decision, .continueNormally)
    }

    func testTrajectoryTriggers() {
        // stalled: any round < 20
        XCTAssertTrue(ProgressScorer.assess(history: [50, 15], anyHighImpactGaps: false,
                      crossRefDensity: 0, newHighImpactGaps: true).flags.contains(.stalled))
        // declining: 98→95→68→58 (-40, 3 declines)
        XCTAssertTrue(ProgressScorer.assess(history: [98, 95, 68, 58], anyHighImpactGaps: false,
                      crossRefDensity: 0, newHighImpactGaps: true).flags.contains(.declining))
        // not declining: only a 2-round dip
        XCTAssertFalse(ProgressScorer.assess(history: [98, 58], anyHighImpactGaps: false,
                       crossRefDensity: 0, newHighImpactGaps: true).flags.contains(.declining))
        // plateau: within 5 pts AND no new high-impact gaps
        let plat = ProgressScorer.assess(history: [72, 74], anyHighImpactGaps: false,
                                         crossRefDensity: 0, newHighImpactGaps: false)
        XCTAssertTrue(plat.flags.contains(.plateau))
        // not plateau if new high-impact gaps appeared
        XCTAssertFalse(ProgressScorer.assess(history: [72, 74], anyHighImpactGaps: false,
                       crossRefDensity: 0, newHighImpactGaps: true).flags.contains(.plateau))
        // low-yield two rounds
        XCTAssertTrue(ProgressScorer.assess(history: [38, 30], anyHighImpactGaps: false,
                      crossRefDensity: 0, newHighImpactGaps: true).flags.contains(.lowYieldTwoRounds))
    }

    // MARK: round planning

    func testSwarmAngles() {
        XCTAssertEqual(RoundPlanner.angles(mode: .topic, depth: .standard).count, 5)
        XCTAssertEqual(RoundPlanner.angles(mode: .topic, depth: .deep).count, 8)
        XCTAssertEqual(RoundPlanner.angles(mode: .topic, depth: .retardmax).count, 10)
        let thesis = RoundPlanner.angles(mode: .thesis, depth: .standard)
        XCTAssertEqual(thesis.count, 5)
        XCTAssertEqual(thesis.first { $0.role == "Meta/Review" }?.weight, 1.5)  // most weight
        XCTAssertTrue(thesis.contains { $0.role == "Opposing" })               // steelman built in
        XCTAssertEqual(RoundPlanner.angles(mode: .question, depth: .standard).count, 0)  // dynamic sub-questions
        XCTAssertTrue(RoundPlanner.skipsPlanning(.retardmax))
        XCTAssertFalse(RoundPlanner.skipsPlanning(.deep))
    }
}
