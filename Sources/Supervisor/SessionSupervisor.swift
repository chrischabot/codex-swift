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

public actor SessionSupervisor {
    private let factory: WorkerFactory
    private var workers: [ThreadId: WorkerHandle] = [:]
    /// Latest `SessionConfig` we bound to the worker for each thread. Used
    /// by the router's turn-boundary environment-switch detection so it does
    /// not need to fsync-and-reconstruct the rollout just to know the
    /// current binding.
    private var boundConfigs: [ThreadId: SessionConfig] = [:]
    private var subscribers: [ThreadId: [NotificationSink]] = [:]
    private var relays: [ThreadId: Task<Void, Never>] = [:]
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
                    for s in self.subscribersFor(tid) { s.deliver(n) }
                case .serverRequest(let req):
                    self.recordPending(req.id.description, tid)
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
                    self.clearThread(tid)
                    return
                }
            }
            self.clearThread(tid)
        }
        boundConfigs[config.threadId] = config
        handle.link.sendToWorker(.bind(config))
        if handle.pid != nil {
            applyResourceControl(.normal(memoryLimitBytes: limits.ledgerHardMemoryBytes),
                                 to: config.threadId)
        }
        return sinkId
    }

    private func clearThread(_ tid: ThreadId) {
        relays[tid] = nil
        workers[tid] = nil
        boundConfigs[tid] = nil
        ledgers[tid] = nil
        governorStates[tid] = nil
        resourceControls[tid] = nil
        lastHeartbeats[tid] = nil
        idleUnloadTasks.removeValue(forKey: tid)?.cancel()
        quiescingWorkers.remove(tid)
        subscribers[tid] = nil
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
        guard let tid = pendingServerRequests.removeValue(forKey: requestId),
              let w = workers[tid] else { return }
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
        subscribers[threadId]?.removeAll { $0.id == sinkId }
        if subscribers[threadId]?.isEmpty == true {
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
                    for s in self.subscribersFor(tid) { s.deliver(n) }
                case .serverRequest(let req):
                    self.recordPending(req.id.description, tid)
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
                    self.clearThread(tid)
                    return
                }
            }
            self.clearThread(tid)
        }
        boundConfigs[threadId] = newConfig
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
        workers[threadId] = nil
        boundConfigs[threadId] = nil
        ledgers[threadId] = nil
        governorStates[threadId] = nil
        resourceControls[threadId] = nil
        lastHeartbeats[threadId] = nil
        idleUnloadTasks.removeValue(forKey: threadId)?.cancel()
        quiescingWorkers.remove(threadId)
        subscribers[threadId] = nil
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
        workers[tid] = nil
        ledgers[tid] = nil
        governorStates[tid] = nil
        resourceControls[tid] = nil
        lastHeartbeats[tid] = nil
        idleUnloadTasks.removeValue(forKey: tid)?.cancel()
        quiescingWorkers.remove(tid)
        pendingServerRequests = pendingServerRequests.filter { $0.value != tid }
        resolveMcpResponsesForClosedThread(tid)
    }

    private func forceStopWorker(_ tid: ThreadId, clearSubscribers: Bool) {
        guard let h = workers[tid] else { return }
        h.terminate()
        h.link.finish()
        relays[tid]?.cancel()
        relays[tid] = nil
        workers[tid] = nil
        boundConfigs[tid] = nil
        ledgers[tid] = nil
        governorStates[tid] = nil
        resourceControls[tid] = nil
        lastHeartbeats[tid] = nil
        idleUnloadTasks.removeValue(forKey: tid)?.cancel()
        quiescingWorkers.remove(tid)
        if clearSubscribers { subscribers[tid] = nil }
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
