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

    func testApplyPatchMergesRepeatedUpdateSections() throws {
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
        XCTAssertEqual(applied.filter { $0.kind == .update }.count, 1, "merged into one entry")
        XCTAssertEqual(try String(contentsOfFile: root + "/f.txt", encoding: .utf8), "a\nB\nC")
    }
}