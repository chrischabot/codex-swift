import Foundation
import InfraPrimitives
import Sandbox
import CPTY

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Constants (codex-rs unified_exec parity)

private let MAX_UNIFIED_EXEC_PROCESSES = 64
private let UNIFIED_EXEC_OUTPUT_MAX_BYTES = 1 << 20            // 1 MiB
private let DEFAULT_MAX_OUTPUT_TOKENS = 10_000
private let MIN_EMPTY_YIELD_TIME_MS = 5_000
private let YIELD_MIN_MS = 250
private let YIELD_MAX_MS = 30_000

@inline(__always)
private func uxClamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
    Swift.min(hi, Swift.max(lo, v))
}

// MARK: - UnifiedExecProcess

/// One PTY-backed child process. Non-Sendable POSIX state (fd/pid) is only ever
/// touched while the owning `UnifiedExecManager` actor is executing, so this is
/// safely `@unchecked Sendable` (same boxing pattern as ShellTool's helpers).
final class UnifiedExecProcess: @unchecked Sendable {
    let processId: Int32
    let pid: pid_t
    let masterFD: Int32
    var lastUsed: Double
    var exited: Bool = false
    var exitCode: Int32?

    init(processId: Int32, pid: pid_t, masterFD: Int32) {
        self.processId = processId
        self.pid = pid
        self.masterFD = masterFD
        self.lastUsed = MonotonicClock.now()
    }

    /// Non-blocking poll/read loop bounded by a yield window. Accumulates the
    /// bytes produced *during this window* into a head/tail-bounded buffer.
    /// On PTY EOF (`read` == 0 / `EIO`) the child closed the tty: mark exited
    /// and reap. Never blocks past the deadline.
    func readWindow(yieldMs: Int, maxBytes: Int)
        -> (output: String, exited: Bool, exitCode: Int32?, truncated: Bool) {
        let fl = fcntl(masterFD, F_GETFL, 0)
        if fl >= 0 { _ = fcntl(masterFD, F_SETFL, fl | O_NONBLOCK) }

        var buffer = HeadTailBuffer(maxBytes: Swift.max(16, maxBytes))
        let deadline = MonotonicClock.now() + Double(yieldMs) / 1000.0
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)

        while !exited {
            if pollExited() { break }
            if MonotonicClock.now() >= deadline { break }

            var pfd = pollfd()
            pfd.fd = masterFD
            pfd.events = Int16(POLLIN)
            pfd.revents = 0
            let pr = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, 50) }
            if pr < 0 {
                if errno == EINTR { continue }
                break
            }
            if pr == 0 { continue }   // poll timeout — re-check deadline

            let hup = (pfd.revents & Int16(POLLHUP)) != 0
            let readable = (pfd.revents &
                Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0
            if !readable { continue }

            let n = scratch.withUnsafeMutableBytes {
                read(masterFD, $0.baseAddress, $0.count)
            }
            if n > 0 {
                buffer.append(Array(scratch[0..<n]))
                continue
            }
            if n == 0 { markExited(); break }
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK {
                if hup { markExited(); break }
                continue
            }
            if e == EIO { markExited(); break }
            if e == EINTR { continue }
            markExited()
            break
        }
        return (buffer.rendered(), exited, exitCode, buffer.didTruncate)
    }

    private func markExited() {
        exited = true
        var status: Int32 = 0
        for _ in 0..<100 {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid {
                if status & 0x7f == 0 {
                    exitCode = (status >> 8) & 0xff       // WIFEXITED
                } else {
                    exitCode = 128 + (status & 0x7f)       // killed by signal
                }
                return
            }
            if r < 0, errno == ECHILD { return }
            usleep(1_000)
        }
    }

    private func pollExited() -> Bool {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid else {
            if r < 0, errno == ECHILD {
                exited = true
                return true
            }
            return false
        }
        exited = true
        if status & 0x7f == 0 {
            exitCode = (status >> 8) & 0xff
        } else {
            exitCode = 128 + (status & 0x7f)
        }
        return true
    }

    /// Write UTF-8 bytes to the master fd, looping over partial writes and
    /// briefly retrying on EAGAIN (master is O_NONBLOCK).
    func writeStdin(_ s: String) {
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(masterFD,
                              raw.baseAddress!.advanced(by: off),
                              raw.count - off)
                if n > 0 { off += n; continue }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        usleep(1_000)
                        continue
                    }
                }
                break
            }
        }
    }
}

// MARK: - PTY spawn helper

enum PTY {
    /// Single-quote a string for /bin/sh, escaping embedded single quotes.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// posix_openpt → grantpt → unlockpt → ptsname → open slave →
    /// posix_spawn `/bin/sh -lc "cd <cwd> && exec <argv...>"` with the slave
    /// dup2'd onto 0/1/2. Parent closes the slave and sets the master
    /// non-blocking.
    static func spawn(argv: [String], cwd: String)
        -> Result<(pid: pid_t, masterFD: Int32), ToolError> {
        var nameBuf = [CChar](repeating: 0, count: 256)
        let m = nameBuf.withUnsafeMutableBufferPointer {
            cpty_open_master($0.baseAddress, $0.count)
        }
        guard m >= 0 else {
            return .failure(ToolError(message: "unified_exec: pty open failed"))
        }
        let slaveName = nameBuf.withUnsafeBufferPointer { buf in
            String(decoding: buf.prefix(while: { $0 != 0 })
                .map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        let s = open(slaveName, O_RDWR | O_NOCTTY)
        guard s >= 0 else {
            close(m)
            return .failure(ToolError(message: "unified_exec: open slave failed"))
        }

        let composed = "cd \(shellQuote(cwd)) && exec "
            + argv.map { shellQuote($0) }.joined(separator: " ")
        let launch = ["/bin/sh", "-lc", composed]

        #if canImport(Darwin)
        var fa: posix_spawn_file_actions_t? = nil
        #else
        var fa = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, s, 0)
        posix_spawn_file_actions_adddup2(&fa, s, 1)
        posix_spawn_file_actions_adddup2(&fa, s, 2)
        posix_spawn_file_actions_addclose(&fa, s)
        posix_spawn_file_actions_addclose(&fa, m)

        var cargs: [UnsafeMutablePointer<CChar>?] = launch.map { strdup($0) }
        cargs.append(nil)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        var cenv: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)

        #if canImport(Darwin)
        var attr: posix_spawnattr_t? = nil
        #else
        var attr = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sh", &fa, &attr, cargs, cenv)

        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        for p in cargs where p != nil { free(p) }
        for p in cenv where p != nil { free(p) }
        close(s)   // parent never uses the slave

        if rc != 0 {
            close(m)
            return .failure(ToolError(message: "unified_exec: posix_spawn failed (\(rc))"))
        }

        let fl = fcntl(m, F_GETFL, 0)
        if fl >= 0 { _ = fcntl(m, F_SETFL, fl | O_NONBLOCK) }
        return .success((pid, m))
    }
}

// MARK: - UnifiedExecManager

/// Persistent interactive process store. The actor serializes all access so
/// `UnifiedExecProcess`'s raw fd/pid are race-free. Bounded to
/// `MAX_UNIFIED_EXEC_PROCESSES` with LRU eviction (force-reap the descendant
/// tree on evict/exit).
public actor UnifiedExecManager {
    private var store: [Int32: UnifiedExecProcess] = [:]
    private var nextId: Int32 = 1

    public init() {}

    public func open(argv: [String], cwd: String, yieldMs: Int, maxBytes: Int)
        -> Result<(processId: Int32, output: String, exited: Bool,
                   exitCode: Int32?, truncated: Bool), ToolError> {
        if store.count >= MAX_UNIFIED_EXEC_PROCESSES { evictLRU() }

        let pidId = nextId
        nextId += 1

        switch PTY.spawn(argv: argv, cwd: cwd) {
        case .failure(let e):
            return .failure(e)
        case .success(let spawned):
            let proc = UnifiedExecProcess(processId: pidId,
                                          pid: spawned.pid,
                                          masterFD: spawned.masterFD)
            let r = proc.readWindow(yieldMs: yieldMs, maxBytes: maxBytes)
            proc.lastUsed = MonotonicClock.now()
            if r.exited {
                killProcessGroup(proc.pid)
                reapProcessTree(proc.pid)
                close(proc.masterFD)
            } else {
                store[pidId] = proc
            }
            return .success((pidId, r.output, r.exited, r.exitCode, r.truncated))
        }
    }

    public func writeStdin(processId: Int32, input: String,
                           yieldMs: Int, maxBytes: Int)
        -> Result<(output: String, exited: Bool, exitCode: Int32?,
                   truncated: Bool), ToolError> {
        guard let proc = store[processId] else {
            return .failure(ToolError(
                message: "unified_exec: no such process \(processId)"))
        }
        proc.writeStdin(input)
        let r = proc.readWindow(yieldMs: yieldMs, maxBytes: maxBytes)
        proc.lastUsed = MonotonicClock.now()
        if r.exited {
            killProcessGroup(proc.pid)
            reapProcessTree(proc.pid)
            close(proc.masterFD)
            store[processId] = nil
        }
        return .success((r.output, r.exited, r.exitCode, r.truncated))
    }

    private func evictLRU() {
        guard let victim = store.values
            .min(by: { $0.lastUsed < $1.lastUsed }) else { return }
        killProcessGroup(victim.pid)
        reapProcessTree(victim.pid)
        close(victim.masterFD)
        store[victim.processId] = nil
    }

    public func shutdownAll() {
        for proc in store.values {
            killProcessGroup(proc.pid)
            reapProcessTree(proc.pid)
            close(proc.masterFD)
        }
        store.removeAll()
    }
}

// MARK: - UnifiedExecTool

/// Codex `unified_exec`: open a PTY-backed interactive process with `command`,
/// or continue an existing one with `process_id` (+ optional `input`). Non
/// full-access launches are kernel-sandbox wrapped exactly like `ShellTool`;
/// denial is a clean failure, never an unsandboxed run.
public struct UnifiedExecTool: Tool {
    public let name = "unified_exec"
    public let parallelSafe = false
    public var toolDescription: String {
        "Open and drive an INTERACTIVE PTY process — REPLs, `ssh`, `vim`, "
        + "`bash` sessions where you need to read prompts and write responses. "
        + "Open a new one with `command`; CONTINUE an existing one with "
        + "`process_id`+`input` (the `input` is written to that process's "
        + "stdin verbatim — it does NOT spawn a new command). To run a "
        + "different command, call this tool again WITHOUT `process_id` and "
        + "with a new `command`. Do NOT use this tool to background a "
        + "daemon/server (no real backgrounding happens here); for short "
        + "one-shot commands or background daemons launched with `&`/`nohup`, "
        + "use the `shell` tool instead. Returns captured output within a "
        + "yield window."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"command":{"description":"shell string or argv array to open a new process"},"process_id":{"type":"integer","description":"existing process id to continue"},"input":{"type":"string","description":"stdin to write before reading (may be empty to just poll)"},"yield_time_ms":{"type":"integer"},"max_output_tokens":{"type":"integer"}},"additionalProperties":true}"#
    }

    let manager: UnifiedExecManager
    let sandbox: any Sandbox
    let maxOutputBytes: Int
    let fullAccess: Bool

    public init(manager: UnifiedExecManager,
                sandbox: any Sandbox,
                limits: Limits = Limits(),
                fullAccess: Bool = false) {
        self.manager = manager
        self.sandbox = sandbox
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
        self.fullAccess = fullAccess
    }

    private enum CommandSpec: Decodable {
        case argv([String])
        case line(String)
        init(from d: any Decoder) throws {
            let c = try d.singleValueContainer()
            if let a = try? c.decode([String].self) { self = .argv(a); return }
            self = .line(try c.decode(String.self))
        }
        var argv: [String] {
            switch self {
            case .argv(let a): return a
            case .line(let s): return ["/bin/sh", "-lc", s]
            }
        }
    }

    private struct Args: Decodable {
        var command: CommandSpec?
        var processId: Int?
        var input: String?
        var yieldMs: Int?
        var maxOutputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case command, input
            case process_id, processId
            case yield_time_ms, yieldTimeMs
            case max_output_tokens, maxOutputTokens
        }
        init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            command = try c.decodeIfPresent(CommandSpec.self, forKey: .command)
            input = try c.decodeIfPresent(String.self, forKey: .input)
            processId = try c.decodeIfPresent(Int.self, forKey: .process_id)
                ?? c.decodeIfPresent(Int.self, forKey: .processId)
            yieldMs = try c.decodeIfPresent(Int.self, forKey: .yield_time_ms)
                ?? c.decodeIfPresent(Int.self, forKey: .yieldTimeMs)
            maxOutputTokens =
                try c.decodeIfPresent(Int.self, forKey: .max_output_tokens)
                ?? c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        }
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId,
                              output: "unified_exec: invalid arguments",
                              success: false, truncated: false)
        }

        let workDir = cwd
        let reqYield = args.yieldMs ?? YIELD_MIN_MS
        let tokenBytes = args.maxOutputTokens.map { Swift.max(16, $0 * 4) }
            ?? (DEFAULT_MAX_OUTPUT_TOKENS * 4)
        let maxBytes = Swift.min(maxOutputBytes,
                                 Swift.min(tokenBytes, UNIFIED_EXEC_OUTPUT_MAX_BYTES))

        if let pidInt = args.processId {
            let input = args.input ?? ""
            let yieldMs: Int = input.isEmpty
                ? Swift.max(MIN_EMPTY_YIELD_TIME_MS,
                            uxClamp(reqYield, YIELD_MIN_MS, YIELD_MAX_MS))
                : uxClamp(reqYield, YIELD_MIN_MS, YIELD_MAX_MS)

            let res = await manager.writeStdin(processId: Int32(pidInt),
                                               input: input,
                                               yieldMs: yieldMs,
                                               maxBytes: maxBytes)
            switch res {
            case .failure(let e):
                return ToolResult(callId: call.callId, output: e.message,
                                  success: false, truncated: false)
            case .success(let r):
                return makeResult(callId: call.callId,
                                  processId: Int32(pidInt),
                                  output: r.output, exited: r.exited,
                                  exitCode: r.exitCode, truncated: r.truncated)
            }
        }

        guard let spec = args.command else {
            return ToolResult(
                callId: call.callId,
                output: "unified_exec: provide `command` to open or "
                    + "`process_id`+`input` to continue",
                success: false, truncated: false)
        }

        let yieldMs = uxClamp(reqYield, YIELD_MIN_MS, YIELD_MAX_MS)
        var argv = spec.argv
        if !fullAccess {
            switch sandbox.sandboxedInvocation(argv: argv, cwd: workDir) {
            case .run(let wrapped):
                argv = wrapped
            case .deny(let reason):
                return ToolResult(callId: call.callId,
                                  output: "sandbox denied execution: \(reason)",
                                  success: false, truncated: false)
            }
        }

        let res = await manager.open(argv: argv, cwd: workDir,
                                     yieldMs: yieldMs, maxBytes: maxBytes)
        switch res {
        case .failure(let e):
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        case .success(let r):
            return makeResult(callId: call.callId,
                              processId: r.processId,
                              output: r.output, exited: r.exited,
                              exitCode: r.exitCode, truncated: r.truncated)
        }
    }

    private func makeResult(callId: String, processId: Int32,
                            output: String, exited: Bool,
                            exitCode: Int32?, truncated: Bool) -> ToolResult {
        let exitPart = exitCode.map { " exit_code=\($0)" } ?? ""
        let header =
            "[unified_exec process_id=\(processId) exited=\(exited)\(exitPart)]"
        let body = output.isEmpty ? "(no output)" : output
        // A still-running interactive process is success; a normal exit 0 is
        // success; an exited non-zero is failure.
        let success = !exited || exitCode == 0
        return ToolResult(callId: callId,
                          output: header + "\n" + body,
                          success: success, truncated: truncated)
    }
}

// MARK: - Upstream-shape exec_command / write_stdin

/// Render the structured JSON output shape that upstream `exec_command` and
/// `write_stdin` both emit (see `core/src/tools/handlers/shell_spec.rs` —
/// `unified_exec_output_schema`). Required: `wall_time_seconds`, `output`.
/// Optional: `session_id` (only when the process is still running),
/// `exit_code` (only when it has finished), and `original_token_count`.
///
/// Upstream sets `additionalProperties: false` on this schema, so we emit ONLY
/// upstream-declared fields. Truncation is signaled out-of-band via
/// `ToolResult.truncated` (the captured `output` itself carries the cap).
private func renderExecJSON(sessionId: Int32?,
                            output: String,
                            exited: Bool,
                            exitCode: Int32?,
                            wallTimeSeconds: Double,
                            truncated _: Bool) -> String {
    // Approximate token count (~ 4 bytes/token, matches upstream's
    // `approx_token_count` ballpark for parity reporting).
    let approxTokens = max(1, output.utf8.count / 4)
    var obj: [String: Any] = [
        "wall_time_seconds": wallTimeSeconds,
        "output": output,
        "original_token_count": approxTokens,
    ]
    if !exited, let sid = sessionId {
        obj["session_id"] = Int(sid)
    }
    if exited, let code = exitCode {
        obj["exit_code"] = Int(code)
    }
    // Stable key ordering for deterministic test diffs.
    let data = (try? JSONSerialization.data(
        withJSONObject: obj,
        options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
}

/// Upstream `exec_command`: open a NEW PTY session.
///
/// Schema mirrors `core/src/tools/handlers/shell_spec.rs::create_exec_command_tool`
/// — required `cmd`, optional `cwd` (called `workdir` upstream, aliased here),
/// optional `timeout_ms` and `yield_time_ms`. Output is the structured JSON
/// envelope shared with `write_stdin` so the model can drive multi-turn
/// interactive sessions by passing back `session_id`.
public struct ExecCommandTool: Tool {
    public let name = "exec_command"
    public let parallelSafe = false
    public var toolDescription: String {
        "Open a NEW interactive PTY session and run a shell command. Returns "
        + "a structured JSON object containing `session_id` (when still "
        + "running), `output` captured during the yield window, and "
        + "`exit_code` when the process finishes. Use `write_stdin` with the "
        + "returned `session_id` to continue an interactive session (REPL, "
        + "ssh, vim). For one-shot non-interactive commands, prefer "
        + "`shell_command`."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"cmd":{"description":"Shell command to execute (string or argv array)."},"cwd":{"type":"string","description":"Optional working directory; defaults to the turn cwd."},"timeout_ms":{"type":"number","description":"Soft timeout. Maps onto the PTY yield window."},"yield_time_ms":{"type":"number","description":"How long (ms) to wait for output before yielding."},"max_output_tokens":{"type":"number","description":"Maximum number of tokens to return."}},"required":["cmd"],"additionalProperties":false}"#
    }

    let manager: UnifiedExecManager
    let sandbox: any Sandbox
    let maxOutputBytes: Int
    let fullAccess: Bool

    public init(manager: UnifiedExecManager,
                sandbox: any Sandbox,
                limits: Limits = Limits(),
                fullAccess: Bool = false) {
        self.manager = manager
        self.sandbox = sandbox
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
        self.fullAccess = fullAccess
    }

    private enum CmdSpec: Decodable {
        case argv([String])
        case line(String)
        init(from d: any Decoder) throws {
            let c = try d.singleValueContainer()
            if let a = try? c.decode([String].self) { self = .argv(a); return }
            self = .line(try c.decode(String.self))
        }
        var argv: [String] {
            switch self {
            case .argv(let a): return a
            case .line(let s): return ["/bin/sh", "-lc", s]
            }
        }
    }

    private struct Args: Decodable {
        var cmd: CmdSpec
        var cwd: String?
        var timeoutMs: Int?
        var yieldTimeMs: Int?
        var maxOutputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case cmd
            case cwd, workdir
            case timeout_ms, timeoutMs
            case yield_time_ms, yieldTimeMs
            case max_output_tokens, maxOutputTokens
        }
        init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            cmd = try c.decode(CmdSpec.self, forKey: .cmd)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
                ?? c.decodeIfPresent(String.self, forKey: .workdir)
            timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeout_ms)
                ?? c.decodeIfPresent(Int.self, forKey: .timeoutMs)
            yieldTimeMs = try c.decodeIfPresent(Int.self, forKey: .yield_time_ms)
                ?? c.decodeIfPresent(Int.self, forKey: .yieldTimeMs)
            maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .max_output_tokens)
                ?? c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        }
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId,
                              output: "exec_command: invalid arguments",
                              success: false, truncated: false)
        }

        let workDir = args.cwd ?? cwd
        // `yield_time_ms` is the canonical knob upstream; `timeout_ms` is
        // accepted as an alias so callers driven by the legacy `shell_command`
        // contract Just Work. The two upper-bound each other via clamp.
        let requested = args.yieldTimeMs ?? args.timeoutMs ?? YIELD_MIN_MS
        let yieldMs = uxClamp(requested, YIELD_MIN_MS, YIELD_MAX_MS)
        let tokenBytes = args.maxOutputTokens.map { Swift.max(16, $0 * 4) }
            ?? (DEFAULT_MAX_OUTPUT_TOKENS * 4)
        let maxBytes = Swift.min(maxOutputBytes,
                                 Swift.min(tokenBytes, UNIFIED_EXEC_OUTPUT_MAX_BYTES))

        var argv = args.cmd.argv
        if !fullAccess {
            switch sandbox.sandboxedInvocation(argv: argv, cwd: workDir) {
            case .run(let wrapped):
                argv = wrapped
            case .deny(let reason):
                return ToolResult(callId: call.callId,
                                  output: "sandbox denied execution: \(reason)",
                                  success: false, truncated: false)
            }
        }

        let started = MonotonicClock.now()
        let res = await manager.open(argv: argv, cwd: workDir,
                                     yieldMs: yieldMs, maxBytes: maxBytes)
        let wall = MonotonicClock.now() - started
        switch res {
        case .failure(let e):
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        case .success(let r):
            let body = renderExecJSON(
                sessionId: r.processId,
                output: r.output,
                exited: r.exited,
                exitCode: r.exitCode,
                wallTimeSeconds: wall,
                truncated: r.truncated)
            let success = !r.exited || r.exitCode == 0
            return ToolResult(callId: call.callId,
                              output: body,
                              success: success,
                              truncated: r.truncated)
        }
    }
}

/// Upstream `write_stdin`: continue an existing PTY session.
///
/// Schema mirrors `core/src/tools/handlers/shell_spec.rs::create_write_stdin_tool`
/// — required `session_id`; `chars` is optional (defaults to empty for polling). The optional `terminate` flag is a
/// codex-swift convenience to politely close the session (send EOF / SIGHUP)
/// after the write; ignored if the process is already done. Output shares the
/// `exec_command` JSON envelope.
public struct WriteStdinTool: Tool {
    public let name = "write_stdin"
    public let parallelSafe = false
    public var toolDescription: String {
        "Continue an interactive PTY session opened by `exec_command`. Writes "
        + "`chars` to that session's stdin and returns the next chunk of "
        + "output as structured JSON (same shape as `exec_command`). Pass an "
        + "empty `chars` string to just poll for new output without writing."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"session_id":{"type":"integer","description":"Identifier of the running session, as returned by exec_command."},"chars":{"type":"string","description":"Bytes to write to stdin (may be empty to poll)."},"yield_time_ms":{"type":"number","description":"How long (ms) to wait for output before yielding."},"terminate":{"type":"boolean","description":"If true, close the session after writing (sends EOF + SIGHUP)."},"max_output_tokens":{"type":"number","description":"Maximum number of tokens to return."}},"required":["session_id"],"additionalProperties":false}"#
    }

    let manager: UnifiedExecManager
    let maxOutputBytes: Int

    public init(manager: UnifiedExecManager, limits: Limits = Limits()) {
        self.manager = manager
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
    }

    private struct Args: Decodable {
        var sessionId: Int
        var chars: String
        var yieldTimeMs: Int?
        var terminate: Bool?
        var maxOutputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case session_id, sessionId
            case chars
            case yield_time_ms, yieldTimeMs
            case terminate
            case max_output_tokens, maxOutputTokens
        }
        init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            sessionId = try c.decodeIfPresent(Int.self, forKey: .session_id)
                ?? c.decode(Int.self, forKey: .sessionId)
            chars = (try? c.decode(String.self, forKey: .chars)) ?? ""
            yieldTimeMs = try c.decodeIfPresent(Int.self, forKey: .yield_time_ms)
                ?? c.decodeIfPresent(Int.self, forKey: .yieldTimeMs)
            terminate = try c.decodeIfPresent(Bool.self, forKey: .terminate)
            maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .max_output_tokens)
                ?? c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        }
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId,
                              output: "write_stdin: invalid arguments",
                              success: false, truncated: false)
        }
        let requested = args.yieldTimeMs ?? YIELD_MIN_MS
        // Match unified_exec's empty-input long-poll behavior for parity with
        // upstream's "send-no-bytes, just poll" use case.
        let yieldMs: Int = args.chars.isEmpty
            ? Swift.max(MIN_EMPTY_YIELD_TIME_MS, uxClamp(requested, YIELD_MIN_MS, YIELD_MAX_MS))
            : uxClamp(requested, YIELD_MIN_MS, YIELD_MAX_MS)
        let tokenBytes = args.maxOutputTokens.map { Swift.max(16, $0 * 4) }
            ?? (DEFAULT_MAX_OUTPUT_TOKENS * 4)
        let maxBytes = Swift.min(maxOutputBytes,
                                 Swift.min(tokenBytes, UNIFIED_EXEC_OUTPUT_MAX_BYTES))

        // If the caller asked for termination, append EOT (Ctrl-D) so the
        // process sees stdin EOF and exits cleanly inside this same window.
        let toWrite = (args.terminate == true)
            ? args.chars + "\u{0004}"
            : args.chars

        let started = MonotonicClock.now()
        let res = await manager.writeStdin(processId: Int32(args.sessionId),
                                           input: toWrite,
                                           yieldMs: yieldMs,
                                           maxBytes: maxBytes)
        let wall = MonotonicClock.now() - started
        switch res {
        case .failure(let e):
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        case .success(let r):
            let body = renderExecJSON(
                sessionId: Int32(args.sessionId),
                output: r.output,
                exited: r.exited,
                exitCode: r.exitCode,
                wallTimeSeconds: wall,
                truncated: r.truncated)
            let success = !r.exited || r.exitCode == 0
            return ToolResult(callId: call.callId,
                              output: body,
                              success: success,
                              truncated: r.truncated)
        }
    }
}
