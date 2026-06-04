import XCTest
import Foundation
import os
@testable import DeliveryCore
@testable import InfraPrimitives

/// Severe tests for ADDONS.md Phase 0 #4 — `DurableDeliveryQueue`: at-least-once
/// delivery with send-intent-before-I/O durability, crash replay, backoff,
/// retry-exhaustion dead-lettering, and idempotency dedup.
final class DeliveryCoreTests: XCTestCase {

    // MARK: harness

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "delivery-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Backoff with ~0 delay so retry tests don't actually sleep.
    private let fastBackoff = Backoff(base: .milliseconds(1), maxDelay: .milliseconds(2))

    /// Executor that returns a scripted sequence of outcomes (last repeats),
    /// recording every call.
    private actor ScriptedExecutor: DeliveryExecutor {
        private let outcomes: [DeliveryOutcome]
        private(set) var calls: [OutboundJob] = []
        init(_ outcomes: [DeliveryOutcome]) { self.outcomes = outcomes }
        func deliver(_ job: OutboundJob) async -> DeliveryOutcome {
            let idx = Swift.min(calls.count, outcomes.count - 1)
            calls.append(job)
            return outcomes[idx]
        }
        func count() -> Int { calls.count }
    }

    private final class FakeClock: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: 0.0)
        func advance(_ d: Double) { state.withLock { $0 += d } }
        var fn: @Sendable () -> Double { { [state] in state.withLock { $0 } } }
    }

    private func job(_ id: String, key: String? = nil) -> OutboundJob {
        OutboundJob(id: id, target: "ntfy:test", payload: Data("hi".utf8), idempotencyKey: key)
    }

    private func writeLog(_ dir: String, _ jobs: [OutboundJob]) {
        let enc = JSONEncoder()
        var data = Data()
        for j in jobs { data.append((try? enc.encode(j)) ?? Data()); data.append(0x0A) }
        try? data.write(to: URL(fileURLWithPath: dir + "/queue.jsonl"))
    }

    private func states(_ dir: String, _ id: String) -> [DeliveryState] {
        let dec = JSONDecoder()
        guard let text = try? String(contentsOfFile: dir + "/queue.jsonl", encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? dec.decode(OutboundJob.self, from: Data($0.utf8)) }
            .filter { $0.id == id }.map(\.state)
    }

    // MARK: happy / retry / failure

    func testAckedOnFirstAttempt() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        let r = await q.enqueue(job("j1"))
        let n = await exec.count()
        XCTAssertEqual(r.finalState, .acked)
        XCTAssertEqual(r.attempts, 1)
        XCTAssertEqual(n, 1)
    }

    func testTransientRetriesThenAck() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ScriptedExecutor([.retry, .retry, .acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        let r = await q.enqueue(job("j1"))
        let n = await exec.count()
        XCTAssertEqual(r.finalState, .acked)
        XCTAssertEqual(r.attempts, 3)
        XCTAssertEqual(n, 3)
    }

    func testPermanentFailureDeadLettersImmediately() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ScriptedExecutor([.permanentFailure])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        let r = await q.enqueue(job("j1"))
        XCTAssertEqual(r.finalState, .failed)
        XCTAssertEqual(r.attempts, 1)
    }

    func testRetriesExhaustedFail() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ScriptedExecutor([.retry])   // always transient
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff, maxAttempts: 3)
        let r = await q.enqueue(job("j1"))
        let n = await exec.count()
        XCTAssertEqual(r.finalState, .failed)
        XCTAssertEqual(r.attempts, 3)
        XCTAssertEqual(n, 3, "stops after maxAttempts")
    }

    // MARK: durability — send-intent-before-I/O

    func testTransitionsPersistedInOrder() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        _ = await q.enqueue(job("j1"))
        // enqueued is written, THEN sendAttemptStarted (before the send), THEN acked.
        XCTAssertEqual(states(dir, "j1"), [.enqueued, .sendAttemptStarted, .acked])
    }

    // MARK: idempotency dedup

    func testIdempotencyDedupWithinWindow() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ScriptedExecutor([.acked])
        let clock = FakeClock()
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, now: clock.fn)
        _ = await q.enqueue(job("j1", key: "K"))
        let r2 = await q.enqueue(job("j2", key: "K"))   // same key, within window
        let n = await exec.count()
        XCTAssertTrue(r2.deduped)
        XCTAssertEqual(r2.finalState, .acked)
        XCTAssertEqual(n, 1, "the second same-key send is deduped (executor called once)")
    }

    func testIdempotencyDedupExpiresAfterWindow() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ScriptedExecutor([.acked])
        let clock = FakeClock()
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, now: clock.fn)
        _ = await q.enqueue(job("j1", key: "K"))
        clock.advance(200)                              // past the window
        let r2 = await q.enqueue(job("j2", key: "K"))
        let n = await exec.count()
        XCTAssertFalse(r2.deduped)
        XCTAssertEqual(n, 2, "after the window the same key delivers again")
    }

    // MARK: crash recovery

    func testRecoverReplaysEnqueuedJob() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        // Simulate a crash AFTER persisting `enqueued` but BEFORE any send.
        writeLog(dir, [job("j1")])   // state defaults to .enqueued
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        let receipts = await q.recover()
        let n = await exec.count()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.finalState, .acked)
        XCTAssertEqual(n, 1, "an enqueued-but-unsent job is delivered on recovery")
    }

    func testRecoverSendAttemptStartedBecomesUnknownAndRedelivers() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        // Crash mid-send: last persisted state is sendAttemptStarted.
        var crashed = job("j1"); crashed.state = .sendAttemptStarted; crashed.attempts = 1
        writeLog(dir, [crashed])
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        let receipts = await q.recover()
        let n = await exec.count()
        XCTAssertEqual(receipts.first?.finalState, .acked)
        XCTAssertEqual(n, 1, "at-least-once: a mid-send crash re-delivers")
        // The unknownAfterSend transition was recorded before the re-delivery.
        XCTAssertTrue(states(dir, "j1").contains(.unknownAfterSend))
    }

    func testRecoverSkipsAckedAndFailed() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var acked = job("a"); acked.state = .acked
        var failed = job("b"); failed.state = .failed
        writeLog(dir, [acked, failed])
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        let receipts = await q.recover()
        let n = await exec.count()
        XCTAssertEqual(receipts.count, 0, "terminal jobs are not re-driven")
        XCTAssertEqual(n, 0, "executor not called for acked/failed jobs")
    }

    // MARK: v2 hardening (single-driver guard, timeout, compaction, dead-letter, ordering)

    /// Slow ack so two concurrent recover() calls overlap.
    private actor SlowAckExecutor: DeliveryExecutor {
        private(set) var calls = 0
        func deliver(_ job: OutboundJob) async -> DeliveryOutcome {
            calls += 1
            try? await Task.sleep(for: .milliseconds(60))
            return .acked
        }
        func count() -> Int { calls }
    }

    /// Never returns until cancelled — exercises the per-attempt timeout.
    private actor HangingExecutor: DeliveryExecutor {
        private(set) var calls = 0
        func deliver(_ job: OutboundJob) async -> DeliveryOutcome {
            calls += 1
            try? await Task.sleep(for: .seconds(3600))
            return .acked
        }
        func count() -> Int { calls }
    }

    private actor OrderExecutor: DeliveryExecutor {
        private(set) var ids: [String] = []
        func deliver(_ job: OutboundJob) async -> DeliveryOutcome { ids.append(job.id); return .acked }
        func order() -> [String] { ids }
    }

    func testConcurrentRecoverDoesNotDoubleDeliver() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        writeLog(dir, [job("j1")])   // one enqueued job
        let exec = SlowAckExecutor()
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        async let r1 = q.recover()
        async let r2 = q.recover()
        _ = await (r1, r2)
        let n = await exec.count()
        XCTAssertEqual(n, 1, "the single-driver-per-id guard prevents a double recover() from double-delivering")
    }

    func testHungExecutorTimesOutAndRetriesThenFails() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = HangingExecutor()
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     maxAttempts: 2, attemptTimeout: .milliseconds(30))
        let r = await q.enqueue(job("j1"))
        let n = await exec.count()
        XCTAssertEqual(r.finalState, .failed, "a hung executor times out each attempt and dead-letters")
        XCTAssertEqual(r.attempts, 2)
        XCTAssertEqual(n, 2, "each attempt entered the executor (then timed out) — never wedged")
    }

    func testCompactionBoundsLogToLiveBacklog() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     compactThresholdBytes: 200)
        for i in 0..<30 { _ = await q.enqueue(job("j\(i)")) }
        let text = (try? String(contentsOfFile: dir + "/queue.jsonl", encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
        XCTAssertLessThan(lines, 30, "compaction drops acked records: the log tracks the LIVE backlog, not lifetime history (\(lines) lines for 30 acked jobs)")
    }

    func testFailedJobsAndStatusQuery() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ScriptedExecutor([.permanentFailure])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        _ = await q.enqueue(job("bad"))
        let failed = await q.failedJobs()
        let st = await q.status("bad")
        XCTAssertEqual(failed.map(\.id), ["bad"], "a permanently-failed job is retrievable as dead-letter")
        XCTAssertEqual(st, .failed)
    }

    /// An executor that NEVER returns and ignores cancellation (awaits a
    /// never-resumed continuation) — models a non-cooperative blocking sink.
    private actor StuckExecutor: DeliveryExecutor {
        private(set) var calls = 0
        func deliver(_ job: OutboundJob) async -> DeliveryOutcome {
            calls += 1
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return .acked
        }
        func count() -> Int { calls }
    }

    private func seqOf(_ dir: String, _ id: String) -> Int64? {
        let dec = JSONDecoder()
        guard let t = try? String(contentsOfFile: dir + "/queue.jsonl", encoding: .utf8) else { return nil }
        return t.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? dec.decode(OutboundJob.self, from: Data($0.utf8)) }
            .filter { $0.id == id }.map(\.seq).max()
    }

    /// #2: a non-cooperative (uncancellable) sink must NOT wedge the queue — the
    /// per-attempt timeout returns .retry and the job dead-letters; enqueue
    /// RETURNS instead of hanging forever (a structured task group would hang).
    func testNonCooperativeExecutorTimesOutWithoutWedging() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = StuckExecutor()
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     maxAttempts: 2, attemptTimeout: .milliseconds(40))
        let r = await q.enqueue(job("j1"))
        XCTAssertEqual(r.finalState, .failed, "the stuck attempts time out and dead-letter")
        XCTAssertEqual(r.attempts, 2, "enqueue returned (no wedge) after maxAttempts timeouts")
    }

    /// #5: recover() applies the idempotency dedup window, so two persisted
    /// same-key jobs deliver only once on recovery (not both).
    func testRecoverAppliesIdempotencyDedup() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var a = job("a", key: "K"); a.seq = 1
        var b = job("b", key: "K"); b.seq = 2
        writeLog(dir, [a, b])
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        _ = await q.recover()
        let n = await exec.count()
        XCTAssertEqual(n, 1, "recover() must not re-send a key it already acked this run")
    }

    /// #10: seqCounter is seeded from the log at init, so an enqueue() BEFORE
    /// recover() does not reuse a seq already present in the log.
    func testSeqSeededFromLogAvoidsCollision() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var existing = job("old"); existing.seq = 5; existing.state = .enqueued
        writeLog(dir, [existing])
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        _ = await q.enqueue(job("new"))   // enqueue BEFORE recover
        let newSeq = seqOf(dir, "new") ?? 0
        XCTAssertGreaterThan(newSeq, 5, "new job's seq must be seeded past the persisted seq=5, not reset to 1")
    }

    func testRecoverDrivesInSeqOrder() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var a = job("a"); a.seq = 1
        var b = job("b"); b.seq = 2
        var c = job("c"); c.seq = 3
        writeLog(dir, [c, a, b])   // out of order in the log
        let exec = OrderExecutor()
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        _ = await q.recover()
        let order = await exec.order()
        XCTAssertEqual(order, ["a", "b", "c"], "recovery re-drives in enqueue (seq) order, not dictionary order")
    }
}
