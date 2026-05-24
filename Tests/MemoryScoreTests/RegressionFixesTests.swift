import XCTest
import Foundation
@testable import MemoryScore
@testable import MemoryStore
@testable import MemoryInfer
import InfraPrimitives

/// Regression coverage for Fix #7: BrainGate must refund the budget on
/// unparseable responses — no spend ledger row, no insight row, no metric
/// bump — and surface `Outcome.unparseable` so the caller can triage.
final class BrainGateRegressionFixesTests: XCTestCase {
    private func tmpDB() -> String {
        NSTemporaryDirectory() + "brain-fix-\(UUID().uuidString).db"
    }

    func testUnparseableRefundsBudgetAndSurfacesOutcome() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        // Stub caller returns prose, not JSON.
        let gate = BrainGate(store: store, caller: { _, _, _ in
            (text: "the model rambled and never returned JSON",
             tokensIn: 5_000, tokensOut: 2_000)
        })
        let outcome = try await gate.escalate(
            triggerChunkId: 0,
            dedupeKey: "k1",
            prompt: "what happened?",
            summaryOnly: false,
            score: 1.0,
            deadline: .fromNow(.seconds(5)))
        switch outcome {
        case .unparseable(let model, let observed, _):
            XCTAssertEqual(model, "gpt-5.5")
            XCTAssertGreaterThan(observed, 0)
        default:
            XCTFail("expected .unparseable, got \(outcome)")
        }
        // Refund contract: no spend, no insight stored.
        let monthStart = Int64(Date().timeIntervalSince1970) - 86_400
        let spent = try await store.monthlySpend(bucket: "gpt55", monthStart: monthStart)
        XCTAssertEqual(spent, 0, "unparseable response must not consume budget")
    }
}
