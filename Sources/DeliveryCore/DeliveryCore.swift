import Foundation
import InfraPrimitives
#if canImport(Darwin)
import Darwin
#endif

// ADDONS.md Phase 0 #4: the durable, at-least-once outbound-delivery core.
//
// openclaw's `src/infra/outbound/` (a durable delivery-queue with explicit
// recovery states) is the prior art: reliable outbound is the load-bearing 80%
// of "the agent can message you back." A reply/push lost between turn-completion
// and transport-send (a crash, a daemon restart) is unfixable without a
// SEND-INTENT-BEFORE-I/O durable record. This module is that record + the
// retry/recovery state machine — kept generic so BOTH the Channels reply path
// (#1) and the Push sinks (#7) share one queue. A job is an opaque
// `(target, payload)` the injected `DeliveryExecutor` knows how to send.

/// The durable lifecycle of one delivery (openclaw's recovery states).
public enum DeliveryState: String, Sendable, Codable, Equatable {
    case enqueued
    /// Persisted (fsync'd) BEFORE the transport send is attempted. On replay
    /// this state means "we may or may not have delivered" → `unknownAfterSend`.
    case sendAttemptStarted = "send_attempt_started"
    case acked
    /// A crash observed after `sendAttemptStarted` but before `acked`:
    /// at-least-once means re-deliver (receiver/idempotency dedups).
    case unknownAfterSend = "unknown_after_send"
    /// Retries exhausted or a permanent failure → dead-letter (kept in the log).
    case failed
}

/// One unit of outbound work. `payload` is opaque to the queue.
public struct OutboundJob: Sendable, Codable, Equatable {
    public let id: String
    public let target: String
    public let payload: Data
    /// Collapses duplicate sends within the queue's (in-memory) dedup window.
    public let idempotencyKey: String?
    public var attempts: Int
    public var state: DeliveryState
    /// Monotonic enqueue sequence — recovery re-drives in this order so a
    /// per-target stream is replayed deterministically (not dictionary order).
    public var seq: Int64
    public init(id: String, target: String, payload: Data,
                idempotencyKey: String? = nil, attempts: Int = 0,
                state: DeliveryState = .enqueued, seq: Int64 = 0) {
        self.id = id; self.target = target; self.payload = payload
        self.idempotencyKey = idempotencyKey; self.attempts = attempts
        self.state = state; self.seq = seq
    }
}

/// The result of one transport attempt.
public enum DeliveryOutcome: Sendable, Equatable {
    case acked              // delivered
    case retry              // transient failure — retry with backoff
    case permanentFailure   // non-retryable — dead-letter immediately
}

/// What the queue calls to actually send. #7 provides concrete sinks; the reply
/// path (#1) provides a channel send.
public protocol DeliveryExecutor: Sendable {
    func deliver(_ job: OutboundJob) async -> DeliveryOutcome
}

/// Outcome handed back to the enqueuer.
///
/// CONTRACT: when `deduped == false`, `finalState` is terminal — either `.acked`
/// or `.failed`. When `deduped == true` the call was COLLAPSED (its
/// idempotencyKey was acked within the window, is already in flight, or a
/// recover()/enqueue() race already claimed the id); in that case `finalState`
/// is the last-known persisted state and may be NON-terminal, so callers must
/// check `deduped` before treating `finalState` as this call's delivery outcome.
public struct DeliveryReceipt: Sendable, Equatable {
    public let id: String
    public let finalState: DeliveryState
    public let attempts: Int
    public let deduped: Bool
}

/// A durable, at-least-once delivery queue. Each state transition is appended
/// (fsync'd via F_FULLFSYNC) to a JSONL log BEFORE the corresponding side
/// effect, so a crash leaves a recoverable record. `recover()` re-drives every
/// job whose last persisted state is non-terminal (in `seq` order, applying the
/// same idempotency dedup the enqueue path does). The log is compacted (acked
/// records dropped; failed kept as dead-letter) on recover and when it crosses
/// a size threshold, so it tracks the LIVE backlog, not lifetime history.
///
/// Concurrency: the actor serializes log writes. An `inFlight` id set ensures at
/// most ONE driver per job id, and an `inFlightKeys` set collapses concurrent
/// same-key deliveries; `drive` releases the caller-reserved key on EVERY exit
/// (including the single-driver early-return). `enqueue` awaits `drive` to a
/// terminal state (the reply path #1 wants the result); a fire-and-forget
/// submit layer (#7) wraps `enqueue` in a Task and adds BoundedChannel
/// admission control on top of this core.
public actor DurableDeliveryQueue {
    private let dir: String
    private let logPath: String
    private let executor: any DeliveryExecutor
    private let backoff: Backoff
    private let maxAttempts: Int
    private let attemptTimeout: Duration
    private let dedupWindowSeconds: Double
    private let compactThresholdBytes: Int
    private let now: @Sendable () -> Double
    /// idempotencyKey → monotonic time it was acked (in-memory dedup window).
    private var ackedKeys: [String: Double] = [:]
    /// idempotencyKeys currently being driven (collapse concurrent same-key sends).
    private var inFlightKeys: Set<String> = []
    /// job ids currently being driven (single-driver-per-id guard).
    private var inFlight: Set<String> = []
    private var seqCounter: Int64           // seeded from the log in init
    /// Bytes appended since the last compaction — drives `maybeCompact` without a
    /// per-ack `stat()`.
    private var appendedBytes: Int          // seeded from the log size in init
    /// In-memory mirror of the log's latest-record-per-id (the live backlog).
    /// Maintained in lockstep with the durable log — every successful `persist`
    /// updates it and `compact` rebuilds it, both within the synchronous actor —
    /// so `status`/`failedJobs`/`compact` never re-parse queue.jsonl. Seeded from
    /// the log exactly once, at init.
    private var latestPerJob: [String: OutboundJob]
    private var fh: FileHandle? = nil
    private let encoder = JSONEncoder()

    public init(directory: String,
                executor: any DeliveryExecutor,
                backoff: Backoff = Backoff(base: .milliseconds(50), maxDelay: .seconds(30)),
                maxAttempts: Int = 8,
                attemptTimeout: Duration = .seconds(60),
                dedupWindowSeconds: Double = 300,
                compactThresholdBytes: Int = 1 << 20,
                now: @escaping @Sendable () -> Double = { MonotonicClock.now() }) {
        try? FileManager.default.createDirectory(atPath: directory,
                                                 withIntermediateDirectories: true)
        let path = directory + "/queue.jsonl"
        // Pre-create the log so `persist` always appends through one durable
        // FileHandle (no whole-file fallback that could clobber it). The handle
        // is opened lazily on first persist (a nonisolated init can't store a
        // non-Sendable FileHandle into actor-isolated state). The dedup window is
        // in-memory; the durable LOG guards against LOST delivery (receiver
        // idempotency handles cross-restart DUPLICATEs — standard at-least-once).
        let existed = FileManager.default.fileExists(atPath: path)
        if !existed { FileManager.default.createFile(atPath: path, contents: nil) }
        // Seed the seq counter past any persisted record so an enqueue() BEFORE a
        // recover() can't reuse a seq already in the log (which would make the
        // seq-ordered recovery ambiguous), and seed the append-bytes counter from
        // the current size so compaction triggers without a per-ack stat().
        let folded = DurableDeliveryQueue.fold(logPath: path)
        self.dir = directory
        self.logPath = path
        self.executor = executor
        self.backoff = backoff
        self.maxAttempts = Swift.max(1, maxAttempts)
        self.attemptTimeout = attemptTimeout
        self.dedupWindowSeconds = dedupWindowSeconds
        self.compactThresholdBytes = Swift.max(4096, compactThresholdBytes)
        self.now = now
        self.seqCounter = folded.latest.values.map(\.seq).max() ?? 0
        self.appendedBytes = folded.bytes
        self.latestPerJob = folded.latest
        // Re-seed the (in-memory) idempotency dedup window from the durable log so it
        // SURVIVES a restart. ackedKeys is otherwise empty after a crash, so a recover()
        // re-drive PLUS a fresh enqueue of a just-delivered key would double-send. The log
        // has no per-record ack timestamp and the prior process's monotonic clock is
        // meaningless after a reboot, so we grant each already-acked key a FRESH full
        // window from THIS process's now() — which can only briefly OVER-suppress (never
        // double-send) and self-expires after dedupWindowSeconds. Only `.acked` seeds the
        // window: `.failed` is dead-letter, and a re-enqueue of a failed key is a
        // legitimate operator retry that must NOT be deduped.
        if dedupWindowSeconds > 0 {
            let seedT = now()
            // Seed from the LAST-APPENDED record per idempotency key. `seq` is assigned at
            // ENQUEUE time and does NOT track when a job acked/failed, so reducing by seq is
            // wrong: a lower-seq job can ack chronologically AFTER a higher-seq job fails (e.g.
            // a crash-residue job re-driven by recover() appends its ack after a newer job's
            // failure). The append-only log records terminal transitions in true chronological
            // order, so `fold` builds lastByKey by overwriting per key in file order — its last
            // entry is the genuine newest state. Seed only when that is `.acked`; a key whose
            // newest state is `.failed` stays retryable (the operator-retry case).
            for (key, job) in folded.lastByKey where job.state == .acked {
                ackedKeys[key] = seedT
            }
        }
        // All stored properties are initialized → safe to call an instance method.
        if !existed { fsyncDirectory() }
    }

    /// Lazily open (and cache) the append handle, seeked to end. Actor-isolated.
    private func openHandle() -> FileHandle? {
        if fh == nil {
            fh = FileHandle(forWritingAtPath: logPath)
            _ = try? fh?.seekToEnd()
        }
        return fh
    }

    // MARK: persistence

    /// Append one transition record and fsync it (F_FULLFSYNC) BEFORE its side
    /// effect. Returns false if the durable write could not be made — the caller
    /// MUST NOT perform the side effect in that case.
    private func persist(_ job: OutboundJob) -> Bool {
        guard let fh = openHandle(), var line = try? encoder.encode(job) else { return false }
        line.append(0x0A)
        do {
            try fh.write(contentsOf: line)
        } catch { return false }
        // The line is now in the file. Advance the byte counter + in-memory mirror
        // to match the file's CONTENTS — `fold()`/recovery read written bytes
        // whether or not they've been flushed, so the mirror must too (this is
        // what keeps map == log). The DURABILITY flush is a separate concern:
        appendedBytes += line.count
        latestPerJob[job.id] = job
        // Flush to stable storage. A flush failure means the record may not
        // survive a crash, so the CALLER must NOT perform the side effect — report
        // it by returning false. The line stays in the file + mirror (consistent)
        // and is re-driven on the next recover().
        return Self.flush(fh)
    }

    /// Flush `fh` to stable storage. F_FULLFSYNC flushes the drive cache (plain
    /// fsync/synchronize does not on Apple platforms); fall back to
    /// `synchronize()` if it fails or off-Darwin. Returns whether the flush made
    /// the bytes durable.
    private static func flush(_ fh: FileHandle) -> Bool {
        #if canImport(Darwin)
        if fcntl(fh.fileDescriptor, F_FULLFSYNC) != -1 { return true }
        #endif
        do { try fh.synchronize(); return true } catch { return false }
    }

    private nonisolated func fsyncDirectory() {
        #if canImport(Darwin)
        let fd = open(dir, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        #endif
    }

    // MARK: public API

    /// Enqueue a job and drive it to a terminal state. Deduped (skipped) if its
    /// idempotencyKey was acked within the window, or is currently in-flight.
    @discardableResult
    public func enqueue(_ job0: OutboundJob) async -> DeliveryReceipt {
        pruneDedup()
        if let key = job0.idempotencyKey {
            if let t = ackedKeys[key], now() - t < dedupWindowSeconds {
                return DeliveryReceipt(id: job0.id, finalState: .acked, attempts: 0, deduped: true)
            }
            // Reserve the key SYNCHRONOUSLY (before any await) so a concurrent
            // same-key enqueue is deduped rather than racing to a second send.
            if inFlightKeys.contains(key) {
                return DeliveryReceipt(id: job0.id, finalState: job0.state, attempts: 0, deduped: true)
            }
            inFlightKeys.insert(key)
        }
        var job = job0
        seqCounter &+= 1
        job.seq = seqCounter
        job.state = .enqueued
        guard persist(job) else {
            if let key = job.idempotencyKey { inFlightKeys.remove(key) }
            return DeliveryReceipt(id: job.id, finalState: .failed, attempts: 0, deduped: false)
        }
        return await drive(job)
    }

    /// Replay the durable log and re-drive every job whose last persisted state
    /// is non-terminal, in `seq` order. A `sendAttemptStarted` job becomes
    /// `unknownAfterSend` (crash mid-send → at-least-once). Applies the SAME
    /// idempotency dedup the enqueue path does, so recovery can't re-send a key
    /// just acked this run or one a live enqueue is already driving. Compacts
    /// first and reuses the result (single parse).
    @discardableResult
    public func recover() async -> [DeliveryReceipt] {
        let live = compact()
        let pending = live.filter { $0.state != .failed }.sorted { $0.seq < $1.seq }
        var receipts: [DeliveryReceipt] = []
        for var job in pending {
            seqCounter = Swift.max(seqCounter, job.seq)
            if let key = job.idempotencyKey {
                if let t = ackedKeys[key], now() - t < dedupWindowSeconds { continue }   // recently acked
                if inFlightKeys.contains(key) { continue }                                // a live enqueue owns it
                inFlightKeys.insert(key)                                                   // reserve so a concurrent enqueue is collapsed
            }
            if job.state == .sendAttemptStarted {
                job.state = .unknownAfterSend
                _ = persist(job)
            }
            receipts.append(await drive(job))
        }
        return receipts
    }

    /// Dead-letter inspection: jobs whose last persisted state is `.failed`.
    public func failedJobs() -> [OutboundJob] {
        latestPerJob.values.filter { $0.state == .failed }.sorted { $0.seq < $1.seq }
    }

    /// Last persisted state of a job id (nil if unknown).
    public func status(_ id: String) -> DeliveryState? { latestPerJob[id]?.state }

    // MARK: core state machine

    private func drive(_ job0: OutboundJob) async -> DeliveryReceipt {
        // ALWAYS release the caller-reserved idempotency key on ANY exit,
        // including the single-driver early-return below. Declaring this defer
        // BEFORE the guard is the fix: a defer placed after the guard would not
        // run on the early-return path, permanently poisoning the key.
        defer { if let key = job0.idempotencyKey { inFlightKeys.remove(key) } }
        // Single-driver-per-id: a second recover()/enqueue() for an id already
        // being driven is a no-op. The deduped receipt's finalState is the
        // last-known state (possibly non-terminal) — callers must check `deduped`.
        guard inFlight.insert(job0.id).inserted else {
            return DeliveryReceipt(id: job0.id, finalState: job0.state, attempts: job0.attempts, deduped: true)
        }
        defer { inFlight.remove(job0.id) }
        var job = job0
        while true {
            job.state = .sendAttemptStarted
            job.attempts += 1
            guard persist(job) else {
                // Could not durably record the intent → do NOT send. Treat as a
                // transient failure: back off and retry the persist (up to the
                // attempt ceiling), never delivering without a durable record.
                if job.attempts >= maxAttempts { return await fail(&job) }
                try? await backoff.sleep(forAttempt: job.attempts - 1)
                continue
            }
            switch await deliverWithTimeout(job) {
            case .acked:
                job.state = .acked
                _ = persist(job)
                if let key = job.idempotencyKey { ackedKeys[key] = now() }
                maybeCompact()
                return DeliveryReceipt(id: job.id, finalState: .acked,
                                       attempts: job.attempts, deduped: false)
            case .permanentFailure:
                return await fail(&job)
            case .retry:
                if job.attempts >= maxAttempts { return await fail(&job) }
                try? await backoff.sleep(forAttempt: job.attempts - 1)
            }
        }
    }

    private func fail(_ job: inout OutboundJob) async -> DeliveryReceipt {
        job.state = .failed
        _ = persist(job)
        maybeCompact()
        return DeliveryReceipt(id: job.id, finalState: .failed, attempts: job.attempts, deduped: false)
    }

    /// Race the transport send against a per-attempt deadline, returning as soon
    /// as EITHER completes — WITHOUT awaiting the loser. A structured task group
    /// implicitly awaits all children at scope exit, so a sink that ignores
    /// cancellation would wedge the actor despite the timeout. Using unstructured
    /// tasks + a one-shot gate means a hung send is abandoned (it leaks until it
    /// eventually returns, but never blocks the queue) and the attempt becomes a
    /// `.retry`. `work.cancel()` lets a cooperative sink stop early.
    private func deliverWithTimeout(_ job: OutboundJob) async -> DeliveryOutcome {
        let exec = executor
        let timeout = attemptTimeout
        let gate = SingleResume()
        let work = Task { let o = await exec.deliver(job); await gate.resume(o) }
        let timer = Task { try? await Task.sleep(for: timeout); await gate.resume(.retry) }
        let outcome = await gate.wait()
        work.cancel()
        timer.cancel()
        return outcome
    }

    // MARK: dedup pruning + compaction

    private func pruneDedup() {
        guard !ackedKeys.isEmpty else { return }
        let cutoff = now() - dedupWindowSeconds
        ackedKeys = ackedKeys.filter { $0.value >= cutoff }
    }

    private func maybeCompact() {
        // Use the bytes we appended (tracked in persist) instead of a stat() per ack.
        if appendedBytes > compactThresholdBytes { _ = compact() }
    }

    /// Rewrite the log keeping only the latest record per NON-acked id (failed
    /// jobs are KEPT as dead-letter), so it tracks the live backlog. Returns the
    /// kept set so `recover()` reuses it without a second parse.
    @discardableResult
    private func compact() -> [OutboundJob] {
        let live = latestPerJob.values
            .filter { $0.state != .acked }
            .sorted { $0.seq < $1.seq }
        guard !live.isEmpty || FileManager.default.fileExists(atPath: logPath) else { return live }
        var data = Data()
        for job in live { if let l = try? encoder.encode(job) { data.append(l); data.append(0x0A) } }
        let tmp = logPath + ".compact"
        do {
            try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            // Flush the temp's CONTENTS to disk BEFORE the destructive rename:
            // `.atomic` only renames, it does not F_FULLFSYNC the data, so a crash
            // after the rename could otherwise leave an empty/torn log with the
            // original already unlinked — whole-backlog loss. If we cannot make the
            // compacted copy durable, ABORT into `catch` rather than destroy the
            // original. (Close the temp handle either way — no leak on the abort.)
            let tfh = FileHandle(forWritingAtPath: tmp)
            let durable = tfh.map { Self.flush($0) } ?? false
            try? tfh?.close()
            guard durable else { throw CompactionAborted() }
            // Drop the old handle so the rename can replace the file; `fh = nil`
            // makes the state honest so `catch`/next persist reopens cleanly on
            // whichever log is actually in place.
            try? fh?.close(); fh = nil
            // `try` (NOT try?) so a failed replace enters `catch` with the map +
            // byte counter still matching the UN-replaced (old) log — no drift.
            try FileManager.default.replaceItemAt(URL(fileURLWithPath: logPath),
                                                  withItemAt: URL(fileURLWithPath: tmp))
            fsyncDirectory()
            fh = FileHandle(forWritingAtPath: logPath)
            _ = try? fh?.seekToEnd()
            appendedBytes = data.count
            // The log now holds exactly `live` (acked records dropped); mirror it
            // in memory so a compacted-away acked job reports `nil` status, just as
            // a fresh re-parse would. Reached ONLY when the replace succeeded.
            latestPerJob = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        } catch {
            // Compaction is best-effort and the rewrite did NOT take effect: the
            // old log, the in-memory mirror, and appendedBytes are all left
            // untouched and consistent. Clean up the temp and ensure an open
            // append handle on the (still-original) log.
            try? FileManager.default.removeItem(atPath: tmp)
            if fh == nil { fh = FileHandle(forWritingAtPath: logPath); _ = try? fh?.seekToEnd() }
        }
        return live
    }

    /// Fold the JSONL log to the latest record per job id. A torn final line
    /// (no trailing newline, partial JSON) fails to decode and is dropped — the
    /// prior complete record for that id correctly remains authoritative. Used
    /// once, by `init`, to seed the in-memory mirror + the seq/byte counters;
    /// steady-state reads go through `latestPerJob`, not the log.
    private nonisolated static func fold(logPath: String)
        -> (latest: [String: OutboundJob], lastByKey: [String: OutboundJob], bytes: Int) {
        let decoder = JSONDecoder()
        guard let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) else { return ([:], [:], 0) }
        var latest: [String: OutboundJob] = [:]
        // lastByKey overwrites per idempotency key in FILE (append) order, so its final
        // entry per key is that key's chronologically-newest terminal state — the correct
        // signal for dedup-window re-seeding (seq is enqueue-time, not transition-time).
        var lastByKey: [String: OutboundJob] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let job = try? decoder.decode(OutboundJob.self, from: Data(line.utf8)) {
                latest[job.id] = job
                if let key = job.idempotencyKey { lastByKey[key] = job }
            }
        }
        return (latest, lastByKey, data.count)
    }
}

/// Thrown by `compact()` when the compacted temp could not be made durable, so
/// the destructive rename is aborted and the original log is kept intact.
private struct CompactionAborted: Error {}

/// A one-shot async value: the first `resume` wins, `wait` returns it. Used to
/// race a delivery attempt against a timeout WITHOUT a structured task group
/// (which would await the losing/hung child at scope exit and defeat the timeout).
private actor SingleResume {
    private var cont: CheckedContinuation<DeliveryOutcome, Never>?
    private var pending: DeliveryOutcome?
    func wait() async -> DeliveryOutcome {
        if let p = pending { return p }
        return await withCheckedContinuation { cont = $0 }
    }
    func resume(_ o: DeliveryOutcome) {
        if let c = cont { cont = nil; c.resume(returning: o) }
        else if pending == nil { pending = o }
    }
}
