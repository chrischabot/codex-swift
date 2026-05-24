import XCTest
import Foundation
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif
@testable import InfraPrimitives

final class InfraPrimitivesTests: XCTestCase {

    // MARK: Limits

    func testShellOutputBusFanOutsAndUnsubscribes() async throws {
        // F5b: ShellTool publishes per-callId chunks; SessionEngine subscribes
        // before dispatch, unsubscribes after. The bus must:
        //   1. Deliver chunks only to the matching subscriber
        //   2. Drop publishes after unsubscribe
        //   3. Track live subscription count for diagnostics
        let bus = ShellOutputBus()
        actor Sink {
            var chunks: [(String, String)] = []
            func record(_ s: String, _ c: String) { chunks.append((s, c)) }
            func count() -> Int { chunks.count }
            func stream(at i: Int) -> String { chunks[i].0 }
            func body(at i: Int) -> String { chunks[i].1 }
        }
        let A = Sink(); let B = Sink()
        await bus.subscribe(callId: "call_A") { stream, data in
            Task { await A.record(stream, String(decoding: data, as: UTF8.self)) }
        }
        await bus.subscribe(callId: "call_B") { stream, data in
            Task { await B.record(stream, String(decoding: data, as: UTF8.self)) }
        }
        let n0 = await bus.subscriptionCount(); XCTAssertEqual(n0, 2)

        await bus.publish(callId: "call_A", stream: "stdout",
                           chunk: Data("hello".utf8))
        await bus.publish(callId: "call_B", stream: "stderr",
                           chunk: Data("oops".utf8))
        await bus.publish(callId: "call_missing", stream: "stdout",
                           chunk: Data("ignored".utf8))

        // Let the detached Task.run record finish.
        try await Task.sleep(for: .milliseconds(50))
        let aCount = await A.count(); XCTAssertEqual(aCount, 1)
        let aStream0 = await A.stream(at: 0); XCTAssertEqual(aStream0, "stdout")
        let aBody0 = await A.body(at: 0); XCTAssertEqual(aBody0, "hello")
        let bCount = await B.count(); XCTAssertEqual(bCount, 1)
        let bStream0 = await B.stream(at: 0); XCTAssertEqual(bStream0, "stderr")
        let bBody0 = await B.body(at: 0); XCTAssertEqual(bBody0, "oops")

        await bus.unsubscribe(callId: "call_A")
        let n1 = await bus.subscriptionCount(); XCTAssertEqual(n1, 1)
        await bus.publish(callId: "call_A", stream: "stdout",
                           chunk: Data("post-unsub".utf8))
        try await Task.sleep(for: .milliseconds(50))
        let aCount2 = await A.count()
        XCTAssertEqual(aCount2, 1, "no delivery after unsubscribe")
    }

    func testLimitsLoadOverridesFromConfigTOML() throws {
        // F1: turnDeadline + iterations must be overridable via TOML config
        // so users don't have to recompile the binary.
        let home = NSTemporaryDirectory() + "limits-toml-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let toml = """
        # cat-scan overrides
        turn_deadline_secs = 3600
        max_sampling_iterations_per_turn = 500
        max_compactions_per_turn = 8
        # ignored — unknown key
        bogus_key = 42
        """
        try toml.data(using: .utf8)!.write(to: URL(fileURLWithPath: home + "/config.toml"))

        let l = Limits.loadingOverrides(codexHome: home).clamped()
        XCTAssertEqual(l.turnDeadline, .seconds(3600))
        XCTAssertEqual(l.maxSamplingIterationsPerTurn, 500)
        XCTAssertEqual(l.maxCompactionsPerTurn, 8)
        // Default left intact when not set
        XCTAssertEqual(l.maxIdenticalToolRepeats, Limits().maxIdenticalToolRepeats)
    }

    func testLimitsLoadOverridesMissingConfigReturnsDefaults() {
        let l = Limits.loadingOverrides(codexHome: "/no/such/dir/here").clamped()
        XCTAssertEqual(l.turnDeadline, Limits().turnDeadline)
        XCTAssertEqual(l.maxSamplingIterationsPerTurn,
                       Limits().maxSamplingIterationsPerTurn)
    }

    func testLimitsLoadOverridesBadValuesAreIgnored() throws {
        let home = NSTemporaryDirectory() + "limits-toml-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let toml = """
        turn_deadline_secs = "not a number"
        max_sampling_iterations_per_turn = -1
        """
        try toml.data(using: .utf8)!.write(to: URL(fileURLWithPath: home + "/config.toml"))
        let l = Limits.loadingOverrides(codexHome: home).clamped()
        XCTAssertEqual(l.turnDeadline, Limits().turnDeadline,
                       "non-numeric value falls back to default")
        XCTAssertGreaterThan(l.maxSamplingIterationsPerTurn, 0,
                             "clamp() restores valid floor for negative input")
    }

    func testLimitsClampedToCeilingAndFloors() {
        var l = Limits()
        l.controlChannelDepth = 1 << 30
        l.streamMaxRetries = 9999
        l.ledgerSoftCPUFraction = 99
        l.retryTokensPerSecond = -5
        l.turnDeadline = .seconds(10 * 24 * 3600)
        l.retryBaseDelay = .seconds(999)
        l.retryMaxDelay = .milliseconds(1)        // inverted on purpose
        l.heartbeatInterval = .nanoseconds(1)     // below min tick
        let c = l.clamped()
        XCTAssertEqual(c.controlChannelDepth, Limits.ceiling.controlChannelDepth)
        XCTAssertEqual(c.streamMaxRetries, Limits.ceiling.streamMaxRetries)
        XCTAssertLessThanOrEqual(c.ledgerSoftCPUFraction, 1.0)
        XCTAssertGreaterThanOrEqual(c.ledgerSoftCPUFraction, 0.05)
        XCTAssertGreaterThanOrEqual(c.retryTokensPerSecond, 0)
        XCTAssertLessThanOrEqual(c.turnDeadline, .seconds(24 * 3600))
        XCTAssertGreaterThanOrEqual(c.retryMaxDelay, c.retryBaseDelay)
        XCTAssertGreaterThanOrEqual(c.heartbeatInterval, .milliseconds(1))
        XCTAssertGreaterThanOrEqual(c.effectiveMaxActiveWorkers(), 1)
    }

    func testLimitsRegistryHotReloadBumpsGeneration() async {
        let reg = LimitsRegistry()
        let g0 = await reg.currentGeneration()
        var next = Limits(); next.maxConcurrentTools = 2
        _ = await reg.reload(next)
        let g1 = await reg.currentGeneration()
        XCTAssertEqual(g1, g0 + 1)
        let snap = await reg.snapshot()
        XCTAssertEqual(snap.maxConcurrentTools, 2)
    }

    // MARK: Deadline

    func testDeadlinePropagationIsMinCombine() {
        let near = Deadline.fromNow(.milliseconds(10))
        let far = Deadline.fromNow(.seconds(100))
        XCTAssertEqual(near.earliest(far).atMonotonic, near.atMonotonic, accuracy: 1e-9)
        XCTAssertFalse(near.hasPassed)
    }

    // MARK: Backoff

    func testFullJitterBackoffStaysWithinExponentialCeiling() {
        let bo = Backoff(base: .milliseconds(100), maxDelay: .seconds(20))
        for attempt in 0..<12 {
            let d = bo.delay(forAttempt: attempt).seconds
            let ceiling = min(20.0, 0.1 * pow(2.0, Double(attempt)))
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertLessThanOrEqual(d, ceiling + 1e-9)
        }
    }

    func testBackoffJitterIsActuallyRandomized() {
        let seq = [0.3, 0.9, 0.05]
        let box = SeqBox(seq)
        let bo = Backoff(base: .seconds(1), maxDelay: .seconds(10)) { box.next() }
        XCTAssertEqual(bo.delay(forAttempt: 3).seconds, 0.3 * min(10, 8), accuracy: 1e-9)
        XCTAssertEqual(bo.delay(forAttempt: 3).seconds, 0.9 * min(10, 8), accuracy: 1e-9)
    }

    // MARK: TokenBucket

    func testTokenBucketEnforcesCapacityAndRefill() async {
        let tb = TokenBucket(capacity: 3, refillPerSecond: 1000)
        var t = await tb.tryTake(); XCTAssertTrue(t)
        t = await tb.tryTake(); XCTAssertTrue(t)
        t = await tb.tryTake(); XCTAssertTrue(t)
        t = await tb.tryTake(); XCTAssertFalse(t)          // exhausted
        try? await Task.sleep(for: .milliseconds(50))
        t = await tb.tryTake(); XCTAssertTrue(t)           // refilled
    }

    // MARK: SingleFlight

    func testSingleFlightCoalescesConcurrentCallers() async throws {
        let sf = SingleFlight<String, Int>()
        let counter = Counter()
        let gate = AsyncGate()
        let a = Task { try await sf.run("k") { await counter.inc(); await gate.wait(); return 7 } }
        while await counter.value == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }

        let b = Task { try await sf.run("k") { await counter.inc(); return 8 } }
        let c = Task { try await sf.run("k") { await counter.inc(); return 9 } }
        for _ in 0..<500 where await sf.coalescedCount < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        await gate.open()

        let r = try await [a.value, b.value, c.value]
        XCTAssertEqual(r, [7, 7, 7])
        let cv = await counter.value
        XCTAssertEqual(cv, 1)      // only one upstream call
        let cc = await sf.coalescedCount
        XCTAssertEqual(cc, 2)
    }

    // MARK: CoalescingRing (C3)

    func testCoalescingRingBoundedUnderFloodAndTerminalDeliverOnce() async {
        let ring = CoalescingRing(maxBytes: 1024)
        for _ in 0..<100_000 { await ring.push("0123456789") }   // 1e6 bytes pushed
        let pending = await ring.pendingBytes()
        XCTAssertLessThanOrEqual(pending, 1024) // bounded, no blowup
        await ring.markTerminal()
        let d1 = await ring.drain()
        XCTAssertTrue(d1.isTerminal)
        XCTAssertGreaterThan(d1.coalescedBytes, 0)
        let d2 = await ring.drain()
        XCTAssertFalse(d2.isTerminal)                            // deliver-once
    }

    // MARK: OverwriteRing (C4)

    func testOverwriteRingOverwritesOldestAndCountsDrops() {
        let r = OverwriteRing<Int>(capacity: 4)
        for i in 0..<10 { r.push(i) }
        XCTAssertEqual(r.snapshot(), [6, 7, 8, 9])
        XCTAssertEqual(r.droppedCount, 6)
        XCTAssertEqual(r.fill, 1.0, accuracy: 1e-9)
    }

    // MARK: HeadTailBuffer

    func testHeadTailBufferTruncatesWithMarker() {
        var b = HeadTailBuffer(maxBytes: 20)
        b.append(String(repeating: "A", count: 100))
        let out = b.rendered()
        XCTAssertTrue(b.didTruncate)
        XCTAssertTrue(out.contains("bytes elided"))
        XCTAssertEqual(b.totalBytes, 100)
    }

    // MARK: BoundedChannel

    func testControlChannelBlocksAndPreservesFIFO() async throws {
        let ch = BoundedChannel<Int>(capacity: 2, policy: .block)
        try await ch.send(1)
        try await ch.send(2)
        let producer = Task { try await ch.send(3) }   // must block (full)
        try await Task.sleep(for: .milliseconds(20))
        let a = await ch.receive(); XCTAssertEqual(a, 1)
        let b = await ch.receive(); XCTAssertEqual(b, 2)
        let c = await ch.receive(); XCTAssertEqual(c, 3)  // unblocked, FIFO
        try await producer.value
    }

    func testDataChannelRejectsNewestWithOverload() async throws {
        let ch = BoundedChannel<Int>(capacity: 1, policy: .rejectNewest)
        try await ch.send(1)
        do {
            try await ch.send(2)
            XCTFail("expected OverloadError")
        } catch is OverloadError {
            let rc = await ch.rejectedCount
            XCTAssertEqual(rc, 1)
        }
    }

    func testChannelCloseUnblocksWaitersWithClosedError() async {
        let ch = BoundedChannel<Int>(capacity: 1, policy: .block)
        try? await ch.send(1)
        let blocked = Task { () -> String in
            do { try await ch.send(2); return "sent" }
            catch is ChannelClosedError { return "closed" }
            catch is CancellationError { return "cancelled" }
            catch { return "other" }
        }
        try? await Task.sleep(for: .milliseconds(20))
        await ch.close()
        let outcome = await blocked.value
        XCTAssertEqual(outcome, "closed")
        let drained = await ch.receive()
        XCTAssertEqual(drained, 1)
        let end = await ch.receive()
        XCTAssertNil(end)
    }

    func testCancelledBlockedSenderThrowsCancellationAndNeverDelivers() async throws {
        let ch = BoundedChannel<Int>(capacity: 1, policy: .block)
        try await ch.send(1)                         // buffer full
        let sender = Task { try await ch.send(99) }  // must block
        try await Task.sleep(for: .milliseconds(30))
        sender.cancel()
        var threwCancellation = false
        do { try await sender.value }
        catch is CancellationError { threwCancellation = true }
        catch { XCTFail("expected CancellationError, got \(error)") }
        XCTAssertTrue(threwCancellation, "cancelled blocked sender must throw CancellationError")

        let first = await ch.receive()
        XCTAssertEqual(first, 1)
        // Prove 99 was never enqueued: a fresh receiver must park (no element),
        // and only close() ends it with nil.
        let r = Task { await ch.receive() }
        try await Task.sleep(for: .milliseconds(20))
        await ch.close()
        let v = await r.value
        XCTAssertNil(v, "cancelled sender's element must not be delivered")
    }

    func testCancelBeforeParkIsHonored() async throws {
        // Stress the registration race: cancel immediately after spawning.
        let ch = BoundedChannel<Int>(capacity: 1, policy: .block)
        try await ch.send(1)
        for _ in 0..<200 {
            let s = Task { try await ch.send(2) }
            s.cancel()
            do { try await s.value; XCTFail("should have cancelled") }
            catch is CancellationError {}
            catch is ChannelClosedError {}
            catch { XCTFail("unexpected \(error)") }
        }
        let v = await ch.receive()
        XCTAssertEqual(v, 1, "no cancelled element should ever have been enqueued")
    }

    // MARK: Governor

    func testGovernorPolicyTransitions() {
        var lim = Limits(); lim.ledgerSoftCPUFraction = 0.80
        lim.ledgerHardMemoryBytes = 1_000_000
        let p = GovernorPolicy(limits: lim.clamped())
        func s(_ cpu: Double, _ mem: Int) -> ResourceSample {
            ResourceSample(atMonotonic: 0, cpuFractionOverWindow: cpu, residentBytes: mem)
        }
        XCTAssertEqual(p.evaluate(s(0.10, 1000), hung: false), .normal)
        XCTAssertEqual(p.evaluate(s(0.80, 1000), hung: false), .soft)
        XCTAssertEqual(p.evaluate(s(0.95, 1000), hung: false), .hard)
        XCTAssertEqual(p.evaluate(s(0.10, 64 * 1024 * 1024), hung: false), .terminal)
        XCTAssertEqual(p.evaluate(s(0.10, 1000), hung: true), .terminal)
    }

    func testResourceLedgerEmitsTransitionsOnce() async {
        let led = ResourceLedger(pid: -1, limits: Limits(), sampler: NoopSampler())
        let t1 = await led.observe(.init(atMonotonic: 0, cpuFractionOverWindow: 0.99, residentBytes: 0))
        XCTAssertEqual(t1, .hard)
        let t2 = await led.observe(.init(atMonotonic: 1, cpuFractionOverWindow: 0.99, residentBytes: 0))
        XCTAssertNil(t2, "no transition emitted when state unchanged")
    }

    func testResourceLedgerSamplesWholeProcessTree() async {
        var limits = Limits()
        limits.ledgerHardMemoryBytes = 64 * 1024 * 1024
        let led = ResourceLedger(pid: 1234, limits: limits, sampler: TreeOnlySampler())
        let transition = await led.tick()
        XCTAssertEqual(transition, .terminal)
        let state = await led.currentState()
        XCTAssertEqual(state, .terminal)
    }

    func testDefaultResourceSamplerReportsCurrentProcess() {
        let sampler = DefaultResourceSampler()
        let sample = sampler.sample(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(sample)
        #if os(macOS)
        XCTAssertGreaterThan(sample?.residentBytes ?? 0, 0,
                             "macOS proc_pid_rusage should report real memory")
        XCTAssertGreaterThanOrEqual(sample?.cpuFractionOverWindow ?? -1, 0)
        #endif
    }

    #if os(macOS) || os(Linux)
    func testDefaultResourceSamplerDiscoversForkedDescendant() async throws {
        let dir = NSTemporaryDirectory() + "resource-tree-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let pidFile = dir + "/child.pid"
        let script = dir + "/spawn-child.sh"
        try """
        #!/bin/sh
        sleep 30 &
        echo $! > "\(pidFile)"
        wait
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        let root = Int32(process.processIdentifier)
        var child: Int32 = -1
        defer {
            if child > 0 {
                kill(child, SIGTERM)
                usleep(50_000)
                kill(child, SIGKILL)
            }
            kill(root, SIGTERM)
            process.terminate()
        }

        child = try await waitForChildPID(at: pidFile)
        var pids: [Int32] = []
        for _ in 0..<100 {
            pids = DefaultResourceSampler.processTreePIDs(root: root)
            if pids.contains(child) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(pids.contains(child), "resource sampling must include forked descendants, got \(pids), child \(child)")

        let sample = DefaultResourceSampler().sampleTree(rootPID: root)
        XCTAssertNotNil(sample)
    }
    #endif
}

// Test helpers
actor Counter {
    private(set) var value = 0
    func inc() { value += 1 }
}
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
final class SeqBox: @unchecked Sendable {
    private var seq: [Double]; private var i = 0; private let lock = NSLock()
    init(_ s: [Double]) { seq = s }
    func next() -> Double { lock.lock(); defer { lock.unlock() }; defer { i += 1 }; return seq[i % seq.count] }
}
struct NoopSampler: ResourceSampler {
    func sample(pid: Int32) -> ResourceSample? { nil }
}
struct TreeOnlySampler: ResourceSampler {
    func sample(pid: Int32) -> ResourceSample? {
        ResourceSample(atMonotonic: 1, cpuFractionOverWindow: 0, residentBytes: 1)
    }

    func sampleTree(rootPID: Int32) -> ResourceSample? {
        ResourceSample(atMonotonic: 1, cpuFractionOverWindow: 0, residentBytes: 96 * 1024 * 1024)
    }
}

#if os(macOS) || os(Linux)
private func waitForChildPID(at path: String) async throws -> Int32 {
    for _ in 0..<200 {
        if let raw = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(raw) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(domain: "InfraPrimitivesTests", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "timed out waiting for child pid"])
}
#endif
