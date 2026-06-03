import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import ProtocolModel
@testable import InfraPrimitives

/// Per-response stall guard: a retryable stream error — a connect-time transient
/// OR a mid-stream idle-timeout (the machine slept mid-stream / the connection
/// stalled) — re-attempts the same sampling with a fresh connection instead of
/// failing the turn, bounded by streamMaxRetries CONSECUTIVE failures.
/// Deterministic (MockModelClient).
final class StreamStallRetryTests: XCTestCase {

    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "stall-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private func lastStatus(_ evs: [ServerNotification]) -> TurnStatus? {
        for ev in evs.reversed() { if case .turnCompleted(_, let t) = ev { return t.status } }
        return nil
    }
    private func collect(_ e: SessionEngine, timeout: Duration = .seconds(20)) async -> [ServerNotification] {
        let s = await e.events()
        let c = Task { () -> [ServerNotification] in
            var o: [ServerNotification] = []
            for await ev in s { o.append(ev); if case .turnCompleted = ev { break } }
            return o
        }
        let t = Task { try? await Task.sleep(for: timeout); c.cancel() }
        let r = await c.value; t.cancel(); return r
    }
    private func run(_ mock: MockModelClient, limits: Limits) async throws -> ([ServerNotification], Int) {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let tid = ThreadId("thr_stall_" + UUID().uuidString.prefix(6).lowercased())
        _ = try await store.create(SessionConfig(threadId: tid, cwd: home, approvalPolicy: .never))
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: home, approvalPolicy: .never),
            model: mock, store: store, router: ToolRouter(limits: limits), limits: limits)
        await engine.start()
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await collect(engine)
        let calls = await mock.capturedRequests().count
        return (evs, calls)
    }

    // Connect/open-time transient (5xx / dropped connection) → retry → recover.
    func testStreamOpenStallRetryRecovers() async throws {
        let mock = MockModelClient([
            MockScenario([.failRetryable("transient 503")]),
            MockScenario([.failRetryable("transient 503")]),
            .hello("done"),
        ])
        let (evs, calls) = try await run(mock, limits: Limits())
        XCTAssertEqual(lastStatus(evs), .completed, "a recovered stall must complete the turn")
        XCTAssertEqual(calls, 3, "2 retries + 1 success; got \(calls) model calls")
    }

    // The commute-sleep case: events start, then the stream goes silent
    // mid-stream (idle-timeout) → retry with a fresh connection → recover.
    func testMidStreamStallRetryRecovers() async throws {
        let mock = MockModelClient([
            MockScenario([.created, .delta(itemId: "m", "partial…"),
                          .failRetryable("idle timeout waiting for SSE")]),
            .hello("done"),
        ])
        let (evs, calls) = try await run(mock, limits: Limits())
        XCTAssertEqual(lastStatus(evs), .completed,
                       "a mid-stream stall (laptop slept) must retry + complete, not fail the turn")
        XCTAssertEqual(calls, 2, "1 mid-stream stall + 1 success; got \(calls)")
    }

    // A persistently broken stream must still terminate after streamMaxRetries.
    func testStreamStallExhaustionFails() async throws {
        var lim = Limits(); lim.streamMaxRetries = 2
        let mock = MockModelClient(repeating: MockScenario([.failRetryable("perma 503")]),
                                   times: 20, limits: lim)
        let (evs, calls) = try await run(mock, limits: lim)
        XCTAssertEqual(lastStatus(evs), .failed, "a persistently broken stream must eventually fail")
        XCTAssertEqual(calls, lim.streamMaxRetries + 1,
                       "streamMaxRetries retries then fail; got \(calls)")
    }
}
