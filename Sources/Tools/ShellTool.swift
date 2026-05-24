import Foundation
import InfraPrimitives
import Sandbox

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private final class ProcessExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func resolve(_ value: Int32) {
        lock.lock()
        guard status == nil else {
            lock.unlock()
            return
        }
        status = value
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private actor DrainCompletionFlag {
    private var finished = false
    func setFinished() { finished = true }
    func isFinished() -> Bool { finished }
}

/// Executes a real child process (Codex `shell` / `unified_exec` /
/// `UserShellCommandTask`). Non-full-access launches are wrapped by the
/// kernel sandbox (Seatbelt on macOS, bubblewrap on Linux) via
/// `Sandbox.sandboxedInvocation`; if confinement cannot be enforced the
/// command is denied rather than run unsandboxed (Codex parity). `fullAccess`
/// mirrors `/shell` (UserShell), which runs unsandboxed by design. Output is
/// head+tail bounded so a chatty process cannot exhaust memory.
public struct ShellTool: Tool {
    public let name: String
    public let parallelSafe: Bool
    public var toolDescription: String {
        "Run a shell command (string or argv) to completion and capture the "
        + "combined stdout/stderr. Best for one-shot commands, builds, and "
        + "tests. IMPORTANT: when the shell exits, the tool reaps the entire "
        + "child process group as fork-bomb containment, so plain `cmd &` "
        + "does NOT survive. To launch a long-lived daemon (test server, "
        + "background process you'll monitor in a later turn), detach it "
        + "from the process group with `setsid`, e.g. "
        + "`setsid python3 server.py >log.txt 2>&1 </dev/null &`. Use "
        + "`unified_exec` for INTERACTIVE PTY processes (REPLs, ssh)."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"command":{"description":"shell string or argv array"},"cwd":{"type":"string"},"timeoutMs":{"type":"integer"}},"required":["command"],"additionalProperties":true}"#
    }
    private let sandbox: any Sandbox
    private let maxOutputBytes: Int
    private let fullAccess: Bool

    /// Default timeout when the model omits `timeoutMs`. Matches upstream
    /// `DEFAULT_EXEC_COMMAND_TIMEOUT_MS = 10_000` in `codex-rs/core/src/exec.rs`.
    /// The model is expected to explicitly pass a larger `timeoutMs` for
    /// long-running workloads such as `npm install` or `cargo build`; the
    /// 10 s floor matches the upstream contract so clients sharing the
    /// upstream system prompt see identical timeout semantics.
    public let defaultTimeoutMs: Int = 10_000

    public init(name: String = "shell_command",
                parallelSafe: Bool = false,
                sandbox: any Sandbox,
                limits: Limits = Limits(),
                fullAccess: Bool = false) {
        self.name = name
        self.parallelSafe = parallelSafe
        self.sandbox = sandbox
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
        self.fullAccess = fullAccess
    }

    private struct Args: Decodable {
        var command: CommandSpec
        var cwd: String?
        var timeoutMs: Int?
        enum CodingKeys: String, CodingKey { case command, cwd, timeoutMs, timeout_ms }
        init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            command = try c.decode(CommandSpec.self, forKey: .command)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeoutMs)
                ?? c.decodeIfPresent(Int.self, forKey: .timeout_ms)
        }
    }
    /// Accept either an argv array or a shell string (Codex accepts both).
    private enum CommandSpec: Decodable {
        case argv([String])
        case line(String)
        init(from d: any Decoder) throws {
            let c = try d.singleValueContainer()
            if let arr = try? c.decode([String].self) { self = .argv(arr); return }
            self = .line(try c.decode(String.self))
        }
        var argv: [String] {
            switch self {
            case .argv(let a): return a
            case .line(let s): return ["/bin/sh", "-c", s]
            }
        }
    }

    /// Resolve a possibly-bare executable so the kernel-sandbox wrapper can
    /// exec it directly (no shell PATH resolution inside the jail).
    private func normalize(_ argv: [String]) -> [String] {
        guard let exe = argv.first else { return argv }
        if exe.hasPrefix("/") { return argv }
        return ["/usr/bin/env"] + argv
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid shell arguments",
                              success: false, truncated: false)
        }
        let workDir = args.cwd ?? cwd
        let inner = normalize(args.command.argv)

        let launch: [String]
        if fullAccess {
            launch = inner   // Codex /shell: explicit full-access escape hatch.
        } else {
            switch sandbox.sandboxedInvocation(argv: inner, cwd: workDir) {
            case .run(let wrapped):
                launch = wrapped
            case .deny(let reason):
                return ToolResult(callId: call.callId,
                                  output: "sandbox denied execution: \(reason)",
                                  success: false, truncated: false)
            }
        }
        guard isProcessLaunchSafe(argv: launch, cwd: workDir) else {
            return ToolResult(callId: call.callId,
                              output: "invalid shell command: contains unsupported control bytes",
                              success: false, truncated: false)
        }
        guard let exe = launch.first else {
            return ToolResult(callId: call.callId, output: "empty command",
                              success: false, truncated: false)
        }

        let timeoutMs = args.timeoutMs ?? defaultTimeoutMs
        let collector = OutputCollector(maxBytes: maxOutputBytes)

        #if os(macOS)
        return await runMacOSProcessGroup(callId: call.callId,
                                          launch: launch,
                                          workDir: workDir,
                                          timeoutMs: timeoutMs,
                                          collector: collector)
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = Array(launch.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exitLatch = ProcessExitLatch()
        process.terminationHandler = { p in
            exitLatch.resolve(p.terminationStatus)
        }

        do {
            try process.run()
            if !process.isRunning {
                exitLatch.resolve(process.terminationStatus)
            }
        } catch {
            return ToolResult(callId: call.callId,
                              output: "failed to spawn \(exe): \(error)",
                              success: false, truncated: false)
        }

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let callId = call.callId
        // F5b: publish chunks to the in-process ShellOutputBus so SessionEngine
        // can forward them as `commandOutputDelta` notifications. Subscribers
        // are keyed by callId; nothing happens when no one is listening.
        let drain = Task.detached {
            while true {
                let d = outHandle.availableData
                if d.isEmpty { break }
                await collector.append(Array(d))
                await ShellOutputBus.shared.publish(callId: callId,
                                                    stream: "stdout", chunk: d)
            }
        }
        let drainErr = Task.detached {
            while true {
                let d = errHandle.availableData
                if d.isEmpty { break }
                await collector.append(Array(d))
                await ShellOutputBus.shared.publish(callId: callId,
                                                    stream: "stderr", chunk: d)
            }
        }

        let exitCode: Int32 = await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                await exitLatch.wait()
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                if process.isRunning {
                    // Snapshot + force-reap the whole descendant tree. The
                    // snapshot happens BEFORE any signal so a fast-exiting
                    // shell cannot reparent a runaway grandchild (e.g. the
                    // `yes` in `sh -c "yes > /dev/null"`) out of the ppid
                    // tree first.
                    reapProcessTree(process.processIdentifier)
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? -1
        }
        await waitForDrain(drain, closing: outHandle)
        await waitForDrain(drainErr, closing: errHandle)
        let rendered = await collector.rendered()
        let truncated = await collector.didTruncate()
        return ToolResult(callId: call.callId,
                          output: rendered.isEmpty ? "(no output)" : rendered,
                          success: exitCode == 0, truncated: truncated)
        #endif
    }

    #if os(macOS)
    private func runMacOSProcessGroup(callId: String,
                                      launch: [String],
                                      workDir: String,
                                      timeoutMs: Int,
                                      collector: OutputCollector) async -> ToolResult {
        guard let exe = launch.first else {
            return ToolResult(callId: callId, output: "empty command",
                              success: false, truncated: false)
        }
        var outFD: [Int32] = [0, 0]
        var errFD: [Int32] = [0, 0]
        guard pipe(&outFD) == 0 else {
            return ToolResult(callId: callId,
                              output: "failed to create stdout pipe: \(errno)",
                              success: false, truncated: false)
        }
        guard pipe(&errFD) == 0 else {
            close(outFD[0]); close(outFD[1])
            return ToolResult(callId: callId,
                              output: "failed to create stderr pipe: \(errno)",
                              success: false, truncated: false)
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errFD[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outFD[0])
        posix_spawn_file_actions_addclose(&actions, outFD[1])
        posix_spawn_file_actions_addclose(&actions, errFD[0])
        posix_spawn_file_actions_addclose(&actions, errFD[1])
        _ = workDir.withCString {
            posix_spawn_file_actions_addchdir_np(&actions, $0)
        }

        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)

        var cargs: [UnsafeMutablePointer<CChar>?] = launch.map { strdup($0) }
        cargs.append(nil)
        let env = ProcessInfo.processInfo.environment
        var cenv: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attrs, cargs, cenv)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attrs)
        for p in cargs where p != nil { free(p) }
        for p in cenv where p != nil { free(p) }
        close(outFD[1])
        close(errFD[1])

        guard rc == 0 else {
            close(outFD[0])
            close(errFD[0])
            return ToolResult(callId: callId,
                              output: "failed to spawn \(exe): posix_spawn \(rc)",
                              success: false, truncated: false)
        }

        let childPid = pid
        let exitLatch = ProcessExitLatch()
        Task.detached {
            var status: Int32 = 0
            let waited = waitpid(childPid, &status, 0)
            guard waited == childPid else {
                exitLatch.resolve(-1)
                return
            }
            if status & 0x7f == 0 {
                exitLatch.resolve((status >> 8) & 0xff)
            } else {
                exitLatch.resolve(128 + (status & 0x7f))
            }
        }

        let outHandle = FileHandle(fileDescriptor: outFD[0], closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: errFD[0], closeOnDealloc: true)
        let callId = callId  // capture for the detached tasks
        let drain = Task.detached {
            while true {
                let d = outHandle.availableData
                if d.isEmpty { break }
                await collector.append(Array(d))
                await ShellOutputBus.shared.publish(callId: callId,
                                                    stream: "stdout", chunk: d)
            }
        }
        let drainErr = Task.detached {
            while true {
                let d = errHandle.availableData
                if d.isEmpty { break }
                await collector.append(Array(d))
                await ShellOutputBus.shared.publish(callId: callId,
                                                    stream: "stderr", chunk: d)
            }
        }

        var timedOut = false
        let exitCode: Int32 = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await exitLatch.wait() }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                killProcessGroup(childPid)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first != nil {
                // Clean exit: still tear down the process group so forked
                // grandchildren cannot outlive the tool call (fork-bomb
                // containment). Models that genuinely want to background a
                // long-lived daemon must escape the group with `setsid`
                // (e.g. `setsid python3 server.py >log.txt 2>&1 < /dev/null &`),
                // which the ShellTool description documents.
                killProcessGroup(childPid)
            } else {
                timedOut = true
            }
            return first ?? -1
        }
        await waitForDrain(drain, closing: outHandle)
        await waitForDrain(drainErr, closing: errHandle)
        let rendered = await collector.rendered()
        let truncated = await collector.didTruncate()
        // When the harness terminates the command, append a structured
        // marker so the model can tell a timeout apart from other
        // failure modes (defect #3: models were misattributing timeouts
        // to approval-gate denials).
        let body: String
        if timedOut {
            let prefix = rendered.isEmpty ? "" : rendered + "\n"
            body = "\(prefix)[shell tool: command timed out after \(timeoutMs)ms]"
        } else if rendered.isEmpty {
            body = "(no output)"
        } else {
            body = rendered
        }
        return ToolResult(callId: callId,
                          output: body,
                          success: exitCode == 0 && !timedOut,
                          truncated: truncated)
    }
    #endif

    private func isProcessLaunchSafe(argv: [String], cwd: String) -> Bool {
        func safe(_ s: String) -> Bool {
            !s.unicodeScalars.contains { $0.value == 0 }
        }
        return safe(cwd) && argv.allSatisfy(safe)
    }

    private func waitForDrain(_ task: Task<Void, Never>,
                              closing handle: FileHandle) async {
        let flag = DrainCompletionFlag()
        Task.detached {
            _ = await task.value
            await flag.setFinished()
        }
        for _ in 0..<20 {
            if await flag.isFinished() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? handle.close()
        _ = await task.value
    }
}

/// Serializes head+tail-bounded capture across the stdout/stderr drains.
actor OutputCollector {
    private var buf: HeadTailBuffer
    init(maxBytes: Int) { buf = HeadTailBuffer(maxBytes: max(16, maxBytes)) }
    func append(_ bytes: [UInt8]) { buf.append(bytes) }
    func rendered() -> String { buf.rendered() }
    func didTruncate() -> Bool { buf.didTruncate }
}

/// Force-reap a process and its entire descendant tree (CWE-400 guard). A
/// timed-out `sh -c "<cmd>"` otherwise reparents long-running grandchildren
/// (e.g. a spinning `yes`) to init where they keep consuming CPU forever.
/// The /proc descendant set is snapshotted BEFORE any kill so a fast-exiting
/// parent cannot detach a child from the ppid tree first; leaves are killed
/// before the root. Linux walks `/proc`; other platforms SIGKILL the root.
/// Single shared implementation (also used by the MCP client).
public func reapProcessTree(_ root: Int32) {
    #if os(Linux)
    var childrenOf: [Int32: [Int32]] = [:]
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") {
        for e in entries {
            guard let pid = Int32(e),
                  let stat = try? String(contentsOfFile: "/proc/\(pid)/stat",
                                         encoding: .utf8),
                  let rparen = stat.lastIndex(of: ")") else { continue }
            let rest = stat[stat.index(after: rparen)...]
                .trimmingCharacters(in: .whitespaces)
            let f = rest.split(separator: " ")
            if f.count >= 2, let ppid = Int32(f[1]) {
                childrenOf[ppid, default: []].append(pid)
            }
        }
    }
    var order: [Int32] = []
    var stack: [Int32] = [root]
    var seen = Set<Int32>()
    while let p = stack.popLast() {
        guard seen.insert(p).inserted else { continue }
        order.append(p)
        for c in childrenOf[p] ?? [] { stack.append(c) }
    }
    for p in order.reversed() { kill(p, SIGKILL) }   // leaves first, root last
    #elseif os(macOS)
    func directChildren(of pid: Int32) -> [Int32] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pgrep") else {
            return []
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return []
        }
        guard p.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }
    var order: [Int32] = []
    var stack: [Int32] = [root]
    var seen = Set<Int32>()
    while let p = stack.popLast() {
        guard seen.insert(p).inserted else { continue }
        order.append(p)
        for c in directChildren(of: p) { stack.append(c) }
    }
    for p in order.reversed() { kill(p, SIGKILL) }
    #else
    kill(root, SIGKILL)
    #endif
}

public func killProcessGroup(_ root: Int32) {
    #if os(macOS) || os(Linux)
    kill(-root, SIGKILL)
    #else
    kill(root, SIGKILL)
    #endif
}

/// Registers the built-in tool inventory on a router (Codex `built_tools`
/// core set). `unified_exec` is a persistent PTY-backed interactive process
/// session manager; `apply_patch` mutates the workspace and is serial.
public enum DefaultTools {
    public static func register(on router: ToolRouter,
                                sandbox: any Sandbox,
                                limits: Limits = Limits(),
                                webSearch: (any WebSearchBackend)? = nil,
                                spawnAgentOptions: SpawnAgentToolOptions = SpawnAgentToolOptions()) async {
        let uem = UnifiedExecManager()
        await router.register(ApplyPatchTool(sandbox: sandbox))
        await router.register(ShellTool(name: "shell_command", parallelSafe: false,
                                        sandbox: sandbox, limits: limits))
        await router.register(UnifiedExecTool(manager: uem,
                                              sandbox: sandbox,
                                              limits: limits))
        // Upstream parity (H-14 / P3.1): expose `exec_command` + `write_stdin`
        // as separate tools sharing the same PTY manager as `unified_exec`.
        await router.register(ExecCommandTool(manager: uem,
                                              sandbox: sandbox,
                                              limits: limits))
        await router.register(WriteStdinTool(manager: uem, limits: limits))
        await router.register(FileSearchTool())
        await router.register(ReadFileTool(limits: limits))
        await router.register(ListDirTool())
        await router.register(WriteFileTool(sandbox: sandbox))
        // Upstream parity (H-16 / P3.3): expose `view_image` so the model can
        // load a local image into context for vision tasks.
        await router.register(ViewImageTool(limits: limits))
        // Upstream parity (H-17 / H-18 / P3.4): expose `update_plan`,
        // `request_user_input`, `request_permissions` so the model can render
        // a plan, ask the user structured questions, and request escalated
        // sandbox permissions through structured channels rather than
        // free-form chat. SessionEngine subscribes to the matching
        // PlanUpdateBus / RequestUserInputBus / RequestPermissionsBus per
        // turn to forward / answer the requests.
        await router.register(UpdatePlanTool())
        await router.register(RequestUserInputTool())
        await router.register(RequestPermissionsTool())
        // Upstream parity (H-19 / P3.5): expose the multi-agent surface so the
        // model can spawn / wait / close / message / resume sub-agents. The
        // tools are thin shims over `MultiAgentBus.shared`, which the host
        // (HarnessCore.AgentOrchestrator) configures at startup. Without an
        // installed provider every call returns a structured "unconfigured"
        // error so the model gets actionable feedback.
        await router.register(SpawnAgentTool(options: spawnAgentOptions))
        await router.register(WaitAgentTool())
        await router.register(CloseAgentTool())
        await router.register(SendInputTool())
        await router.register(ResumeAgentTool())
        await router.register(GitDiffTool(limits: limits))
        await router.register(WebSearchTool(
            backend: webSearch ?? ResolvedWebSearch.fromEnvironment(),
            sandbox: sandbox))
        let nestedToolNames = (await router.specs()).map { $0.name }
        await installCodeMode(on: router, toolNames: nestedToolNames) { name, argsJSON, cwd, timeoutMs in
            await router.dispatchNestedFromCode(name: name,
                                                argumentsJSON: argsJSON,
                                                cwd: cwd,
                                                timeoutMs: timeoutMs)
        }
    }
}
