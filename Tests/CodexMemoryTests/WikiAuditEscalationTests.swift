import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore
import MemoryScore

/// Severe coverage for Audit Pass 3 — truth-escalation (§5.D). Properties:
/// 1. combine() truth table (confirm × disprove → verdict).
/// 2. aggregate() page rollup (contradicted dominates; mixed; supported; insufficient).
/// 3. escalate() re-fetches each claim's cited URLs and judges; aggregates per page.
/// 4. Degradation: no cited URL / fetch failure / judge-unavailable never fabricate.
/// 5. citedURLs dedupes + filters http(s) + caps.
/// 6. persist() artifact shape.
/// 7. The live adjudicator's SpendGate ceiling short-circuits before any network call.
/// All hermetic — mock fetcher + mock judge; the ceiling=0 path never hits the network.
final class WikiAuditEscalationTests: XCTestCase {

    private final class MockFetcher: AuditEvidenceFetcher, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var fetched: [String] = []
        let byURL: [String: String]   // url.absoluteString → markdown (absent → fetch fails)
        init(_ byURL: [String: String]) { self.byURL = byURL }
        func fetchMarkdown(_ url: URL) async -> String? {
            lock.withLock { fetched.append(url.absoluteString) }
            return byURL[url.absoluteString]
        }
    }

    private final class MockJudge: ClaimAdjudicator, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seen: [String] = []
        private(set) var seenEvidence: [String] = []
        let verdictByClaim: [String: AuditVerdict]   // claim text → verdict (absent → nil/degrade)
        let defaultNil: Bool
        init(_ verdictByClaim: [String: AuditVerdict], defaultNil: Bool = true) {
            self.verdictByClaim = verdictByClaim; self.defaultNil = defaultNil
        }
        func adjudicate(claim: String, evidence: String) async -> (verdict: AuditVerdict, rationale: String)? {
            lock.withLock { seen.append(claim); seenEvidence.append(evidence) }
            if let v = verdictByClaim[claim] { return (v, "mock") }
            return defaultNil ? nil : (.insufficient, "mock-default")
        }
    }

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "auditesc-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }

    private let now: Int64 = 1_000_000_000

    /// Build a synthesis page with `claims`, each backed by evidence at a given URL.
    /// Returns (synthID, [(claimText, claimID)]).
    @discardableResult
    private func page(_ store: MemoryStore, slug: String,
                      claims: [(text: String, url: String?)]) async throws -> (Int64, [(String, Int64)]) {
        let synthID = try await store.upsertSynthesis(SynthesisRow(
            slug: slug, category: "synthesis", title: slug, bodyPath: "inline:\(slug)",
            createdAt: now, updatedAt: now, generatedAt: now))
        var made: [(String, Int64)] = []
        for c in claims {
            let cid = try await store.upsertClaim(ClaimRow(text: c.text, firstSeen: now, updatedAt: now))
            try await store.linkSynthesisClaim(synthesis: synthID, claim: cid)
            if let url = c.url {
                let docID = try await store.upsertDocument(DocumentRow(
                    source: .web, sourceURI: url, title: "src", bodyPath: "inline:\(url)",
                    fetchedAt: now, contentSHA: Data("\(url)".utf8), rawBytes: 10))
                try await store.attachEvidence(ClaimEvidenceRow(claimID: cid, documentID: docID))
            }
            made.append((c.text, cid))
        }
        return (synthID, made)
    }

    // MARK: pure logic

    func testCombineTruthTable() {
        XCTAssertEqual(WikiClaimAdjudicator.combine(supports: true, contradicts: false), .supported)
        XCTAssertEqual(WikiClaimAdjudicator.combine(supports: false, contradicts: true), .contradicted)
        XCTAssertEqual(WikiClaimAdjudicator.combine(supports: true, contradicts: true), .mixed)
        XCTAssertEqual(WikiClaimAdjudicator.combine(supports: false, contradicts: false), .insufficient)
    }

    func testParseBool() {
        XCTAssertEqual(WikiClaimAdjudicator.parseBool(true), true)
        XCTAssertEqual(WikiClaimAdjudicator.parseBool(false), false)
        XCTAssertEqual(WikiClaimAdjudicator.parseBool("yes"), true)
        XCTAssertEqual(WikiClaimAdjudicator.parseBool("FALSE"), false)
        XCTAssertEqual(WikiClaimAdjudicator.parseBool("1"), true)
        XCTAssertNil(WikiClaimAdjudicator.parseBool(nil))
        XCTAssertNil(WikiClaimAdjudicator.parseBool("maybe"))
    }

    func testAggregate() {
        func v(_ verds: [AuditVerdict]) -> AuditVerdict {
            AuditTruthEscalation.aggregate(verds.enumerated().map {
                AuditClaimVerdict(claimID: Int64($0.offset), verdict: $0.element, rationale: "")
            })
        }
        XCTAssertEqual(v([]), .insufficient)
        XCTAssertEqual(v([.supported, .contradicted, .insufficient]), .contradicted, "contradicted dominates")
        XCTAssertEqual(v([.supported, .mixed]), .mixed, "mixed beats supported")
        XCTAssertEqual(v([.supported, .supported]), .supported, "all supported → supported")
        XCTAssertEqual(v([.supported, .insufficient]), .mixed, "partial verification → mixed")
        XCTAssertEqual(v([.insufficient, .insufficient]), .insufficient)
    }

    // MARK: escalate

    func testEscalateReVerifiesAndAggregates() async throws {
        let store = try makeStore()
        let (synthID, _) = try await page(store, slug: "p", claims: [
            ("Claim alpha is true.", "https://ex.com/a"),
            ("Claim beta is false.", "https://ex.com/b"),
        ])
        let fetcher = MockFetcher(["https://ex.com/a": "evidence A", "https://ex.com/b": "evidence B"])
        let judge = MockJudge(["Claim alpha is true.": .supported, "Claim beta is false.": .contradicted])
        let verdicts = await AuditTruthEscalation.escalate(store: store, driftedIDs: [synthID],
                                                           fetcher: fetcher, judge: judge, limit: 10)
        XCTAssertEqual(verdicts.count, 1)
        XCTAssertEqual(verdicts.first?.verdict, .contradicted, "one contradicted claim → page contradicted")
        XCTAssertEqual(verdicts.first?.claims.count, 2)
        XCTAssertEqual(Set(fetcher.fetched), ["https://ex.com/a", "https://ex.com/b"], "both cited URLs re-fetched")
    }

    func testEscalateNoCitedURLIsInsufficient() async throws {
        let store = try makeStore()
        let (synthID, _) = try await page(store, slug: "p", claims: [("Ungrounded claim here.", nil)])
        let fetcher = MockFetcher([:])
        let judge = MockJudge([:], defaultNil: false)
        let verdicts = await AuditTruthEscalation.escalate(store: store, driftedIDs: [synthID],
                                                           fetcher: fetcher, judge: judge, limit: 10)
        XCTAssertEqual(verdicts.first?.claims.first?.verdict, .insufficient)
        XCTAssertTrue(fetcher.fetched.isEmpty, "no URL → nothing fetched")
        XCTAssertTrue(judge.seen.isEmpty, "no URL → judge never consulted")
    }

    func testEscalateFetchFailureIsInsufficient() async throws {
        let store = try makeStore()
        let (synthID, _) = try await page(store, slug: "p", claims: [("Claim with dead link.", "https://dead.com/x")])
        let fetcher = MockFetcher([:])   // URL present but fetch returns nil
        let judge = MockJudge([:], defaultNil: false)
        let verdicts = await AuditTruthEscalation.escalate(store: store, driftedIDs: [synthID],
                                                           fetcher: fetcher, judge: judge, limit: 10)
        XCTAssertEqual(verdicts.first?.claims.first?.verdict, .insufficient)
        XCTAssertEqual(fetcher.fetched, ["https://dead.com/x"], "the fetch was attempted")
        XCTAssertTrue(judge.seen.isEmpty, "unfetchable evidence → judge never consulted")
    }

    func testEscalateJudgeUnavailableDropsPage() async throws {
        let store = try makeStore()
        let (synthID, _) = try await page(store, slug: "p", claims: [("Claim X.", "https://ex.com/a")])
        let fetcher = MockFetcher(["https://ex.com/a": "evidence A"])
        let judge = MockJudge([:], defaultNil: true)   // judge returns nil (no key/budget)
        let verdicts = await AuditTruthEscalation.escalate(store: store, driftedIDs: [synthID],
                                                           fetcher: fetcher, judge: judge, limit: 10)
        XCTAssertTrue(verdicts.isEmpty, "a page whose only claim couldn't be judged is dropped, never fabricated")
    }

    func testCitedURLsDedupesFiltersAndCaps() async throws {
        let store = try makeStore()
        // one claim, three evidence rows: dup URL, an ftp (filtered), two distinct https
        let cid = try await store.upsertClaim(ClaimRow(text: "c", firstSeen: now, updatedAt: now))
        func doc(_ uri: String) async throws -> Int64 {
            try await store.upsertDocument(DocumentRow(source: .web, sourceURI: uri, bodyPath: "b",
                                                       fetchedAt: now, contentSHA: Data(uri.utf8), rawBytes: 1))
        }
        let d1 = try await doc("https://ex.com/a")
        let d2 = try await doc("https://ex.com/b")
        let d3 = try await doc("ftp://ex.com/c")
        let d4 = try await doc("https://ex.com/a2")
        for d in [d1, d2, d3, d4] { try await store.attachEvidence(ClaimEvidenceRow(claimID: cid, documentID: d)) }
        let urls = await AuditTruthEscalation.citedURLs(store: store, claimID: cid, max: 2)
        XCTAssertEqual(urls.count, 2, "capped at max")
        XCTAssertTrue(urls.allSatisfy { $0.scheme == "https" }, "ftp filtered out")
    }

    func testPersistWritesVerdictArtifact() async throws {
        let dir = NSTemporaryDirectory() + "auditvault-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let verdicts = [
            AuditPageVerdict(pageID: 7, verdict: .contradicted,
                             claims: [AuditClaimVerdict(claimID: 1, verdict: .contradicted, rationale: "r")]),
            AuditPageVerdict(pageID: 8, verdict: .supported,
                             claims: [AuditClaimVerdict(claimID: 2, verdict: .supported, rationale: "r")]),
        ]
        let path = AuditTruthEscalation.persist(vaultRoot: dir, verdicts: verdicts, now: now)
        XCTAssertTrue(path.hasSuffix(".audit/verdicts.json"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(obj["pages"] as? Int, 2)
        XCTAssertEqual(obj["contradicted"] as? Int, 1)
    }

    func testAdjudicatorSpendGateCeilingShortCircuits() async throws {
        let store = try makeStore()
        let gate = SpendGate(store: store, config: .init(monthlyCeilingUSD: 0, bucket: "wiki-audit"))
        let judge = WikiClaimAdjudicator(apiKey: "unused-because-rate-limited",
                                         model: "gpt-4o-mini", spendGate: gate)
        let r = await judge.adjudicate(claim: "A claim.", evidence: "Some evidence body.")
        XCTAssertNil(r, "ceiling=0 must short-circuit before any network call")
        let spent = try await gate.monthlySpentUSD()
        XCTAssertEqual(spent, 0, accuracy: 1e-9)
    }

    // MARK: adjudicator two-call (confirm + disprove) semantics — the load-bearing
    // invariant. Uses an injected deterministic transport (no network).

    func testAdjudicatorBothCallsSucceedYieldsVerdict() async throws {
        let judge = WikiClaimAdjudicator(apiKey: "k", model: "m", spendGate: nil,
            transport: { sys, _, _ in
                sys.contains("SUPPORTS") ? (#"{"supports":true,"why":"s"}"#, 1, 1)
                                         : (#"{"contradicts":false,"why":"d"}"#, 1, 1) })
        let r = await judge.adjudicate(claim: "c", evidence: "e")
        XCTAssertEqual(r?.verdict, .supported)
    }

    func testAdjudicatorPartialCallFailureReturnsNil() async throws {
        struct StubErr: Error {}
        // confirm succeeds, disprove THROWS → the whole adjudication must fail (both
        // calls are required; a one-sided answer is never a verdict).
        let judge = WikiClaimAdjudicator(apiKey: "k", model: "m", spendGate: nil,
            transport: { sys, _, _ in
                if sys.contains("SUPPORTS") { return (#"{"supports":true,"why":"s"}"#, 1, 1) }
                throw StubErr() })
        let r = await judge.adjudicate(claim: "c", evidence: "e")
        XCTAssertNil(r, "a failed disprove call must drop the whole verdict")
    }

    func testAdjudicatorMalformedOrMissingKeyReturnsNil() async throws {
        let bad = WikiClaimAdjudicator(apiKey: "k", model: "m", spendGate: nil,
            transport: { _, _, _ in ("not json at all", 1, 1) })
        let rBad = await bad.adjudicate(claim: "c", evidence: "e")
        XCTAssertNil(rBad, "non-JSON → nil")
        let missing = WikiClaimAdjudicator(apiKey: "k", model: "m", spendGate: nil,
            transport: { _, _, _ in (#"{"why":"no bool here"}"#, 1, 1) })
        let rMissing = await missing.adjudicate(claim: "c", evidence: "e")
        XCTAssertNil(rMissing, "missing bool key → nil")
    }

    func testMultiURLEvidenceReachesJudge() async throws {
        let store = try makeStore()
        let cid = try await store.upsertClaim(ClaimRow(text: "multi-source claim", firstSeen: now, updatedAt: now))
        let synthID = try await store.upsertSynthesis(SynthesisRow(
            slug: "m", category: "synthesis", title: "m", bodyPath: "inline:m",
            createdAt: now, updatedAt: now, generatedAt: now))
        try await store.linkSynthesisClaim(synthesis: synthID, claim: cid)
        for url in ["https://ex.com/1", "https://ex.com/2"] {
            let d = try await store.upsertDocument(DocumentRow(source: .web, sourceURI: url, bodyPath: "b",
                                                               fetchedAt: now, contentSHA: Data(url.utf8), rawBytes: 1))
            try await store.attachEvidence(ClaimEvidenceRow(claimID: cid, documentID: d))
        }
        let fetcher = MockFetcher(["https://ex.com/1": "FIRST_SOURCE_BODY", "https://ex.com/2": "SECOND_SOURCE_BODY"])
        let judge = MockJudge(["multi-source claim": .supported])
        _ = await AuditTruthEscalation.escalate(store: store, driftedIDs: [synthID], fetcher: fetcher,
                                                judge: judge, limit: 10, maxClaimsPerPage: 5, maxURLsPerClaim: 2)
        let ev = judge.seenEvidence.first ?? ""
        XCTAssertTrue(ev.contains("FIRST_SOURCE_BODY"), "first cited source reaches the judge")
        XCTAssertTrue(ev.contains("SECOND_SOURCE_BODY"), "second cited source ALSO reaches the judge (budgeted, not truncated away)")
    }

    func testMaxClaimsPerPageCaps() async throws {
        let store = try makeStore()
        let (synthID, _) = try await page(store, slug: "p", claims: [
            ("claim one text", "https://ex.com/1"),
            ("claim two text", "https://ex.com/2"),
            ("claim three text", "https://ex.com/3"),
        ])
        let fetcher = MockFetcher(["https://ex.com/1": "e1", "https://ex.com/2": "e2", "https://ex.com/3": "e3"])
        let judge = MockJudge(["claim one text": .supported, "claim two text": .supported, "claim three text": .supported])
        let v = await AuditTruthEscalation.escalate(store: store, driftedIDs: [synthID], fetcher: fetcher,
                                                    judge: judge, limit: 10, maxClaimsPerPage: 2)
        XCTAssertEqual(v.first?.claims.count, 2, "only the first maxClaimsPerPage claims are judged")
        XCTAssertEqual(judge.seen.count, 2)
    }

    func testLimitCapsPages() async throws {
        let store = try makeStore()
        let (s1, _) = try await page(store, slug: "p1", claims: [("a claim one", "https://ex.com/a")])
        let (s2, _) = try await page(store, slug: "p2", claims: [("a claim two", "https://ex.com/b")])
        let fetcher = MockFetcher(["https://ex.com/a": "ea", "https://ex.com/b": "eb"])
        let judge = MockJudge(["a claim one": .supported, "a claim two": .supported])
        let v = await AuditTruthEscalation.escalate(store: store, driftedIDs: [s1, s2], fetcher: fetcher,
                                                    judge: judge, limit: 1)
        XCTAssertEqual(v.count, 1, "limit caps the number of pages escalated")
        XCTAssertEqual(v.first?.pageID, s1, "the cap keeps the first page in order")
    }

    func testPersistEmptyVerdicts() async throws {
        let dir = NSTemporaryDirectory() + "auditempty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = AuditTruthEscalation.persist(vaultRoot: dir, verdicts: [], now: now)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(obj["pages"] as? Int, 0)
        XCTAssertEqual(obj["contradicted"] as? Int, 0)
        XCTAssertEqual((obj["verdicts"] as? [[String: Any]])?.count, 0)
    }
}
