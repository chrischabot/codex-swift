import XCTest
import Foundation
@testable import InfraPrimitives
@testable import WireProtocol
@testable import ProtocolModel
@testable import ModelClient
@testable import Tools
@testable import Persistence
@testable import HarnessCore

final class AdversarialTests: XCTestCase {

    // MARK: ingress overload storm → exact -32001, others unaffected

    func testIngressOverloadStormYieldsRetryableError() async throws {
        let ch = BoundedChannel<Int>(capacity: 8, policy: .rejectNewest)
        var rejected = 0
        for i in 0..<100_000 {
            do { try await ch.send(i) } catch is OverloadError { rejected += 1 }
        }
        XCTAssertGreaterThan(rejected, 90_000)
        let rc = await ch.rejectedCount
        XCTAssertEqual(rc, rejected)
        // Channel still usable for a legitimate consumer afterward.
        let v = await ch.receive()
        XCTAssertNotNil(v)
    }

    // MARK: garbage / wrong-kind wire input never crashes the codec

    func testWireCodecSurvivesHostileInput() {
        let codec = WireCodec(maxInboundBytes: 4096)
        let hostile = [
            Data(),
            Data("{".utf8),
            Data(repeating: 0xFF, count: 4096),
            Data(#"{"id":1,"result":{"a":{"b":{"c":[1,2,3]}}}}"#.utf8),
            Data(#"{"method":"x","params":{"deeply":{"nested":{"x":{"y":{"z":1}}}}}}"#.utf8),
            Data("\u{0000}\u{0001}\u{0002}".utf8),
        ]
        for h in hostile { _ = try? codec.decode(h) }      // must not trap
        // A valid message still decodes after the hostile barrage.
        let ok = try? codec.decode(Data(#"{"method":"initialized"}"#.utf8))
        if case .notification(let n)? = ok { XCTAssertEqual(n.method, "initialized") }
        else { XCTFail("codec broken after hostile input") }
    }

    // MARK: tool fan-out cap never exceeded under a dispatch storm

    func testToolFanoutCapIsEnforcedUnderStorm() async {
        var lim = Limits(); lim.maxConcurrentTools = 4
        let router = ToolRouter(limits: lim)
        let probe = ConcurrencyProbe()
        await router.register(ConcurrencyTool(probe: probe))
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<200 {
                g.addTask {
                    _ = await router.dispatch(
                        ToolCall(callId: "\(i)", name: "probe", argumentsJSON: "{}"),
                        cwd: "/tmp", deadline: .fromNow(.seconds(10)))
                }
            }
        }
        let peak = await probe.peak
        XCTAssertLessThanOrEqual(peak, 4, "fan-out semaphore must bound concurrency to the cap")
        XCTAssertGreaterThan(peak, 1, "but tools should still run in parallel up to the cap")
    }

    // MARK: mid-stream terminal model failure is isolated; session recovers

    func testTerminalModelFailureIsolatedThenRecovers() async throws {
        let home = NSTemporaryDirectory() + "adv-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // First turn: mid-stream terminal failure. Second turn: success.
        let model = MockModelClient([
            MockScenario([.created, .delta(itemId: "m", "partial"),
                          .failTerminal("provider exploded")]),
            .hello("recovered after failure"),
        ])
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: "/w"),
                                   model: model, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let events = await engine.events()
        // Drive two turns; collect until the second turn completes.
        let collector = Task { () -> [ServerNotification] in
            var out: [ServerNotification] = []
            var completed = 0
            for await n in events {
                out.append(n)
                if case .turnCompleted = n { completed += 1; if completed == 2 { break } }
            }
            return out
        }
        await engine.submit(.startTurn(input: [TurnInput(text: "first")], model: nil))
        try await Task.sleep(for: .milliseconds(200))
        await engine.submit(.startTurn(input: [TurnInput(text: "second")], model: nil))
        let evs = await collector.value

        let completions = evs.compactMap { n -> TurnStatus? in
            if case .turnCompleted(_, let t) = n { return t.status }; return nil
        }
        XCTAssertEqual(completions.count, 2)
        XCTAssertEqual(completions[0], .failed, "failed turn is isolated")
        XCTAssertEqual(completions[1], .completed, "session recovers and serves the next turn")
        XCTAssertTrue(evs.contains {
            if case .itemCompleted(_, _, let i) = $0, case .agentMessage(_, let t) = i {
                return t == "recovered after failure"
            }; return false
        })
    }

    // MARK: unbounded-growth attempt stays bounded (coalescing ring)

    func testCoalescingRingNeverGrowsUnbounded() async {
        let ring = CoalescingRing(maxBytes: 4096)
        for _ in 0..<1_000_000 { await ring.push("xxxxxxxxxx") }   // 1e7 bytes attempted
        let pending = await ring.pendingBytes()
        XCTAssertLessThanOrEqual(pending, 4096, "ring must bound memory under flood")
        await ring.markTerminal()
        let d = await ring.drain()
        XCTAssertTrue(d.isTerminal, "terminal is never coalesced away")
        XCTAssertGreaterThan(d.coalescedBytes, 0)
    }
}

actor ConcurrencyProbe {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
struct ConcurrencyTool: Tool {
    let name = "probe"; let parallelSafe = true
    let probe: ConcurrencyProbe
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        await probe.enter()
        try await Task.sleep(for: .milliseconds(30))
        await probe.leave()
        return ToolResult(callId: call.callId, output: "ok", success: true, truncated: false)
    }
}