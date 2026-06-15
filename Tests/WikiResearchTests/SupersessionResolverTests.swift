import XCTest
@testable import WikiResearch
@testable import MemoryStore

/// Severe coverage for the auto-supersession resolver (gbrain.md Wave 3.23): the
/// pure verdict→action mapping (incl. the ≥0.8 auto-threshold gate and
/// older-claim selection) and the store transitions it drives.
final class SupersessionResolverTests: XCTestCase {
    private func claim(_ id: Int64, _ text: String, firstSeen: Int64) -> ClaimRow {
        ClaimRow(id: id, text: text, firstSeen: firstSeen, updatedAt: firstSeen)
    }
    private func pair(_ v: ContradictionVerdict, _ c: Double) -> JudgedPair {
        JudgedPair(verdict: v, confidence: c, reasoning: "t")
    }

    // MARK: - pure resolve

    func testSupersessionArchivesOlderKeepsNewer() {
        let older = claim(1, "X is CEO", firstSeen: 100)
        let newer = claim(2, "X stepped down", firstSeen: 200)
        // Order of args must not matter — older is always archived.
        XCTAssertEqual(SupersessionResolver.resolve(pair(.temporalSupersession, 0.9), a: older, b: newer),
                       .archiveOlder(keep: 2, archive: 1))
        XCTAssertEqual(SupersessionResolver.resolve(pair(.temporalSupersession, 0.9), a: newer, b: older),
                       .archiveOlder(keep: 2, archive: 1))
    }

    func testLowConfidenceSupersessionFlagsNotArchives() {
        let a = claim(1, "a", firstSeen: 100); let b = claim(2, "b", firstSeen: 200)
        let action = SupersessionResolver.resolve(pair(.temporalSupersession, 0.79), a: a, b: b)
        guard case .flagForReview = action else { return XCTFail("expected flagForReview, got \(action)") }
    }

    func testGenuineContradictionMarksBoth() {
        let a = claim(1, "a", firstSeen: 100); let b = claim(2, "b", firstSeen: 100)
        XCTAssertEqual(SupersessionResolver.resolve(pair(.contradiction, 0.95), a: a, b: b),
                       .markBothContradicted(1, 2))
    }

    func testLowConfidenceContradictionFlags() {
        let a = claim(1, "a", firstSeen: 100); let b = claim(2, "b", firstSeen: 100)
        guard case .flagForReview = SupersessionResolver.resolve(pair(.contradiction, 0.5), a: a, b: b)
        else { return XCTFail("low-confidence contradiction must flag, not mutate") }
    }

    func testNoContradictionSkips() {
        let a = claim(1, "a", firstSeen: 100); let b = claim(2, "b", firstSeen: 100)
        XCTAssertEqual(SupersessionResolver.resolve(pair(.noContradiction, 0.99), a: a, b: b), .skip)
    }

    func testRegressionEvolutionArtifactAlwaysFlag() {
        let a = claim(1, "a", firstSeen: 100); let b = claim(2, "b", firstSeen: 200)
        for v in [ContradictionVerdict.temporalRegression, .temporalEvolution, .negationArtifact] {
            guard case .flagForReview = SupersessionResolver.resolve(pair(v, 0.99), a: a, b: b)
            else { return XCTFail("\(v) should flag for review") }
        }
    }

    // MARK: - apply (store transitions via the previously-dead primitives)

    private func makeStore() throws -> MemoryStore {
        let db = NSTemporaryDirectory() + "supersession-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: db, embeddingDimension: 8))
    }

    func testApplyArchiveOlderTransitionsAndLinks() async throws {
        let store = try makeStore()
        let now: Int64 = 1_800_000_000
        let keep = try await store.upsertClaim(ClaimRow(text: "X stepped down", status: .active,
                                                        firstSeen: 200, updatedAt: 200))
        let archive = try await store.upsertClaim(ClaimRow(text: "X is CEO", status: .active,
                                                           firstSeen: 100, updatedAt: 100))
        let mutated = try await SupersessionResolver.apply(
            .archiveOlder(keep: keep, archive: archive), to: store, now: now)
        XCTAssertTrue(mutated)
        let archivedClaim = try await store.claim(id: archive)
        let keptClaim = try await store.claim(id: keep)
        XCTAssertEqual(archivedClaim?.status, .archived)
        XCTAssertEqual(keptClaim?.status, .active, "the kept claim stays active")
        let linked = try await store.contradictingClaims(of: keep)
        XCTAssertTrue(linked.contains { $0.id == archive }, "the pair must be linked")
    }

    func testApplyMarkBothContradicted() async throws {
        let store = try makeStore()
        let now: Int64 = 1_800_000_000
        let x = try await store.upsertClaim(ClaimRow(text: "rev is up", status: .active, firstSeen: 1, updatedAt: 1))
        let y = try await store.upsertClaim(ClaimRow(text: "rev is down", status: .active, firstSeen: 1, updatedAt: 1))
        _ = try await SupersessionResolver.apply(.markBothContradicted(x, y), to: store, now: now)
        let cx = try await store.claim(id: x)
        let cy = try await store.claim(id: y)
        XCTAssertEqual(cx?.status, .contradicted)
        XCTAssertEqual(cy?.status, .contradicted)
    }

    func testApplyFlagForReviewLinksButDoesNotMutateStatus() async throws {
        let store = try makeStore()
        let now: Int64 = 1_800_000_000
        let x = try await store.upsertClaim(ClaimRow(text: "a", status: .active, firstSeen: 1, updatedAt: 1))
        let y = try await store.upsertClaim(ClaimRow(text: "b", status: .active, firstSeen: 1, updatedAt: 1))
        let mutated = try await SupersessionResolver.apply(
            .flagForReview(x, y, reason: "evolution"), to: store, now: now)
        XCTAssertFalse(mutated, "flagForReview records a link but changes no status")
        let cx = try await store.claim(id: x)
        XCTAssertEqual(cx?.status, .active)
        let linked = try await store.contradictingClaims(of: x)
        XCTAssertTrue(linked.contains { $0.id == y })
    }

    func testApplySkipDoesNothing() async throws {
        let store = try makeStore()
        let x = try await store.upsertClaim(ClaimRow(text: "a", status: .active, firstSeen: 1, updatedAt: 1))
        let mutated = try await SupersessionResolver.apply(.skip, to: store, now: 1)
        XCTAssertFalse(mutated)
        let cx = try await store.claim(id: x)
        XCTAssertEqual(cx?.status, .active)
    }
}
