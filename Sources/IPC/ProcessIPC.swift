import Foundation
import ProtocolModel
import WireProtocol

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One serialized supervisor↔worker message. Exactly one group of fields is
/// populated per envelope. Notifications/server-requests cross as their wire
/// (method, params[, id]) so the supervisor relays/correlates them unchanged.
public struct IPCEnvelope: Codable, Sendable {
    // Supervisor → worker
    public var bind: SessionConfig?
    public var op: EngineOp?
    public var resourceControl: WorkerResourceControl?
    public var mcpRequest: WorkerMcpRequest?
    public var quiesce: Bool?
    public var serverResponseId: String?
    public var serverResponseResult: JSONValue?
    public var serverResponseFailed: Bool?
    // Worker → supervisor
    public var readyThreadId: String?
    public var heartbeatThreadId: String?
    public var notifMethod: String?
    public var notifParams: JSONValue?
    public var serverRequestId: String?
    public var serverRequestMethod: String?
    public var serverRequestParams: JSONValue?
    public var mcpResponse: WorkerMcpResponse?
    public var finished: Bool?

    public init() {}

    static func s2w(_ m: SupervisorToWorker) -> IPCEnvelope {
        var e = IPCEnvelope()
        switch m {
        case .bind(let c): e.bind = c
        case .op(let o): e.op = o
        case .resourceControl(let control): e.resourceControl = control
        case .mcpRequest(let request): e.mcpRequest = request
        case .quiesce: e.quiesce = true
        case .serverResponse(let response):
            e.serverResponseId = response.requestId
            e.serverResponseResult = response.result
            e.serverResponseFailed = response.failed
        }
        return e
    }

    func toS2W() -> SupervisorToWorker? {
        if let c = bind { return .bind(c) }
        if let o = op { return .op(o) }
        if let control = resourceControl { return .resourceControl(control) }
        if let request = mcpRequest { return .mcpRequest(request) }
        if quiesce == true { return .quiesce }
        if let id = serverResponseId {
            return .serverResponse(WorkerServerResponse(
                requestId: id,
                result: serverResponseResult,
                failed: serverResponseFailed ?? false))
        }
        return nil
    }

    static func w2s(_ m: WorkerToSupervisor) -> IPCEnvelope {
        var e = IPCEnvelope()
        switch m {
        case .ready(let t):
            e.readyThreadId = t.raw
        case .heartbeat(let t):
            e.heartbeatThreadId = t.raw
        case .notification(let n):
            if case .notification(let jn) = n.toMessage() {
                e.notifMethod = jn.method
                e.notifParams = jn.params
            }
        case .serverRequest(let r):
            if case .request(let jr) = r.toMessage() {
                e.serverRequestId = r.id.description
                e.serverRequestMethod = jr.method
                e.serverRequestParams = jr.params
            }
        case .mcpResponse(let response):
            e.mcpResponse = response
        case .finished:
            e.finished = true
        }
        return e
    }

    /// Reconstruct on the supervisor side. Notifications become `.raw` so the
    /// relay's `toMessage()` reproduces the exact wire form; server requests
    /// are rebuilt typed and correlate by their original (string) id.
    func toW2S() -> WorkerToSupervisor? {
        if let t = readyThreadId { return .ready(ThreadId(t)) }
        if let t = heartbeatThreadId { return .heartbeat(ThreadId(t)) }
        if let m = notifMethod {
            return .notification(.raw(method: m, params: notifParams ?? .null))
        }
        if let m = serverRequestMethod, let idS = serverRequestId,
           let sr = ServerRequest.reconstruct(
                method: m, id: .string(idS),
                params: serverRequestParams ?? .object([:])) {
            return .serverRequest(sr)
        }
        if let response = mcpResponse { return .mcpResponse(response) }
        if finished == true { return .finished }
        return nil
    }
}

/// Newline-delimited JSON framing of `IPCEnvelope` over a blocking fd. Reads
/// run on a dedicated OS thread (never the cooperative pool); writes are
/// serialized with a pthread mutex (safe from async + sync).
public enum ProcessIPC {
    private static let ignoreSIGPIPEOnce: Void = {
        #if canImport(Glibc) || canImport(Darwin)
        signal(SIGPIPE, SIG_IGN)
        #endif
    }()

    private static func writeLine(_ fd: Int32, _ env: IPCEnvelope,
                                  _ lock: ProcessIPCWriteLock) {
        guard var data = try? JSONEncoder().encode(env) else { return }
        data.append(0x0A)
        let bytes = Array(data)
        lock.withLock {
            var off = 0
            bytes.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                while off < bytes.count {
                    #if canImport(Glibc)
                    let n = send(fd, base + off, bytes.count - off, Int32(MSG_NOSIGNAL))
                    #else
                    let n = send(fd, base + off, bytes.count - off, 0)
                    #endif
                    if n <= 0 { break }
                    off += n
                }
            }
        }
    }

    private static func suppressSigPipe(_ fd: Int32) {
        _ = ignoreSIGPIPEOnce
        #if canImport(Darwin)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.stride))
        #else
        _ = fd
        #endif
    }

    private static func reader(_ fd: Int32,
                               _ onLine: @escaping @Sendable (IPCEnvelope) -> Void,
                               _ onEOF: @escaping @Sendable () -> Void) {
        let t = Thread {
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 65536, 0) }
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = buf.subdata(in: buf.startIndex..<nl)
                    buf.removeSubrange(buf.startIndex...nl)
                    if line.isEmpty { continue }
                    if let env = try? JSONDecoder().decode(IPCEnvelope.self, from: line) {
                        onLine(env)
                    }
                }
            }
            onEOF()
        }
        t.stackSize = 1 << 20
        t.name = "ai.igent.codexkit.ipc.reader"
        t.start()
    }

    /// Supervisor side: pump `link.inbound` (messages destined for the child)
    /// to `fd`, and decode `fd` (messages from the child) into
    /// `link.sendToSupervisor`.
    public static func runSupervisorBridge(link: WorkerLink, fd: Int32) {
        suppressSigPipe(fd)
        let lock = ProcessIPCWriteLock()
        Task {
            for await m in link.inbound { writeLine(fd, IPCEnvelope.s2w(m), lock) }
        }
        reader(fd, { env in
            if let w2s = env.toW2S() { link.sendToSupervisor(w2s) }
        }, {
            link.sendToSupervisor(.finished)
        })
    }

    /// Worker side: decode `fd` into `link.sendToWorker`, and pump
    /// `link.outbound` to `fd`.
    public static func runWorkerBridge(link: WorkerLink, fd: Int32) {
        suppressSigPipe(fd)
        let lock = ProcessIPCWriteLock()
        Task {
            for await m in link.outbound { writeLine(fd, IPCEnvelope.w2s(m), lock) }
        }
        reader(fd, { env in
            if let s2w = env.toS2W() { link.sendToWorker(s2w) }
        }, {
            link.sendToWorker(.quiesce)
        })
    }
}

/// pthread-mutex write lock (callable from async + sync; no NSLock
/// async-context restriction).
public final class ProcessIPCWriteLock: @unchecked Sendable {
    private let m = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    public init() { pthread_mutex_init(m, nil) }
    deinit { pthread_mutex_destroy(m); m.deallocate() }
    public func withLock(_ body: () -> Void) {
        pthread_mutex_lock(m); defer { pthread_mutex_unlock(m) }
        body()
    }
}
