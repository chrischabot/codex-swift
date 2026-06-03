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

/// Terminal outcome handed back to the enqueuer.
public struct DeliveryReceipt: Sendable, Equatable {
    public let id: String
    public let finalState: DeliveryState   // .acked or .failed (or current, if skipped)
    public let attempts: Int
    public let deduped: Bool               // skipped: idempotency window OR already in-flight
}

/// A durable, at-least-once delivery queue. Each state transition is appended
/// (fsync'd via F_FULLFSYNC) to a JSONL log BEFORE the corresponding side
/// effect, so a crash leaves a recoverable record. `recover()` re-drives every
/// job whose last persisted state is non-terminal (in `seq` order). The log is
/// compacted (terminal records dropped) on recover and when it crosses a size
/// threshold, so it tracks the LIVE backlog, not lifetime history.
///
/// Concurrency: the actor serializes log writes. An `inFlight` id set ensures
/// at most ONE driver per job id, so a double `recover()` (or `recover()`
/// racing a live `enqueue()` for the same id) does NOT fork into two senders.
/// `enqueue` awaits `drive` to a terminal state (the reply path #1 wants the
/// result); #7's fire-and-forget submit layer wraps `enqueue` in a Task and
/// adds BoundedChannel admission control on top of this core.
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
    /// idempotencyKeys currently being driven (so two concurrent same-key
    /// enqueues don't both deliver before either acks).
    private var inFlightKeys: Set<String> = []
    /// job ids currently being driven (single-driver-per-id guard).
    private var inFlight: Set<String> = []
    private var seqCounter: Int64 = 0
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
        self.dir = directory
        self.logPath = directory + "/queue.jsonl"
        self.executor = executor
        self.backoff = backoff
        self.maxAttempts = Swift.max(1, maxAttempts)
        self.attemptTimeout = attemptTimeout
        self.dedupWindowSeconds = dedupWindowSeconds
        self.compactThresholdBytes = Swift.max(4096, compactThresholdBytes)
        self.now = now
        // Pre-create + open the log once, so `persist` ALWAYS appends through a
        // single durable FileHandle (no brittle whole-file fallback that could
        // clobber the log). The dedup window is in-memory; the durable LOG is
        // the cross-restart guarantee against LOST delivery (receiver
        // idempotency handles cross-restart DUPLICATEs — standard at-least-once).
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            fsyncDirectory()   // make the new file's directory entry durable
        }
        // The append FileHandle is opened lazily on first persist (an
        // actor-isolated context); a nonisolated init can't store a non-Sendable
        // FileHandle into actor-isolated state.
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
        // F_FULLFSYNC flushes the drive cache (plain fsync/synchronize does not
        // on Apple platforms). Fall back to synchronize() elsewhere.
        #if canImport(Darwin)
        if fcntl(fh.fileDescriptor, F_FULLFSYNC) == -1 { try? fh.synchronize() }
        #else
        try? fh.synchronize()
        #endif
        return true
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
                return DeliveryReceipt(id: job0.id, finalState: .enqueued, attempts: 0, deduped: true)
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
    /// `unknownAfterSend` (crash mid-send → at-least-once). Idempotent: a job
    /// already in-flight (from a prior recover or a live enqueue) is skipped.
    /// Compacts the log first (drops terminal records).
    @discardableResult
    public func recover() async -> [DeliveryReceipt] {
        compact()
        let pending = loadLatestPerJob().values
            .filter { $0.state != .acked && $0.state != .failed }
            .sorted { $0.seq < $1.seq }
        var receipts: [DeliveryReceipt] = []
        for var job in pending {
            // keep the running seq monotonic past recovered ids
            seqCounter = Swift.max(seqCounter, job.seq)
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
        loadLatestPerJob().values.filter { $0.state == .failed }.sorted { $0.seq < $1.seq }
    }

    /// Last persisted state of a job id (nil if unknown).
    public func status(_ id: String) -> DeliveryState? { loadLatestPerJob()[id]?.state }

    // MARK: core state machine

    private func drive(_ job0: OutboundJob) async -> DeliveryReceipt {
        // Single-driver-per-id: a second recover()/enqueue() for an id already
        // being driven is a no-op (prevents concurrent self-duplication).
        guard inFlight.insert(job0.id).inserted else {
            return DeliveryReceipt(id: job0.id, finalState: job0.state, attempts: job0.attempts, deduped: true)
        }
        defer {
            inFlight.remove(job0.id)
            if let key = job0.idempotencyKey { inFlightKeys.remove(key) }
        }
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

    /// Race the transport send against a per-attempt deadline so a hung sink
    /// can never wedge the queue; a timeout is a synthetic `.retry`.
    private func deliverWithTimeout(_ job: OutboundJob) async -> DeliveryOutcome {
        let exec = executor
        let timeout = attemptTimeout
        return await withTaskGroup(of: DeliveryOutcome?.self) { group -> DeliveryOutcome in
            group.addTask { await exec.deliver(job) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? .some(.retry)
            group.cancelAll()
            return first ?? .retry   // nil sentinel = timeout → retry
        }
    }

    // MARK: dedup pruning + compaction

    private func pruneDedup() {
        guard !ackedKeys.isEmpty else { return }
        let cutoff = now() - dedupWindowSeconds
        ackedKeys = ackedKeys.filter { $0.value >= cutoff }
    }

    private func maybeCompact() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logPath)
        let size = (attrs?[.size] as? Int) ?? 0
        if size > compactThresholdBytes { compact() }
    }

    /// Rewrite the log keeping only the latest record per NON-terminal id, so it
    /// tracks the live backlog. In-flight jobs are non-terminal → preserved;
    /// their next `persist` appends to the reopened handle.
    private func compact() {
        // Drop only acked (delivered) records — the bulk of the log. KEEP failed
        // jobs as a dead-letter for failedJobs()/status() retrieval (a TTL is
        // future work). In-flight (non-terminal) jobs are preserved too.
        let live = loadLatestPerJob().values
            .filter { $0.state != .acked }
            .sorted { $0.seq < $1.seq }
        guard !live.isEmpty || FileManager.default.fileExists(atPath: logPath) else { return }
        var data = Data()
        for job in live { if let l = try? encoder.encode(job) { data.append(l); data.append(0x0A) } }
        let tmp = logPath + ".compact"
        do {
            try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            try? fh?.close()
            _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: logPath),
                                                       withItemAt: URL(fileURLWithPath: tmp))
            fsyncDirectory()
            fh = FileHandle(forWritingAtPath: logPath)
            _ = try? fh?.seekToEnd()
        } catch {
            // Compaction is best-effort; on failure keep appending to the old fh.
            try? FileManager.default.removeItem(atPath: tmp)
            if fh == nil { fh = FileHandle(forWritingAtPath: logPath); _ = try? fh?.seekToEnd() }
        }
    }

    /// Fold the JSONL log to the latest record per job id. A torn final line
    /// (no trailing newline, partial JSON) fails to decode and is dropped — the
    /// prior complete record for that id correctly remains authoritative.
    private func loadLatestPerJob() -> [String: OutboundJob] {
        let decoder = JSONDecoder()
        guard let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var latest: [String: OutboundJob] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let job = try? decoder.decode(OutboundJob.self, from: Data(line.utf8)) {
                latest[job.id] = job
            }
        }
        return latest
    }
}
