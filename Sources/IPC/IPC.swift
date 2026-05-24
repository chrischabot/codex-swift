import Foundation
import ProtocolModel
import WireProtocol

public enum WorkerResourceQoS: String, Sendable, Codable, Equatable {
    case normal
    case throttled
}

public struct WorkerResourceControl: Sendable, Codable, Equatable {
    public let qos: WorkerResourceQoS
    public let physicalMemoryLimitBytes: Int?

    public init(qos: WorkerResourceQoS, physicalMemoryLimitBytes: Int? = nil) {
        self.qos = qos
        self.physicalMemoryLimitBytes = physicalMemoryLimitBytes
    }

    public static func normal(memoryLimitBytes: Int? = nil) -> WorkerResourceControl {
        WorkerResourceControl(qos: .normal, physicalMemoryLimitBytes: memoryLimitBytes)
    }

    public static func throttled(memoryLimitBytes: Int? = nil) -> WorkerResourceControl {
        WorkerResourceControl(qos: .throttled, physicalMemoryLimitBytes: memoryLimitBytes)
    }
}

public struct WorkerServerResponse: Sendable, Codable, Equatable {
    public let requestId: String
    public let result: JSONValue?
    public let failed: Bool

    public init(requestId: String, result: JSONValue?, failed: Bool = false) {
        self.requestId = requestId
        self.result = result
        self.failed = failed
    }
}

public enum WorkerMcpRequestKind: String, Sendable, Codable, Equatable {
    case callTool
    case readResource
}

public struct WorkerMcpRequest: Sendable, Codable, Equatable {
    public let requestId: String
    public let kind: WorkerMcpRequestKind
    public let threadId: ThreadId
    public let server: String
    public let tool: String?
    public let uri: String?
    public let argumentsJSON: String?

    public init(requestId: String,
                kind: WorkerMcpRequestKind,
                threadId: ThreadId,
                server: String,
                tool: String? = nil,
                uri: String? = nil,
                argumentsJSON: String? = nil) {
        self.requestId = requestId
        self.kind = kind
        self.threadId = threadId
        self.server = server
        self.tool = tool
        self.uri = uri
        self.argumentsJSON = argumentsJSON
    }
}

public struct WorkerMcpResponse: Sendable, Codable, Equatable {
    public let requestId: String
    public let result: JSONValue?
    public let error: String?

    public init(requestId: String, result: JSONValue?, error: String? = nil) {
        self.requestId = requestId
        self.result = result
        self.error = error
    }
}

/// Supervisor → worker.
public enum SupervisorToWorker: Sendable {
    case bind(SessionConfig)
    case op(EngineOp)
    case resourceControl(WorkerResourceControl)
    case mcpRequest(WorkerMcpRequest)
    case quiesce
    case serverResponse(WorkerServerResponse)
}

/// Worker → supervisor.
public enum WorkerToSupervisor: Sendable {
    case ready(ThreadId)
    case heartbeat(ThreadId)
    case notification(ServerNotification)
    case finished
    case serverRequest(ServerRequest)
    case mcpResponse(WorkerMcpResponse)
}

/// Duplex link between a supervisor and one worker. Tests and explicit
/// single-process mode use the in-memory streams directly; production
/// `codexd` bridges the same link to a spawned `codex-session` over a
/// `socketpair`. XPC is an optional future host transport if an app-bundled
/// product needs service identity or integration points the standalone daemon
/// does not require.
public struct WorkerLink: @unchecked Sendable {
    public let inbound: AsyncStream<SupervisorToWorker>     // worker consumes
    public let outbound: AsyncStream<WorkerToSupervisor>    // supervisor consumes
    private let inCont: AsyncStream<SupervisorToWorker>.Continuation
    private let outCont: AsyncStream<WorkerToSupervisor>.Continuation

    private init(inbound: AsyncStream<SupervisorToWorker>,
                 inCont: AsyncStream<SupervisorToWorker>.Continuation,
                 outbound: AsyncStream<WorkerToSupervisor>,
                 outCont: AsyncStream<WorkerToSupervisor>.Continuation) {
        self.inbound = inbound; self.inCont = inCont
        self.outbound = outbound; self.outCont = outCont
    }

    public static func make() -> WorkerLink {
        let (inS, inC) = AsyncStream<SupervisorToWorker>.makeStream()
        let (outS, outC) = AsyncStream<WorkerToSupervisor>.makeStream()
        return WorkerLink(inbound: inS, inCont: inC, outbound: outS, outCont: outC)
    }

    public func sendToWorker(_ m: SupervisorToWorker) { inCont.yield(m) }
    public func sendToSupervisor(_ m: WorkerToSupervisor) { outCont.yield(m) }
    public func finish() { inCont.finish(); outCont.finish() }
}
