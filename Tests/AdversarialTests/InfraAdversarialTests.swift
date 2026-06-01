import XCTest
import Foundation
import Dispatch
@testable import InfraPrimitives

final class InfraAdversarialTests: XCTestCase {

    // MARK: Limits.clamped — every field survives hostile values

    func testLimitsClampedHostileExtremes() {
        var l = Limits()
        l.controlChannelDepth = Int.max
        l.dataChannelDepth = Int.min
        l.streamDeltaRingBytes = -1
        l.telemetryRingCount = 0
        l.maxInboundMessageBytes = Int.max
        l.maxToolOutputBytes = -999
        l.maxSamplingIterationsPerTurn = Int.max
        l.maxConcurrentTools = -5
        l.streamMaxRetries = 99999
        l.maxPendingTurnInputs = Int.max
        l.mailboxCapacity = -1
        l.maxJSONNestingDepth = Int.max
        l.maxConcurrentSessions = 0
        l.retryTokensCapacity = -1
        l.retryTokensPerSecond = .nan
        l.ledgerSoftCPUFraction = .nan
        l.ledgerHardMemoryBytes = -1
        l.turnDeadline = .seconds(-100)
        l.retryBaseDelay = .seconds(99_999)
        l.retryMaxDelay = .milliseconds(1)        // inverted vs base
        l.heartbeatInterval = .nanoseconds(1)
        l.idleUnload = .seconds(-1)
        l.watchdogMissedHeartbeats = -3
        l.maxActiveWorkers = -7
        let c = l.clamped()
        let k = Limits.ceiling
        XCTAssertGreaterThanOrEqual(c.controlChannelDepth, 1)
        XCTAssertLessThanOrEqual(c.controlChannelDepth, k.controlChannelDepth)
        XCTAssertGreaterThanOrEqual(c.dataChannelDepth, 1)
        XCTAssertGreaterThanOrEqual(c.maxToolOutputBytes, 1)
        XCTAssertGreaterThanOrEqual(c.maxPendingTurnInputs, 1)
        XCTAssertLessThanOrEqual(c.maxPendingTurnInputs, k.maxPendingTurnInputs)
        XCTAssertGreaterThanOrEqual(c.mailboxCapacity, 1)
        XCTAssertLessThanOrEqual(c.mailboxCapacity, k.mailboxCapacity)
        XCTAssertGreaterThanOrEqual(c.maxJSONNestingDepth, 1)
        XCTAssertLessThanOrEqual(c.maxJSONNestingDepth, k.maxJSONNestingDepth)
        XCTAssertGreaterThanOrEqual(c.maxConcurrentSessions, 1)
        XCTAssertLessThanOrEqual(c.maxConcurrentSessions, k.maxConcurrentSessions)
        XCTAssertFalse(c.retryTokensPerSecond.isNaN)
        XCTAssertGreaterThanOrEqual(c.retryTokensPerSecond, 0)
        XCTAssertFalse(c.ledgerSoftCPUFraction.isNaN)
        XCTAssertGreaterThanOrEqual(c.ledgerSoftCPUFraction, 0.05)
        XCTAssertLessThanOrEqual(c.ledgerSoftCPUFraction, 1.0)
        XCTAssertGreaterThanOrEqual(c.ledgerHardMemoryBytes, 64 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(c.turnDeadline, .seconds(1))
        XCTAssertLessThanOrEqual(c.turnDeadline, .seconds(365 * 24 * 3600))
        XCTAssertGreaterThanOrEqual(c.retryMaxDelay, c.retryBaseDelay,
                                    "inverted retry window is corrected")
        XCTAssertGreaterThanOrEqual(c.heartbeatInterval, .milliseconds(1))
        XCTAssertGreaterThanOrEqual(c.idleUnload, .seconds(1))
        XCTAssertGreaterThanOrEqual(c.watchdogMissedHeartbeats, 1)
        XCTAssertGreaterThanOrEqual(c.maxActiveWorkers, 0)
        XCTAssertGreaterThanOrEqual(c.effectiveMaxActiveWorkers(), 1)
        // Idempotent: clamping a clamped value changes nothing.
        XCTAssertEqual(c.clamped(), c)
    }

    func testLimitsRegistryReloadAlwaysClampsAndBumpsGeneration() async {
        let reg = LimitsRegistry()
        let g0 = await reg.currentGeneration()
        var bad = Limits()
        bad.maxJSONNestingDepth = Int.max
        bad.mailboxCapacity = -42
        _ = await reg.reload(bad)
        let snap = await reg.snapshot()
        XCTAssertLessThanOrEqual(snap.maxJSONNestingDepth,
                                 Limits.ceiling.maxJSONNestingDepth)
        XCTAssertGreaterThanOrEqual(snap.mailboxCapacity, 1)
        let g1 = await reg.currentGeneration()
        XCTAssertEqual(g1, g0 + 1)
    }

    // MARK: Backoff never yields NaN / Infinity sleeps

    func testBackoffNeverInfiniteOrNaN() {
        let bo = Backoff(base: .seconds(1), maxDelay: .seconds(5)) { 1.0 }
        for a in [0, 1, 10, 100, 1000, 100_000, Int.max] {
            let d = bo.delay(forAttempt: a).seconds
            XCTAssertFalse(d.isNaN, "attempt \(a)")
            XCTAssertFalse(d.isInfinite, "attempt \(a)")
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertLessThanOrEqual(d, 5.0 + 1e-9, "never exceeds maxDelay")
        }
        XCTAssertEqual(bo.delay(forAttempt: -5).seconds,
                       bo.delay(forAttempt: 0).seconds, accuracy: 1e-9)
    }

    // MARK: TokenBucket adversarial

    func testTokenBucketAdversarial() async {
        let tb = TokenBucket(capacity: 1, refillPerSecond: 0)
        let first = await tb.tryTake()
        XCTAssertTrue(first)
        for _ in 0..<1000 {
            let t = await tb.tryTake()
            XCTAssertFalse(t)
        }
        let big = await tb.tryTake(1_000_000)
        XCTAssertFalse(big)
        let avail = await tb.available()
        XCTAssertGreaterThanOrEqual(avail, 0)
        // Concurrent contention: at most `capacity` successes.
        let tb2 = TokenBucket(capacity: 50, refillPerSecond: 0)
        let ok = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<5000 {
                g.addTask { if await tb2.tryTake() { await ok.inc() } }
            }
        }
        let v = await ok.value
        XCTAssertLessThanOrEqual(v, 50, "never over-issues under contention")
    }

    // MARK: SingleFlight storm

    func testSingleFlightStormCoalescesAndPropagatesError() async {
        let sf = SingleFlight<String, Int>()
        let calls = Counter()
        await withTaskGroup(of: Int?.self) { g in
            for _ in 0..<10_000 {
                g.addTask {
                    try? await sf.run("k") {
                        await calls.inc()
                        try? await Task.sleep(for: .milliseconds(20))
                        return 7
                    }
                }
            }
            for await _ in g {}
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1, "10k concurrent → exactly one call")
        // Error fan-out then recovery.
        struct Boom: Error {}
        let failed = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<200 {
                g.addTask {
                    do { _ = try await sf.run("e") { throw Boom() } }
                    catch { await failed.inc() }
                }
            }
        }
        let failCount = await failed.value
        XCTAssertEqual(failCount, 200, "all waiters see the error")
        let after = try? await sf.run("e") { 99 }
        XCTAssertEqual(after, 99, "key is reusable after a failed flight")
    }

    // MARK: BoundedChannel brutal storm

    func testBoundedChannelBlockingStormNoLossNoDeadlock() async {
        let ch = BoundedChannel<Int>(capacity: 4, policy: .block)
        let n = 4000
        let received = Counter()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<n { g.addTask { try? await ch.send(i) } }
            for _ in 0..<n {
                g.addTask {
                    if await ch.receive() != nil { await received.inc() }
                }
            }
        }
        let got = await received.value
        XCTAssertEqual(got, n, "blocking channel loses nothing under a storm")
        let depth = await ch.depth()
        XCTAssertLessThanOrEqual(depth, 4, "never exceeds capacity")
    }

    func testBoundedChannelRejectNewestStormAccountsRejections() async {
        let ch = BoundedChannel<Int>(capacity: 8, policy: .rejectNewest)
        var rejected = 0
        for i in 0..<200_000 {
            do { try await ch.send(i) }
            catch is OverloadError { rejected += 1 }
            catch { /* exhaustive: no other error expected pre-close */ }
        }
        XCTAssertGreaterThan(rejected, 190_000)
        let rc = await ch.rejectedCount
        XCTAssertEqual(rc, rejected, "rejection accounting is exact")
        await ch.close()
        // Drain remaining then nil.
        var drained = 0
        while await ch.receive() != nil { drained += 1; if drained > 16 { break } }
        XCTAssertLessThanOrEqual(drained, 8)
    }

    // MARK: rings / buffers bounded under flood + concurrency

    func testCoalescingRingFloodBoundedTerminalOnce() async {
        let ring = CoalescingRing(maxBytes: 4096)
        for _ in 0..<1_000_000 { await ring.push("0123456789") }
        let pending = await ring.pendingBytes()
        XCTAssertLessThanOrEqual(pending, 4096)
        await ring.markTerminal()
        let d1 = await ring.drain()
        XCTAssertTrue(d1.isTerminal)
        XCTAssertGreaterThan(d1.coalescedBytes, 0)
        let d2 = await ring.drain()
        XCTAssertFalse(d2.isTerminal)
    }

    func testOverwriteRingConcurrentPushBounded() {
        let ring = OverwriteRing<Int>(capacity: 64)
        DispatchQueue.concurrentPerform(iterations: 32) { t in
            for i in 0..<20_000 { ring.push(t * 1_000_000 + i) }
        }
        XCTAssertLessThanOrEqual(ring.snapshot().count, 64,
                                 "snapshot never exceeds capacity under 32-way races")
        XCTAssertGreaterThan(ring.droppedCount, 0)
        XCTAssertEqual(ring.fill, 1.0, accuracy: 1e-9)
    }

    func testHeadTailBufferAdversarialSizesAndUnicode() {
        var b = HeadTailBuffer(maxBytes: 9)               // just above the >8 floor
        b.append(String(repeating: "A", count: 1_000_000))
        XCTAssertTrue(b.didTruncate)
        XCTAssertTrue(b.rendered().contains("tokens truncated"))
        XCTAssertEqual(b.totalBytes, 1_000_000)
        // Multibyte content at the truncation boundary must not trap.
        var u = HeadTailBuffer(maxBytes: 16)
        u.append(String(repeating: "🙂🇿🇦中", count: 10_000))
        _ = u.rendered()
        XCTAssertTrue(u.didTruncate)
    }

    func testFlightRecorderBoundedDump() {
        let fr = FlightRecorder(capacity: 8)
        for i in 0..<10_000 { fr.record("k", "detail-\(i)") }
        XCTAssertLessThanOrEqual(fr.snapshot().count, 8)
        let lines = fr.dumpJSONL().split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertLessThanOrEqual(lines.count, 8)
    }

    func testGovernorPolicyExtremeSamples() {
        var lim = Limits(); lim.ledgerSoftCPUFraction = 0.8
        lim.ledgerHardMemoryBytes = 1_000_000
        let p = GovernorPolicy(limits: lim.clamped())
        func s(_ cpu: Double, _ mem: Int) -> ResourceSample {
            ResourceSample(atMonotonic: 0, cpuFractionOverWindow: cpu, residentBytes: mem)
        }
        XCTAssertEqual(p.evaluate(s(-100, -100), hung: false), .normal)
        XCTAssertEqual(p.evaluate(s(1e9, 0), hung: false), .hard)
        XCTAssertEqual(p.evaluate(s(0, Int.max), hung: false), .terminal)
        XCTAssertEqual(p.evaluate(s(0, 0), hung: true), .terminal)
    }
}

private actor Counter {
    private(set) var value = 0
    func inc() { value += 1 }
}