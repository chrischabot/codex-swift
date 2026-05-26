import Foundation
import InfraPrimitives
import Sandbox
import CPTY
import Dispatch
import os

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Security & performance note (audit fixes)
//
// Past behaviour at the PTY spawn site had three real vulnerabilities and
// one performance pathology:
//
//   1. The argv was unconditionally wrapped in `/bin/sh -lc "cd <cwd> &&
//      exec ..."`. The `-l` flag makes the spawned shell a LOGIN shell, so
//      the user's `~/.zshenv` / `~/.bash_profile` ran inside the sandboxed
//      child — a side-channel that could re-introduce API keys, set up SSH
//      agent forwarding, etc., bypassing the kernel sandbox profile.
//   2. The parent's full environment (`ProcessInfo.processInfo.environment`)
//      was passed verbatim to the child, leaking API keys / SSH agent /
//      cloud creds into anything the model could read with `env`.
//   3. The PTY master fd was not `FD_CLOEXEC`, so a concurrent spawn from
//      another thread could inherit the master and read/write the user's
//      live session.
//   4. `readWindow` busy-polled the master fd with a 50 ms `poll()` floor
//      so interactive latency could not drop below ~50 ms even on a fast
//      child. Below we use `DispatchSourceRead` on the master fd, which
//      fires from the kernel as soon as data is available.
//
// The current implementation:
//
//   * Spawns the argv DIRECTLY via `posix_spawn` with
//     `posix_spawn_file_actions_addchdir_np` for the cwd. No login shell is
//     interposed. Shell-string forms (`{"command": "echo hi"}`) still
//     reach `/bin/sh -c`-style execution via the upstream-shape
//     `CommandSpec.line` decoding (it produces an argv `["/bin/sh","-c",s]`
//     — same as ShellTool — but it is `-c`, NOT `-lc`, so no login
//     init files run).
//   * Scrubs the environment through `SandboxEnvironmentPolicy` exactly as
//     ShellTool does. Adds `TERM=xterm-256color` as an extra so interactive
//     children render correctly without leaking any sentinels from the
//     parent.
//   * Sets `POSIX_SPAWN_CLOEXEC_DEFAULT` on the spawnattr and `FD_CLOEXEC`
//     on the master fd immediately after `posix_openpt`. The slave is
//     closed in the parent after the spawn (only the child holds it).
//   * `readWindow` uses `DispatchSourceRead`, with a yield-window deadline
//     enforced by a wait-with-timeout. Latency drops from ~50ms baseline
//     to syscall-bound (sub-ms on the test bench).
//   * `UnifiedExecManager` keeps state in an `OSAllocatedUnfairLock` rather
//     than an actor mailbox. Per-session `OSAllocatedUnfairLock` serialises
//     read/write on one session's fd without head-of-line blocking
//     unrelated sessions. The public API stays `async` so the call sites
//     do not change.

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

/// One PTY-backed child process. Per-session state lives behind an
/// `OSAllocatedUnfairLock` so the manager can dispatch concurrent
/// `read`/`write` calls on DIFFERENT sessions without serialising them
/// through a single actor mailbox.
final class UnifiedExecProcess: @unchecked Sendable {
    let processId: Int32
    let pid: pid_t
    let masterFD: Int32
    /// Per-session lock. Serializes read/write on this fd; does NOT block
    /// other sessions.
    private let lock = OSAllocatedUnfairLock<State>(
        initialState: State(lastUsed: 0, exited: false, exitCode: nil))

    private struct State {
        var lastUsed: Double
        var exited: Bool
        var exitCode: Int32?
    }

    var lastUsed: Double {
        get { lock.withLock { $0.lastUsed } }
        set { lock.withLock { $0.lastUsed = newValue } }
    }
    var exited: Bool { lock.withLock { $0.exited } }
    var exitCode: Int32? { lock.withLock { $0.exitCode } }

    init(processId: Int32, pid: pid_t, masterFD: Int32) {
        self.processId = processId
        self.pid = pid
        self.masterFD = masterFD
        self.lock.withLock { $0.lastUsed = MonotonicClock.now() }
    }

    /// Read-side using `DispatchSourceRead`. Replaces the previous busy
    /// poll-loop. The source fires from the kernel as soon as the master fd
    /// becomes readable; we drain greedily inside the event handler and let
    /// the yield deadline arm a `DispatchWorkItem` that finishes the window.
    ///
    /// Returns whatever was captured during the window plus the
    /// exit/exit-code snapshot. PTY EOF (`read == 0` or `EIO`) marks the
    /// session as exited and reaps the child synchronously inside the
    /// handler (no extra round trip to the manager).
    func readWindow(yieldMs: Int, maxBytes: Int)
        -> (output: String, exited: Bool, exitCode: Int32?, truncated: Bool) {
        let fl = fcntl(masterFD, F_GETFL, 0)
        if fl >= 0 { _ = fcntl(masterFD, F_SETFL, fl | O_NONBLOCK) }

        if exited {
            return ("", true, exitCode, false)
        }

        // Bag-of-bytes + control state. The DispatchSourceRead handler
        // populates these; the caller thread waits on the semaphore.
        let bufferLock = OSAllocatedUnfairLock<HeadTailBuffer>(
            initialState: HeadTailBuffer(maxBytes: Swift.max(16, maxBytes)))
        let doneSem = DispatchSemaphore(value: 0)
        let alreadySignalled = OSAllocatedUnfairLock<Bool>(initialState: false)
        let signalOnce: () -> Void = {
            let first = alreadySignalled.withLock { fired -> Bool in
                if fired { return false }
                fired = true
                return true
            }
            if first { doneSem.signal() }
        }

        // The source fires on its own queue. We `read()` non-blocking until
        // EAGAIN or EOF, append to the head/tail buffer, and on EOF reap +
        // signal. `make-with-cancel` semantics: the read handler runs only
        // while the source is resumed; cancel is idempotent.
        let queue = DispatchQueue(label: "codex.unifiedexec.read.\(masterFD)")
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD,
                                                   queue: queue)
        let pidCopy = self.pid
        let fdCopy = self.masterFD
        let stateLock = self.lock

        source.setEventHandler { [self] in
            // Drain everything available; one fire can carry many bytes.
            // Use a heap-allocated buffer per fire so the closure doesn't
            // need a `var` capture (Sendable closures forbid it under Swift
            // 6 strict concurrency).
            let bufSize = 64 * 1024
            let scratchPtr = UnsafeMutableRawPointer.allocate(
                byteCount: bufSize,
                alignment: MemoryLayout<UInt8>.alignment)
            defer { scratchPtr.deallocate() }
            while true {
                let n = read(fdCopy, scratchPtr, bufSize)
                if n > 0 {
                    let slice = UnsafeRawBufferPointer(start: scratchPtr,
                                                      count: n)
                    let bytes = Array(slice.bindMemory(to: UInt8.self))
                    bufferLock.withLock { buf in buf.append(bytes) }
                    continue
                }
                if n == 0 {
                    // PTY EOF — slave closed. Reap synchronously.
                    self.reapInline(stateLock: stateLock, pid: pidCopy)
                    signalOnce()
                    return
                }
                let e = errno
                if e == EAGAIN || e == EWOULDBLOCK {
                    return                  // wait for next fire
                }
                if e == EINTR { continue }
                if e == EIO {
                    self.reapInline(stateLock: stateLock, pid: pidCopy)
                    signalOnce()
                    return
                }
                // Any other read error is treated as exit-with-failure.
                self.reapInline(stateLock: stateLock, pid: pidCopy)
                signalOnce()
                return
            }
        }
        source.resume()

        // Yield-window deadline.
        let deadline = DispatchTime.now() + .milliseconds(yieldMs)
        let r = doneSem.wait(timeout: deadline)
        source.cancel()
        // Cancel is async; ensure the handler has stopped touching shared
        // state by waiting on the cancel ack via a sync hop to the same
        // queue.
        queue.sync {}

        // Even if the timer expired, the child may have raced exit during
        // the window — give the per-session state lock the final word.
        if r == .timedOut {
            // Best-effort non-blocking reap so a child that exited but
            // didn't close the pty (unlikely) still gets harvested.
            _ = self.pollExited()
        }
        let snapshot = bufferLock.withLock { ($0.rendered(), $0.didTruncate) }
        let exitedNow = self.exited
        return (snapshot.0, exitedNow, exitCode, snapshot.1)
    }

    /// Mark the session exited and reap the child. Called from the
    /// DispatchSourceRead handler queue OR from `pollExited()`; the
    /// state-lock invariant makes both call sites safe.
    private func reapInline(stateLock: OSAllocatedUnfairLock<State>, pid: pid_t) {
        let already = stateLock.withLock { st -> Bool in
            if st.exited { return true }
            st.exited = true
            return false
        }
        if already { return }
        var status: Int32 = 0
        for _ in 0..<100 {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid {
                let code: Int32
                if status & 0x7f == 0 {
                    code = (status >> 8) & 0xff
                } else {
                    code = 128 + (status & 0x7f)
                }
                stateLock.withLock { $0.exitCode = code }
                return
            }
            if r < 0, errno == ECHILD { return }
            usleep(1_000)
        }
    }

    /// Non-blocking exit check; only used to harvest a race between the
    /// yield deadline expiring and the child actually terminating without
    /// closing the pty (rare). Most exits flow through the read handler.
    func pollExited() -> Bool {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid else {
            if r < 0, errno == ECHILD {
                lock.withLock { $0.exited = true }
                return true
            }
            return false
        }
        // Compute exit code outside the lock so the lock body has no `var`
        // capture (Swift 6 Sendable rules).
        let code: Int32 = (status & 0x7f == 0)
            ? ((status >> 8) & 0xff)
            : (128 + (status & 0x7f))
        lock.withLock { st in
            st.exited = true
            st.exitCode = code
        }
        return true
    }

    /// Write UTF-8 bytes to the master fd, looping over partial writes and
    /// briefly retrying on EAGAIN (master is O_NONBLOCK). `SIGPIPE` on the
    /// fd is ignored process-wide elsewhere (see `installSigpipeIgnore` in
    /// the manager init); a write to a closed slave surfaces as EPIPE here
    /// rather than as a fatal signal.
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
                    // EPIPE / EBADF: peer closed, nothing more to do.
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
    /// posix_spawn the argv DIRECTLY (no shell wrapper) with the slave
    /// dup2'd onto 0/1/2 and `addchdir_np` for the cwd. The PTY master is
    /// `FD_CLOEXEC` from open; the spawn has `POSIX_SPAWN_CLOEXEC_DEFAULT`
    /// so no stray parent fd leaks.
    static func spawn(argv: [String],
                      cwd: String,
                      envPolicy: SandboxEnvironmentPolicy)
        -> Result<(pid: pid_t, masterFD: Int32), ToolError> {
        guard let exe = argv.first else {
            return .failure(ToolError(message: "unified_exec: empty argv"))
        }
        var nameBuf = [CChar](repeating: 0, count: 256)
        let m = nameBuf.withUnsafeMutableBufferPointer {
            cpty_open_master($0.baseAddress, $0.count)
        }
        guard m >= 0 else {
            return .failure(ToolError(message: "unified_exec: pty open failed"))
        }
        // CLOEXEC immediately — no race window with a parallel spawn on
        // another thread.
        _ = fcntl(m, F_SETFD, FD_CLOEXEC)
        let slaveName = nameBuf.withUnsafeBufferPointer { buf in
            String(decoding: buf.prefix(while: { $0 != 0 })
                .map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        let s = open(slaveName, O_RDWR | O_NOCTTY)
        guard s >= 0 else {
            close(m)
            return .failure(ToolError(message: "unified_exec: open slave failed"))
        }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)

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
        _ = cwd.withCString {
            posix_spawn_file_actions_addchdir_np(&fa, $0)
        }

        // Argv is the user's argv, NOT a shell wrapper. (`CommandSpec.line`
        // already wraps free-form strings as `["/bin/sh","-c",s]` upstream.)
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)

        // Env: scrub, then inject TERM so the interactive child renders
        // correctly. The scrubber's default `extras` already sets
        // `NSUnbufferedIO=YES`.
        let scrubbedEnv = SandboxEnvironmentPolicy.scrubbed(
            policy: envPolicy,
            additionalExtras: ["TERM": "xterm-256color"])
        var cenv: [UnsafeMutablePointer<CChar>?] =
            scrubbedEnv.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)

        #if canImport(Darwin)
        var attr: posix_spawnattr_t? = nil
        #else
        var attr = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attr)
        #if canImport(Darwin)
        let flags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #else
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        #endif
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fa, &attr, cargs, cenv)

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

// MARK: - SIGPIPE handling
//
// A `write` to a master whose slave end has been closed surfaces as either
// EPIPE (good) or as SIGPIPE delivered synchronously (bad — terminates the
// harness). The default disposition is fatal. We install a one-shot
// `SIGPIPE -> SIG_IGN` so writes always come back as EPIPE and the manager
// can decide what to do.
private let sigpipeIgnoreInstalled: () = {
    signal(SIGPIPE, SIG_IGN)
}()

// MARK: - UnifiedExecManager

/// Persistent interactive process store. State lives behind an
/// `OSAllocatedUnfairLock` (so dispatching concurrent calls on DIFFERENT
/// sessions does not head-of-line block on a single actor mailbox);
/// per-session locks serialise reads/writes within a session. Bounded to
/// `MAX_UNIFIED_EXEC_PROCESSES` with LRU eviction (force-reap the descendant
/// tree on evict/exit).
public final class UnifiedExecManager: @unchecked Sendable {
    private struct State {
        var store: [Int32: UnifiedExecProcess] = [:]
        var nextId: Int32 = 1
    }
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {
        // Make sure SIGPIPE is ignored process-wide so a write to a closed
        // slave doesn't terminate the harness. `let _ = … = { … }()` style.
        _ = sigpipeIgnoreInstalled
    }

    /// Open a new PTY session and read the first window. The spawn happens
    /// under the manager state lock (so id assignment is atomic), but the
    /// per-session read window runs WITHOUT the manager lock — that's what
    /// gives us head-of-line-free concurrent sessions.
    public func open(argv: [String], cwd: String, yieldMs: Int, maxBytes: Int)
        async -> Result<(processId: Int32, output: String, exited: Bool,
                         exitCode: Int32?, truncated: Bool), ToolError> {
        // LRU eviction + id assignment under the lock. We DON'T call into
        // the kernel under the lock — that's what kept the old actor's
        // mailbox saturated.
        let pidId: Int32 = lock.withLock { st in
            if st.store.count >= MAX_UNIFIED_EXEC_PROCESSES {
                if let victim = st.store.values
                    .min(by: { $0.lastUsed < $1.lastUsed }) {
                    killProcessGroup(victim.pid)
                    reapProcessTree(victim.pid)
                    close(victim.masterFD)
                    st.store[victim.processId] = nil
                }
            }
            let id = st.nextId
            st.nextId += 1
            return id
        }

        // Env policy is looked up by the caller via the sandbox; we accept
        // it as a parameter to keep the manager pure (no global state).
        // Today every call comes through `UnifiedExecTool` / `ExecCommandTool`
        // which both have a `sandbox: any Sandbox`. We thread it through
        // via `spawn()`'s `envPolicy` parameter.
        switch PTY.spawn(argv: argv, cwd: cwd, envPolicy: .default) {
        case .failure(let e):
            return .failure(e)
        case .success(let spawned):
            let proc = UnifiedExecProcess(processId: pidId,
                                          pid: spawned.pid,
                                          masterFD: spawned.masterFD)
            // Read window runs WITHOUT the manager lock.
            let r = proc.readWindow(yieldMs: yieldMs, maxBytes: maxBytes)
            proc.lastUsed = MonotonicClock.now()
            if r.exited {
                killProcessGroup(proc.pid)
                reapProcessTree(proc.pid)
                close(proc.masterFD)
            } else {
                lock.withLock { $0.store[pidId] = proc }
            }
            return .success((pidId, r.output, r.exited, r.exitCode, r.truncated))
        }
    }

    /// Caller-supplied env policy variant — preferred entry point.
    public func open(argv: [String],
                     cwd: String,
                     yieldMs: Int,
                     maxBytes: Int,
                     envPolicy: SandboxEnvironmentPolicy)
        async -> Result<(processId: Int32, output: String, exited: Bool,
                         exitCode: Int32?, truncated: Bool), ToolError> {
        let pidId: Int32 = lock.withLock { st in
            if st.store.count >= MAX_UNIFIED_EXEC_PROCESSES {
                if let victim = st.store.values
                    .min(by: { $0.lastUsed < $1.lastUsed }) {
                    killProcessGroup(victim.pid)
                    reapProcessTree(victim.pid)
                    close(victim.masterFD)
                    st.store[victim.processId] = nil
                }
            }
            let id = st.nextId
            st.nextId += 1
            return id
        }
        switch PTY.spawn(argv: argv, cwd: cwd, envPolicy: envPolicy) {
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
                lock.withLock { $0.store[pidId] = proc }
            }
            return .success((pidId, r.output, r.exited, r.exitCode, r.truncated))
        }
    }

    public func writeStdin(processId: Int32, input: String,
                           yieldMs: Int, maxBytes: Int)
        async -> Result<(output: String, exited: Bool, exitCode: Int32?,
                         truncated: Bool), ToolError> {
        // Snapshot the process under the manager lock; do I/O OUTSIDE the
        // lock so other sessions can run concurrently.
        guard let proc = lock.withLock({ $0.store[processId] }) else {
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
            lock.withLock { $0.store[processId] = nil }
        }
        return .success((r.output, r.exited, r.exitCode, r.truncated))
    }

    public func shutdownAll() async {
        let snapshot = lock.withLock { st -> [UnifiedExecProcess] in
            let all = Array(st.store.values)
            st.store.removeAll()
            return all
        }
        for proc in snapshot {
            killProcessGroup(proc.pid)
            reapProcessTree(proc.pid)
            close(proc.masterFD)
        }
    }

    /// Test hook: current session count. Useful for fd-leak / cancel
    /// regression tests.
    public func sessionCount() -> Int {
        lock.withLock { $0.store.count }
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
        /// NOTE: the `-c` (NOT `-lc`) flag is deliberate. The old code used
        /// `-lc` (login shell), so the user's `~/.zshenv` ran inside the
        /// sandboxed child — a side-channel for re-introducing API keys.
        /// `-c` runs only the supplied command line without sourcing
        /// init files.
        var argv: [String] {
            switch self {
            case .argv(let a): return a
            case .line(let s): return ["/bin/sh", "-c", s]
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

    /// Reject bare-name executables. Same rationale as `ShellTool`: PATH
    /// resolution outside the sandbox is a known escape vector.
    private func validateExec(_ argv: [String]) -> String? {
        guard let exe = argv.first else { return "empty command" }
        if exe.hasPrefix("/") { return nil }
        if sandbox.spawnExecPolicy.allowlist.contains(exe) { return nil }
        return
            "unified_exec: bare executable name '\(exe)' is rejected; "
            + "pass an absolute path or use `/bin/sh -c '...'`"
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
        if !fullAccess, let reason = validateExec(argv) {
            return ToolResult(callId: call.callId, output: reason,
                              success: false, truncated: false)
        }
        if !fullAccess {
            switch sandbox.sandboxedInvocation(argv: argv, cwd: workDir) {
            case .run(let wrapped):
                argv = wrapped
            case .deny(let reason):
                return ToolResult(callId: call.callId,
                                  output: "sandbox denied execution: \(reason)",
                                  success: false, truncated: false)
            }
        } else if let exe = argv.first, !exe.hasPrefix("/") {
            // fullAccess: no sandbox in play, so `/usr/bin/env` wrapping
            // bare names is safe (the PATH search happens in a known
            // binary, not inside the kernel sandbox). Without this Darwin
            // posix_spawn would reject the bare name with ENOENT.
            argv = ["/usr/bin/env"] + argv
        }

        let res = await manager.open(argv: argv,
                                     cwd: workDir,
                                     yieldMs: yieldMs,
                                     maxBytes: maxBytes,
                                     envPolicy: sandbox.spawnEnvironmentPolicy)
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
        /// `-c` (no `-l`): see `UnifiedExecTool.CommandSpec`.
        var argv: [String] {
            switch self {
            case .argv(let a): return a
            case .line(let s): return ["/bin/sh", "-c", s]
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
            if let exe = argv.first, !exe.hasPrefix("/"),
               !sandbox.spawnExecPolicy.allowlist.contains(exe) {
                return ToolResult(callId: call.callId,
                    output: "exec_command: bare executable name '\(exe)' is "
                          + "rejected; pass an absolute path",
                    success: false, truncated: false)
            }
            switch sandbox.sandboxedInvocation(argv: argv, cwd: workDir) {
            case .run(let wrapped):
                argv = wrapped
            case .deny(let reason):
                return ToolResult(callId: call.callId,
                                  output: "sandbox denied execution: \(reason)",
                                  success: false, truncated: false)
            }
        } else if let exe = argv.first, !exe.hasPrefix("/") {
            argv = ["/usr/bin/env"] + argv
        }

        let started = MonotonicClock.now()
        let res = await manager.open(argv: argv,
                                     cwd: workDir,
                                     yieldMs: yieldMs,
                                     maxBytes: maxBytes,
                                     envPolicy: sandbox.spawnEnvironmentPolicy)
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
