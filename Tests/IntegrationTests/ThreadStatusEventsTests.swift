import XCTest
import Foundation
@testable import Supervisor
@testable import IPC
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import WireProtocol

/// Covers the `app-server-events` status-machinery findings: thread/status/changed
/// (active/idle/waitingOnApproval/waitingOnUserInput transitions), serverRequest/resolved
/// broadcast on approval resolution, and thread/closed on idle unload. Mirrors
/// upstream ThreadWatchManager semantics (app-server/src/thread_status.rs).
final class ThreadStatusEventsTests: XCTestCase {

    // MARK: - thread/status/changed

    func testThreadBecomesIdleOnLoadThenActiveOnTurnStartAndIdleOnComplete() async throws {
        let tid = ThreadId("thr_status_turn")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make()
        let supervisor = SessionSupervisor(factory: { _ in
            WorkerHandle(link: link, task: Task {})
        })
        let probe = StatusProbe()
        _ = await supervisor.ensureWorker(
            cfg, onNotification: { probe.append($0) })

        // Loading a fresh quiescent worker → idle (notLoaded -> idle).
        try await eventuallyTrue { probe.statuses() == [.idle] }

        let turn = TurnObject(id: TurnId("turn-1"), status: .inProgress)
        link.sendToSupervisor(.notification(.turnStarted(threadId: tid, turn: turn)))
        try await eventuallyTrue {
            probe.statuses().last == .active(activeFlags: [])
        }

        let done = TurnObject(id: TurnId("turn-1"), status: .completed)
        link.sendToSupervisor(.notification(.turnCompleted(threadId: tid, turn: done)))
        try await eventuallyTrue { probe.statuses().last == .idle }

        // Only real transitions are emitted: idle, active, idle.
        XCTAssertEqual(probe.statuses(), [.idle, .active(activeFlags: []),
                                          .idle])
    }

    func testApprovalRequestRaisesWaitingOnApprovalAndResolutionClearsIt() async throws {
        let tid = ThreadId("thr_status_approval")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make()
        let supervisor = SessionSupervisor(factory: { _ in
            WorkerHandle(link: link, task: Task {})
        })
        let probe = StatusProbe()
        _ = await supervisor.ensureWorker(
            cfg, onNotification: { probe.append($0) })
        try await eventuallyTrue { probe.statuses() == [.idle] }

        let approval = ServerRequest.commandApproval(
            .string("appr-1"),
            CommandApprovalParams(threadId: tid, turnId: TurnId("turn-1"),
                                  itemId: ItemId("item-1")))
        link.sendToSupervisor(.serverRequest(approval))
        try await eventuallyTrue {
            probe.statuses().last == .active(activeFlags: [.waitingOnApproval])
        }

        await supervisor.deliverServerResponse(
            "appr-1", result: .object(["decision": .string("approved")]))
        try await eventuallyTrue { probe.statuses().last == .idle }

        // serverRequest/resolved must be broadcast on resolution.
        XCTAssertTrue(probe.resolvedIds().contains("appr-1"),
                      "resolution must broadcast serverRequest/resolved")
    }

    func testToolUserInputRaisesWaitingOnUserInputFlag() async throws {
        let tid = ThreadId("thr_status_userinput")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make()
        let supervisor = SessionSupervisor(factory: { _ in
            WorkerHandle(link: link, task: Task {})
        })
        let probe = StatusProbe()
        _ = await supervisor.ensureWorker(
            cfg, onNotification: { probe.append($0) })
        try await eventuallyTrue { probe.statuses() == [.idle] }

        let userInput = ServerRequest.toolRequestUserInput(
            .string("ui-1"),
            ToolRequestUserInputParams(threadId: tid, turnId: TurnId("turn-1"),
                                       itemId: ItemId("item-1"), questions: []))
        link.sendToSupervisor(.serverRequest(userInput))
        try await eventuallyTrue {
            probe.statuses().last == .active(activeFlags: [.waitingOnUserInput])
        }
    }

    func testStatusNeutralRequestDoesNotChangeStatus() async throws {
        let tid = ThreadId("thr_status_neutral")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make()
        let supervisor = SessionSupervisor(factory: { _ in
            WorkerHandle(link: link, task: Task {})
        })
        let probe = StatusProbe()
        _ = await supervisor.ensureWorker(
            cfg, requestAttestation: true, onNotification: { probe.append($0) },
            onServerRequest: { _ in })
        try await eventuallyTrue { probe.statuses() == [.idle] }

        // attestation/generate is status-neutral (no active guard upstream).
        link.sendToSupervisor(.serverRequest(.attestationGenerate(.string("att-1"), .init())))
        // Give the relay a moment; status must remain idle (no new transition).
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.statuses(), [.idle])
    }

    // MARK: - error vs. stream-error (willRetry) status semantics

    // app-server-events finding 1: upstream (bespoke_event_handling.rs:883-942)
    // mutates thread status (running=false, has_system_error=true → SystemError)
    // ONLY on the terminal EventMsg::Error (willRetry == false). The transient
    // EventMsg::StreamError handler (willRetry == true) explicitly does NOT touch
    // thread status — those are intermediate retry states, so the thread must
    // stay Active across retries.

    func testTerminalErrorFlipsThreadToSystemError() async throws {
        let tid = ThreadId("thr_status_terminal_error")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make()
        let supervisor = SessionSupervisor(factory: { _ in
            WorkerHandle(link: link, task: Task {})
        })
        let probe = StatusProbe()
        _ = await supervisor.ensureWorker(
            cfg, onNotification: { probe.append($0) })
        try await eventuallyTrue { probe.statuses() == [.idle] }

        // Start a turn so the thread is Active before the error arrives.
        let turn = TurnObject(id: TurnId("turn-1"), status: .inProgress)
        link.sendToSupervisor(.notification(.turnStarted(threadId: tid, turn: turn)))
        try await eventuallyTrue {
            probe.statuses().last == .active(activeFlags: [])
        }

        // Terminal error (willRetry == false) → SystemError.
        link.sendToSupervisor(.notification(.error(
            threadId: tid, turnId: TurnId("turn-1"), willRetry: false,
            ErrorBody(message: "fatal"))))
        try await eventuallyTrue { probe.statuses().last == .systemError }
    }

    func testTransientStreamErrorKeepsThreadActive() async throws {
        let tid = ThreadId("thr_status_stream_error")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make()
        let supervisor = SessionSupervisor(factory: { _ in
            WorkerHandle(link: link, task: Task {})
        })
        let probe = StatusProbe()
        _ = await supervisor.ensureWorker(
            cfg, onNotification: { probe.append($0) })
        try await eventuallyTrue { probe.statuses() == [.idle] }

        let turn = TurnObject(id: TurnId("turn-1"), status: .inProgress)
        link.sendToSupervisor(.notification(.turnStarted(threadId: tid, turn: turn)))
        try await eventuallyTrue {
            probe.statuses().last == .active(activeFlags: [])
        }

        // Transient stream error (willRetry == true) must NOT touch status:
        // the thread stays Active and never bounces to SystemError.
        link.sendToSupervisor(.notification(.error(
            threadId: tid, turnId: TurnId("turn-1"), willRetry: true,
            ErrorBody(message: "transient stream hiccup"))))
        // Give the relay a moment; a retryable error emits no new transition.
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.statuses(), [.idle, .active(activeFlags: [])],
                       "retryable stream errors must leave the thread Active (no SystemError transition)")

        // A subsequent terminal error still flips to SystemError, proving the
        // gate is on willRetry and not a blanket suppression.
        link.sendToSupervisor(.notification(.error(
            threadId: tid, turnId: TurnId("turn-1"), willRetry: false,
            ErrorBody(message: "fatal after retries"))))
        try await eventuallyTrue { probe.statuses().last == .systemError }
    }

    // MARK: - thread/closed

    func testIdleUnloadEmitsThreadClosedToFormerSubscriber() async throws {
        let tid = ThreadId("thr_closed_idle")
        let cfg = SessionConfig(threadId: tid, cwd: "/tmp")
        let link = WorkerLink.make()
        // Tight idle/heartbeat windows so the idle-unload + quiesce-fallback
        // timers fire quickly. The in-memory link never answers quiesce, so the
        // fallback forceStop path runs and emits thread/closed.
        var limits = Limits()
        limits.idleUnload = .seconds(1)
        limits.heartbeatInterval = .milliseconds(1)
        limits.watchdogMissedHeartbeats = 1
        let supervisor = SessionSupervisor(factory: { _ in
            WorkerHandle(link: link, task: Task {})
        }, limits: limits)
        let probe = StatusProbe()
        let sinkId = await supervisor.ensureWorker(
            cfg, onNotification: { probe.append($0) })

        await supervisor.unsubscribe(tid, sinkId)
        try await eventuallyTrue(timeout: .seconds(8)) {
            probe.closedIds().contains(tid.raw)
        }
    }
}

// MARK: - helpers

private final class StatusProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var statusList: [ThreadStatus] = []
    private var resolved: [String] = []
    private var closed: [String] = []

    func append(_ n: ServerNotification) {
        lock.lock(); defer { lock.unlock() }
        switch n {
        case .threadStatusChanged(_, let status): statusList.append(status)
        case .serverRequestResolved(_, let rid): resolved.append(rid.description)
        case .threadClosed(let tid): closed.append(tid.raw)
        default: break
        }
    }

    func statuses() -> [ThreadStatus] { lock.lock(); defer { lock.unlock() }; return statusList }
    func resolvedIds() -> [String] { lock.lock(); defer { lock.unlock() }; return resolved }
    func closedIds() -> [String] { lock.lock(); defer { lock.unlock() }; return closed }
}

private func eventuallyTrue(timeout: Duration = .seconds(2),
                            _ predicate: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("condition was not met before timeout")
}
