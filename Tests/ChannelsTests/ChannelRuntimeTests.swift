import XCTest
import Foundation
@testable import Channels

/// Severe tests for the ADDONS #1 channel runtime: durable per-conversation
/// thread mapping, the supervisor host's routing + owner-flag threading, and the
/// ChannelManager's start/stop/restart-with-backoff supervision.
final class ChannelRuntimeTests: XCTestCase {

    private func tmp() -> String {
        NSTemporaryDirectory() + "channels-\(UUID().uuidString)/threads.json"
    }

    // MARK: ChannelThreadStore

    func testThreadStoreStableAndNamespaced() async {
        let store = ChannelThreadStore(path: tmp())
        let a1 = await store.threadId(channelId: "tg", conversationId: "chat-1")
        let a2 = await store.threadId(channelId: "tg", conversationId: "chat-1")
        let b = await store.threadId(channelId: "tg", conversationId: "chat-2")
        let c = await store.threadId(channelId: "gmail", conversationId: "chat-1")
        XCTAssertEqual(a1, a2, "same conversation → same thread")
        XCTAssertNotEqual(a1, b, "different conversations → different threads")
        XCTAssertNotEqual(a1, c, "same conversationId on a different channel is namespaced apart")
        let count = await store.count()
        XCTAssertEqual(count, 3)
    }

    func testThreadStoreKeyDoesNotCollide() async {
        let store = ChannelThreadStore(path: tmp())
        let t1 = await store.threadId(channelId: "a/b", conversationId: "c")
        let t2 = await store.threadId(channelId: "a", conversationId: "b/c")
        XCTAssertNotEqual(t1, t2, "ambiguous channel/conversation concatenation must not collide into one thread")
    }

    func testThreadStoreDurableAcrossReload() async {
        let path = tmp()
        let s1 = ChannelThreadStore(path: path)
        let t = await s1.threadId(channelId: "tg", conversationId: "chat-9")
        let s2 = ChannelThreadStore(path: path)
        let t2 = await s2.threadId(channelId: "tg", conversationId: "chat-9")
        XCTAssertEqual(t, t2, "thread mapping survives a restart")
        let existing = await s2.existingThreadId(channelId: "tg", conversationId: "never")
        XCTAssertNil(existing, "an unseen conversation has no thread without minting")
    }

    // MARK: SupervisorChannelHost

    func testHostRoutesThroughThreadStoreAndRunner() async {
        let store = ChannelThreadStore(path: tmp(), mint: { "fixed-thread" })
        let recorder = RunnerRecorder()
        let host = SupervisorChannelHost(threadStore: store, runTurn: recorder.run)
        let reply = await host.deliver(InboundMessage(
            channelId: "tg", conversationId: "c1", senderId: "u1", senderIsOwner: true, text: "hello"))
        XCTAssertEqual(reply.text, "ran:hello")
        XCTAssertEqual(reply.status, "completed")
        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.threadId, "fixed-thread", "uses the durable threadId")
        XCTAssertEqual(calls.first?.owner, true, "the SERVER-stamped owner flag is threaded through")
        XCTAssertEqual(calls.first?.text, "hello")
    }

    func testHostNonOwnerFlagThreaded() async {
        let store = ChannelThreadStore(path: tmp())
        let recorder = RunnerRecorder()
        let host = SupervisorChannelHost(threadStore: store, runTurn: recorder.run)
        _ = await host.deliver(InboundMessage(
            channelId: "tg", conversationId: "c1", senderId: "stranger", senderIsOwner: false, text: "hi"))
        let calls = await recorder.calls()
        XCTAssertEqual(calls.first?.owner, false, "a non-owner sender is threaded as non-owner")
    }

    // MARK: ChannelManager

    func testManagerStartStop() async {
        let host = RecordingHost()
        let mgr = ChannelManager(host: host, sleep: { _ in try? await Task.sleep(for: .milliseconds(1)) })
        let ch = FlakyChannel(id: "tg", failures: 0)
        await mgr.register(ch)
        await mgr.start("tg")
        await waitFor { await mgr.status("tg")?.state == .running }
        let running = await mgr.status("tg")?.state
        XCTAssertEqual(running, .running)
        await mgr.stop("tg")
        let stopped = await mgr.status("tg")?.state
        let chStopped = await ch.stoppedObserved()
        XCTAssertEqual(stopped, .stopped)
        XCTAssertTrue(chStopped, "stop() reaches the transport")
    }

    func testManagerRestartsFailingChannelWithBackoff() async {
        let host = RecordingHost()
        let mgr = ChannelManager(host: host, sleep: { _ in try? await Task.sleep(for: .milliseconds(1)) })
        let ch = FlakyChannel(id: "tg", failures: 2)
        await mgr.register(ch)
        await mgr.start("tg")
        // Wait on the deterministic start COUNT (2 failures + 1 success), not the
        // status, which momentarily flickers to .running on each spawn before a
        // fast failure flips it back to .backoff.
        await waitFor { await ch.startsObserved() >= 3 }
        let starts = await ch.startsObserved()
        XCTAssertEqual(starts, 3, "restarted exactly past 2 failures into a running state")
        await waitFor { await mgr.status("tg")?.state == .running }
        let state = await mgr.status("tg")?.state
        XCTAssertEqual(state, .running)
        await mgr.stop("tg")
    }

    func testManagerStopDuringBackoffDoesNotRestart() async {
        let host = RecordingHost()
        let mgr = ChannelManager(host: host, sleep: { _ in try? await Task.sleep(for: .milliseconds(120)) })
        let ch = FlakyChannel(id: "tg", failures: 1_000)   // always fails
        await mgr.register(ch)
        await mgr.start("tg")
        try? await Task.sleep(for: .milliseconds(20))
        await mgr.stop("tg")
        let startsAtStop = await ch.startsObserved()
        try? await Task.sleep(for: .milliseconds(250))
        let startsLater = await ch.startsObserved()
        let state = await mgr.status("tg")?.state
        XCTAssertEqual(startsLater, startsAtStop, "a stopped channel must not be restarted by a pending backoff")
        XCTAssertEqual(state, .stopped)
    }

    func testManagerDoubleStartIsIdempotent() async {
        let host = RecordingHost()
        let mgr = ChannelManager(host: host, sleep: { _ in try? await Task.sleep(for: .milliseconds(1)) })
        let ch = FlakyChannel(id: "tg", failures: 0)
        await mgr.register(ch)
        await mgr.start("tg")
        await waitFor { await mgr.status("tg")?.state == .running }
        await mgr.start("tg")   // no-op on a running channel
        try? await Task.sleep(for: .milliseconds(30))
        let starts = await ch.startsObserved()
        XCTAssertEqual(starts, 1, "a double-start does not spawn a second run loop")
        await mgr.stop("tg")
    }

    /// The HIGH fix: while stop() is mid-teardown (.stopping, blocked in the
    /// transport's stop()), a concurrent start() must be BARRIERED — it must not
    /// spawn a new run task that races the old task's / transport's cleanup.
    func testStartDuringStoppingIsBarriered() async {
        let host = RecordingHost()
        let gate = Gate()
        let mgr = ChannelManager(host: host, sleep: { _ in try? await Task.sleep(for: .milliseconds(1)) })
        let ch = BlockingStopChannel(id: "tg", stopGate: gate)
        await mgr.register(ch)
        await mgr.start("tg")
        await waitFor { await mgr.status("tg")?.state == .running }
        // Begin a stop that blocks in channel.stop().
        async let stopping: Void = mgr.stop("tg")
        await waitFor { await mgr.status("tg")?.state == .stopping }
        // A start() during the .stopping barrier must be a no-op.
        await mgr.start("tg")
        let stateDuring = await mgr.status("tg")?.state
        let startsDuring = await ch.startsObserved()
        XCTAssertEqual(stateDuring, .stopping, "start() during .stopping is barriered")
        XCTAssertEqual(startsDuring, 1, "no second run task spawned during transport teardown")
        // Release the teardown → stop settles to .stopped.
        await gate.release()
        _ = await stopping
        let finalState = await mgr.status("tg")?.state
        XCTAssertEqual(finalState, .stopped)
    }

    // MARK: helpers

    private func waitFor(_ cond: @Sendable () async -> Bool, timeoutMs: Int = 2000) async {
        var waited = 0
        while waited < timeoutMs {
            if await cond() { return }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
    }
}

private enum ChannelTestError: Error { case boom }

private actor RunnerRecorder {
    struct Call: Sendable { let threadId: String; let owner: Bool; let text: String }
    private var recorded: [Call] = []
    func calls() -> [Call] { recorded }
    nonisolated var run: SupervisorChannelHost.TurnRunner {
        { [self] threadId, owner, text in
            await self.record(Call(threadId: threadId, owner: owner, text: text))
            return ChannelReply(text: "ran:\(text)", status: "completed")
        }
    }
    private func record(_ c: Call) { recorded.append(c) }
}

private actor RecordingHost: ChannelHost {
    private(set) var delivered: [InboundMessage] = []
    func deliver(_ msg: InboundMessage) async -> ChannelReply {
        delivered.append(msg)
        return ChannelReply(text: "ok", status: "completed")
    }
}

/// A channel whose `start` throws the first `failures` times, then blocks
/// (running) until cancelled — models a transport that flaps then stabilises.
private actor FlakyChannel: Channel {
    nonisolated let id: String
    private let failures: Int
    private var starts = 0
    private var stopped = false
    init(id: String, failures: Int) { self.id = id; self.failures = failures }

    func start(_ host: any ChannelHost) async throws {
        starts += 1
        if starts <= failures { throw ChannelTestError.boom }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }
    func stop() async { stopped = true }
    func startsObserved() -> Int { starts }
    func stoppedObserved() -> Bool { stopped }
}

/// A one-shot gate: `wait()` blocks until `release()`.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let w = waiters; waiters = []
        for c in w { c.resume() }
    }
}

/// A channel whose `stop()` blocks until a gate is released — exercises the
/// `.stopping` barrier window.
private actor BlockingStopChannel: Channel {
    nonisolated let id: String
    private let stopGate: Gate
    private var starts = 0
    init(id: String, stopGate: Gate) { self.id = id; self.stopGate = stopGate }
    func start(_ host: any ChannelHost) async throws {
        starts += 1
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }
    func stop() async { await stopGate.wait() }
    func startsObserved() -> Int { starts }
}
