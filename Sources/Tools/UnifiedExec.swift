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
//     ShellTool does, then applies the upstream `UNIFIED_EXEC_ENV` block
//     (NO_COLOR=1, TERM=dumb, LANG/LC_*=C.UTF-8, COLORTERM="", PAGER/GIT_PAGER/
//     GH_PAGER=cat, CODEX_CI=1) AFTER the scrub so child output is
//     deterministic and free of ANSI escapes / pager pauses — matching
//     `apply_unified_exec_env` (process_manager.rs:60-99).
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
/// Upstream `default_exec_yield_time_ms()` (core/src/tools/handlers/unified_exec.rs).
private let DEFAULT_EXEC_YIELD_TIME_MS = 10_000
private let YIELD_MAX_MS = 30_000
/// Upstream `DEFAULT_MAX_BACKGROUND_TERMINAL_TIMEOUT_MS` (core/src/unified_exec/mod.rs:66).
/// Empty-input long-polls clamp their upper bound to this 5-minute background
/// cap, not to `YIELD_MAX_MS`.
private let DEFAULT_MAX_BACKGROUND_TERMINAL_TIMEOUT_MS = 300_000

@inline(__always)
private func uxClamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
    Swift.min(hi, Swift.max(lo, v))
}

/// Verbatim upstream `UNIFIED_EXEC_ENV` (core/src/unified_exec/process_manager.rs:60-71).
/// Forces a non-interactive, no-color, paging-disabled environment for every
/// unified-exec child so command output is deterministic and free of ANSI
/// escapes / pager pauses. Applied AFTER the base scrub so these override
/// inherited values. Key order matches upstream.
let UNIFIED_EXEC_ENV: [(String, String)] = [
    ("NO_COLOR", "1"),
    ("TERM", "dumb"),
    ("LANG", "C.UTF-8"),
    ("LC_CTYPE", "C.UTF-8"),
    ("LC_ALL", "C.UTF-8"),
    ("COLORTERM", ""),
    ("PAGER", "cat"),
    ("GIT_PAGER", "cat"),
    ("GH_PAGER", "cat"),
    ("CODEX_CI", "1"),
]

// MARK: - UnifiedExecProcess

/// One PTY-backed child process. Per-session state lives behind an
/// `OSAllocatedUnfairLock` so the manager can dispatch concurrent
/// `read`/`write` calls on DIFFERENT sessions without serialising them
/// through a single actor mailbox.
final class UnifiedExecProcess: @unchecked Sendable {
    let processId: Int32
    let pid: pid_t
    let masterFD: Int32
    /// Whether this session is PTY-backed (stdin writable) or plain-pipes
    /// (stdin closed). Mirrors upstream `tty` flag; when `false`, `write_stdin`
    /// with non-empty input must return `StdinClosed`.
    let tty: Bool
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

    init(processId: Int32, pid: pid_t, masterFD: Int32, tty: Bool = true) {
        self.processId = processId
        self.pid = pid
        self.masterFD = masterFD
        self.tty = tty
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
        -> (output: String, exited: Bool, exitCode: Int32?, truncated: Bool,
            originalBytes: Int) {
        let fl = fcntl(masterFD, F_GETFL, 0)
        if fl >= 0 { _ = fcntl(masterFD, F_SETFL, fl | O_NONBLOCK) }

        if exited {
            return ("", true, exitCode, false, 0)
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
        let snapshot = bufferLock.withLock {
            ($0.rendered(), $0.didTruncate, $0.totalBytes)
        }
        let exitedNow = self.exited
        return (snapshot.0, exitedNow, exitCode, snapshot.1, snapshot.2)
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

    /// Build the scrubbed child environment, applying the upstream
    /// `UNIFIED_EXEC_ENV` block AFTER the base scrub so the deterministic
    /// non-interactive values (`TERM=dumb`, `NO_COLOR=1`, `PAGER=cat`, …)
    /// override anything inherited. Mirrors upstream `apply_unified_exec_env`
    /// (process_manager.rs:94-99).
    static func unifiedExecEnv(policy: SandboxEnvironmentPolicy)
        -> [String: String] {
        var extras: [String: String] = [:]
        for (k, v) in UNIFIED_EXEC_ENV { extras[k] = v }
        return SandboxEnvironmentPolicy.scrubbed(
            policy: policy,
            additionalExtras: extras)
    }

    /// posix_openpt → grantpt → unlockpt → ptsname → open slave →
    /// posix_spawn the argv DIRECTLY (no shell wrapper) with the slave
    /// dup2'd onto 0/1/2 and `addchdir_np` for the cwd. The PTY master is
    /// `FD_CLOEXEC` from open; the spawn has `POSIX_SPAWN_CLOEXEC_DEFAULT`
    /// so no stray parent fd leaks.
    ///
    /// When `tty == false` (upstream default) no PTY is allocated: stdout and
    /// stderr are attached to a single pipe and stdin is CLOSED, matching
    /// upstream `pipe::spawn_process_no_stdin_with_inherited_fds`
    /// (process_manager.rs:978-987). The returned `masterFD` is then the read
    /// end of that pipe and `tty=false` so `writeStdin` returns StdinClosed.
    static func spawn(argv: [String],
                      cwd: String,
                      envPolicy: SandboxEnvironmentPolicy,
                      tty: Bool = true)
        -> Result<(pid: pid_t, masterFD: Int32, tty: Bool), ToolError> {
        guard let exe = argv.first else {
            return .failure(ToolError(message: "unified_exec: empty argv"))
        }

        // The fd the parent reads child output from, and (for PTY) writes
        // stdin to. For the pipe path we open a read fd + write fd and dup
        // the write end onto the child's 1/2 with stdin closed.
        let masterFD: Int32
        let childOut: Int32      // fd the child's stdout/stderr is wired to
        if tty {
            var nameBuf = [CChar](repeating: 0, count: 256)
            let m = nameBuf.withUnsafeMutableBufferPointer {
                cpty_open_master($0.baseAddress, $0.count)
            }
            guard m >= 0 else {
                return .failure(ToolError(message: "unified_exec: pty open failed"))
            }
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
            masterFD = m
            childOut = s
        } else {
            var fds: [Int32] = [0, 0]
            let rc = fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }
            guard rc == 0 else {
                return .failure(ToolError(message: "unified_exec: pipe open failed"))
            }
            // fds[0] = read end (parent), fds[1] = write end (child).
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            masterFD = fds[0]
            childOut = fds[1]
        }

        #if canImport(Darwin)
        var fa: posix_spawn_file_actions_t? = nil
        #else
        var fa = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&fa)
        if tty {
            // Wire stdin/stdout/stderr to the slave PTY.
            posix_spawn_file_actions_adddup2(&fa, childOut, 0)
            posix_spawn_file_actions_adddup2(&fa, childOut, 1)
            posix_spawn_file_actions_adddup2(&fa, childOut, 2)
            posix_spawn_file_actions_addclose(&fa, childOut)
            posix_spawn_file_actions_addclose(&fa, masterFD)
        } else {
            // Plain pipes: stdin CLOSED, stdout+stderr → pipe write end.
            // Open /dev/null and dup it onto fd 0 so a read from stdin sees
            // immediate EOF (upstream closes stdin entirely; /dev/null gives
            // the same "no input" semantics portably under posix_spawn).
            _ = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(&fa, 0, path, O_RDONLY, 0)
            }
            posix_spawn_file_actions_adddup2(&fa, childOut, 1)
            posix_spawn_file_actions_adddup2(&fa, childOut, 2)
            posix_spawn_file_actions_addclose(&fa, childOut)
            posix_spawn_file_actions_addclose(&fa, masterFD)
        }
        _ = cwd.withCString {
            posix_spawn_file_actions_addchdir_np(&fa, $0)
        }

        // Argv is the user's argv, NOT a shell wrapper. (`CommandSpec.line`
        // already wraps free-form strings as `["/bin/sh","-c",s]` upstream.)
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)

        // Env: scrub, then apply the upstream UNIFIED_EXEC_ENV block (TERM=dumb,
        // NO_COLOR=1, PAGER=cat, …) so output is deterministic and free of ANSI
        // escapes / pager pauses. The scrubber's default `extras` already sets
        // `NSUnbufferedIO=YES`.
        let scrubbedEnv = unifiedExecEnv(policy: envPolicy)
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
        close(childOut)   // parent never uses the child's end

        if rc != 0 {
            close(masterFD)
            return .failure(ToolError(message: "unified_exec: posix_spawn failed (\(rc))"))
        }

        let fl = fcntl(masterFD, F_GETFL, 0)
        if fl >= 0 { _ = fcntl(masterFD, F_SETFL, fl | O_NONBLOCK) }
        return .success((pid, masterFD, tty))
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
        /// Sequential counter, used ONLY when `deterministicIds == true`
        /// (test mode). Production allocates a random id in `[1000, 100000)`.
        var nextId: Int32 = 1000
    }
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    /// Test-only deterministic id mode. Mirrors upstream
    /// `set_deterministic_process_ids_for_tests` (process_manager.rs:336-338):
    /// when `true`, ids are allocated sequentially from 1000; otherwise a
    /// random value in `[1000, 100000)` is used (retrying on collision),
    /// matching `allocate_process_id` (process_manager.rs:332-357).
    private let deterministicIds: Bool

    public init(deterministicIds: Bool = false) {
        self.deterministicIds = deterministicIds
        // Make sure SIGPIPE is ignored process-wide so a write to a closed
        // slave doesn't terminate the harness. `let _ = … = { … }()` style.
        _ = sigpipeIgnoreInstalled
    }

    /// Allocate a fresh process id under the state lock. Production uses a
    /// random value in `[1000, 100000)` (retry on collision); test mode uses
    /// a max+1 sequential scheme starting at 1000.
    private func allocateProcessId(_ st: inout State) -> Int32 {
        if deterministicIds {
            let id = Swift.max(st.nextId, 1000)
            st.nextId = id + 1
            return id
        }
        while true {
            let candidate = Int32.random(in: 1000..<100_000)
            if st.store[candidate] == nil { return candidate }
        }
    }

    /// Open a new PTY session and read the first window. The spawn happens
    /// under the manager state lock (so id assignment is atomic), but the
    /// per-session read window runs WITHOUT the manager lock — that's what
    /// gives us head-of-line-free concurrent sessions.
    public typealias OpenResult = (processId: Int32, output: String,
                                   exited: Bool, exitCode: Int32?,
                                   truncated: Bool, originalBytes: Int)
    public typealias WriteResult = (output: String, exited: Bool,
                                    exitCode: Int32?, truncated: Bool,
                                    originalBytes: Int)

    public func open(argv: [String], cwd: String, yieldMs: Int, maxBytes: Int,
                     tty: Bool = true)
        async -> Result<OpenResult, ToolError> {
        await open(argv: argv, cwd: cwd, yieldMs: yieldMs, maxBytes: maxBytes,
                   envPolicy: .default, tty: tty)
    }

    /// Caller-supplied env policy variant — preferred entry point.
    public func open(argv: [String],
                     cwd: String,
                     yieldMs: Int,
                     maxBytes: Int,
                     envPolicy: SandboxEnvironmentPolicy,
                     tty: Bool = true)
        async -> Result<OpenResult, ToolError> {
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
            return allocateProcessId(&st)
        }
        switch PTY.spawn(argv: argv, cwd: cwd, envPolicy: envPolicy, tty: tty) {
        case .failure(let e):
            return .failure(e)
        case .success(let spawned):
            let proc = UnifiedExecProcess(processId: pidId,
                                          pid: spawned.pid,
                                          masterFD: spawned.masterFD,
                                          tty: spawned.tty)
            let r = proc.readWindow(yieldMs: yieldMs, maxBytes: maxBytes)
            proc.lastUsed = MonotonicClock.now()
            if r.exited {
                killProcessGroup(proc.pid)
                reapProcessTree(proc.pid)
                close(proc.masterFD)
            } else {
                lock.withLock { $0.store[pidId] = proc }
            }
            return .success((pidId, r.output, r.exited, r.exitCode,
                             r.truncated, r.originalBytes))
        }
    }

    public func writeStdin(processId: Int32, input: String,
                           yieldMs: Int, maxBytes: Int)
        async -> Result<WriteResult, ToolError> {
        // Snapshot the process under the manager lock; do I/O OUTSIDE the
        // lock so other sessions can run concurrently.
        guard let proc = lock.withLock({ $0.store[processId] }) else {
            // Upstream `UnifiedExecError::UnknownProcessId`
            // (core/src/unified_exec/errors.rs:10-12) renders as
            // `Unknown process id <id>`; `write_stdin.rs:77-79` then wraps it as
            // `write_stdin failed: Unknown process id <id>`. Match the exact
            // wording the model is trained on.
            return .failure(ToolError(
                message: "Unknown process id \(processId)"))
        }
        // Upstream `write_stdin` (process_manager.rs:617-620): writing
        // non-empty input to a NON-tty (plain pipes, stdin closed) session is
        // a hard error — the model must rerun exec_command with tty=true.
        if !input.isEmpty, !proc.tty {
            return .failure(ToolError(
                message: "stdin is closed for this session; rerun exec_command "
                       + "with tty=true to keep stdin open"))
        }
        proc.writeStdin(input)
        // Upstream `process_manager.rs:621-626`: after a successful non-empty
        // write, sleep 100ms to give the child a window to react so its output
        // lands inside the following poll. Empty polls skip the settle.
        if !input.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let r = proc.readWindow(yieldMs: yieldMs, maxBytes: maxBytes)
        proc.lastUsed = MonotonicClock.now()
        if r.exited {
            killProcessGroup(proc.pid)
            reapProcessTree(proc.pid)
            close(proc.masterFD)
            lock.withLock { $0.store[processId] = nil }
        }
        return .success((r.output, r.exited, r.exitCode, r.truncated,
                         r.originalBytes))
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
            // Upstream derives the launch argv from the user's default shell
            // (`session.user_shell().derive_exec_args`, shell.rs:43-52), not a
            // hardcoded /bin/sh. `-c` (not `-lc`): login init files are not
            // sourced.
            case .line(let s): return UserShell.execArgs(command: s)
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
            // Empty polls clamp to the configurable background-terminal cap
            // (300s) per process_manager.rs:642-650; non-empty writes keep the
            // fixed 30s interactive cap.
            let yieldMs: Int = input.isEmpty
                ? Swift.max(MIN_EMPTY_YIELD_TIME_MS,
                            Swift.min(reqYield, DEFAULT_MAX_BACKGROUND_TERMINAL_TIMEOUT_MS))
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
                // Continuing an existing session with input is the equivalent
                // of upstream's `write_stdin` interaction; surface the stdin so
                // the host can emit `item/commandExecution/terminalInteraction`.
                // A pure poll (empty input) is not an interaction.
                if !input.isEmpty {
                    await TerminalInteractionPublisher.publish(
                        callId: call.callId,
                        processId: String(pidInt),
                        stdin: input)
                }
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

// MARK: - Terminal-interaction publishing

/// Bridges a PTY stdin write to `SessionEngine` via `TerminalInteractionBus`.
/// Encodes the `{ processId, stdin }` payload as a JSON string (the bus stays
/// type-free), mirroring the `ApplyPatchDeltaBus` publishing idiom. Best-effort:
/// if encoding fails the interaction is simply not surfaced (no fidelity-
/// critical state is lost — the tool output is unaffected).
enum TerminalInteractionPublisher {
    private struct Payload: Encodable { var processId: String; var stdin: String }
    static func publish(callId: String, processId: String, stdin: String) async {
        guard let data = try? JSONEncoder().encode(Payload(processId: processId, stdin: stdin)),
              let json = String(data: data, encoding: .utf8) else { return }
        await TerminalInteractionBus.shared.publish(callId: callId, payloadJSON: json)
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
/// Verbatim upstream `shell_spec.rs::unified_exec_output_schema()` — the
/// structured `output_schema` advertised on BOTH `exec_command` and
/// `write_stdin`. Keys are emitted in upstream `json!` order.
let unifiedExecOutputSchema: String =
    #"{"type":"object","properties":{"chunk_id":{"type":"string","description":"Chunk identifier included when the response reports one."},"wall_time_seconds":{"type":"number","description":"Elapsed wall time spent waiting for output in seconds."},"exit_code":{"type":"number","description":"Process exit code when the command finished during this call."},"session_id":{"type":"number","description":"Session identifier to pass to write_stdin when the process is still running."},"original_token_count":{"type":"number","description":"Approximate token count before output truncation."},"output":{"type":"string","description":"Command output text, possibly truncated."}},"required":["wall_time_seconds","output"],"additionalProperties":false}"#

/// The escalation/approval parameter triplet `sandbox_permissions`,
/// `justification`, `prefix_rule` that upstream `shell_spec.rs`
/// (`create_approval_parameters`, lines 281-325) inserts UNCONDITIONALLY into
/// both the `exec_command` and `shell_command` schemas — only the extra
/// `additional_permissions` object is gated on `exec_permission_approvals_enabled`
/// (which is off in this port's default path). Descriptions are verbatim from
/// `shell_spec.rs:287-313` (the flag-off `sandbox_permissions` wording). Emitted
/// as a JSON object-property fragment (no leading/trailing braces) so callers can
/// splice it into the surrounding `properties` object. The fragment is ordered
/// BTreeMap-style (justification, prefix_rule, sandbox_permissions) like upstream.
let approvalParametersSchemaFragment: String =
    #""justification":{"type":"string","description":"Only set if sandbox_permissions is \\\"require_escalated\\\".\n                    Request approval from the user to run this command outside the sandbox.\n                    Phrased as a simple question that summarizes the purpose of the\n                    command as it relates to the task at hand - e.g. 'Do you want to\n                    fetch and pull the latest version of this git branch?'"},"prefix_rule":{"type":"array","description":"Only specify when sandbox_permissions is `require_escalated`.\n                        Suggest a prefix command pattern that will allow you to fulfill similar requests from the user in the future.\n                        Should be a short but reasonable prefix, e.g. [\\\"git\\\", \\\"pull\\\"] or [\\\"uv\\\", \\\"run\\\"] or [\\\"pytest\\\"].","items":{"type":"string"}},"sandbox_permissions":{"type":"string","description":"Sandbox permissions for the command. Set to \"require_escalated\" to request running without sandbox restrictions; defaults to \"use_default\"."}"#

/// 6 lowercase-hex chars, matching upstream `unified_exec::generate_chunk_id`
/// (`(0..6).map(|_| format!("{:x}", rng.random_range(0..16)))`).
func generateChunkId() -> String {
    let hex = "0123456789abcdef"
    var s = ""
    for _ in 0..<6 { s.append(hex.randomElement()!) }
    return s
}

func renderExecJSON(sessionId: Int32?,
                            output: String,
                            exited: Bool,
                            exitCode: Int32?,
                            wallTimeSeconds: Double,
                            chunkId: String,
                            originalBytes: Int,
                            truncated _: Bool) -> String {
    // Upstream `ExecCommandOutput::response_text` (core/src/tools/context.rs:400):
    // a newline-joined section block sent to the model as plain text — NOT a
    // JSON envelope.
    var sections: [String] = []
    // Upstream pushes "Chunk ID: <id>" as the FIRST section whenever chunk_id is
    // non-empty (context.rs:403-404); the success paths always set one.
    if !chunkId.isEmpty {
        sections.append("Chunk ID: \(chunkId)")
    }
    sections.append(String(format: "Wall time: %.4f seconds", wallTimeSeconds))
    // Upstream `response_text` (context.rs:410-416) emits these two lines from
    // INDEPENDENT conditions: the exit-code line whenever `exit_code.is_some()`
    // and the session-id line whenever `process_id.is_some()`. A still-alive
    // process (ProcessStatus::Alive, process_manager.rs:509-516) can carry both a
    // Some(process_id) AND a Some(exit_code), so both lines may appear together.
    // Gate the exit-code line solely on exitCode (NOT on `exited`); gate the
    // session-id line on a live (non-exited) session, since upstream sets
    // process_id to None once the process has exited.
    if let code = exitCode {
        sections.append("Process exited with code \(code)")
    }
    if !exited, let sid = sessionId {
        sections.append("Process running with session ID \(sid)")
    }
    // Approximate token count (~4 bytes/token), upstream `original_token_count`.
    // Match `approx_token_count` (utils/string/src/truncate.rs:71-74): ceil
    // division `(len + 3) / 4`, with empty output yielding 0 (no min-of-1).
    // Upstream computes this from the FULL pre-truncation collected text
    // (process_manager.rs:578 `approx_token_count(&text)` where `text` is the
    // whole window output BEFORE the `output` field is separately truncated),
    // so use the original (uncapped) byte count, NOT the post-cap `output`.
    sections.append("Original token count: \((originalBytes + 3) / 4)")
    sections.append("Output:")
    sections.append(output)
    return sections.joined(separator: "\n")
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
    // Upstream `unified_exec/exec_command.rs::supports_parallel_tool_calls`
    // returns `true`: exec_command takes the read side of the per-turn gate so
    // it can run concurrently with other parallel-safe tools.
    public let parallelSafe = true
    // Verbatim upstream `shell_spec.rs::create_exec_command_tool_with_environment_id`
    // (non-Windows) description.
    public var toolDescription: String {
        "Runs a command in a PTY, returning output or a session ID for ongoing interaction."
    }
    // Upstream `shell_spec.rs::create_exec_command_tool_with_environment_id`
    // advertises (BTreeMap-sorted) cmd, max_output_tokens, shell, tty, workdir,
    // yield_time_ms with verbatim descriptions, PLUS the unconditionally-inserted
    // approval triplet justification / prefix_rule / sandbox_permissions
    // (`create_approval_parameters`, called regardless of
    // exec_permission_approvals_enabled — only `additional_permissions` is
    // flag-gated). The optional `login` boolean is advertised ONLY when
    // `allow_login_shell` is enabled (shell_spec.rs:281-288). `timeout_ms` is
    // accepted only as a decode alias for back-compat, not advertised. Required
    // [cmd], additionalProperties:false, plus the shared unified_exec output
    // schema.
    public var jsonSchema: String {
        var props =
            #""cmd":{"type":"string","description":"Shell command to execute."},"workdir":{"type":"string","description":"Optional working directory to run the command in; defaults to the turn cwd."},"shell":{"type":"string","description":"Shell binary to launch. Defaults to the user's default shell."},"tty":{"type":"boolean","description":"Whether to allocate a TTY for the command. Defaults to false (plain pipes); set to true to open a PTY and access TTY process."},"yield_time_ms":{"type":"number","description":"How long to wait (in milliseconds) for output before yielding."},"max_output_tokens":{"type":"number","description":"Maximum number of tokens to return. Excess output will be truncated."}"#
        if allowLoginShell {
            // Verbatim upstream `shell_spec.rs:283-287` exec_command `login` wording.
            props += #","login":{"type":"boolean","description":"Whether to run the shell with -l/-i semantics. Defaults to true."}"#
        }
        props += "," + approvalParametersSchemaFragment
        return #"{"type":"object","properties":{"# + props
            + #"},"required":["cmd"],"additionalProperties":false}"#
    }
    public var outputSchemaJSON: String? { unifiedExecOutputSchema }

    let manager: UnifiedExecManager
    let sandbox: any Sandbox
    let maxOutputBytes: Int
    let fullAccess: Bool
    /// Mirrors upstream `CommandToolOptions.allow_login_shell`. Off by default
    /// (matching the upstream default); when enabled the `login` boolean is
    /// advertised and a `login:true` request derives `-lc` argv. When disabled,
    /// an explicit `login:true` request is rejected (upstream
    /// `unified_exec::get_command`, unified_exec.rs:118-122).
    let allowLoginShell: Bool
    /// Upstream `effective_max_output_tokens` clamps `resolve_max_tokens(...)`
    /// down to `turn.truncation_policy.token_budget()` (unified_exec.rs:75-80).
    /// The port threads that per-turn budget here (in TOKENS). `nil` means no
    /// turn truncation policy was supplied, so only the static caps apply.
    let truncationPolicyTokenBudget: Int?

    public init(manager: UnifiedExecManager,
                sandbox: any Sandbox,
                limits: Limits = Limits(),
                fullAccess: Bool = false,
                allowLoginShell: Bool = false,
                truncationPolicyTokenBudget: Int? = nil) {
        self.manager = manager
        self.sandbox = sandbox
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
        self.fullAccess = fullAccess
        self.allowLoginShell = allowLoginShell
        self.truncationPolicyTokenBudget = truncationPolicyTokenBudget
    }

    /// Upstream `effective_max_output_tokens`
    /// (unified_exec.rs:75-80): `resolve_max_tokens(max_output_tokens)
    /// .min(truncation_policy.token_budget())`. `resolve_max_tokens` defaults a
    /// missing request to `DEFAULT_MAX_OUTPUT_TOKENS`; the turn truncation
    /// budget (when threaded) clamps it further down.
    private func effectiveMaxOutputTokens(_ requested: Int?) -> Int {
        let resolved = requested ?? DEFAULT_MAX_OUTPUT_TOKENS
        guard let budget = truncationPolicyTokenBudget else { return resolved }
        return Swift.min(resolved, budget)
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
        var argv: [String] { argv(shell: nil, useLoginShell: false) }

        /// Build the launch argv. For the string (line) form, honor the
        /// optional `shell` binary the model requested (upstream `shell` param);
        /// otherwise fall back to the user's default shell. `useLoginShell`
        /// selects `-lc` vs `-c`, matching upstream `Shell::derive_exec_args`
        /// (shell.rs:43-52) / `unified_exec::get_command`. The argv form is
        /// launched as-is (login semantics do not apply to a literal argv).
        func argv(shell: String?, useLoginShell: Bool) -> [String] {
            switch self {
            case .argv(let a): return a
            case .line(let s):
                // Honor the explicit `shell` arg if the model supplied one;
                // otherwise fall back to the user's default shell (upstream
                // `session.user_shell()`, shell.rs:312-336) — NOT /bin/sh.
                let sh = (shell?.isEmpty == false) ? shell! : UserShell.path
                // Derive per-shell-type argv, mirroring upstream
                // `Shell::derive_exec_args` (shell.rs:43-70) keyed on the shell
                // type detected from the binary basename (shell_detect.rs:5-24):
                //   PowerShell (pwsh/powershell): [path, ("-NoProfile" unless
                //                                  login), "-Command", command]
                //   Cmd (cmd):                    [path, "/c", command]
                //   Zsh/Bash/Sh (default):        [path, "-lc"|"-c", command]
                switch Self.detectShellType(sh) {
                case .powerShell:
                    var args = [sh]
                    if !useLoginShell { args.append("-NoProfile") }
                    args.append("-Command")
                    args.append(s)
                    return args
                case .cmd:
                    return [sh, "/c", s]
                case .posix:
                    return [sh, useLoginShell ? "-lc" : "-c", s]
                }
            }
        }

        private enum ShellKind { case posix, powerShell, cmd }

        /// Mirror upstream `detect_shell_type` (shell_detect.rs:5-24): match the
        /// shell-binary basename (path stem, extension stripped). Anything not
        /// recognised as PowerShell/Cmd is treated as a POSIX shell using
        /// `-c`/`-lc`, matching the Zsh/Bash/Sh arm.
        private static func detectShellType(_ path: String) -> ShellKind {
            // Strip directory and a single extension to obtain the file stem,
            // lowercased for case-insensitive matching (e.g. `cmd.exe`, `PWSH`).
            let base = (path as NSString).lastPathComponent
            let stem = (base as NSString).deletingPathExtension
            switch stem.lowercased() {
            case "pwsh", "powershell": return .powerShell
            case "cmd": return .cmd
            default: return .posix
            }
        }
    }

    #if DEBUG
    /// Test-only hook: derive the launch argv for a free-form command `line`
    /// using the per-shell-type conventions, exactly as the production
    /// `exec_command` line path does. Mirrors upstream `derive_exec_args`.
    static func _testDeriveArgv(line: String,
                                shell: String?,
                                useLoginShell: Bool) -> [String] {
        CmdSpec.line(line).argv(shell: shell, useLoginShell: useLoginShell)
    }
    #endif

    private struct Args: Decodable {
        var cmd: CmdSpec
        var cwd: String?
        var shell: String?
        var tty: Bool?
        var login: Bool?
        var timeoutMs: Int?
        var yieldTimeMs: Int?
        var maxOutputTokens: Int?
        // Upstream `ExecCommandArgs` (unified_exec.rs:44-50) decodes the escalation
        // triplet alongside the exec args. `sandbox_permissions` defaults to
        // "use_default"; `justification`/`prefix_rule` accompany "require_escalated".
        var sandboxPermissions: String?
        var justification: String?
        var prefixRule: [String]?
        enum CodingKeys: String, CodingKey {
            case cmd
            case cwd, workdir
            case shell
            case tty
            case login
            case timeout_ms, timeoutMs
            case yield_time_ms, yieldTimeMs
            case max_output_tokens, maxOutputTokens
            case sandbox_permissions, sandboxPermissions
            case justification
            case prefix_rule, prefixRule
        }
        init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            cmd = try c.decode(CmdSpec.self, forKey: .cmd)
            // Upstream advertises `workdir`; `cwd` accepted as an alias.
            cwd = try c.decodeIfPresent(String.self, forKey: .workdir)
                ?? c.decodeIfPresent(String.self, forKey: .cwd)
            shell = try c.decodeIfPresent(String.self, forKey: .shell)
            tty = try c.decodeIfPresent(Bool.self, forKey: .tty)
            login = try c.decodeIfPresent(Bool.self, forKey: .login)
            timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeout_ms)
                ?? c.decodeIfPresent(Int.self, forKey: .timeoutMs)
            yieldTimeMs = try c.decodeIfPresent(Int.self, forKey: .yield_time_ms)
                ?? c.decodeIfPresent(Int.self, forKey: .yieldTimeMs)
            maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .max_output_tokens)
                ?? c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
            sandboxPermissions = try c.decodeIfPresent(String.self, forKey: .sandbox_permissions)
                ?? c.decodeIfPresent(String.self, forKey: .sandboxPermissions)
            justification = try c.decodeIfPresent(String.self, forKey: .justification)
            prefixRule = try c.decodeIfPresent([String].self, forKey: .prefix_rule)
                ?? c.decodeIfPresent([String].self, forKey: .prefixRule)
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
        // Upstream `exec_command` default yield is `default_exec_yield_time_ms()`
        // = 10_000ms (NOT the 250ms MIN). write_stdin keeps the 250ms default.
        let requested = args.yieldTimeMs ?? args.timeoutMs ?? DEFAULT_EXEC_YIELD_TIME_MS
        let yieldMs = uxClamp(requested, YIELD_MIN_MS, YIELD_MAX_MS)
        // Upstream caps the token count by BOTH resolve_max_tokens AND the turn
        // truncation policy budget (effective_max_output_tokens); convert the
        // resulting token cap to bytes (~4 bytes/token) then floor at 16.
        let effTokens = effectiveMaxOutputTokens(args.maxOutputTokens)
        let tokenBytes = Swift.max(16, effTokens * 4)
        let maxBytes = Swift.min(maxOutputBytes,
                                 Swift.min(tokenBytes, UNIFIED_EXEC_OUTPUT_MAX_BYTES))

        // Honor the upstream `shell` param for the string command form.
        // `tty` defaults to false (upstream `shell_spec.rs` / `default_tty()`):
        // plain pipes with stdin CLOSED. Only `tty:true` allocates a PTY. A
        // subsequent write_stdin to a non-tty session returns StdinClosed.
        let useTty = args.tty ?? false
        // Mirror upstream `unified_exec::get_command` (unified_exec.rs:118-126):
        // `login:true` requires `allow_login_shell` (else reject); when omitted,
        // login defaults to `allow_login_shell`. Off by default, so the standard
        // path stays `-c` (no login init files / no API-key side-channel).
        let useLoginShell: Bool
        switch args.login {
        case .some(true) where !allowLoginShell:
            return ToolResult(callId: call.callId,
                output: "login shell is disabled by config; omit `login` or set it to false.",
                success: false, truncated: false)
        case .some(let v): useLoginShell = v
        case .none: useLoginShell = allowLoginShell
        }
        var argv = args.cmd.argv(shell: args.shell, useLoginShell: useLoginShell)
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
                // Upstream `exec_command.rs:279-294`: a `SandboxDenied` is still
                // returned to the model as a structured `ExecCommandToolOutput`
                // (the same envelope as a normal exec result) carrying a
                // chunk_id, wall_time, exit_code and original_token_count — NOT a
                // bare error string. The port denies pre-spawn, so the denial
                // text becomes the output, `exit_code` is set (terminal), and
                // there is no live session id for write_stdin to resume
                // (`process_id: None`). Mirror upstream's
                // `output.aggregated_output.text` / `original_token_count =
                // approx_token_count(&output_text)` (errors built from the
                // denied exec output).
                let deniedText = "sandbox denied execution: \(reason)"
                let body = renderExecJSON(
                    sessionId: nil,
                    output: deniedText,
                    exited: true,
                    exitCode: 1,
                    wallTimeSeconds: 0,
                    chunkId: generateChunkId(),
                    originalBytes: deniedText.utf8.count,
                    truncated: false)
                return ToolResult(callId: call.callId,
                                  output: body,
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
                                     envPolicy: sandbox.spawnEnvironmentPolicy,
                                     tty: useTty)
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
                chunkId: generateChunkId(),
                originalBytes: r.originalBytes,
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
    // Verbatim upstream `shell_spec.rs::create_write_stdin_tool` description.
    public var toolDescription: String {
        "Writes characters to an existing unified exec session and returns recent output."
    }
    // Upstream `create_write_stdin_tool`: session_id (number), chars,
    // yield_time_ms, max_output_tokens (BTreeMap-sorted), required [session_id],
    // additionalProperties:false, shared unified_exec output schema. The
    // non-upstream `terminate` flag is dropped to match the advertised contract.
    public var jsonSchema: String {
        #"{"type":"object","properties":{"session_id":{"type":"number","description":"Identifier of the running unified exec session."},"chars":{"type":"string","description":"Bytes to write to stdin (may be empty to poll)."},"yield_time_ms":{"type":"number","description":"How long to wait (in milliseconds) for output before yielding."},"max_output_tokens":{"type":"number","description":"Maximum number of tokens to return. Excess output will be truncated."}},"required":["session_id"],"additionalProperties":false}"#
    }
    public var outputSchemaJSON: String? { unifiedExecOutputSchema }

    let manager: UnifiedExecManager
    let maxOutputBytes: Int
    /// See `ExecCommandTool.truncationPolicyTokenBudget`. Upstream `write_stdin`
    /// also clamps via `effective_max_output_tokens(args.max_output_tokens,
    /// turn.truncation_policy)` (write_stdin.rs:65-66).
    let truncationPolicyTokenBudget: Int?

    public init(manager: UnifiedExecManager, limits: Limits = Limits(),
                truncationPolicyTokenBudget: Int? = nil) {
        self.manager = manager
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
        self.truncationPolicyTokenBudget = truncationPolicyTokenBudget
    }

    /// Upstream `effective_max_output_tokens` (unified_exec.rs:75-80).
    private func effectiveMaxOutputTokens(_ requested: Int?) -> Int {
        let resolved = requested ?? DEFAULT_MAX_OUTPUT_TOKENS
        guard let budget = truncationPolicyTokenBudget else { return resolved }
        return Swift.min(resolved, budget)
    }

    private struct Args: Decodable {
        var sessionId: Int
        var chars: String
        var yieldTimeMs: Int?
        // `terminate` is NOT advertised in the (upstream-faithful) schema, but is
        // still DECODED for back-compat so callers can politely close a session.
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
            ? Swift.max(MIN_EMPTY_YIELD_TIME_MS,
                        Swift.min(requested, DEFAULT_MAX_BACKGROUND_TERMINAL_TIMEOUT_MS))
            : uxClamp(requested, YIELD_MIN_MS, YIELD_MAX_MS)
        // effective_max_output_tokens: resolve, then clamp to the turn
        // truncation budget (when threaded), then convert to bytes.
        let effTokens = effectiveMaxOutputTokens(args.maxOutputTokens)
        let tokenBytes = Swift.max(16, effTokens * 4)
        let maxBytes = Swift.min(maxOutputBytes,
                                 Swift.min(tokenBytes, UNIFIED_EXEC_OUTPUT_MAX_BYTES))

        // `terminate` (back-compat, not advertised): append EOT (Ctrl-D) so the
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
            // Upstream `write_stdin.rs:77-79` wraps every manager error as
            // `write_stdin failed: {err}`, so an unknown session surfaces as
            // `write_stdin failed: Unknown process id <id>`.
            return ToolResult(callId: call.callId,
                              output: "write_stdin failed: \(e.message)",
                              success: false, truncated: false)
        case .success(let r):
            // Surface the stdin written to the interactive PTY so the host can
            // emit `item/commandExecution/terminalInteraction` (parity with
            // upstream `write_stdin` handler firing `EventMsg::TerminalInteraction`,
            // core/.../unified_exec/write_stdin.rs:81). `chars` (not the
            // EOF-augmented `toWrite`) matches upstream's `args.chars`.
            await TerminalInteractionPublisher.publish(
                callId: call.callId,
                processId: String(args.sessionId),
                stdin: args.chars)
            let body = renderExecJSON(
                sessionId: Int32(args.sessionId),
                output: r.output,
                exited: r.exited,
                exitCode: r.exitCode,
                wallTimeSeconds: wall,
                chunkId: generateChunkId(),
                originalBytes: r.originalBytes,
                truncated: r.truncated)
            let success = !r.exited || r.exitCode == 0
            return ToolResult(callId: call.callId,
                              output: body,
                              success: success,
                              truncated: r.truncated)
        }
    }
}
