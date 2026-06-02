import XCTest
import Foundation
@testable import Supervisor
@testable import IPC
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import WireProtocol

/// Severe tests for ADDONS.md Phase 0 #1 — `SessionSupervisor.collectTurn`, the
/// turn-collection adapter that folds the supervisor's `ServerNotification`
/// stream (correlated to a specific `turnId`) into a `CollectedTurn`.
///
/// The harness drives notifications deterministically: a fake `WorkerLink`
/// whose `sendToSupervisor` pushes `WorkerToSupervisor` events the supervisor's
/// relay fans out to subscribers. We start `collectTurn` concurrently
/// (`async let` / `Task`), wait until its transient sink has subscribed (so no
/// notification races ahead of the subscription), then emit a scripted turn.
/// Every collect passes an explicit `turnId` so the test can emit matching
/// `item/completed` + `turn/completed` notifications (the fold correlates on
/// `(threadId, turnId)` — see the adversarial-review fix).
final class SupervisorTurnCollectorTests: XCTestCase {

    // MARK: harness

    private func makeSupervisor(_ link: WorkerLink) -> SessionSupervisor {
        SessionSupervisor(factory: { _ in WorkerHandle(link: link, task: Task {}) })
    }

    /// Poll an async predicate to a deadline (the shared `eventuallyTrue` is
    /// file-private and takes a *synchronous* predicate; subscriber counts are
    /// actor-isolated, so we need an async one).
    private func waitUntil(_ timeout: Duration = .seconds(2),
                           file: StaticString = #filePath, line: UInt = #line,
                           _ cond: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await cond() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("waitUntil timed out", file: file, line: line)
    }

    private func note(_ n: ServerNotification, on link: WorkerLink) {
        link.sendToSupervisor(.notification(n))
    }

    private func msg(_ tid: ThreadId, _ turn: TurnId, _ item: String, _ text: String) -> ServerNotification {
        .itemCompleted(threadId: tid, turnId: turn, item: .agentMessage(id: ItemId(item), text: text))
    }
    private func done(_ tid: ThreadId, _ turn: TurnId, _ status: TurnStatus) -> ServerNotification {
        .turnCompleted(threadId: tid, turn: TurnObject(id: turn, status: status))
    }

    // MARK: happy path

    func testCompletedTurnReturnsFinalAgentMessage() async throws {
        let tid = ThreadId("thr_completed"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(msg(tid, turn, "i1", "hello world"), on: link)
        note(done(tid, turn, .completed), on: link)

        let r = await result
        XCTAssertEqual(r.text, "hello world")
        XCTAssertEqual(r.status, "completed")
        XCTAssertTrue(r.ok)
        try await waitUntil { await sup.subscriberCount(tid) == 0 }   // no leak after completion
    }

    func testToolOnlyTurnReturnsEmptyTextButCompleted() async throws {
        let tid = ThreadId("thr_toolonly"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "run a tool")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(done(tid, turn, .completed), on: link)   // no agentMessage item

        let r = await result
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.status, "completed")
    }

    func testLastAgentMessageOfTheTurnWins() async throws {
        let tid = ThreadId("thr_multi"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(msg(tid, turn, "i1", "first"), on: link)
        note(msg(tid, turn, "i2", "second"), on: link)
        note(done(tid, turn, .completed), on: link)

        let r = await result
        XCTAssertEqual(r.text, "second")
        XCTAssertEqual(r.status, "completed")
    }

    // MARK: terminal-status mapping

    func testFailedStatusPropagated() async throws {
        let tid = ThreadId("thr_failed"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(done(tid, turn, .failed), on: link)

        let r = await result
        XCTAssertEqual(r.status, "failed")
        XCTAssertFalse(r.ok)
    }

    func testInterruptedStatusPropagated() async throws {
        let tid = ThreadId("thr_interrupted"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(msg(tid, turn, "i1", "partial"), on: link)
        note(done(tid, turn, .interrupted), on: link)

        let r = await result
        XCTAssertEqual(r.text, "partial")
        XCTAssertEqual(r.status, "interrupted")
    }

    /// A non-terminal `turn/completed{inProgress}` must NOT resolve the collect
    /// (the engine contract never emits it, but the fold must not leak it as a
    /// CollectedTurn status). Folding continues until the real completion.
    func testInProgressTurnCompletedIsNotTerminal() async throws {
        let tid = ThreadId("thr_inprogress"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(done(tid, turn, .inProgress), on: link)   // must be ignored
        note(msg(tid, turn, "i1", "real"), on: link)
        note(done(tid, turn, .completed), on: link)

        let r = await result
        XCTAssertEqual(r.text, "real")
        XCTAssertEqual(r.status, "completed")
    }

    // MARK: error semantics

    func testNonRetryableErrorMapsToFailed() async throws {
        let tid = ThreadId("thr_fatal"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(.error(threadId: tid, turnId: turn, willRetry: false,
                    ErrorBody(message: "fatal", codexErrorInfo: "BadRequest")), on: link)

        let r = await result
        XCTAssertEqual(r.status, "failed")
        try await waitUntil { await sup.subscriberCount(tid) == 0 }   // no leak after fatal error
    }

    func testRetryableErrorIsIgnoredThenTurnCompletes() async throws {
        let tid = ThreadId("thr_retry"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        // willRetry == true must NOT terminate the collect.
        note(.error(threadId: tid, turnId: turn, willRetry: true,
                    ErrorBody(message: "transient", codexErrorInfo: "ServerOverloaded")), on: link)
        note(msg(tid, turn, "i1", "recovered"), on: link)
        note(done(tid, turn, .completed), on: link)

        let r = await result
        XCTAssertEqual(r.text, "recovered")
        XCTAssertEqual(r.status, "completed")
    }

    // MARK: turn-id correlation (review fix)

    /// A `turn/completed` for a DIFFERENT turn on the same thread must NOT end
    /// this collect, and a foreign turn's agent message must not clobber ours.
    func testForeignTurnCompletionDoesNotEndCollect() async throws {
        let tid = ThreadId("thr_foreign_turn"); let mine = TurnId("mine")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: mine, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        // Another turn's traffic on the same thread — all must be ignored.
        note(msg(tid, TurnId("other"), "io", "foreign message"), on: link)
        note(done(tid, TurnId("other"), .completed), on: link)
        // Our turn.
        note(msg(tid, mine, "i1", "real"), on: link)
        note(done(tid, mine, .completed), on: link)

        let r = await result
        XCTAssertEqual(r.text, "real")
        XCTAssertEqual(r.status, "completed")
    }

    /// Two concurrent collects on one thread (each its own turnId) must NOT
    /// cross-wire — the broadcast fan-out reaches both sinks, but correlation
    /// keeps each fold on its own turn.
    func testConcurrentCollectsOnSameThreadAreNotCrossWired() async throws {
        let tid = ThreadId("thr_concurrent")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)
        let tA = TurnId("tA"); let tB = TurnId("tB")

        async let ra = sup.collectTurn(cfg, input: [TurnInput(text: "A")], turnId: tA, timeout: .seconds(5))
        async let rb = sup.collectTurn(cfg, input: [TurnInput(text: "B")], turnId: tB, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 2 }
        // Interleave both turns' traffic on the shared broadcast.
        note(msg(tid, tA, "a1", "reply A"), on: link)
        note(msg(tid, tB, "b1", "reply B"), on: link)
        note(done(tid, tB, .completed), on: link)
        note(done(tid, tA, .completed), on: link)

        let a = await ra; let b = await rb
        XCTAssertEqual(a.text, "reply A")
        XCTAssertEqual(b.text, "reply B")
        XCTAssertEqual(a.status, "completed")
        XCTAssertEqual(b.status, "completed")
        try await waitUntil { await sup.subscriberCount(tid) == 0 }
    }

    /// Notifications carrying a DIFFERENT threadId (defensive guard) must be
    /// ignored even when delivered to this sink.
    func testForeignThreadNotificationsIgnored() async throws {
        let tid = ThreadId("thr_self"); let other = ThreadId("thr_other"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        // Same turnId but wrong threadId — must be ignored by the `t == threadId` guard.
        note(msg(other, turn, "io", "foreign thread message"), on: link)
        note(done(other, turn, .completed), on: link)
        note(msg(tid, turn, "i1", "real"), on: link)
        note(done(tid, turn, .completed), on: link)

        let r = await result
        XCTAssertEqual(r.text, "real")
        XCTAssertEqual(r.status, "completed")
    }

    /// Completion is the hard boundary: an agent message relayed AFTER
    /// turn/completed is not folded in.
    func testMessageAfterTurnCompletedIsIgnored() async throws {
        let tid = ThreadId("thr_late"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(5))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(msg(tid, turn, "i1", "early"), on: link)
        note(done(tid, turn, .completed), on: link)
        note(msg(tid, turn, "i2", "late"), on: link)   // after completion → ignored

        let r = await result
        XCTAssertEqual(r.text, "early")
        XCTAssertEqual(r.status, "completed")
    }

    // MARK: teardown / cancellation (review fixes)

    /// Worker death mid-turn (outbound `.finished` → `clearThread`) must return
    /// promptly as "interrupted" — NOT hang to the timeout (proved by the long
    /// timeout: a hang would surface as "timeout", not "interrupted").
    func testWorkerFinishedMidCollectReturnsInterruptedPromptly() async throws {
        let tid = ThreadId("thr_workerdeath"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(60))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(msg(tid, turn, "i1", "partial"), on: link)
        link.sendToSupervisor(.finished)   // worker outbound ends → clearThread → thread/closed

        let r = await result
        XCTAssertEqual(r.status, "interrupted")
        XCTAssertEqual(r.text, "partial")
    }

    /// Cancelling the task awaiting `collectTurn` must tear it down PROMPTLY
    /// (well under the long timeout) and unsubscribe — proving caller
    /// cancellation propagates into the fold.
    func testCallerCancellationUnsubscribesPromptly() async throws {
        let tid = ThreadId("thr_cancel"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        let t = Task { await sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(60)) }
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        t.cancel()
        // Must clean up far sooner than the 60 s timeout.
        try await waitUntil(.seconds(3)) { await sup.subscriberCount(tid) == 0 }
        _ = await t.value
    }

    // MARK: timeout + cleanup

    func testTimeoutWhenNoCompletion() async throws {
        let tid = ThreadId("thr_timeout"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .milliseconds(150))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(msg(tid, turn, "i1", "still working"), on: link)   // partial, never completes

        let r = await result
        XCTAssertEqual(r.status, "timeout")
        try await waitUntil { await sup.subscriberCount(tid) == 0 }   // no leak after timeout
    }

    // MARK: no-leak under repetition

    func testSequentialCollectsDoNotAccumulateSubscribers() async throws {
        let tid = ThreadId("thr_sequential")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        for i in 0..<4 {
            let turn = TurnId("t\(i)")
            async let result = sup.collectTurn(cfg, input: [TurnInput(text: "turn \(i)")], turnId: turn, timeout: .seconds(5))
            try await waitUntil { await sup.subscriberCount(tid) >= 1 }
            note(msg(tid, turn, "i\(i)", "reply \(i)"), on: link)
            note(done(tid, turn, .completed), on: link)
            let r = await result
            XCTAssertEqual(r.text, "reply \(i)")
            try await waitUntil { await sup.subscriberCount(tid) == 0 }   // no accumulation across collects
        }
    }

    // MARK: explicit teardown mid-collect (codex-review fixes)

    /// `quiesce(_:)` mid-collect must return promptly as "interrupted" (it now
    /// delivers thread/closed) — NOT hang to the timeout.
    func testQuiesceMidCollectReturnsInterruptedPromptly() async throws {
        let tid = ThreadId("thr_quiesce"); let turn = TurnId("t1")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make(); let sup = makeSupervisor(link)

        async let result = sup.collectTurn(cfg, input: [TurnInput(text: "hi")], turnId: turn, timeout: .seconds(60))
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }
        note(msg(tid, turn, "i1", "partial"), on: link)
        await sup.quiesce(tid)

        let r = await result
        XCTAssertEqual(r.status, "interrupted")   // prompt (not a 60s timeout); text is best-effort under a racing teardown
        try await waitUntil { await sup.subscriberCount(tid) == 0 }
    }

    /// Rebind replaces the worker but KEEPS subscribers. The old worker's relay
    /// then drains (forceStopWorker finished its link) and calls `clearThread`,
    /// which must NO-OP under the stale-generation guard — so the preserved
    /// subscriber is neither dropped nor sent a spurious thread/closed.
    func testRebindKeepsSubscriberAndDoesNotEmitThreadClosed() async throws {
        let tid = ThreadId("thr_rebind")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let cfg2 = SessionConfig(threadId: tid, cwd: "/tmp/other")
        let link1 = WorkerLink.make(); let link2 = WorkerLink.make()
        let picker = LinkPicker(link1, link2)
        let sup = SessionSupervisor(factory: { _ in WorkerHandle(link: picker.next(), task: Task {}) })
        let probe = NoteCollector()
        _ = await sup.ensureWorker(cfg, onNotification: { probe.add($0) })
        try await waitUntil { await sup.subscriberCount(tid) >= 1 }

        await sup.rebindRemoteEnvironment(tid, newConfig: cfg2)
        // Let the OLD relay drain (its link was finished by forceStopWorker) and
        // reach clearThread — which must no-op under the generation guard.
        try await Task.sleep(for: .milliseconds(60))

        let count = await sup.subscriberCount(tid)
        XCTAssertEqual(count, 1, "rebind must preserve the subscriber")
        XCTAssertFalse(probe.closedThreadIds().contains(tid.raw),
                       "rebind must not emit thread/closed to the preserved subscriber")
    }
}

// MARK: - local test helpers (the ones in ThreadStatusEventsTests are file-private)

/// Hands out a fixed sequence of links across factory calls (last repeats).
private final class LinkPicker: @unchecked Sendable {
    private let lock = NSLock(); private var i = 0; private let links: [WorkerLink]
    init(_ links: WorkerLink...) { self.links = links }
    func next() -> WorkerLink {
        lock.lock(); defer { lock.unlock() }
        let l = links[Swift.min(i, links.count - 1)]; i += 1; return l
    }
}

/// Collects `thread/closed` notifications seen by a subscriber.
private final class NoteCollector: @unchecked Sendable {
    private let lock = NSLock(); private var closed: [String] = []
    func add(_ n: ServerNotification) {
        lock.lock(); defer { lock.unlock() }
        if case let .threadClosed(t) = n { closed.append(t.raw) }
    }
    func closedThreadIds() -> [String] { lock.lock(); defer { lock.unlock() }; return closed }
}
