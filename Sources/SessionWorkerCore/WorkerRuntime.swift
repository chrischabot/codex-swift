import Foundation
import IPC
import HarnessCore
import ProtocolModel
#if os(macOS)
import Darwin
#endif

public typealias WorkerMcpHandler = @Sendable (WorkerMcpRequest) async -> WorkerMcpResponse

public struct SessionRuntimeComponents: Sendable {
    public let engine: SessionEngine
    public let mcpHandler: WorkerMcpHandler?

    public init(engine: SessionEngine, mcpHandler: WorkerMcpHandler? = nil) {
        self.engine = engine
        self.mcpHandler = mcpHandler
    }
}

/// Runs inside a `codex-session` worker (or in-process in tests). Owns exactly
/// one `SessionEngine` for the bound thread subtree (rework §6.1/§7.2). The
/// engine factory is injected so the same runtime works for the in-process
/// test path and the spawned-process path. It is also the engine's
/// `ApprovalCoordinator`: server→client approval requests are emitted over
/// the `WorkerLink` and the correlated decision is awaited here.
public actor WorkerRuntime: ApprovalCoordinator {
    private let link: WorkerLink
    private let attestationBroker: WorkerAttestationBroker?
    private let serverRequestBroker: WorkerServerRequestBroker?
    private let makeComponents: @Sendable (SessionConfig) async -> SessionRuntimeComponents
    private var engine: SessionEngine?
    private var mcpHandler: WorkerMcpHandler?
    private var threadId: ThreadId?
    private var relayTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingApprovals: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var approvalTimeouts: [String: Task<Void, Never>] = [:]
    /// Safety timeout: if no client decision arrives, default to decline so a
    /// turn cannot hang forever on a missing approval.
    private let approvalTimeout: Duration
    private let heartbeatInterval: Duration

    public init(link: WorkerLink,
                attestationBroker: WorkerAttestationBroker? = nil,
                serverRequestBroker: WorkerServerRequestBroker? = nil,
                approvalTimeout: Duration = .seconds(300),
                heartbeatInterval: Duration = .seconds(2),
                makeEngine: @escaping @Sendable (SessionConfig) async -> SessionEngine) {
        self.init(link: link,
                  attestationBroker: attestationBroker,
                  serverRequestBroker: serverRequestBroker,
                  approvalTimeout: approvalTimeout,
                  heartbeatInterval: heartbeatInterval,
                  makeComponents: { config in
                      SessionRuntimeComponents(engine: await makeEngine(config))
                  })
    }

    public init(link: WorkerLink,
                attestationBroker: WorkerAttestationBroker? = nil,
                serverRequestBroker: WorkerServerRequestBroker? = nil,
                approvalTimeout: Duration = .seconds(300),
                heartbeatInterval: Duration = .seconds(2),
                makeComponents: @escaping @Sendable (SessionConfig) async -> SessionRuntimeComponents) {
        self.link = link
        self.attestationBroker = attestationBroker
        self.serverRequestBroker = serverRequestBroker
        self.approvalTimeout = approvalTimeout
        self.heartbeatInterval = heartbeatInterval
        self.makeComponents = makeComponents
    }

    // MARK: ApprovalCoordinator

    public func requestApproval(_ request: ServerRequest) async -> ApprovalDecision {
        let key = request.id.description
        let timeout = approvalTimeout
        let decision = await withCheckedContinuation { (c: CheckedContinuation<ApprovalDecision, Never>) in
            pendingApprovals[key] = c
            link.sendToSupervisor(.serverRequest(request))
            approvalTimeouts[key] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resolveApproval(key, .decline)
            }
        }
        return decision
    }

    private func resolveApproval(_ key: String, _ d: ApprovalDecision) {
        approvalTimeouts.removeValue(forKey: key)?.cancel()
        if let c = pendingApprovals.removeValue(forKey: key) { c.resume(returning: d) }
    }

    private func resolveServerResponse(_ response: WorkerServerResponse) async {
        if let attestationBroker {
            if await attestationBroker.resolve(response) { return }
        }
        if let serverRequestBroker {
            if await serverRequestBroker.resolve(response) { return }
        }
        let decision: ApprovalDecision
        if response.failed {
            decision = .cancel
        } else if let result = response.result,
                  let decoded = try? ServerRequest.decodeDecision(result) {
            decision = decoded
        } else {
            decision = .decline
        }
        resolveApproval(response.requestId, decision)
    }

    private func cancelAllApprovals() {
        for (_, t) in approvalTimeouts { t.cancel() }
        approvalTimeouts.removeAll()
        for (_, c) in pendingApprovals { c.resume(returning: .cancel) }
        pendingApprovals.removeAll()
    }

    public func run() async {
        for await msg in link.inbound {
            switch msg {
            case .bind(let cfg):
                guard engine == nil else { continue }
                threadId = cfg.threadId
                let components = await makeComponents(cfg)
                let e = components.engine
                engine = e
                mcpHandler = components.mcpHandler
                await e.setApprovalCoordinator(self)
                await e.start()
                let events = await e.events()
                relayTask = Task {
                    for await n in events {
                        self.link.sendToSupervisor(.notification(n))
                    }
                    self.link.sendToSupervisor(.finished)
                }
                link.sendToSupervisor(.ready(cfg.threadId))
                startHeartbeat(cfg.threadId)
            case .op(let op):
                await engine?.submit(op)
            case .resourceControl(let control):
                let failures = ProcessResourceControl.apply(control)
                if !failures.isEmpty, let threadId {
                    let message = "worker resource control degraded: " + failures.joined(separator: "; ")
                    link.sendToSupervisor(.notification(.warning(
                        threadId: threadId,
                        message: message
                    )))
                }
            case .serverResponse(let response):
                await resolveServerResponse(response)
            case .mcpRequest(let request):
                await handleMcpRequest(request)
            case .quiesce:
                cancelAllApprovals()
                mcpHandler = nil
                heartbeatTask?.cancel()
                await engine?.quiesce()
                relayTask?.cancel()
                link.sendToSupervisor(.finished)
                return
            }
        }
        cancelAllApprovals()
        mcpHandler = nil
        heartbeatTask?.cancel()
        relayTask?.cancel()
    }

    private func handleMcpRequest(_ request: WorkerMcpRequest) async {
        guard request.threadId == threadId else {
            link.sendToSupervisor(.mcpResponse(WorkerMcpResponse(
                requestId: request.requestId,
                result: nil,
                error: "MCP request targeted a different session")))
            return
        }
        guard let mcpHandler else {
            link.sendToSupervisor(.mcpResponse(WorkerMcpResponse(
                requestId: request.requestId,
                result: nil,
                error: "session worker has no MCP handler")))
            return
        }
        let response = await mcpHandler(request)
        link.sendToSupervisor(.mcpResponse(response))
    }

    private func startHeartbeat(_ threadId: ThreadId) {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [link] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                link.sendToSupervisor(.heartbeat(threadId))
            }
        }
    }
}

enum ProcessResourceControl {
    static func apply(_ control: WorkerResourceControl) -> [String] {
        #if os(macOS)
        var failures: [String] = []
        let latency: task_latency_qos_t
        let throughput: task_throughput_qos_t
        switch control.qos {
        case .normal:
            latency = task_latency_qos_t(LATENCY_QOS_TIER_3.rawValue)
            throughput = task_throughput_qos_t(THROUGHPUT_QOS_TIER_3.rawValue)
        case .throttled:
            latency = task_latency_qos_t(LATENCY_QOS_TIER_5.rawValue)
            throughput = task_throughput_qos_t(THROUGHPUT_QOS_TIER_5.rawValue)
        }

        var policy = task_qos_policy(task_latency_qos_tier: latency,
                                     task_throughput_qos_tier: throughput)
        let count = mach_msg_type_number_t(
            MemoryLayout<task_qos_policy>.stride / MemoryLayout<integer_t>.stride)
        let qosKR = withUnsafeMutablePointer(to: &policy) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_policy_set(mach_task_self_,
                                task_policy_flavor_t(TASK_BASE_QOS_POLICY),
                                raw,
                                count)
            }
        }
        if qosKR != KERN_SUCCESS {
            failures.append("task_policy_set(TASK_BASE_QOS_POLICY) failed with kern_return_t \(qosKR)")
        }
        if let bytes = control.physicalMemoryLimitBytes {
            if let failure = applyPhysicalFootprintLimit(bytes) {
                failures.append(failure)
            }
        }
        return failures
        #else
        _ = control
        return []
        #endif
    }

    #if os(macOS)
    static func physicalFootprintLimitMebibytes(forBytes bytes: Int) -> Int32 {
        guard bytes > 0 else { return 0 }
        return Int32(max(1, min(Int(Int32.max), (bytes + 1_048_575) / 1_048_576)))
    }

    private static func applyPhysicalFootprintLimit(_ bytes: Int) -> String? {
        let mebibytes = physicalFootprintLimitMebibytes(forBytes: bytes)
        guard mebibytes > 0 else { return nil }
        var oldLimit: Int32 = 0
        let kr = task_set_phys_footprint_limit(mach_task_self_, mebibytes, &oldLimit)
        guard kr == KERN_SUCCESS else {
            return "task_set_phys_footprint_limit(\(mebibytes) MiB) failed with kern_return_t \(kr)"
        }
        return nil
    }
    #endif
}
