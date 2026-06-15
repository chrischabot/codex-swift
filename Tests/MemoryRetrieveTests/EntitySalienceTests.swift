import XCTest
@testable import MemoryRetrieve

/// Severe coverage for the zero-LLM entity-salience extractor (gbrain.md Wave 4.28).
final class EntitySalienceTests: XCTestCase {
    private func w(_ pairs: [(String, String)]) -> [SalienceTurn] {
        pairs.map { SalienceTurn(role: $0.0, text: $0.1) }
    }

    func testExtractsProperNounsAndHandles() {
        let cands = EntitySalience.extract(window: w([
            ("user", "Tell me about Alice Smith and @sama"),
        ]))
        let surfaces = Set(cands.map(\.surface))
        XCTAssertTrue(surfaces.contains("Alice Smith"))
        XCTAssertTrue(surfaces.contains("@sama"))
    }

    func testRecencyDominates() {
        // Same entity in an early vs a late turn → later ranks higher.
        let cands = EntitySalience.extract(window: w([
            ("user", "Bob Jones did a thing"),
            ("assistant", "noted"),
            ("user", "What about Carol Lee"),
        ]))
        let bob = cands.first { $0.surface == "Bob Jones" }!
        let carol = cands.first { $0.surface == "Carol Lee" }!
        XCTAssertGreaterThan(carol.weight, bob.weight, "more-recent mention ranks higher")
    }

    func testUserMentionBeatsAssistantIntroduced() {
        // Same recency/frequency; only the user-vs-assistant role differs.
        let cands = EntitySalience.extract(window: w([
            ("user", "Acme Corp is interesting"),
            ("assistant", "Also consider Globex Inc"),
        ]))
        let acme = cands.first { $0.surface == "Acme Corp" }
        let globex = cands.first { $0.surface == "Globex Inc" }
        XCTAssertNotNil(acme); XCTAssertNotNil(globex)
        XCTAssertTrue(acme!.userMention)
        XCTAssertFalse(globex!.userMention)
    }

    func testFrequencyCappedAtFour() {
        let many = (0..<10).map { _ in ("user", "Zeta Corp again") }
        let cands = EntitySalience.extract(window: w(many))
        let zeta = cands.first { $0.surface == "Zeta Corp" }!
        // recency (1.0) + capped freq (4·0.1=0.4) + userBonus (0.15) = 1.55
        XCTAssertEqual(zeta.weight, 1.0 + 0.4 + 0.15, accuracy: 1e-9)
        XCTAssertEqual(zeta.occurrences, 10, "occurrences still counted, just capped in the weight")
    }

    func testMaxCandidatesCap() {
        let text = (0..<30).map { "Name\($0)X Surname\($0)Y" }.joined(separator: " ")
        let cands = EntitySalience.extract(window: w([("user", text)]), maxCandidates: 5)
        XCTAssertLessThanOrEqual(cands.count, 5)
    }

    func testSuppressesSentenceStartStopwords() {
        let cands = EntitySalience.extract(window: w([("user", "The weather is fine today")]))
        XCTAssertFalse(cands.contains { $0.surface == "The" })
    }

    func testDeterministicOrder() {
        let win = w([("user", "Acme Corp and Beta LLC and Acme Corp")])
        let a = EntitySalience.extract(window: win)
        let b = EntitySalience.extract(window: win)
        XCTAssertEqual(a, b)
    }

    func testEmptyWindow() {
        XCTAssertEqual(EntitySalience.extract(window: []), [])
    }
}
