import XCTest
import Foundation
@testable import MemoryScore
import MemoryStore
import InfraPrimitives

/// Coverage for the generic frontier spend gate: cost accounting, ledger
/// recording, the soft monthly ceiling, and the rate-limited (no-call) path.
final class SpendGateTests: XCTestCase {
    private func tmpStore() throws -> (MemoryStore, String) {
        let path = NSTemporaryDirectory() + "spendgate-\(UUID().uuidString).db"
        return (try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8)), path)
    }

    func testRunRecordsTokenCostAndReturnsReceipt() async throws {
        let (store, path) = try tmpStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        let gate = SpendGate(store: store, config: .init(monthlyCeilingUSD: 100, bucket: "t",
                                                         inputUSDPerMTok: 10, outputUSDPerMTok: 20))
        let out = try await gate.run(prompt: "p", model: "m") { _, _, _ in
            ("answer", 1_000_000, 500_000)   // 1M in, 0.5M out
        }
        guard case .ran(let r) = out else { return XCTFail("expected ran, got \(out)") }
        XCTAssertEqual(r.text, "answer")
        // cost = 1M/1M*10 + 0.5M/1M*20 = 10 + 10 = 20
        XCTAssertEqual(r.costUSD, 20, accuracy: 1e-9)
        let spent = try await gate.monthlySpentUSD()
        XCTAssertEqual(spent, 20, accuracy: 1e-9)
        let remaining = try await gate.remainingBudgetUSD()
        XCTAssertEqual(remaining, 80, accuracy: 1e-9)
    }

    func testRateLimitedDoesNotCall() async throws {
        let (store, path) = try tmpStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        let gate = SpendGate(store: store, config: .init(monthlyCeilingUSD: 5, bucket: "t",
                                                         inputUSDPerMTok: 10, outputUSDPerMTok: 0))
        // First call spends 10 (> ceiling 5) → ledgered.
        _ = try await gate.run(prompt: "p", model: "m") { _, _, _ in ("x", 1_000_000, 0) }
        // Second call: already over ceiling → rate-limited, and the closure must NOT run.
        let flag = CallFlag()
        let out = try await gate.run(prompt: "p", model: "m") { _, _, _ in flag.set(); return ("y", 1, 1) }
        XCTAssertFalse(flag.wasCalled, "the gate must not invoke the call when rate-limited")
        guard case .rateLimited(_, let spent, let ceiling) = out else { return XCTFail("expected rateLimited, got \(out)") }
        XCTAssertEqual(spent, 10, accuracy: 1e-9)
        XCTAssertEqual(ceiling, 5, accuracy: 1e-9)
    }

    func testBucketsAreIsolated() async throws {
        let (store, path) = try tmpStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        let a = SpendGate(store: store, config: .init(monthlyCeilingUSD: 100, bucket: "a", inputUSDPerMTok: 10, outputUSDPerMTok: 0))
        let b = SpendGate(store: store, config: .init(monthlyCeilingUSD: 100, bucket: "b", inputUSDPerMTok: 10, outputUSDPerMTok: 0))
        _ = try await a.run(prompt: "p", model: "m") { _, _, _ in ("x", 1_000_000, 0) }  // spends 10 on bucket a
        let aSpent = try await a.monthlySpentUSD()
        let bSpent = try await b.monthlySpentUSD()
        XCTAssertEqual(aSpent, 10, accuracy: 1e-9)
        XCTAssertEqual(bSpent, 0, accuracy: 1e-9)   // bucket b untouched
    }

    func testConcurrentReservationBoundsCeiling() async throws {
        let (store, path) = try tmpStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        // reservationUSD == ceiling → a single in-flight call reserves the whole budget,
        // so a concurrent second call must be rate-limited even though spend=0.
        let gate = SpendGate(store: store, config: .init(monthlyCeilingUSD: 10, bucket: "t",
                                                         inputUSDPerMTok: 0, outputUSDPerMTok: 0,
                                                         reservationUSD: 10))
        let aInside = Latch()
        let hold = Latch()
        let aTask = Task {
            try await gate.run(prompt: "a", model: "m") { _, _, _ in
                await aInside.release()   // A is now inside the call → has reserved
                await hold.wait()         // stay in-flight until released
                return ("a", 0, 0)
            }
        }
        await aInside.wait()              // ensure A reserved before B runs
        let b = try await gate.run(prompt: "b", model: "m") { _, _, _ in ("b", 0, 0) }
        XCTAssertTrue(b.isRateLimited, "B must be rate-limited by A's in-flight reservation")
        await hold.release()
        let aOut = try await aTask.value
        XCTAssertNotNil(aOut.receipt)     // A completed and released its reservation
        // After A finishes, a fresh call is admitted again (reservation released).
        let c = try await gate.run(prompt: "c", model: "m") { _, _, _ in ("c", 0, 0) }
        XCTAssertNotNil(c.receipt)
    }

    func testPropagatesCallError() async throws {
        let (store, path) = try tmpStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        let gate = SpendGate(store: store, config: .init(monthlyCeilingUSD: 100, bucket: "t"))
        struct Boom: Error {}
        do {
            _ = try await gate.run(prompt: "p", model: "m") { _, _, _ in throw Boom() }
            XCTFail("error should propagate")
        } catch is Boom { /* expected */ }
        // a thrown call records no spend
        let spent = try await gate.monthlySpentUSD()
        XCTAssertEqual(spent, 0, accuracy: 1e-9)
    }
}

/// One-shot latch for deterministic concurrency tests.
private actor Latch {
    private var released = false
    private var conts: [CheckedContinuation<Void, Never>] = []
    func release() { released = true; for c in conts { c.resume() }; conts.removeAll() }
    func wait() async { if released { return }; await withCheckedContinuation { conts.append($0) } }
}

/// Sendable mutable flag for asserting a @Sendable closure did/didn't run.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    func set() { lock.lock(); called = true; lock.unlock() }
    var wasCalled: Bool { lock.lock(); defer { lock.unlock() }; return called }
}
