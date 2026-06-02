import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import ProtocolModel
@testable import InfraPrimitives

/// Runaway-loop guard: a turn whose model emits the IDENTICAL tool call every
/// iteration (no progress) is bounded by `maxIdenticalToolRepeats`, while a turn
/// that varies its calls is NOT tripped. Deterministic (MockModelClient).
final class IdenticalToolLoopGuardTests: XCTestCase {

    /// Always-succeeds no-op tool so each iteration dispatches cleanly.
    private struct NoopTool: Tool {
        let name = "noop"
        let parallelSafe = true
        func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
            ToolResult(callId: call.callId, output: "ok", success: true, truncated: false)
        }
    }

    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "idloop-" + UUID().uuidString
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

    private func makeEngine(_ mock: MockModelClient, limits: Limits,
                            home: String, tid: ThreadId) async throws -> SessionEngine {
        let store = try ThreadStore(codexHome: home, limits: Limits())
        _ = try await store.create(SessionConfig(threadId: tid, cwd: home, approvalPolicy: .never))
        let router = ToolRouter(limits: limits)
        await router.register(NoopTool())
        return SessionEngine(
            config: SessionConfig(threadId: tid, cwd: home, approvalPolicy: .never),
            model: mock, store: store, router: router, limits: limits)
    }

    // POSITIVE: identical tool call every iteration → guard fires on the
    // (maxIdenticalToolRepeats + 1)th iteration. maxSamplingIterationsPerTurn
    // defaults high + the deadline is long, so the identical guard is the only
    // thing that can fire here.
    func testGuardFiresOnIdenticalRepeats() async throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        var lim = Limits()
        lim.maxIdenticalToolRepeats = 3
        let scenario = MockScenario([
            .created,
            .toolCall(callId: "c", name: "noop", argumentsJSON: #"{"x":1}"#),
            .completeContinue(responseId: "r", tokens: 1),
        ])
        let mock = MockModelClient(repeating: scenario, times: 50, limits: lim)
        let tid = ThreadId("thr_idloop_pos")
        let engine = try await makeEngine(mock, limits: lim, home: home, tid: tid)
        await engine.start()
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await collect(engine)

        XCTAssertEqual(lastStatus(evs), .failed, "an identical-tool-call loop must fail the turn")
        // The guard must fire on the (N+1)th identical iteration — NOT run to the
        // mock's 50 scenarios, and NOT some other cap (iterations=1M, deadline long).
        let calls = await mock.capturedRequests().count
        XCTAssertEqual(calls, lim.maxIdenticalToolRepeats + 1,
                       "guard fires on the (maxIdenticalToolRepeats+1)th identical iteration; got \(calls) model calls")
    }

    // NEGATIVE: varying tool args each iteration → signature differs → the
    // counter resets every iteration → the guard NEVER fires even at a low
    // threshold; the turn ends normally. Proves no false positive on legit work.
    func testGuardDoesNotFireOnVaryingCalls() async throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        var lim = Limits()
        lim.maxIdenticalToolRepeats = 3
        var scenarios: [MockScenario] = []
        for i in 0..<8 {     // 8 > threshold, but each call is DIFFERENT
            scenarios.append(MockScenario([
                .created,
                .toolCall(callId: "c\(i)", name: "noop", argumentsJSON: "{\"x\":\(i)}"),
                .completeContinue(responseId: "r\(i)", tokens: 1),
            ]))
        }
        scenarios.append(.hello("done"))   // final endTurn
        let mock = MockModelClient(scenarios, limits: lim)
        let tid = ThreadId("thr_idloop_neg")
        let engine = try await makeEngine(mock, limits: lim, home: home, tid: tid)
        await engine.start()
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await collect(engine)

        XCTAssertEqual(lastStatus(evs), .completed,
                       "varying tool calls must NOT trip the identical-loop guard")
        let calls = await mock.capturedRequests().count
        XCTAssertEqual(calls, 9, "all 8 varying iterations + the final ran; got \(calls)")
    }
}
