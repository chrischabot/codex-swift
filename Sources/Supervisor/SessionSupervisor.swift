import Foundation
import IPC
import ProtocolModel
import InfraPrimitives
import WireProtocol

public struct WorkerHandle: Sendable {
    public let link: WorkerLink
    public let task: Task<Void, Never>
    public let pid: Int32?
    public let terminate: @Sendable () -> Void
    public init(link: WorkerLink,
                task: Task<Void, Never>,
                pid: Int32? = nil,
                terminate: @escaping @Sendable () -> Void = {}) {
        self.link = link
        self.task = task
        self.pid = pid
        self.terminate = terminate
    }
}

/// Builds/spawns a worker for a session. In-process for tests/single-process;
/// `posix_spawn` of `codex-session` on macOS. The factory boundary keeps the
/// process model pluggable without changing the supervisor.
public typealias WorkerFactory = @Sendable (SessionConfig) async -> WorkerHandle

/// One subscriber's notification sink (a connection's relay callback).
public struct NotificationSink: Sendable {
    public let id: UInt64
    public let requestAttestation: Bool
    public let deliver: @Sendable (ServerNotification) -> Void
    public let onServerRequest: @Sendable (ServerRequest) -> Void
    public init(id: UInt64,
                requestAttestation: Bool = false,
                deliver: @escaping @Sendable (ServerNotification) -> Void,
                onServerRequest: @escaping @Sendable (ServerRequest) -> Void = { _ in }) {
        self.id = id
        self.requestAttestation = requestAttestation
        self.deliver = deliver
        self.onServerRequest = onServerRequest
    }
}

/// Per-thread runtime facts mirroring upstream `RuntimeFacts`
/// (app-server/src/thread_status.rs:421-427). The derived `ThreadStatus`
/// follows `loaded_thread_status` exactly: a loaded thread is `Active` while a
/// turn is running or any approval/user-input request is outstanding (carrying
/// the corresponding `activeFlags`), `systemError` when flagged, otherwise
/// `idle`; an unloaded thread is `notLoaded`.
private struct ThreadRuntimeFacts: Equatable {
    var isLoaded = false
    var running = false
    var pendingPermissionRequests = 0
    var pendingUserInputRequests = 0
    var hasSystemError = false

    /// Mirror of upstream `loaded_thread_status`.
    var status: ThreadStatus {
        guard isLoaded else { return .notLoaded }
        var flags: [ThreadActiveFlag] = []
        if pendingPermissionRequests > 0 { flags.append(.waitingOnApproval) }
        if pendingUserInputRequests > 0 { flags.append(.waitingOnUserInput) }
        if running || !flags.isEmpty { return .active(activeFlags: flags) }
        if hasSystemError { return .systemError }
        return .idle
    }
}

public actor SessionSupervisor {
    private let factory: WorkerFactory
    private var workers: [ThreadId: WorkerHandle] = [:]
    /// Latest `SessionConfig` we bound to the worker for each thread. Used
    /// by the router's turn-boundary environment-switch detection so it does
    /// not need to fsync-and-reconstruct the rollout just to know the
    /// current binding.
    private var boundConfigs: [ThreadId: SessionConfig] = [:]
    private var subscribers: [ThreadId: [NotificationSink]] = [:]
    /// The last subscriber(s) seen before a thread went subscriber-less, kept
    /// only to deliver a final `thread/closed` on idle-unload (upstream
    /// ThreadClosedNotification). Cleared on re-subscribe or teardown.
    private var formerSubscribers: [ThreadId: [NotificationSink]] = [:]
    private var relays: [ThreadId: Task<Void, Never>] = [:]
    /// Monotonic per-thread relay generation. Bumped on every relay CREATION
    /// (`ensureWorker`, `rebindRemoteEnvironment`) and on every force-stop /
    /// quiesce. A relay captures its generation; when it ends it calls
    /// `clearThread(_:gen:)`, which no-ops if the generation is stale — so a
    /// relay whose worker was replaced (rebind) or explicitly torn down cannot
    /// clobber the live worker/subscribers or emit a spurious `thread/closed`.
    private var relayGen: [ThreadId: UInt64] = [:]
    private var nextSinkId: UInt64 = 0
    private let maxSessions: Int
    private let limits: Limits
    private let sampler: any ResourceSampler
    private var ledgers: [ThreadId: ResourceLedger] = [:]
    private var governorStates: [ThreadId: GovernorState] = [:]
    private var resourceControls: [ThreadId: WorkerResourceControl] = [:]
    private var lastHeartbeats: [ThreadId: Double] = [:]
    private var idleUnloadTasks: [ThreadId: Task<Void, Never>] = [:]
    private var quiescingWorkers: Set<ThreadId> = []
    private var pendingServerRequests: [String: ThreadId] = [:]
    /// The typed `RequestId` for each outstanding server request, keyed by its
    /// string form. Retained so resolution/abort can broadcast a faithful
    /// `serverRequest/resolved` notification (which carries a `RequestId`).
    private var pendingServerRequestIds: [String: RequestId] = [:]
    /// The `ThreadActiveFlag` (if any) each outstanding server request
    /// contributes to the thread's status, so resolution can decrement the
    /// correct runtime counter. Approval-class requests map to
    /// `.waitingOnApproval`, user-input/elicitation requests to
    /// `.waitingOnUserInput`; status-neutral requests (attestation, dynamic
    /// tool call, auth-token refresh) are absent.
    private var pendingServerRequestFlags: [String: ThreadActiveFlag] = [:]
    /// Per-thread runtime facts driving `thread/status/changed` emission.
    private var statusFacts: [ThreadId: ThreadRuntimeFacts] = [:]
    private var pendingMcpResponses: [String: CheckedContinuation<WorkerMcpResponse, Never>] = [:]
    private var mcpResponseTimeouts: [String: Task<Void, Never>] = [:]

    public init(factory: @escaping WorkerFactory,
                maxSessions: Int = 1024,
                limits: Limits = Limits(),
                sampler: any ResourceSampler = DefaultResourceSampler()) {
        self.factory = factory
        self.maxSessions = Swift.max(1, maxSessions)
        self.limits = limits.clamped()
        self.sampler = sampler
    }

    /// Session-flood admission control: true when no new session may bind.
    /// Already-bound sessions (idempotent re-bind) are unaffected.
    public func atCapacity() -> Bool { workers.count >= maxSessions }

    private func subscribersFor(_ t: ThreadId) -> [NotificationSink] { subscribers[t] ?? [] }

    /// Advance and return the relay generation for `t` (see `relayGen`).
    private func nextRelayGen(_ t: ThreadId) -> UInt64 {
        let g = (relayGen[t] ?? 0) &+ 1
        relayGen[t] = g
        return g
    }

    /// Bind (or reuse) a worker for `config` and add this connection as a
    /// subscriber. Idempotent per thread; many connections fan out from one
    /// worker (rework many-conn→one-thread). Returns the subscriber id so a
    /// connection can later unsubscribe.
    @discardableResult
    public func ensureWorker(
        _ config: SessionConfig,
        requestAttestation: Bool = false,
        onNotification: @escaping @Sendable (ServerNotification) -> Void,
        onServerRequest: @escaping @Sendable (ServerRequest) -> Void = { _ in }
    ) async -> UInt64 {
        let sinkId = nextSinkId; nextSinkId &+= 1
        subscribers[config.threadId, default: []].append(
            NotificationSink(id: sinkId, requestAttestation: requestAttestation,
                             deliver: onNotification,
                             onServerRequest: onServerRequest))
        formerSubscribers[config.threadId] = nil

        idleUnloadTasks.removeValue(forKey: config.threadId)?.cancel()

        if workers[config.threadId] != nil {
            if quiescingWorkers.contains(config.threadId) {
                forceStopWorker(config.threadId, clearSubscribers: false)
            } else {
                return sinkId   // already running; just subscribed
            }
        }

        let handle = await factory(config)
        workers[config.threadId] = handle
        lastHeartbeats[config.threadId] = MonotonicClock.now()
        if let pid = handle.pid {
            ledgers[config.threadId] = ResourceLedger(pid: pid, limits: limits, sampler: sampler)
            governorStates[config.threadId] = .normal
        }
        let tid = config.threadId
        let gen = nextRelayGen(tid)
        relays[tid] = Task {
            for await ev in handle.link.outbound {
                switch ev {
                case .ready:
                    self.recordHeartbeat(tid)
                    continue
                case .heartbeat(let threadId):
                    if threadId == tid { self.recordHeartbeat(tid) }
                    continue
                case .notification(let n):
                    self.applyStatusEffect(n, tid)
                    for s in self.subscribersFor(tid) { s.deliver(n) }
                case .serverRequest(let req):
                    self.recordPending(req.id.description, tid)
                    self.noteServerRequestIssued(req, tid)
                    let sinks = self.subscribersFor(tid)
                    if case .attestationGenerate = req {
                        if let sink = sinks.first(where: { $0.requestAttestation }) {
                            sink.onServerRequest(req)
                        } else {
                            self.deliverServerResponse(
                                req.id.description,
                                result: .null,
                                failed: false)
                        }
                    } else {
                        for s in sinks { s.onServerRequest(req) }
                    }
                case .mcpResponse(let response):
                    self.resolveMcpResponse(response)
                case .finished:
                    self.clearThread(tid, gen: gen)
                    return
                }
            }
            self.clearThread(tid, gen: gen)
        }
        boundConfigs[config.threadId] = config
        markThreadLoaded(config.threadId)
        handle.link.sendToWorker(.bind(config))
        if handle.pid != nil {
            applyResourceControl(.normal(memoryLimitBytes: limits.ledgerHardMemoryBytes),
                                 to: config.threadId)
        }
        return sinkId
    }

    private func clearThread(_ tid: ThreadId, gen: UInt64) {
        // Stale-relay guard: a relay whose generation is no longer current (its
        // worker was replaced by a rebind, or force-stopped/quiesced) must NOT
        // tear down the live thread or emit thread/closed to (possibly
        // preserved) subscribers. Only the CURRENT relay's natural end runs.
        guard relayGen[tid] == gen else { return }
        relays[tid] = nil
        workers[tid] = nil
        boundConfigs[tid] = nil
        ledgers[tid] = nil
        governorStates[tid] = nil
        resourceControls[tid] = nil
        lastHeartbeats[tid] = nil
        idleUnloadTasks.removeValue(forKey: tid)?.cancel()
        quiescingWorkers.remove(tid)
        // Resolve outstanding server requests and emit the final notLoaded
        // status while subscribers are still attached.
        resolveAllServerRequests(for: tid)
        removeStatusFacts(tid)
        // Notify subscribers the thread closed (worker died / outbound ended)
        // BEFORE dropping them, so an in-flight turn collector (collectTurn)
        // and any other subscriber observe a terminal event instead of hanging
        // until their own timeout. Mirrors the idle-unload `thread/closed`
        // delivery in `forceStopWorker`.
        let closing = subscribers[tid] ?? formerSubscribers[tid] ?? []
        for s in closing { s.deliver(.threadClosed(threadId: tid)) }
        subscribers[tid] = nil
        formerSubscribers[tid] = nil
        pendingServerRequests = pendingServerRequests.filter { $0.value != tid }
        resolveMcpResponsesForClosedThread(tid)
    }

    private func recordHeartbeat(_ tid: ThreadId) {
        lastHeartbeats[tid] = MonotonicClock.now()
    }

    private func recordPending(_ requestId: String, _ tid: ThreadId) {
        pendingServerRequests[requestId] = tid
    }

    /// Route a client's approval/server-request response back to the worker
    /// that issued it. Keyed by the request-id string form.
    public func deliverServerResponse(_ requestId: String,
                                      result: JSONValue?,
                                      failed: Bool = false) {
        guard let tid = pendingServerRequests.removeValue(forKey: requestId) else { return }
        // Notify subscribers the prompt is gone (upstream
        // resolve_pending_server_request) and roll back the status flag.
        resolveServerRequest(requestId, tid)
        guard let w = workers[tid] else { return }
        w.link.sendToWorker(.serverResponse(WorkerServerResponse(
            requestId: requestId, result: result, failed: failed)))
    }

    public func requestMcp(_ request: WorkerMcpRequest,
                           timeout: Duration = .seconds(10)) async -> WorkerMcpResponse? {
        guard let worker = workers[request.threadId] else { return nil }
        let key = request.requestId
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<WorkerMcpResponse, Never>) in
            pendingMcpResponses[key] = continuation
            worker.link.sendToWorker(.mcpRequest(request))
            mcpResponseTimeouts[key] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resolveMcpResponse(WorkerMcpResponse(
                    requestId: key,
                    result: nil,
                    error: "MCP request timed out"))
            }
        }
    }

    private func resolveMcpResponse(_ response: WorkerMcpResponse) {
        mcpResponseTimeouts.removeValue(forKey: response.requestId)?.cancel()
        if let continuation = pendingMcpResponses.removeValue(forKey: response.requestId) {
            continuation.resume(returning: response)
        }
    }

    private func resolveMcpResponsesForClosedThread(_ threadId: ThreadId) {
        let prefix = "mcp-\(threadId.raw)-"
        for key in pendingMcpResponses.keys where key.hasPrefix(prefix) {
            resolveMcpResponse(WorkerMcpResponse(
                requestId: key,
                result: nil,
                error: "session worker closed before MCP response"))
        }
    }

    public func unsubscribe(_ threadId: ThreadId, _ sinkId: UInt64) {
        let removed = (subscribers[threadId] ?? []).first { $0.id == sinkId }
        subscribers[threadId]?.removeAll { $0.id == sinkId }
        if subscribers[threadId]?.isEmpty == true {
            // Retain the (former) subscriber so an eventual idle-unload can
            // deliver thread/closed to it (upstream notifies connections
            // subscribed to the thread). Cleared on re-subscribe or teardown.
            if let removed { formerSubscribers[threadId] = [removed] }
            subscribers[threadId] = nil
            scheduleIdleUnload(threadId)
        }
    }

    /// Push a thread-scoped notification to every current subscriber of that
    /// thread. Used for store-side mutations (goals/name/etc.) that do not
    /// flow through the engine event stream. No-op when no subscribers.
    public func broadcast(_ threadId: ThreadId, _ notification: ServerNotification) {
        for s in subscribers[threadId] ?? [] { s.deliver(notification) }
    }

    /// Terminal teardown for `thread/delete`: stop any running worker FIRST (so
    /// no further `record()` can revive the rollout file the store is about to
    /// remove), resolve outstanding requests, emit `thread/deleted` to current
    /// subscribers, then drop ALL in-memory state for the thread. Unlike
    /// idle-unload this is non-recoverable, so it emits `thread/deleted` rather
    /// than `thread/closed`. Safe to call for an unknown/unloaded thread (no-op
    /// beyond a harmless generation bump and the subscriber sweep).
    public func evictDeletedThread(_ tid: ThreadId) {
        if let h = workers[tid] { h.terminate(); h.link.finish() }
        relays[tid]?.cancel()
        relays[tid] = nil
        // Invalidate the cancelled relay's generation so its eventual drain into
        // clearThread no-ops instead of double-emitting a terminal event.
        _ = nextRelayGen(tid)
        workers[tid] = nil
        boundConfigs[tid] = nil
        ledgers[tid] = nil
        governorStates[tid] = nil
        resourceControls[tid] = nil
        lastHeartbeats[tid] = nil
        idleUnloadTasks.removeValue(forKey: tid)?.cancel()
        quiescingWorkers.remove(tid)
        resolveAllServerRequests(for: tid)
        removeStatusFacts(tid)
        let recipients = subscribers[tid] ?? formerSubscribers[tid] ?? []
        for s in recipients { s.deliver(.threadDeleted(threadId: tid)) }
        subscribers[tid] = nil
        formerSubscribers[tid] = nil
        pendingServerRequests = pendingServerRequests.filter { $0.value != tid }
        resolveMcpResponsesForClosedThread(tid)
    }

    // MARK: - thread/status/changed tracking (upstream ThreadWatchManager)

    /// Mutate a thread's runtime facts and, if the derived `ThreadStatus`
    /// transitions, broadcast `thread/status/changed`. Only emits on a real
    /// change (parity with upstream `status_changed_notification`'s
    /// previous-vs-current comparison).
    private func updateStatusFacts(_ tid: ThreadId,
                                   _ mutate: (inout ThreadRuntimeFacts) -> Void) {
        var facts = statusFacts[tid] ?? ThreadRuntimeFacts()
        let previous = facts.status
        mutate(&facts)
        let next = facts.status
        statusFacts[tid] = facts
        guard previous != next else { return }
        broadcast(tid, .threadStatusChanged(threadId: tid, status: next))
    }

    /// Mark a thread loaded (worker bound). Mirrors upstream `upsert_thread`:
    /// a freshly loaded, quiescent thread transitions `notLoaded` → `idle`.
    private func markThreadLoaded(_ tid: ThreadId) {
        updateStatusFacts(tid) { $0.isLoaded = true }
    }

    /// Drop a thread's status tracking and, if it was previously a loaded
    /// status, emit a final `notLoaded` transition (upstream `remove_thread`).
    private func removeStatusFacts(_ tid: ThreadId) {
        guard let facts = statusFacts.removeValue(forKey: tid) else { return }
        let previous = facts.status
        guard previous != .notLoaded else { return }
        broadcast(tid, .threadStatusChanged(threadId: tid, status: .notLoaded))
    }

    /// The active flag a server request contributes to thread status, or `nil`
    /// for status-neutral requests. Mirrors upstream's guard selection in
    /// bespoke_event_handling.rs (approval-class → permission/`waitingOnApproval`;
    /// user-input/elicitation → `waitingOnUserInput`).
    private static func statusFlag(for req: ServerRequest) -> ThreadActiveFlag? {
        switch req {
        case .commandApproval, .patchApproval, .permissionsApproval,
             .mcpElicitation, .applyPatchApproval, .execCommandApproval:
            return .waitingOnApproval
        case .toolRequestUserInput:
            return .waitingOnUserInput
        case .dynamicToolCall, .chatgptAuthTokensRefresh, .attestationGenerate:
            return nil
        }
    }

    /// Note a server request was issued: track its id/flag and bump the
    /// corresponding runtime counter (driving `thread/status/changed`).
    private func noteServerRequestIssued(_ req: ServerRequest, _ tid: ThreadId) {
        let key = req.id.description
        pendingServerRequestIds[key] = req.id
        guard let flag = Self.statusFlag(for: req) else { return }
        pendingServerRequestFlags[key] = flag
        updateStatusFacts(tid) { facts in
            switch flag {
            case .waitingOnApproval: facts.pendingPermissionRequests += 1
            case .waitingOnUserInput: facts.pendingUserInputRequests += 1
            }
        }
    }

    /// Resolve a single outstanding server request id: drop its bookkeeping,
    /// decrement the runtime counter, broadcast `serverRequest/resolved` to the
    /// thread's subscribers, and emit any resulting `thread/status/changed`.
    private func resolveServerRequest(_ key: String, _ tid: ThreadId) {
        if let rid = pendingServerRequestIds.removeValue(forKey: key) {
            broadcast(tid, .serverRequestResolved(threadId: tid, requestId: rid))
        }
        guard let flag = pendingServerRequestFlags.removeValue(forKey: key) else { return }
        updateStatusFacts(tid) { facts in
            switch flag {
            case .waitingOnApproval:
                facts.pendingPermissionRequests = Swift.max(0, facts.pendingPermissionRequests - 1)
            case .waitingOnUserInput:
                facts.pendingUserInputRequests = Swift.max(0, facts.pendingUserInputRequests - 1)
            }
        }
    }

    /// Abort/resolve every outstanding server request for a thread (turn
    /// boundaries / teardown). Upstream `abort_pending_server_requests`.
    private func resolveAllServerRequests(for tid: ThreadId) {
        let keys = pendingServerRequests.filter { $0.value == tid }.map(\.key)
        for key in keys {
            pendingServerRequests.removeValue(forKey: key)
            resolveServerRequest(key, tid)
        }
    }

    /// Apply a thread-scoped notification's effect on tracked runtime status
    /// before it is relayed to subscribers (turn start/complete, error).
    private func applyStatusEffect(_ n: ServerNotification, _ tid: ThreadId) {
        switch n {
        case .turnStarted:
            // A new turn begins; cancel any stale pending server requests
            // (upstream aborts them on turn transition) then mark running.
            resolveAllServerRequests(for: tid)
            updateStatusFacts(tid) { $0.running = true; $0.hasSystemError = false }
        case .turnCompleted:
            resolveAllServerRequests(for: tid)
            updateStatusFacts(tid) { $0.running = false }
        case .error(_, _, let willRetry, _):
            // Parity with upstream `bespoke_event_handling.rs:883-942`: only the
            // TERMINAL `EventMsg::Error` (willRetry == false) calls
            // `note_system_error` (running=false, has_system_error=true). The
            // transient `EventMsg::StreamError` handler (willRetry == true)
            // explicitly does NOT touch thread status — they are intermediate
            // retry states, so the thread stays Active across retries.
            if !willRetry {
                updateStatusFacts(tid) { $0.running = false; $0.hasSystemError = true }
            }
        default:
            break
        }
    }

    /// Rebinds the running worker for `threadId` to a new `SessionConfig`,
    /// typically used by `turn/start` to switch the thread's remote
    /// exec-server environment at a turn boundary. Existing notification
    /// subscribers are preserved; the worker process (if any) is replaced.
    /// In-flight remote tool work on the previous environment is severed by
    /// the worker termination — the next turn runs cleanly on the new
    /// environment.
    public func rebindRemoteEnvironment(_ threadId: ThreadId,
                                        newConfig: SessionConfig) async {
        guard workers[threadId] != nil else { return }
        forceStopWorker(threadId, clearSubscribers: false)
        let handle = await factory(newConfig)
        workers[threadId] = handle
        lastHeartbeats[threadId] = MonotonicClock.now()
        if let pid = handle.pid {
            ledgers[threadId] = ResourceLedger(pid: pid, limits: limits, sampler: sampler)
            governorStates[threadId] = .normal
        }
        let tid = threadId
        let gen = nextRelayGen(tid)
        relays[tid] = Task {
            for await ev in handle.link.outbound {
                switch ev {
                case .ready:
                    self.recordHeartbeat(tid)
                    continue
                case .heartbeat(let threadId):
                    if threadId == tid { self.recordHeartbeat(tid) }
                    continue
                case .notification(let n):
                    self.applyStatusEffect(n, tid)
                    for s in self.subscribersFor(tid) { s.deliver(n) }
                case .serverRequest(let req):
                    self.recordPending(req.id.description, tid)
                    self.noteServerRequestIssued(req, tid)
                    let sinks = self.subscribersFor(tid)
                    if case .attestationGenerate = req {
                        if let sink = sinks.first(where: { $0.requestAttestation }) {
                            sink.onServerRequest(req)
                        } else {
                            self.deliverServerResponse(
                                req.id.description,
                                result: .null,
                                failed: false)
                        }
                    } else {
                        for s in sinks { s.onServerRequest(req) }
                    }
                case .mcpResponse(let response):
                    self.resolveMcpResponse(response)
                case .finished:
                    self.clearThread(tid, gen: gen)
                    return
                }
            }
            self.clearThread(tid, gen: gen)
        }
        boundConfigs[threadId] = newConfig
        markThreadLoaded(threadId)
        handle.link.sendToWorker(.bind(newConfig))
        if handle.pid != nil {
            applyResourceControl(.normal(memoryLimitBytes: limits.ledgerHardMemoryBytes),
                                 to: threadId)
        }
    }

    /// The currently-bound remote environment for `threadId`, if any. Returns
    /// `nil` for unknown threads, locally-bound threads, or threads whose
    /// worker has been unloaded.
    public func currentRemoteEnvironment(
        _ threadId: ThreadId
    ) -> SessionConfig.RemoteEnvironment? {
        boundConfigs[threadId]?.remoteEnvironment
    }

    /// The currently-bound `SessionConfig` for `threadId`, if a worker is
    /// active. Returns `nil` for unknown threads.
    public func currentBoundConfig(_ threadId: ThreadId) -> SessionConfig? {
        boundConfigs[threadId]
    }

    @discardableResult
    public func submit(_ threadId: ThreadId, _ op: EngineOp) -> Bool {
        if let state = governorStates[threadId],
           state == .hard || state == .terminal {
            let body = ErrorBody(
                message: "worker resource governor is \(state.rawValue); turn rejected",
                codexErrorInfo: "Overloaded")
            for s in subscribersFor(threadId) {
                s.deliver(.error(threadId: threadId, turnId: nil,
                                 willRetry: false, body))
            }
            return false
        }
        guard let worker = workers[threadId] else { return false }
        worker.link.sendToWorker(.op(op))
        return true
    }

    public func quiesce(_ threadId: ThreadId) {
        guard let h = workers[threadId] else { return }
        h.link.sendToWorker(.quiesce)
        h.terminate()
        relays[threadId]?.cancel()
        relays[threadId] = nil
        _ = nextRelayGen(threadId)   // invalidate the cancelled relay (see forceStopWorker)
        workers[threadId] = nil
        boundConfigs[threadId] = nil
        ledgers[threadId] = nil
        governorStates[threadId] = nil
        resourceControls[threadId] = nil
        lastHeartbeats[threadId] = nil
        idleUnloadTasks.removeValue(forKey: threadId)?.cancel()
        quiescingWorkers.remove(threadId)
        resolveAllServerRequests(for: threadId)
        removeStatusFacts(threadId)
        // Tell subscribers (e.g. an in-flight `collectTurn`) the thread closed,
        // so they observe a terminal event instead of hanging to their own
        // timeout (the relay was cancelled above and no longer delivers).
        let closing = subscribers[threadId] ?? formerSubscribers[threadId] ?? []
        for s in closing { s.deliver(.threadClosed(threadId: threadId)) }
        subscribers[threadId] = nil
        formerSubscribers[threadId] = nil
        pendingServerRequests = pendingServerRequests.filter { $0.value != threadId }
        resolveMcpResponsesForClosedThread(threadId)
    }

    private func scheduleIdleUnload(_ threadId: ThreadId) {
        guard workers[threadId] != nil else { return }
        idleUnloadTasks.removeValue(forKey: threadId)?.cancel()
        let delay = limits.idleUnload
        idleUnloadTasks[threadId] = Task { [threadId] in
            try? await Task.sleep(for: delay)
            self.unloadIfStillIdle(threadId)
        }
    }

    private func unloadIfStillIdle(_ threadId: ThreadId) {
        idleUnloadTasks[threadId] = nil
        guard subscribers[threadId]?.isEmpty ?? true,
              let worker = workers[threadId],
              !quiescingWorkers.contains(threadId) else { return }
        quiescingWorkers.insert(threadId)
        worker.link.sendToWorker(.quiesce)
        scheduleQuiesceFallback(threadId)
    }

    private func scheduleQuiesceFallback(_ threadId: ThreadId) {
        let seconds = Swift.max(1.0, limits.heartbeatInterval.seconds
            * Double(limits.watchdogMissedHeartbeats))
        idleUnloadTasks[threadId] = Task { [threadId] in
            try? await Task.sleep(for: .seconds(seconds))
            self.forceStopQuiescingWorker(threadId)
        }
    }

    private func forceStopQuiescingWorker(_ threadId: ThreadId) {
        guard quiescingWorkers.contains(threadId) else { return }
        forceStopWorker(threadId, clearSubscribers: true)
    }

    /// Escalate workers that miss the configured heartbeat budget. This is a
    /// separate pass from resource sampling so it also covers hung IPC/runtime
    /// workers that are otherwise quiet.
    public func tickWatchdogs(now: Double = MonotonicClock.now()) {
        let threshold = limits.heartbeatInterval.seconds
            * Double(limits.watchdogMissedHeartbeats)
        for (tid, last) in lastHeartbeats where now - last >= threshold {
            terminateWorker(tid,
                            message: "worker watchdog missed heartbeats",
                            codexErrorInfo: "WorkerWatchdogTerminal")
        }
    }

    /// Poll worker resource ledgers and enforce per-session containment.
    /// Soft/hard states warn and hard rejects new turns; terminal kills only
    /// the offending worker and fails that session.
    public func tickResources(hung: Set<ThreadId> = []) async {
        let current = ledgers
        for (tid, ledger) in current {
            let transition = await ledger.tick(hung: hung.contains(tid))
            let state = await ledger.currentState()
            governorStates[tid] = state
            guard let transition else { continue }
            enforceResourceTransition(tid, transition)
        }
    }

    public func governorState(_ threadId: ThreadId) -> GovernorState? {
        governorStates[threadId]
    }

    private func enforceResourceTransition(_ tid: ThreadId, _ state: GovernorState) {
        switch state {
        case .normal:
            applyResourceControl(.normal(memoryLimitBytes: limits.ledgerHardMemoryBytes), to: tid)
            broadcast(tid, .warning(threadId: tid, message: "worker resource governor returned to normal"))
        case .soft, .hard:
            applyResourceControl(.throttled(memoryLimitBytes: limits.ledgerHardMemoryBytes), to: tid)
            broadcast(tid, .warning(threadId: tid, message: "worker resource governor entered \(state.rawValue)"))
        case .terminal:
            terminateWorker(tid,
                            message: "worker resource governor reached terminal state",
                            codexErrorInfo: "ResourceGovernorTerminal")
        }
    }

    private func terminateWorker(_ tid: ThreadId, message: String, codexErrorInfo: String) {
        guard let h = workers[tid] else { return }
        let body = ErrorBody(message: message, codexErrorInfo: codexErrorInfo)
        for s in subscribersFor(tid) {
            s.deliver(.error(threadId: tid, turnId: nil,
                             willRetry: false, body))
        }
        h.terminate()
        h.link.finish()
        relays[tid]?.cancel()
        relays[tid] = nil
        // Invalidate the cancelled relay (it no-ops in clearThread) and do our
        // OWN full teardown — including `boundConfigs` and `subscribers`, which
        // the relay's clearThread used to clear — so a thread re-ensured before
        // the old relay drains is not clobbered. The non-retryable `.error`
        // delivered above is the collector's terminal signal (folds to "failed").
        _ = nextRelayGen(tid)
        workers[tid] = nil
        boundConfigs[tid] = nil
        ledgers[tid] = nil
        governorStates[tid] = nil
        resourceControls[tid] = nil
        lastHeartbeats[tid] = nil
        idleUnloadTasks.removeValue(forKey: tid)?.cancel()
        quiescingWorkers.remove(tid)
        resolveAllServerRequests(for: tid)
        removeStatusFacts(tid)
        subscribers[tid] = nil
        formerSubscribers[tid] = nil
        pendingServerRequests = pendingServerRequests.filter { $0.value != tid }
        resolveMcpResponsesForClosedThread(tid)
    }

    private func forceStopWorker(_ tid: ThreadId, clearSubscribers: Bool) {
        guard let h = workers[tid] else { return }
        h.terminate()
        h.link.finish()
        relays[tid]?.cancel()
        relays[tid] = nil
        // Invalidate the just-cancelled relay's generation SYNCHRONOUSLY (before
        // any `await` in a caller like rebind), so when that relay drains and
        // calls `clearThread` it no-ops instead of tearing down the replacement
        // worker / emitting a spurious thread/closed. This path does its own
        // teardown + (when clearSubscribers) thread/closed below.
        _ = nextRelayGen(tid)
        workers[tid] = nil
        boundConfigs[tid] = nil
        ledgers[tid] = nil
        governorStates[tid] = nil
        resourceControls[tid] = nil
        lastHeartbeats[tid] = nil
        idleUnloadTasks.removeValue(forKey: tid)?.cancel()
        quiescingWorkers.remove(tid)
        // Resolve outstanding requests and emit the notLoaded status transition
        // while subscribers are still attached.
        resolveAllServerRequests(for: tid)
        removeStatusFacts(tid)
        if clearSubscribers {
            // Idle-unload teardown: tell the former subscribers the thread was
            // unloaded and must be resumed before the next turn (upstream
            // ThreadClosedNotification). The rebind path keeps subscribers and
            // re-binds a fresh worker, so it must NOT emit thread/closed.
            let recipients = subscribers[tid] ?? formerSubscribers[tid] ?? []
            for s in recipients { s.deliver(.threadClosed(threadId: tid)) }
            subscribers[tid] = nil
        }
        formerSubscribers[tid] = nil
        pendingServerRequests = pendingServerRequests.filter { $0.value != tid }
        resolveMcpResponsesForClosedThread(tid)
    }

    private func applyResourceControl(_ control: WorkerResourceControl, to tid: ThreadId) {
        guard resourceControls[tid] != control,
              let worker = workers[tid] else { return }
        resourceControls[tid] = control
        worker.link.sendToWorker(.resourceControl(control))
    }

    public func isBound(_ threadId: ThreadId) -> Bool { workers[threadId] != nil }
    public func subscriberCount(_ threadId: ThreadId) -> Int { subscribers[threadId]?.count ?? 0 }
}
