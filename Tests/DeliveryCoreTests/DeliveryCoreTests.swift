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

    // The audit fix: the dedup window survives a restart (was in-memory only → a crash
    // emptied it, so recover()+re-enqueue of a just-delivered key double-sent).

    func testDedupWindowSurvivesRestart() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var acked = job("j1", key: "K"); acked.state = .acked
        writeLog(dir, [acked])                              // a delivery committed before the crash
        let clock = FakeClock()
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, now: clock.fn)   // restart: re-seeds from the log
        let r = await q.enqueue(job("j2", key: "K"))         // fresh enqueue of the same key post-restart
        let n = await exec.count()
        XCTAssertTrue(r.deduped, "a key acked before the crash stays deduped after restart")
        XCTAssertEqual(n, 0, "the executor is NOT called — no cross-restart double-send")
    }

    func testReseedExpiresAfterWindow() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var acked = job("j1", key: "K"); acked.state = .acked
        writeLog(dir, [acked])
        let clock = FakeClock()
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, now: clock.fn)
        clock.advance(200)                                   // past the re-seeded window
        let r = await q.enqueue(job("j2", key: "K"))
        let n = await exec.count()
        XCTAssertFalse(r.deduped, "the re-seeded window is a real bounded window, not a permanent block")
        XCTAssertEqual(n, 1)
    }

    func testFailedKeyIsNotReseeded() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var failed = job("j1", key: "K"); failed.state = .failed
        writeLog(dir, [failed])                              // dead-lettered before the crash
        let clock = FakeClock()
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, now: clock.fn)
        let r = await q.enqueue(job("j2", key: "K"))         // a legitimate operator retry
        let n = await exec.count()
        XCTAssertFalse(r.deduped, "a re-enqueue of a FAILED key is a legit retry — must NOT be swallowed")
        XCTAssertEqual(n, 1)
    }

    // The re-seed reduces per-JOB-ID (fold's key), so ONE idempotency key with an acked
    // record under one id AND a later failed record under another id appeared twice; the
    // old loop seeded the window from the stale acked one, swallowing the failed key's
    // legitimate retry. Re-seed must reduce to the LATEST record per key (highest seq).
    func testAckedDoesNotShadowFailedRetryAcrossRestart() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var acked = job("j1", key: "K"); acked.state = .acked; acked.seq = 1
        var failed = job("j2", key: "K"); failed.state = .failed; failed.seq = 2  // later, different id
        writeLog(dir, [acked, failed])
        let clock = FakeClock()
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, now: clock.fn)
        let r = await q.enqueue(job("j3", key: "K"))         // operator retry; newest state for K is .failed
        let n = await exec.count()
        XCTAssertFalse(r.deduped, "a stale acked record must NOT shadow the key's LATER failed state")
        XCTAssertEqual(n, 1, "the retry of the failed key is actually delivered")
    }

    // The reverse ordering must still suppress: a failed attempt (seq 1) SUPERSEDED by a
    // later ack (seq 2) for the same key → the latest state is acked → window re-seeded.
    func testLaterAckWinsOverEarlierFailedAcrossRestart() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var failed = job("j1", key: "K"); failed.state = .failed; failed.seq = 1
        var acked = job("j2", key: "K"); acked.state = .acked; acked.seq = 2     // later success
        writeLog(dir, [failed, acked])
        let clock = FakeClock()
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, now: clock.fn)
        let r = await q.enqueue(job("j3", key: "K"))
        let n = await exec.count()
        XCTAssertTrue(r.deduped, "the key's NEWEST state is acked → deduped, no double-send")
        XCTAssertEqual(n, 0)
    }

    // seq is enqueue-time, NOT transition-time: a lower-seq job can ACK chronologically
    // AFTER a higher-seq job FAILS (e.g. a crash-residue job re-driven by recover() appends
    // its ack after a newer job's failure). The durable log is appended in true terminal
    // order, so the LAST-appended record per key is authoritative. Here acked(seq5) is
    // appended AFTER failed(seq6): the key IS delivered → must dedup, not double-send. A
    // seq-based reduction would pick failed(seq6) and wrongly re-send.
    func testAckAppendedAfterHigherSeqFailedSuppressesAcrossRestart() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var failed = job("j1", key: "K"); failed.state = .failed; failed.seq = 6  // higher seq, earlier in log
        var acked = job("j2", key: "K"); acked.state = .acked; acked.seq = 5      // lower seq, appended LATER
        writeLog(dir, [failed, acked])   // append order: failed then acked → acked is the latest state
        let clock = FakeClock()
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, now: clock.fn)
        let r = await q.enqueue(job("j3", key: "K"))
        let n = await exec.count()
        XCTAssertTrue(r.deduped, "the last-appended state for K is acked → suppress (append order, not seq)")
        XCTAssertEqual(n, 0, "no double-send of an already-delivered key")
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

    // Compaction must NOT hollow out the cross-restart dedup re-seed. recover() always
    // compacts and the job log drops acked records, so the dedup window is re-seeded from the
    // durable `dedup.jsonl` SIDECAR (which compaction does not touch). A key delivered then
    // compacted-through must still dedup after a restart.
    func testCompactionPreservesDedupViaSidecarForReseed() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = FakeClock()
        do {
            let exec = ScriptedExecutor([.acked])
            let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                         dedupWindowSeconds: 100, compactThresholdBytes: 4096, now: clock.fn)
            _ = await q.enqueue(job("j1", key: "K"))   // delivered → sidecar records K
            _ = await q.recover()                       // recover() ALWAYS compacts (drops acked K from queue.jsonl)
        }
        let exec2 = ScriptedExecutor([.acked])
        let q2 = DurableDeliveryQueue(directory: dir, executor: exec2, backoff: fastBackoff,
                                      dedupWindowSeconds: 100, now: clock.fn)   // restart, re-seed from sidecar
        let r = await q2.enqueue(job("j2", key: "K"))   // same key, within window
        let n = await exec2.count()
        XCTAssertTrue(r.deduped, "a key acked then compacted-through stays deduped after restart (via sidecar)")
        XCTAssertEqual(n, 0, "no cross-restart double-send of an already-delivered key")
    }

    // The JOB LOG stays the LIVE backlog even under a heavily KEYED workload: keyed
    // cross-restart dedup memory lives in the dedup.jsonl sidecar, never retained in queue.jsonl.
    func testJobLogStaysBoundedUnderManyKeyedAcks() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = FakeClock()
        let exec = ScriptedExecutor([.acked])
        // 60 DISTINCT keys, large window, small threshold (cf. testCompactionBoundsLogToLiveBacklog).
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100_000, compactThresholdBytes: 200, now: clock.fn)
        for i in 0..<60 { _ = await q.enqueue(job("j\(i)", key: "K\(i)")) }
        let text = (try? String(contentsOfFile: dir + "/queue.jsonl", encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
        XCTAssertLessThan(lines, 30, "the job log tracks the live backlog, not delivered keyed history (\(lines) lines)")
    }

    // The sidecar itself stays bounded by the distinct WITHIN-WINDOW key count: keys acked
    // before the window elapses are pruned on compaction, not accumulated for the daemon's
    // life. (Enough distinct keys to cross the 4096-byte compaction floor for tiny records.)
    func testDedupSidecarIsWindowBounded() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = FakeClock()
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, compactThresholdBytes: 200, now: clock.fn)
        for i in 0..<240 { _ = await q.enqueue(job("old\(i)", key: "OLD\(i)")) }  // first cohort (> 4096 B)
        clock.advance(200)                                                        // expire the first cohort
        for i in 0..<10 { _ = await q.enqueue(job("new\(i)", key: "NEW\(i)")) }   // triggers compactDedup → prune
        let text = (try? String(contentsOfFile: dir + "/dedup.jsonl", encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("\"OLD"), "expired-window keys are pruned from the sidecar")
        XCTAssertTrue(text.contains("\"NEW"), "current-window keys remain")
    }

    // (a) FAILURE-AWARE re-seed: the sidecar only records ACKS, so a key acked earlier then
    // permanently failed later (newest LOG state .failed) must NOT be re-seeded from the stale
    // sidecar ack — that is an operator retry and swallowing it loses the delivery.
    func testSidecarAckDoesNotShadowFailedRetry() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var acked = job("j1", key: "K"); acked.state = .acked; acked.seq = 1
        var failed = job("j2", key: "K"); failed.state = .failed; failed.seq = 2
        writeLog(dir, [acked, failed])      // newest log state for K is .failed
        try "{\"k\":\"K\",\"w\":0}\n".write(toFile: dir + "/dedup.jsonl", atomically: true, encoding: .utf8)
        let mono = FakeClock(); let wall = FakeClock()   // wall==0 matches the sidecar w==0 → within window
        let exec = ScriptedExecutor([.acked])
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     dedupWindowSeconds: 100, now: mono.fn, wallNow: wall.fn)
        let r = await q.enqueue(job("j3", key: "K"))
        let n = await exec.count()
        XCTAssertFalse(r.deduped, "a stale sidecar ack must NOT shadow the key's newest .failed log state")
        XCTAssertEqual(n, 1, "the failed key's retry is actually delivered")
    }

    // (b) EXPIRY-AWARE re-seed: the windowed-dedup contract must survive a restart. A key acked
    // longer than the window ago (by durable WALL time) is re-deliverable after a restart — the
    // sidecar must not grant it a fresh full window forever.
    func testSidecarDedupWindowExpiresAcrossRestart() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mono = FakeClock(); let wall = FakeClock()
        do {
            let exec = ScriptedExecutor([.acked])
            let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                         dedupWindowSeconds: 100, now: mono.fn, wallNow: wall.fn)
            _ = await q.enqueue(job("j1", key: "K"))   // sidecar records K at wall==0
        }
        wall.advance(200)                              // wall time passes the window across the restart
        let exec2 = ScriptedExecutor([.acked])
        let q2 = DurableDeliveryQueue(directory: dir, executor: exec2, backoff: fastBackoff,
                                      dedupWindowSeconds: 100, now: mono.fn, wallNow: wall.fn)
        let r = await q2.enqueue(job("j2", key: "K"))
        let n = await exec2.count()
        XCTAssertFalse(r.deduped, "an ack older than the window (wall time) is re-deliverable after restart")
        XCTAssertEqual(n, 1)
    }

    // Within the window, the durable sidecar dedups across a restart.
    func testSidecarDedupSurvivesRestartWithinWindow() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mono = FakeClock(); let wall = FakeClock()
        do {
            let exec = ScriptedExecutor([.acked])
            let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                         dedupWindowSeconds: 100, now: mono.fn, wallNow: wall.fn)
            _ = await q.enqueue(job("j1", key: "K"))
            _ = await q.recover()                      // compact the acked record out of the job log
        }
        wall.advance(40)                               // still within the 100s window
        let exec2 = ScriptedExecutor([.acked])
        let q2 = DurableDeliveryQueue(directory: dir, executor: exec2, backoff: fastBackoff,
                                      dedupWindowSeconds: 100, now: mono.fn, wallNow: wall.fn)
        let r = await q2.enqueue(job("j2", key: "K"))
        let n = await exec2.count()
        XCTAssertTrue(r.deduped, "within the window, a delivered key stays deduped after restart (via sidecar)")
        XCTAssertEqual(n, 0)
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

    // MARK: #13 — in-memory latest-per-job mirror

    /// Acks anything, permanently-fails ids prefixed "bad" — gives one queue a
    /// mix of terminal states without per-call scripting.
    private actor ByIdExecutor: DeliveryExecutor {
        func deliver(_ job: OutboundJob) async -> DeliveryOutcome {
            job.id.hasPrefix("bad") ? .permanentFailure : .acked
        }
    }

    /// #13: status()/failedJobs() read an in-memory mirror instead of re-parsing
    /// queue.jsonl. The mirror must be a FAITHFUL copy of the durable log — so a
    /// live (map-backed) queue and a FRESH queue that re-seeds its map from the
    /// same log file via fold() must report identical results. If the live map
    /// had drifted from what was persisted, these would diverge.
    func testInMemoryMapMatchesFreshReparse() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ByIdExecutor()
        // High threshold → no compaction, so acked records stay in log + map.
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     compactThresholdBytes: 1 << 20)
        for i in 0..<5 { _ = await q.enqueue(job("ok\(i)")) }
        _ = await q.enqueue(job("bad1"))
        _ = await q.enqueue(job("bad2"))

        let liveFailed = await q.failedJobs().map(\.id).sorted()
        let liveOk0 = await q.status("ok0")
        let liveBad1 = await q.status("bad1")

        // A fresh queue on the same dir re-seeds its map from the log in init.
        let fresh = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                         compactThresholdBytes: 1 << 20)
        let freshFailed = await fresh.failedJobs().map(\.id).sorted()
        let freshOk0 = await fresh.status("ok0")
        let freshBad1 = await fresh.status("bad1")

        XCTAssertEqual(liveFailed, ["bad1", "bad2"])
        XCTAssertEqual(liveOk0, .acked)
        XCTAssertEqual(liveBad1, .failed)
        XCTAssertEqual(liveFailed, freshFailed, "map-backed failedJobs must equal a fresh re-parse")
        XCTAssertEqual(liveOk0, freshOk0, "map-backed status must equal a fresh re-parse")
        XCTAssertEqual(liveBad1, freshBad1)
    }

    /// #13: compaction drops acked records from the log; the in-memory mirror
    /// must drop them in lockstep, so a compacted-away acked job reports nil
    /// status from memory exactly as a fresh re-parse of the compacted log would.
    func testMapTracksCompactionLikeReparse() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let exec = ByIdExecutor()
        // Low threshold → acked records are compacted away during the run.
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     compactThresholdBytes: 200)
        for i in 0..<20 { _ = await q.enqueue(job("ok\(i)")) }
        _ = await q.enqueue(job("bad1"))

        let liveOk0 = await q.status("ok0")        // first acked → long since compacted
        let liveBad1 = await q.status("bad1")
        let liveFailed = await q.failedJobs().map(\.id)

        let fresh = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        let freshOk0 = await fresh.status("ok0")
        let freshBad1 = await fresh.status("bad1")
        let freshFailed = await fresh.failedJobs().map(\.id)

        XCTAssertNil(liveOk0, "an acked job compacted out of the log reports nil from the map too")
        XCTAssertEqual(liveOk0, freshOk0, "no drift through compaction vs a fresh re-parse")
        XCTAssertEqual(liveBad1, .failed)
        XCTAssertEqual(liveBad1, freshBad1)
        XCTAssertEqual(liveFailed, ["bad1"])
        XCTAssertEqual(liveFailed, freshFailed)
    }

    #if canImport(Darwin)
    /// #13 (failure path): if `compact()`'s rewrite FAILS, the in-memory mirror
    /// must NOT drift from the on-disk log. We force the failure by making the
    /// queue directory read-only so the compacted temp can't be created/renamed,
    /// then assert the live (map-backed) status still matches a fresh re-fold of
    /// the un-rewritten log. Without the `try` (vs `try?`) on replaceItemAt + the
    /// abort-on-undurable-temp, the map would drop the acked job while the log
    /// still held it.
    func testCompactFailureDoesNotDriftMapFromLog() async throws {
        try XCTSkipIf(geteuid() == 0, "read-only-dir fault injection needs a non-root euid")
        let dir = tmpDir()
        defer { chmod(dir, 0o755); try? FileManager.default.removeItem(atPath: dir) }
        let exec = ByIdExecutor()
        // High threshold → the ack does NOT auto-compact; we trigger compaction
        // explicitly via recover() once the dir is read-only.
        let q = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff,
                                     compactThresholdBytes: 1 << 20)
        _ = await q.enqueue(job("keep"))          // acked → log + map both hold it
        let beforeStatus = await q.status("keep")
        XCTAssertEqual(beforeStatus, .acked)

        XCTAssertEqual(chmod(dir, 0o500), 0)       // read-only: temp create/rename will fail
        _ = await q.recover()                      // recover() → compact() → rewrite FAILS → catch
        let liveStatus = await q.status("keep")

        chmod(dir, 0o755)                          // restore so a fresh queue can fold the intact log
        let fresh = DurableDeliveryQueue(directory: dir, executor: exec, backoff: fastBackoff)
        let freshStatus = await fresh.status("keep")

        XCTAssertEqual(liveStatus, .acked, "a failed compaction must leave the acked record in the mirror")
        XCTAssertEqual(liveStatus, freshStatus, "map must still match a fresh re-fold after compact failure")
    }
    #endif
}
