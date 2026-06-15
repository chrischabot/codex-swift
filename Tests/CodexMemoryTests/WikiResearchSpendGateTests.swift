import XCTest
import Foundation
@testable import codex_memory
import MemoryStore
import MemoryScore
import Tools
import WikiResearch

/// Proves the wiki-research lane's THREE paid surfaces (claim extractor already gated;
/// the web_search swarm + gap reflector now gated) actually admission-control through the
/// shared `wiki-research` SpendGate — adversarially: a zero/exhausted ceiling must short-
/// circuit BEFORE the network call (callCount==0), not merely after.
final class WikiResearchSpendGateTests: XCTestCase {
    private actor CountingWebSearch: WebSearchBackend {
        private(set) var callCount = 0
        let answer: String
        init(answer: String = "Sources:\n- Title https://ex.com/a") { self.answer = answer }
        func search(_ query: String) async -> Result<String, ToolError> {
            callCount += 1
            return .success(answer)
        }
    }

    private func makeStore() throws -> MemoryStore {
        let p = NSTemporaryDirectory() + "rsgate-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: p, embeddingDimension: 8))
    }
    private let twoAngles = [SwarmAngle(role: "r1", focus: "f1"), SwarmAngle(role: "r2", focus: "f2")]

    func testZeroCeilingSwarmShortCircuitsBeforeNetwork() async throws {
        let store = try makeStore()
        let gate = SpendGate(store: store, config: .init(monthlyCeilingUSD: 0, bucket: "wiki-research"))
        let counter = CountingWebSearch()
        let swarm = LiveResearchSwarm(webSearch: counter, perAngle: 4, spendGate: gate)
        let out = try await swarm.gather(topic: "x", mode: .topic, angles: twoAngles, round: 1, gaps: [])
        XCTAssertTrue(out.isEmpty, "zero ceiling → no sources")
        let calls = await counter.callCount
        XCTAssertEqual(calls, 0, "the gate must short-circuit BEFORE any paid web_search")
        let spent = try await gate.monthlySpentUSD()
        XCTAssertEqual(spent, 0)
    }

    func testZeroCeilingReflectorShortCircuits() async throws {
        let store = try makeStore()
        let gate = SpendGate(store: store, config: .init(monthlyCeilingUSD: 0, bucket: "wiki-research"))
        let counter = CountingWebSearch()
        let gaps = try await LiveGapReflector(webSearch: counter, spendGate: gate).reflect(topic: "x", rounds: [])
        XCTAssertTrue(gaps.isEmpty)
        let calls = await counter.callCount
        XCTAssertEqual(calls, 0, "the gap reflector's search is now gated")
    }

    func testBudgetExhaustedMidRunRateLimitsEveryAngle() async throws {
        let store = try makeStore()
        // Pre-load the bucket past a $1 ceiling.
        try await store.recordSpend(SpendRow(ts: Int64(Date().timeIntervalSince1970),
                                             bucket: "wiki-research", units: 1, unitKind: "tokens", costUSD: 5.0))
        let gate = SpendGate(store: store, config: .init(monthlyCeilingUSD: 1, bucket: "wiki-research"))
        let counter = CountingWebSearch()
        let swarm = LiveResearchSwarm(webSearch: counter, perAngle: 4, spendGate: gate)
        let out = try await swarm.gather(topic: "x", mode: .topic, angles: twoAngles, round: 1, gaps: [])
        XCTAssertTrue(out.isEmpty)
        let calls = await counter.callCount
        XCTAssertEqual(calls, 0, "month-to-date over ceiling rate-limits every angle")
    }

    func testSpendIsRecordedOnSuccessSoSwarmCannotSpinUnbounded() async throws {
        let store = try makeStore()
        let gate = SpendGate(store: store, config: .init(
            monthlyCeilingUSD: 100, bucket: "wiki-research", inputUSDPerMTok: 0.15))
        let counter = CountingWebSearch()
        let swarm = LiveResearchSwarm(webSearch: counter, perAngle: 4, spendGate: gate)
        _ = try await swarm.gather(topic: "x", mode: .topic, angles: twoAngles, round: 1, gaps: [])
        let calls = await counter.callCount
        XCTAssertEqual(calls, 2, "two angles → two metered searches")
        let spent = try await gate.monthlySpentUSD()
        XCTAssertGreaterThan(spent, 0, "the token-less web_search is metered as a flat per-call cost")
    }

    func testNilGateBackCompatStillSearches() async throws {
        // The defaulted property must NOT break the old memberwise init or the ungated path.
        let counter = CountingWebSearch()
        let swarm = LiveResearchSwarm(webSearch: counter, perAngle: 4)   // no spendGate arg
        let out = try await swarm.gather(topic: "x", mode: .topic,
                                         angles: [SwarmAngle(role: "r", focus: "f")], round: 1, gaps: [])
        XCTAssertFalse(out.isEmpty, "ungated path still returns sources")
        let calls = await counter.callCount
        XCTAssertEqual(calls, 1)
    }
}
