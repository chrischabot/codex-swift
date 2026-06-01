import Foundation
#if canImport(Network)
import Network
#endif

/// A loopback WebSocket server that speaks codex-swift's exec-server JSON-RPC
/// protocol (the server side of `Sources/Tools/RemoteExecServerTools.swift`),
/// bridging the agent's tool calls into the task container:
///
///  - `fs/*`        → the **host bind-mounted workspace clone** (fast, native;
///                    the clone is mounted at `/app`, so writes are visible to
///                    in-container processes).
///  - `process/*`   → `container exec -w <cwd> <id> …` (real toolchain + deps).
///
/// codex-swift connects via `SessionConfig.remoteEnvironment.execServerUrl`.
/// This requires **zero** changes to codex-swift core. Only consumed by the
/// host agent — the container never connects here.
#if canImport(Network)
public final class ContainerExecServer: @unchecked Sendable {
    private let workspace: String           // host clone dir (maps to /app)
    private let mountPoint: String          // container path the clone is mounted at
    private let runtime: any ContainerRuntime
    private let containerId: String
    private let procs = StreamRegistry(maxBytes: 8 * 1024 * 1024)
    private let queue = DispatchQueue(label: "codex-bench.exec-server")
    private var listener: NWListener?
    public private(set) var url: String = ""
    private let commandLog: URL?              // JSONL of every command/fs op the agent ran
    private let logQueue = DispatchQueue(label: "codex-bench.cmdlog")
    private let actionLock = NSLock()
    private var lastActionAt = Date()         // last tool call of ANY kind — for the no-progress watchdog
    private var writeCount = 0                 // count of MUTATING fs ops (write/remove) — for the write-aware deadline

    private func markAction() { actionLock.lock(); lastActionAt = Date(); actionLock.unlock() }
    /// Mark a MUTATING operation (file write/remove). Distinct from markAction:
    /// used by the write-aware "force-write" deadline to detect an agent that
    /// explores/searches/reads for a long time but never edits (analysis-paralysis).
    private func markWrite() { actionLock.lock(); writeCount += 1; actionLock.unlock() }
    /// Seconds since the agent last made ANY tool call (exec, write, read, search,
    /// list, process poll). A long gap means the model is reasoning in a loop with
    /// no tool use at all — the real "stuck" signal — not merely exploring.
    public func secondsSinceLastAction() -> Double {
        actionLock.lock(); defer { actionLock.unlock() }
        return Date().timeIntervalSince(lastActionAt)
    }
    /// Number of file writes/removes the agent has made so far. 0 = it has only
    /// explored/read, never edited.
    public func writesMade() -> Int {
        actionLock.lock(); defer { actionLock.unlock() }
        return writeCount
    }

    public init(workspace: String, mountPoint: String = "/app",
                runtime: any ContainerRuntime, containerId: String, commandLog: URL? = nil) {
        self.workspace = (workspace as NSString).standardizingPath
        self.mountPoint = mountPoint
        self.runtime = runtime
        self.containerId = containerId
        self.commandLog = commandLog
        if let commandLog { FileManager.default.createFile(atPath: commandLog.path, contents: nil) }
    }

    /// Append one tool-call/fs-op record to the command log (best-effort).
    /// Gives complete tool-call provenance — the agent's exact argv and edited
    /// paths, which codex-swift's rollout does NOT record (it stores only the
    /// tool name + output).
    private func logEvent(_ obj: [String: Any]) {
        guard let commandLog else { return }
        logQueue.async {
            var record = obj
            record["ts"] = ISO8601DateFormatter().string(from: Date())
            guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
            data.append(0x0A)
            if let fh = try? FileHandle(forWritingTo: commandLog) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd(); try? fh.write(contentsOf: data)
            }
        }
    }

    /// Start listening on a loopback ephemeral port; returns the `ws://` URL.
    public func start() async throws -> String {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // Bind to loopback only.
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            tcp.version = .v4
        }
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue { cont.resume(returning: p) }
                    else { cont.resume(throwing: BenchError.runtimeUnavailable("no exec-server port")) }
                case .failed(let e):
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        url = "ws://127.0.0.1:\(port)"
        return url
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        Task { await procs.killAll() }   // kill any host-side `container exec` still streaming
    }

    // MARK: receive loop

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { return }   // transport error → stop (do not re-arm)
            // A WebSocket close frame (or a nil/empty final message with no
            // context) means the peer hung up; stop re-arming to avoid a 100%
            // CPU spin on receiveMessage completing instantly forever.
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, meta.opcode == .close {
                return
            }
            if data == nil && context == nil { return }
            if let data, !data.isEmpty {
                Task { await self.handle(data, on: conn) }
            }
            self.receive(on: conn)
        }
    }

    private func send(_ obj: [String: Any], on conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "resp", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func handle(_ data: Data, on conn: NWConnection) async {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let method = msg["method"] as? String
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        // Notifications (no id) — e.g. "initialized".
        guard let id else { return }

        do {
            let result = try await dispatch(method ?? "", params)
            send(["id": id, "result": result], on: conn)
        } catch let e as ToolBridgeError {
            send(["id": id, "error": ["message": e.message]], on: conn)
        } catch {
            send(["id": id, "error": ["message": "\(error)"]], on: conn)
        }
    }

    private struct ToolBridgeError: Error { let message: String }

    private func dispatch(_ method: String, _ p: [String: Any]) async throws -> [String: Any] {
        // Any tool call (read, search, list, process poll — not just exec/write)
        // counts as the agent actively working. The watchdog should fire only on
        // TRUE inactivity: the model reasoning with zero tool use for minutes, the
        // real "stuck in a loop" signal. (Counting only exec/write misfired during
        // legitimate read/search exploration between edits.)
        if method != "initialize" { markAction() }
        switch method {
        case "initialize":
            return ["sessionId": "codex-bench-\(containerId)"]
        case "process/start":   return try await procStart(p)
        case "process/read":    return try await procRead(p)
        case "process/write":
            if let pid = p["processId"] as? String,
               let b64 = p["chunk"] as? String, let d = Data(base64Encoded: b64) {
                await procs.writeStdin(pid, d)
            }
            return ["ok": true]
        case "process/terminate": await procs.terminate(p["processId"] as? String ?? ""); return [:]
        case "fs/readFile":     return try fsReadFile(p)
        case "fs/writeFile":    return try fsWriteFile(p)
        case "fs/remove":       return try fsRemove(p)
        case "fs/createDirectory": return try fsCreateDir(p)
        case "fs/readDirectory": return try fsReadDir(p)
        case "fs/copy":         return try fsCopy(p)
        default:
            throw ToolBridgeError(message: "unknown method \(method)")
        }
    }

    // MARK: process bridge (→ container exec)

    private func procStart(_ p: [String: Any]) async throws -> [String: Any] {
        guard let pid = p["processId"] as? String,
              let argv = p["argv"] as? [String] else {
            throw ToolBridgeError(message: "process/start needs processId+argv")
        }
        let cwd = (p["cwd"] as? String) ?? mountPoint
        var env: [String: String] = [:]
        if let e = p["env"] as? [String: String] { env = e }
        // Spawn `container exec …` directly with a streaming pipe we own, so
        // output flows incrementally and `process/terminate` can really kill it.
        logEvent(["kind": "exec", "cwd": cwd, "argv": argv]); markAction()
        let (exe, args) = runtime.execCommand(containerId, workdir: cwd, env: env, command: argv)
        await procs.start(pid, executable: exe, args: args)
        return [:]
    }

    private func procRead(_ p: [String: Any]) async throws -> [String: Any] {
        guard let pid = p["processId"] as? String else {
            throw ToolBridgeError(message: "process/read needs processId")
        }
        let afterSeq = (p["afterSeq"] as? NSNumber)?.uint64Value ?? (p["afterSeq"] as? UInt64)
        let waitMs = (p["waitMs"] as? Int) ?? 100
        let data = await procs.read(pid, afterSeq: afterSeq, waitMs: waitMs)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: fs bridge (→ host clone)

    /// Map a container path (rooted at the mount point, e.g. `/app/src/x`) to its
    /// host clone path, refusing anything that escapes the workspace.
    private func hostPath(_ containerPath: String) throws -> String {
        var rel = containerPath
        if rel == mountPoint { rel = "" }
        else if rel.hasPrefix(mountPoint + "/") { rel = String(rel.dropFirst(mountPoint.count + 1)) }
        else if rel.hasPrefix("/") {
            // Absolute but outside /app — disallow (agent should stay in workspace).
            throw ToolBridgeError(message: "path outside workspace: \(containerPath)")
        }
        if rel.split(separator: "/").contains("..") {
            throw ToolBridgeError(message: "path traversal: \(containerPath)")
        }
        let joined = rel.isEmpty ? workspace : (workspace as NSString).appendingPathComponent(rel)
        let std = (joined as NSString).standardizingPath
        guard std == workspace || std.hasPrefix(workspace + "/") else {
            throw ToolBridgeError(message: "path escapes workspace: \(containerPath)")
        }
        return std
    }

    private func fsReadFile(_ p: [String: Any]) throws -> [String: Any] {
        let path = try hostPath(p["path"] as? String ?? "")
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ToolBridgeError(message: "no such file: \(p["path"] ?? "")")
        }
        return ["dataBase64": data.base64EncodedString()]
    }

    private func fsWriteFile(_ p: [String: Any]) throws -> [String: Any] {
        let path = try hostPath(p["path"] as? String ?? "")
        let data = (p["dataBase64"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        logEvent(["kind": "write", "path": p["path"] as? String ?? "", "bytes": data.count]); markAction(); markWrite()
        return [:]
    }

    private func fsRemove(_ p: [String: Any]) throws -> [String: Any] {
        logEvent(["kind": "remove", "path": p["path"] as? String ?? ""]); markWrite()
        let path = try hostPath(p["path"] as? String ?? "")
        if !FileManager.default.fileExists(atPath: path) {
            throw ToolBridgeError(message: "not found: \(p["path"] ?? "")")
        }
        try FileManager.default.removeItem(atPath: path)
        return [:]
    }

    private func fsCreateDir(_ p: [String: Any]) throws -> [String: Any] {
        let path = try hostPath(p["path"] as? String ?? "")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return [:]
    }

    private func fsReadDir(_ p: [String: Any]) throws -> [String: Any] {
        let path = try hostPath(p["path"] as? String ?? "")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        var entries: [[String: Any]] = []
        for name in names {
            var isDir: ObjCBool = false
            let full = (path as NSString).appendingPathComponent(name)
            _ = FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            entries.append(["fileName": name, "isDirectory": isDir.boolValue, "isFile": !isDir.boolValue])
        }
        return ["entries": entries]
    }

    private func fsCopy(_ p: [String: Any]) throws -> [String: Any] {
        let src = try hostPath(p["sourcePath"] as? String ?? "")
        let dst = try hostPath(p["destinationPath"] as? String ?? "")
        try? FileManager.default.removeItem(atPath: dst)
        try FileManager.default.copyItem(atPath: src, toPath: dst)
        return [:]
    }
}

/// Registry of streaming bridged processes. `process/read(afterSeq, waitMs)`
/// returns only chunks newer than `afterSeq`, blocking up to `waitMs` for fresh
/// output — so the agent sees a long build/test stream live instead of one dump
/// at the end.
private actor StreamRegistry {
    private var procs: [String: StreamingExec] = [:]
    private let maxBytes: Int
    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func start(_ id: String, executable: String, args: [String]) {
        let ex = StreamingExec(executable: executable, args: args, maxBytes: maxBytes)
        procs[id] = ex
        ex.start()
    }
    func writeStdin(_ id: String, _ data: Data) { procs[id]?.writeStdin(data) }
    func terminate(_ id: String) { procs[id]?.killProcess() }
    func killAll() { for ex in procs.values { ex.killProcess() } }

    /// JSON-encoded `process/read` response (Data is Sendable across the actor
    /// boundary; forwarded verbatim by the caller).
    func read(_ id: String, afterSeq: UInt64?, waitMs: Int) async -> Data {
        func enc(_ d: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8) }
        guard let ex = procs[id] else {
            return enc(["failure": "no such process \(id)", "exited": true, "closed": true])
        }
        let after = afterSeq ?? 0
        let deadline = Date().addingTimeInterval(Double(min(max(waitMs, 10), 30_000)) / 1000.0)
        repeat {
            let s = ex.snapshot(afterSeq: after)
            if !s.chunks.isEmpty || s.closed { return enc(Self.response(s)) }
            try? await Task.sleep(for: .milliseconds(40))
        } while Date() < deadline
        return enc(Self.response(ex.snapshot(afterSeq: after)))
    }

    private static func response(_ s: StreamingExec.Snapshot) -> [String: Any] {
        var o: [String: Any] = ["chunks": s.chunks, "nextSeq": NSNumber(value: s.nextSeq),
                                "exited": s.exited, "closed": s.closed]
        if s.exited { o["exitCode"] = s.exitCode }
        return o
    }
}

/// One bridged container process with LIVE output streaming. Owns the real
/// `Process` so `killProcess()` actually kills it (no zombie test runs left
/// holding files/CPU). Output is captured incrementally via pipe readability
/// handlers and tagged with an incrementing sequence so `process/read(afterSeq)`
/// returns only new bytes.
private final class StreamingExec: @unchecked Sendable {
    struct Snapshot { var chunks: [[String: Any]]; var nextSeq: UInt64; var exited: Bool; var exitCode: Int; var closed: Bool }

    private let proc = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let inPipe = Pipe()
    private let lock = NSLock()
    private var chunks: [(seq: UInt64, stream: String, b64: String)] = []
    private var seq: UInt64 = 0
    private var total = 0
    private let maxBytes: Int
    private var exited = false
    private var exitCode: Int32 = 0
    private var outEOF = false
    private var errEOF = false

    init(executable: String, args: [String], maxBytes: Int) {
        self.maxBytes = maxBytes
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe
    }

    func start() {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.onData(h.availableData, "stdout") }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.onData(h.availableData, "stderr") }
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); self.exited = true; self.exitCode = p.terminationStatus; self.lock.unlock()
            // Drain anything still buffered, then mark closed (deterministic EOF).
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.drainAndClose() }
        }
        do { try proc.run() }
        catch {
            lock.lock()
            exited = true; exitCode = 127; outEOF = true; errEOF = true
            seq += 1; chunks.append((seq, "stderr", Data("spawn failed: \(error)".utf8).base64EncodedString()))
            lock.unlock()
        }
    }

    private func onData(_ d: Data, _ stream: String) {
        lock.lock(); defer { lock.unlock() }
        if d.isEmpty { if stream == "stdout" { outEOF = true } else { errEOF = true }; return }
        if total >= maxBytes { return }
        let slice = total + d.count > maxBytes ? d.prefix(maxBytes - total) : d
        total += slice.count
        seq += 1
        chunks.append((seq, stream, slice.base64EncodedString()))
    }

    private func drainAndClose() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let o = try? outPipe.fileHandleForReading.readToEnd(), !o.isEmpty { onData(o, "stdout") }
        if let e = try? errPipe.fileHandleForReading.readToEnd(), !e.isEmpty { onData(e, "stderr") }
        lock.lock(); outEOF = true; errEOF = true; lock.unlock()
    }

    func writeStdin(_ data: Data) { try? inPipe.fileHandleForWriting.write(contentsOf: data) }

    func snapshot(afterSeq: UInt64) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let newer = chunks.filter { $0.seq > afterSeq }
        let out = newer.map { ["chunk": $0.b64, "stream": $0.stream] as [String: Any] }
        return Snapshot(chunks: out, nextSeq: newer.last?.seq ?? afterSeq,
                        exited: exited, exitCode: Int(exitCode), closed: exited && outEOF && errEOF)
    }

    func killProcess() {
        guard proc.isRunning else { return }
        proc.terminate()                                   // SIGTERM
        let p = proc
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { _ = kill(p.processIdentifier, SIGKILL) }   // escalate
        }
    }
}
#endif
