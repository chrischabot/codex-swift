import XCTest
import Foundation
@testable import Tools
@testable import InfraPrimitives

private actor IntervalRecorder {
    struct Interval { var name: String; var start: Double; var end: Double }
    private(set) var intervals: [Interval] = []
    func mark(_ name: String, _ start: Double, _ end: Double) {
        intervals.append(Interval(name: name, start: start, end: end))
    }
    func overlaps(_ a: String, _ b: String) -> Bool {
        guard let x = intervals.first(where: { $0.name == a }),
              let y = intervals.first(where: { $0.name == b }) else { return false }
        return x.start < y.end && y.start < x.end
    }
}

private struct TimedTool: Tool {
    let name: String
    let parallelSafe: Bool
    let rec: IntervalRecorder
    let durationMs: Int
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let s = MonotonicClock.now()
        try await Task.sleep(for: .milliseconds(durationMs))
        let e = MonotonicClock.now()
        await rec.mark(name, s, e)
        return ToolResult(callId: call.callId, output: name, success: true, truncated: false)
    }
}

final class ToolsGatingTests: XCTestCase {

    func testParallelSafeToolsOverlap() async {
        let rec = IntervalRecorder()
        let router = ToolRouter(limits: Limits())
        await router.register(TimedTool(name: "p1", parallelSafe: true, rec: rec, durationMs: 120))
        await router.register(TimedTool(name: "p2", parallelSafe: true, rec: rec, durationMs: 120))
        async let a = router.dispatch(ToolCall(callId: "1", name: "p1", argumentsJSON: "{}"),
                                      cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        async let b = router.dispatch(ToolCall(callId: "2", name: "p2", argumentsJSON: "{}"),
                                      cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        _ = await [a, b]
        let overlap = await rec.overlaps("p1", "p2")
        XCTAssertTrue(overlap, "parallel-safe tools must run concurrently")
    }

    func testSerialToolIsExclusive() async {
        let rec = IntervalRecorder()
        let router = ToolRouter(limits: Limits())
        await router.register(TimedTool(name: "s", parallelSafe: false, rec: rec, durationMs: 120))
        await router.register(TimedTool(name: "p", parallelSafe: true, rec: rec, durationMs: 120))
        async let a = router.dispatch(ToolCall(callId: "1", name: "s", argumentsJSON: "{}"),
                                      cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        async let b = router.dispatch(ToolCall(callId: "2", name: "p", argumentsJSON: "{}"),
                                      cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        _ = await [a, b]
        let overlap = await rec.overlaps("s", "p")
        XCTAssertFalse(overlap, "a serial tool must not overlap any other tool")
    }

    // Audit tools-router finding 1: upstream's wait handler has no
    // `supports_parallel_tool_calls` override (wait.rs:31-205), so it falls back
    // to the trait default `false` (tool_executor.rs:50-52) and takes the
    // exclusive write side of the per-turn parallel gate. The Swift port must
    // declare `wait_agent` serial, not parallel-safe.
    func testWaitAgentIsSerial() {
        XCTAssertFalse(WaitAgentTool().parallelSafe,
            "wait_agent must be serial (upstream trait default) — finding 1")
    }

    func testWaitAgentDoesNotOverlapOtherTools() async {
        let rec = IntervalRecorder()
        let router = ToolRouter(limits: Limits())
        // A wait-like serial tool must take the exclusive side and NOT overlap a
        // concurrently dispatched parallel-safe tool.
        await router.register(TimedTool(name: "wait_agent",
                                        parallelSafe: WaitAgentTool().parallelSafe,
                                        rec: rec, durationMs: 120))
        await router.register(TimedTool(name: "p", parallelSafe: true, rec: rec, durationMs: 120))
        async let a = router.dispatch(ToolCall(callId: "1", name: "wait_agent", argumentsJSON: "{}"),
                                      cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        async let b = router.dispatch(ToolCall(callId: "2", name: "p", argumentsJSON: "{}"),
                                      cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        _ = await [a, b]
        let overlap = await rec.overlaps("wait_agent", "p")
        XCTAssertFalse(overlap, "wait_agent (serial) must not overlap a parallel tool")
    }

    // Audit tools-router finding 2: upstream emits the model-visible tool list in
    // deterministic executor-collection (registration) order, NOT alphabetically
    // (spec_plan.rs:122-148). `specs()` must preserve registration insertion
    // order rather than impose a flat alphabetical sort.
    func testSpecsPreserveRegistrationOrder() async {
        let rec = IntervalRecorder()
        let router = ToolRouter(limits: Limits())
        // Register in a deliberately non-alphabetical order.
        await router.register(TimedTool(name: "zeta", parallelSafe: true, rec: rec, durationMs: 1))
        await router.register(TimedTool(name: "alpha", parallelSafe: true, rec: rec, durationMs: 1))
        await router.register(TimedTool(name: "mike", parallelSafe: true, rec: rec, durationMs: 1))
        let names = await router.specs().map { $0.name }
        XCTAssertEqual(names, ["zeta", "alpha", "mike"],
            "specs() must preserve registration order, not sort alphabetically — finding 2")
    }

    func testSpecsAppendActivatedDeferredInActivationOrder() async {
        let rec = IntervalRecorder()
        let router = ToolRouter(limits: Limits())
        await router.register(TimedTool(name: "shell", parallelSafe: true, rec: rec, durationMs: 1))
        await router.registerDeferred(TimedTool(name: "d_beta", parallelSafe: true, rec: rec, durationMs: 1))
        await router.registerDeferred(TimedTool(name: "d_alpha", parallelSafe: true, rec: rec, durationMs: 1))
        // Activate in non-alphabetical order; deferred tools append after the
        // directly-visible ones, in activation order.
        await router.activate(["d_beta", "d_alpha"])
        let names = await router.specs().map { $0.name }
        XCTAssertEqual(names, ["shell", "d_beta", "d_alpha"],
            "activated deferred tools append in activation order after registered tools")
    }

    func testApplyPatchRejectsPathTraversal() {
        let ap = ApplyPatch()
        let escape = """
        *** Begin Patch
        *** Add File: ../../etc/evil
        +pwned
        *** End Patch
        """
        XCTAssertThrowsError(try ap.parse(escape)) {
            guard case ApplyPatchError.unsafePath = $0 else { return XCTFail("expected unsafePath") }
        }
        let abs = "*** Begin Patch\n*** Delete File: /etc/passwd\n*** End Patch"
        XCTAssertThrowsError(try ap.parse(abs)) {
            guard case ApplyPatchError.unsafePath = $0 else { return XCTFail("expected unsafePath") }
        }
    }

    func testApplyPatchRepeatedUpdateSectionsBecomeSeparateHunks() throws {
        let root = NSTemporaryDirectory() + "ap-merge-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "a\nb\nc".write(toFile: root + "/f.txt", atomically: true, encoding: .utf8)
        let patch = """
        *** Begin Patch
        *** Update File: f.txt
        @@
         a
        -b
        +B
        *** Update File: f.txt
        @@
        -c
        +C
        *** End Patch
        """
        let ap = ApplyPatch()
        let applied = try ap.apply(patch, root: root)
        // Upstream parity (apply-patch parser.rs:314-365): each `*** Update File:`
        // block becomes its OWN Hunk::UpdateFile — repeated sections for the same
        // path are NOT merged into a single entry.
        XCTAssertEqual(applied.filter { $0.kind == .update }.count, 2,
                       "each Update block is a separate hunk (no merge)")
        // Upstream guarantees a trailing newline on the updated file (lib.rs:681-683).
        XCTAssertEqual(try String(contentsOfFile: root + "/f.txt", encoding: .utf8), "a\nB\nC\n")
    }
}