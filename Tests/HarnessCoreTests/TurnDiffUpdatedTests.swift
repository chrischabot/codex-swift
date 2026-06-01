import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives

private func tduTmp(_ tag: String) -> String {
    let p = NSTemporaryDirectory() + "tdu-\(tag)-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

private func tduCollect(_ e: SessionEngine,
                        timeout: Duration = .seconds(30)) async -> [ServerNotification] {
    let s = await e.events()
    let c = Task { () -> [ServerNotification] in
        var o: [ServerNotification] = []
        for await ev in s { o.append(ev); if case .turnCompleted = ev { break } }
        return o
    }
    let t = Task { try? await Task.sleep(for: timeout); c.cancel() }
    let r = await c.value; t.cancel(); return r
}

/// Integration coverage for the `turn/diff/updated` notification: a turn whose
/// model emits an `apply_patch` tool call must accumulate the committed change
/// into the per-turn `TurnDiffTracker` and emit a `turn/diff/updated`
/// notification carrying the cumulative Git-format unified diff.
final class TurnDiffUpdatedTests: XCTestCase {

    func testApplyPatchTurnEmitsTurnDiffUpdated() async throws {
        let home = tduTmp("home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = tduTmp("w"); defer { try? FileManager.default.removeItem(atPath: work) }

        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                writableRoots: [work]))
        let router = ToolRouter(limits: Limits())
        await router.register(ApplyPatchTool(sandbox: sb))

        // Add File: a.txt with `foo` (escaped for embedding in tool-call JSON).
        let patch = "*** Begin Patch\\n*** Add File: a.txt\\n+foo\\n*** End Patch"
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "apply_patch",
                                    argumentsJSON: "{\"patch\":\"\(patch)\"}"),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            .hello("done"),
        ])

        // policy .never with cwd inside writable roots → patch proceeds
        // sandboxed without a prompt.
        let cfg = SessionConfig(threadId: ThreadId.generate(), cwd: work,
                                approvalPolicy: .never,
                                writableRoots: [work])
        _ = try? await store.create(cfg)
        let eng = SessionEngine(config: cfg, model: model, store: store,
                                router: router, limits: Limits())
        await eng.start()
        let col = Task { await tduCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value

        // The file was written.
        XCTAssertTrue(FileManager.default.fileExists(atPath: work + "/a.txt"))

        // Three turn/diff/updated emits, all carrying the same cumulative
        // unified diff:
        //   (1) the per-apply_patch incremental emit from `ingestApplyPatchDelta`
        //       (request 1's tool drain), then
        //   (2) request 1's end-of-sampling-request consolidated re-emit
        //       (turn.rs:2306-2314, armed by `should_emit_turn_diff` on
        //       `ResponseEvent::Completed`), then
        //   (3) request 2's (the `.hello` follow-up) end-of-request re-emit:
        //       `should_emit_turn_diff` is armed on every completed sampling
        //       request, and the `TurnDiffTracker` is turn-scoped, so the
        //       still-tracked `+foo` diff is re-emitted even though request 2
        //       committed no new patch.
        // The consolidated re-emits are functionally duplicates but preserve
        // exact event-stream parity with upstream.
        let diffs: [(ThreadId, TurnId, String)] = evs.compactMap {
            if case .turnDiffUpdated(let tid, let turnId, let diff) = $0 {
                return (tid, turnId, diff)
            }
            return nil
        }
        XCTAssertEqual(diffs.count, 3,
                       "expected per-apply_patch emit + a consolidated re-emit per completed sampling request")
        for (tid, _, diff) in diffs {
            XCTAssertEqual(tid, cfg.threadId)
            XCTAssertTrue(diff.hasPrefix("diff --git a/a.txt b/a.txt\n"),
                          "unexpected diff header: \(diff)")
            XCTAssertTrue(diff.contains("new file mode 100644"))
            XCTAssertTrue(diff.contains("+foo"))
        }
        // All emits carry the identical cumulative diff.
        XCTAssertEqual(diffs[0].2, diffs[1].2)
        XCTAssertEqual(diffs[1].2, diffs[2].2)
    }

    /// Upstream maps a FAILED apply_patch (`ToolEventFailure::Output`) to
    /// `TurnDiffTrackerUpdate::Invalidate`: the tracker is flipped invalid and —
    /// because a prior diff existed — a CLEARED `turn/diff/updated` (diff "") is
    /// still emitted so the client drops its stale accumulated diff. Verify a
    /// successful apply_patch followed by a failing one in the same turn emits
    /// first the cumulative diff, then the cleared diff.
    func testFailedApplyPatchInvalidatesAndClearsTurnDiff() async throws {
        let home = tduTmp("home2"); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: Limits())
        let work = tduTmp("w2"); defer { try? FileManager.default.removeItem(atPath: work) }

        let sb = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                writableRoots: [work]))
        let router = ToolRouter(limits: Limits())
        await router.register(ApplyPatchTool(sandbox: sb))

        // First patch: add a.txt (succeeds → accumulates a diff).
        let addPatch = "*** Begin Patch\\n*** Add File: a.txt\\n+foo\\n*** End Patch"
        // Second patch: update a file that does not exist (fails → invalidates).
        let badPatch = "*** Begin Patch\\n*** Update File: ghost.txt\\n@@\\n-old\\n+new\\n*** End Patch"
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "apply_patch",
                                    argumentsJSON: "{\"patch\":\"\(addPatch)\"}"),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .toolCall(callId: "c2", name: "apply_patch",
                                    argumentsJSON: "{\"patch\":\"\(badPatch)\"}"),
                          .completeContinue(responseId: "r2", tokens: 1)]),
            .hello("done"),
        ])

        let cfg = SessionConfig(threadId: ThreadId.generate(), cwd: work,
                                approvalPolicy: .never,
                                writableRoots: [work])
        _ = try? await store.create(cfg)
        let eng = SessionEngine(config: cfg, model: model, store: store,
                                router: router, limits: Limits())
        await eng.start()
        let col = Task { await tduCollect(eng) }
        await eng.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        let evs = await col.value

        let diffs: [String] = evs.compactMap {
            if case .turnDiffUpdated(_, _, let diff) = $0 { return diff }
            return nil
        }
        // Request 1 (successful add): per-apply_patch incremental emit (+foo)
        // then the end-of-request consolidated re-emit (also +foo,
        // turn.rs:2306). Request 2 (failing update): the invalidate path emits
        // a single cleared diff (""); the end-of-request re-emit is suppressed
        // because `getUnifiedDiff()` returns nil after invalidation. So the
        // ordered stream is [+foo, +foo, ""].
        XCTAssertEqual(diffs.count, 3,
                       "expected accumulate + consolidated re-emit, then a cleared (invalidate) emit, got \(diffs)")
        XCTAssertTrue(diffs[0].contains("+foo"),
                      "first emit is the per-apply_patch cumulative diff: \(diffs[0])")
        XCTAssertTrue(diffs[1].contains("+foo"),
                      "second emit is the end-of-request consolidated re-emit: \(diffs[1])")
        XCTAssertEqual(diffs[0], diffs[1],
                       "the consolidated re-emit duplicates the per-apply_patch diff")
        XCTAssertEqual(diffs.last, "",
                       "failed apply_patch must clear the tracked diff (invalidate)")
    }
}
