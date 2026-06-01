import XCTest
import Foundation
import ProtocolModel
import WireProtocol
@testable import Workflows

final class WorkflowExtrasTests: XCTestCase {

    // MARK: progress notifier (debounced)

    func testProgressNotifierBatchesAndEmitsRaw() async {
        final class Sink: @unchecked Sendable {
            let lock = NSLock(); var notes: [ServerNotification] = []
            func add(_ n: ServerNotification) { lock.lock(); notes.append(n); lock.unlock() }
            var all: [ServerNotification] { lock.lock(); defer { lock.unlock() }; return notes }
        }
        let sink = Sink()
        let notifier = WorkflowProgressNotifier(runId: "wf_aaaaaaaaaaaa", taskId: "task_wf_aaaaaaaaaaaa",
                                                sink: { sink.add($0) })
        await notifier.enqueue(.phase(index: 0, title: "Scope", kind: nil))
        await notifier.enqueue(.log(message: "hi"))
        await notifier.enqueue(.agent(index: 1, label: "a", phaseIndex: 0, phaseTitle: "Scope",
                                      state: .start, cached: false, skipped: false, error: nil,
                                      tokens: 0, toolCalls: 0, durationMs: 0, model: nil,
                                      attempt: 1, promptPreview: "p"))
        // allow the debounce flush to fire
        try? await Task.sleep(for: .milliseconds(60))
        await notifier.flushNow()

        let raws = sink.all.compactMap { note -> (String, JSONValue)? in
            if case .raw(let m, let p) = note { return (m, p) }; return nil
        }
        XCTAssertFalse(raws.isEmpty)
        XCTAssertTrue(raws.allSatisfy { $0.0 == "workflow/progress" })
        // The batched events should total the 3 we enqueued across flushes.
        var total = 0
        for (_, p) in raws {
            if case .object(let o) = p, case .array(let evs)? = o["events"] { total += evs.count }
        }
        XCTAssertEqual(total, 3)
    }

    // MARK: worktree helper (no side effects outside a repo)

    func testWorktreeCreateReturnsNilOutsideRepo() async {
        let tmp = NSTemporaryDirectory() + "wfwt-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let handle = await WorkflowWorktree.create(runId: "wf_bbbbbbbbbbbb", index: 0, cwd: tmp)
        XCTAssertNil(handle, "should not create a worktree outside a git repo")
    }

    func testWorktreeIsolationNotice() {
        let notice = WorkflowWorktree.isolationNotice(path: "/tmp/wt", mainCwd: "/repo")
        XCTAssertTrue(notice.contains("/tmp/wt"))
        XCTAssertTrue(notice.contains("/repo"))
        XCTAssertTrue(notice.lowercased().contains("worktree"))
    }
}
