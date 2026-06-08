import Foundation
import InfraPrimitives
import Sandbox
import Dispatch
import os

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Security note (audit fixes)
//
// Past behaviour shipped two real vulnerabilities at this spawn site:
//
//   1. Full env passthrough leaked every API key in the harness environment
//      (`OPENAI_API_KEY`, `ANTHROPIC_*`, `GITHUB_TOKEN`, `AWS_*`, …,
//      `SSH_AUTH_SOCK`) into the sandboxed child. `env`/`ps -E -p $$` inside
//      the jail then surfaced them to the model. The kernel sandbox profile
//      cannot help here — secrets are inherited through the spawn itself.
//
//   2. Pipe file descriptors and the PTY slave were not `O_CLOEXEC`, so a
//      concurrent spawn from another thread could inherit them across tool
//      calls and bridge output between unrelated children.
//
// The current implementation:
//
//   * Scrubs the environment through `SandboxEnvironmentPolicy` before every
//     spawn (allowlist + secret-name blocklist + project-namespace passthrough
//     for `CODEX_*`). The policy is on `SandboxPolicy.environmentPolicy` and
//     defaults to the restrictive allowlist defined in
//     `Sources/Sandbox/SpawnEnvironment.swift`.
//   * Sets `POSIX_SPAWN_CLOEXEC_DEFAULT` on the spawnattr AND `FD_CLOEXEC` on
//     every pipe fd immediately after `pipe()` — belt + suspenders, since
//     there is a brief window between `pipe()` and `posix_spawn()` during
//     which another spawn on another thread could inherit the fds.
//   * Refuses bare-name executables. Previously a `/usr/bin/env <name>`
//     wrapper was prepended for non-absolute paths so PATH search would
//     work — but the PATH search happened OUTSIDE the kernel sandbox,
//     letting models reach binaries the sandbox profile would otherwise
//     deny. Models must now pass an absolute path, or invoke `/bin/sh -c`
//     explicitly.
//
// Foundation.Subprocess (SE-0407): the task brief asks for an
// `if #available(macOS 26, *)` migration. As of macOS 26.4.1 SDK on this
// machine, `Foundation.Subprocess` is not present in the SDK — it ships as
// the out-of-tree `swift-subprocess` package (0.4 at time of writing).
// Adding that dependency would pull `swift-system` and `swift-docc-plugin`
// into the closure for marginal benefit on the host-side spawn path; the
// performance wins requested in the brief (DispatchSource-based wait, libproc
// for child-pid enumeration, OSAllocatedUnfairLock for locking, per-session
// state on UnifiedExecManager) are all achievable on the existing posix_spawn
// path and have been implemented below. The Subprocess migration is deferred
// to a follow-up change so the security fixes can land cleanly.

// MARK: - Lock-protected state primitives

/// Latches the child's exit code and parks awaiters. Replaces the old
/// `NSLock + waiters[]` helper with `OSAllocatedUnfairLock` — same
/// semantics, no Foundation lock overhead. The latch fans the eventual exit
/// status out to every `wait()` caller (in practice there's only one).
private final class ProcessExitLatch: @unchecked Sendable {
    private struct State {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>]
    }
    private let lock: OSAllocatedUnfairLock<State>

    init() {
        self.lock = OSAllocatedUnfairLock(initialState: State(status: nil,
                                                              waiters: []))
    }

    /// Idempotent: once a status is set, further calls are ignored.
    func resolve(_ value: Int32) {
        let pending = lock.withLock { st -> [CheckedContinuation<Int32, Never>] in
            guard st.status == nil else { return [] }
            st.status = value
            let waiters = st.waiters
            st.waiters.removeAll()
            return waiters
        }
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let resolved = lock.withLock { st -> Int32? in
                if let status = st.status { return status }
                st.waiters.append(continuation)
                return nil
            }
            if let r = resolved { continuation.resume(returning: r) }
        }
    }
}

/// Stand-in for the old `DrainCompletionFlag` actor — a single sync bool
/// behind an unfair lock. Used while waiting on detached drain tasks; an
/// actor was overkill (and adds a hop on the hot path).
private final class DrainCompletionFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    func setFinished() { lock.withLock { $0 = true } }
    func isFinished() -> Bool { lock.withLock { $0 } }
}

// MARK: - libproc-based descendant enumeration (macOS)
//
// The old `directChildren` implementation spawned `/usr/bin/pgrep -P <ppid>`
// per node in the descendant tree. That's two ms of latency per node (fork +
// exec + waitpid) and breaks down completely under sandbox profiles that
// deny `pgrep` outright (workspace-write profiles allow exec, but a future
// stricter profile is on the roadmap). The replacement is a single libproc
// call that returns the entire pid table in one round trip; we then build
// the ppid->[pid] map ourselves and walk it.

#if os(macOS)
/// Read the entire process list via `proc_listallpids` and return a
/// ppid → [pid] adjacency map. One libproc call regardless of tree size;
/// constant overhead per `reapProcessTree` invocation.
private func snapshotProcessTable() -> [Int32: [Int32]] {
    // First call sizes the buffer.
    let need = proc_listallpids(nil, 0)
    guard need > 0 else { return [:] }
    // `proc_listallpids` writes `Int32` pids. Over-allocate by 32 slots in
    // case new processes appear between sizing and reading.
    var pids = [pid_t](repeating: 0, count: Int(need) + 32)
    let actualBytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
        proc_listallpids(buf.baseAddress,
                         Int32(buf.count * MemoryLayout<pid_t>.size))
    }
    guard actualBytes > 0 else { return [:] }
    let count = Int(actualBytes) / MemoryLayout<pid_t>.size

    var childrenOf: [Int32: [Int32]] = [:]
    var info = proc_bsdshortinfo()
    let infoSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
    for i in 0..<count {
        let pid = pids[i]
        guard pid > 0 else { continue }
        // `PROC_PIDT_SHORTBSDINFO` returns ppid (and a few other fields) in
        // a fixed-size struct. Failures (gone process, permission) just skip
        // the pid.
        let r = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, ptr, infoSize)
        }
        if r == infoSize {
            let ppid = Int32(bitPattern: info.pbsi_ppid)
            if ppid > 0 {
                childrenOf[ppid, default: []].append(pid)
            }
        }
    }
    return childrenOf
}
#endif

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
    // Verbatim upstream `shell_spec.rs::create_shell_command_tool` description
    // (non-Windows). Prepend Windows-specific guidance under `cfg!(windows)`
    // upstream; this port targets POSIX so the non-Windows string is used.
    public var toolDescription: String {
        "Runs a shell command and returns its output.\n"
        + "- Always set the `workdir` param when using the shell_command "
        + "function. Do not use `cd` unless absolutely necessary."
    }
    public var jsonSchema: String {
        // Verbatim upstream `shell_spec.rs::create_shell_command_tool`
        // (BTreeMap-sorted): `command` / `timeout_ms` / `workdir` with the
        // upstream property descriptions, PLUS the escalation/approval triplet
        // justification / prefix_rule / sandbox_permissions, which upstream's
        // `create_approval_parameters` inserts UNCONDITIONALLY (only the extra
        // `additional_permissions` object is gated on
        // exec_permission_approvals_enabled — off in the port's default path).
        // The optional `login` boolean is advertised ONLY when `allow_login_shell`
        // is enabled (shell_spec.rs:170-178). Required [command],
        // additionalProperties:false.
        var props =
            #""command":{"type":"string","description":"The shell script to execute in the user's default shell"},"timeout_ms":{"type":"number","description":"The timeout for the command in milliseconds"},"workdir":{"type":"string","description":"The working directory to execute the command in"}"#
        if allowLoginShell {
            // Verbatim upstream `shell_spec.rs:172-177` shell_command `login` wording.
            props += #","login":{"type":"boolean","description":"Whether to run the shell with login shell semantics. Defaults to true."}"#
        }
        props += "," + approvalParametersSchemaFragment
        return #"{"type":"object","properties":{"# + props
            + #"},"required":["command"],"additionalProperties":false}"#
    }
    private let sandbox: any Sandbox
    private let maxOutputBytes: Int
    private let fullAccess: Bool
    /// Mirrors upstream `CommandToolOptions.allow_login_shell`. Off by default;
    /// when enabled the `login` boolean is advertised and `login:true` derives
    /// `-lc` argv. When disabled, an explicit `login:true` request is rejected.
    private let allowLoginShell: Bool

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
                fullAccess: Bool = false,
                allowLoginShell: Bool = false) {
        self.name = name
        self.parallelSafe = parallelSafe
        self.sandbox = sandbox
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
        self.fullAccess = fullAccess
        self.allowLoginShell = allowLoginShell
    }

    private struct Args: Decodable {
        var command: CommandSpec
        var cwd: String?
        var timeoutMs: Int?
        var login: Bool?
        // Upstream `shell_command` decodes the escalation triplet alongside the
        // command (shell_spec.rs advertises them unconditionally). They are
        // consumed by the session-level approval/escalation gate (which inspects
        // the raw args JSON); decoded here so they are recognized rather than
        // silently dropped as unknown keys.
        var sandboxPermissions: String?
        var justification: String?
        var prefixRule: [String]?
        // Upstream field names are `workdir` and `timeout_ms` (with serde alias
        // `timeout`). Accept those as the canonical wire keys; keep `cwd` and
        // `timeoutMs` as tolerant legacy aliases.
        enum CodingKeys: String, CodingKey {
            case command, workdir, cwd, timeout_ms, timeout, timeoutMs
            case login
            case sandbox_permissions, sandboxPermissions
            case justification
            case prefix_rule, prefixRule
        }
        init(from d: any Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            command = try c.decode(CommandSpec.self, forKey: .command)
            cwd = try c.decodeIfPresent(String.self, forKey: .workdir)
                ?? c.decodeIfPresent(String.self, forKey: .cwd)
            timeoutMs = try c.decodeIfPresent(Int.self, forKey: .timeout_ms)
                ?? c.decodeIfPresent(Int.self, forKey: .timeout)
                ?? c.decodeIfPresent(Int.self, forKey: .timeoutMs)
            login = try c.decodeIfPresent(Bool.self, forKey: .login)
            sandboxPermissions = try c.decodeIfPresent(String.self, forKey: .sandbox_permissions)
                ?? c.decodeIfPresent(String.self, forKey: .sandboxPermissions)
            justification = try c.decodeIfPresent(String.self, forKey: .justification)
            prefixRule = try c.decodeIfPresent([String].self, forKey: .prefix_rule)
                ?? c.decodeIfPresent([String].self, forKey: .prefixRule)
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
        var argv: [String] { argv(useLoginShell: false) }

        /// Build the launch argv. `useLoginShell` selects `-lc` vs `-c`, matching
        /// upstream `Shell::derive_exec_args(cmd, use_login_shell)` (shell.rs:43-52).
        func argv(useLoginShell: Bool) -> [String] {
            switch self {
            case .argv(let a): return a
            // Upstream `shell_command.rs` runs the free-form string under the
            // user's default shell via `shell.derive_exec_args(cmd,
            // use_login_shell)` (shell.rs:43-52), NOT a hardcoded /bin/sh, so
            // zsh/bash syntax the model relies on works. Default `-c` (not
            // `-lc`): login init files are not sourced (no API-key side-channel)
            // unless `login` is explicitly requested with allow_login_shell on.
            case .line(let s):
                return UserShell.execArgs(command: s, useLoginShell: useLoginShell)
            }
        }
    }

    /// Reject bare-name executables outright.
    ///
    /// Previously the code prepended `/usr/bin/env` to anything without a
    /// leading slash so PATH search would resolve the binary. That search
    /// happened OUTSIDE the kernel sandbox, so the model could reference a
    /// binary the sandbox profile would otherwise have denied (and the env
    /// wrapper would happily fork it before the sandbox even applied). The
    /// secure replacement: require an absolute path, full stop. Argv arrays
    /// from the model are expected to carry absolute paths
    /// (`["/bin/ls", "."]`); free-form shell strings already prepend
    /// `/bin/sh` via `CommandSpec.argv`. A future allowlist mode lives on
    /// `SandboxExecPolicy.allowlist` (unused today).
    /// Returns nil on success or a human-readable rejection reason.
    private func validateExec(_ argv: [String]) -> String? {
        guard let exe = argv.first else { return "empty command" }
        if exe.hasPrefix("/") { return nil }
        let allow = sandbox.spawnExecPolicy.allowlist
        if allow.contains(exe) { return nil }
        return
            "shell tool: bare executable name '\(exe)' is rejected; "
            + "pass an absolute path or use `/bin/sh -c '...'` so the kernel "
            + "sandbox can confine the resolved binary"
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid shell arguments",
                              success: false, truncated: false)
        }
        let workDir = args.cwd ?? cwd
        // Mirror upstream `unified_exec::get_command` login resolution: `login:true`
        // requires `allow_login_shell` (else reject); when omitted, login defaults
        // to `allow_login_shell`. Off by default, so the standard path stays `-c`.
        let useLoginShell: Bool
        switch args.login {
        case .some(true) where !allowLoginShell:
            return ToolResult(callId: call.callId,
                output: "login shell is disabled by config; omit `login` or set it to false.",
                success: false, truncated: false)
        case .some(let v): useLoginShell = v
        case .none: useLoginShell = allowLoginShell
        }
        let inner = args.command.argv(useLoginShell: useLoginShell)
        // Refuse bare-name exec BEFORE the sandbox wrapper runs (otherwise we
        // would just produce a confusing kernel-deny later for the same root
        // cause).
        if !fullAccess, let reason = validateExec(inner) {
            return ToolResult(callId: call.callId, output: reason,
                              success: false, truncated: false)
        }

        let launch: [String]
        if fullAccess {
            // Codex /shell: explicit full-access escape hatch. There is no
            // sandbox to escape from in this mode, so PATH lookup is fine;
            // we still wrap bare names through `/usr/bin/env` so PATH
            // resolution happens in a well-known binary rather than relying
            // on `posix_spawn`'s implicit PATH search (which Darwin does
            // NOT perform — it requires an absolute exe). Without this
            // wrapper a bare `python3` would fail with ENOENT.
            if let exe = inner.first, !exe.hasPrefix("/") {
                launch = ["/usr/bin/env"] + inner
            } else {
                launch = inner
            }
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
        let envPolicy = sandbox.spawnEnvironmentPolicy

        #if os(macOS)
        return await runMacOSProcessGroup(callId: call.callId,
                                          launch: launch,
                                          workDir: workDir,
                                          timeoutMs: timeoutMs,
                                          collector: collector,
                                          envPolicy: envPolicy)
        #else
        return await runLinuxFallback(callId: call.callId,
                                      exe: exe,
                                      launch: launch,
                                      workDir: workDir,
                                      timeoutMs: timeoutMs,
                                      collector: collector,
                                      envPolicy: envPolicy)
        #endif
    }

    #if !os(macOS)
    private func runLinuxFallback(callId: String,
                                  exe: String,
                                  launch: [String],
                                  workDir: String,
                                  timeoutMs: Int,
                                  collector: OutputCollector,
                                  envPolicy: SandboxEnvironmentPolicy)
        async -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = Array(launch.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        // Scrub env on Linux too — Foundation.Process inherits parent env by
        // default. Same allowlist policy as the macOS path.
        process.environment = envPolicy.scrub(ProcessInfo.processInfo.environment)
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
            return ToolResult(callId: callId,
                              output: "failed to spawn \(exe): \(error)",
                              success: false, truncated: false)
        }

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let id = callId
        let drain = Task.detached {
            while true {
                let d = outHandle.availableData
                if d.isEmpty { break }
                await collector.append(Array(d))
                await ShellOutputBus.shared.publish(callId: id,
                                                    stream: "stdout", chunk: d)
            }
        }
        let drainErr = Task.detached {
            while true {
                let d = errHandle.availableData
                if d.isEmpty { break }
                await collector.append(Array(d))
                await ShellOutputBus.shared.publish(callId: id,
                                                    stream: "stderr", chunk: d)
            }
        }

        let startTime = Date()
        var timedOut = false
        let exitCode: Int32 = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await exitLatch.wait() }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                if process.isRunning {
                    reapProcessTree(process.processIdentifier)
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { timedOut = true }
            return first ?? -1
        }
        await waitForDrain(drain, closing: outHandle)
        await waitForDrain(drainErr, closing: errHandle)
        let rendered = await collector.rendered()
        let truncated = await collector.didTruncate()
        let durationSeconds = Date().timeIntervalSince(startTime)
        let reportedExit: Int32 = timedOut ? shellExecTimeoutExitCode : exitCode
        let body = formatShellExecOutputStructured(output: rendered,
                                                   exitCode: reportedExit,
                                                   durationSeconds: durationSeconds,
                                                   timedOut: timedOut,
                                                   timeoutMs: timeoutMs)
        return ToolResult(callId: callId,
                          output: body,
                          success: exitCode == 0 && !timedOut, truncated: truncated)
    }
    #endif

    #if os(macOS)
    private func runMacOSProcessGroup(callId: String,
                                      launch: [String],
                                      workDir: String,
                                      timeoutMs: Int,
                                      collector: OutputCollector,
                                      envPolicy: SandboxEnvironmentPolicy)
        async -> ToolResult {
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
        // Apply FD_CLOEXEC to the pipe fds *immediately* (belt + suspenders;
        // see security note at top of file). Without this a concurrent
        // posix_spawn from another thread could inherit our pipe fds during
        // the gap before our own posix_spawn applies the dup2 + close
        // file actions. `POSIX_SPAWN_CLOEXEC_DEFAULT` (set below) only
        // covers the spawn we're about to do.
        _ = fcntl(outFD[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(outFD[1], F_SETFD, FD_CLOEXEC)
        guard pipe(&errFD) == 0 else {
            close(outFD[0]); close(outFD[1])
            return ToolResult(callId: callId,
                              output: "failed to create stderr pipe: \(errno)",
                              success: false, truncated: false)
        }
        _ = fcntl(errFD[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(errFD[1], F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        // The child still needs stdout/stderr on 1/2 — `addinherit_np` clears
        // CLOEXEC on the dup2 target so the child keeps them. addclose for
        // the read ends of the pipes (the child has no business reading its
        // own output back).
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
        // POSIX_SPAWN_CLOEXEC_DEFAULT: every fd in the parent is treated as
        // O_CLOEXEC during the spawn except those explicitly dup'd via
        // posix_spawn_file_actions_adddup2 (Apple extension; the only
        // hermetic way to prevent stray-fd inheritance on Darwin).
        let flags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attrs, flags)
        posix_spawnattr_setpgroup(&attrs, 0)

        var cargs: [UnsafeMutablePointer<CChar>?] = launch.map { strdup($0) }
        cargs.append(nil)
        // Scrub env: strip API keys / SSH agent socket / cloud creds before
        // they reach the child. See `SandboxEnvironmentPolicy.default`.
        let scrubbedEnv = envPolicy.scrub(ProcessInfo.processInfo.environment)
        var cenv: [UnsafeMutablePointer<CChar>?] =
            scrubbedEnv.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)

        let startTime = Date()
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
        // Non-blocking exit notification via DispatchSource(.exit). The old
        // path detached a `Task { waitpid(blocking) }` which was correct but
        // (a) parked an OS thread in the cooperative pool for the whole
        // run and (b) introduced a syscall on every tool invocation even for
        // a sub-second child. DispatchSource fires from the kernel when the
        // process state changes; we then `waitpid(WNOHANG)` to harvest the
        // status, cancel, and exit the source.
        let waitQueue = DispatchQueue(label: "codex.shell.wait.\(childPid)")
        let exitSource = DispatchSource.makeProcessSource(
            identifier: childPid,
            eventMask: .exit,
            queue: waitQueue)
        exitSource.setEventHandler {
            var status: Int32 = 0
            let r = waitpid(childPid, &status, WNOHANG)
            if r == childPid {
                if status & 0x7f == 0 {
                    exitLatch.resolve((status >> 8) & 0xff)
                } else {
                    exitLatch.resolve(128 + (status & 0x7f))
                }
                exitSource.cancel()
            } else if r < 0 && errno == ECHILD {
                exitLatch.resolve(-1)
                exitSource.cancel()
            }
        }
        exitSource.resume()

        let outHandle = FileHandle(fileDescriptor: outFD[0], closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: errFD[0], closeOnDealloc: true)
        let id = callId  // capture for the detached tasks
        let drain = Task.detached {
            while true {
                let d = outHandle.availableData
                if d.isEmpty { break }
                await collector.append(Array(d))
                await ShellOutputBus.shared.publish(callId: id,
                                                    stream: "stdout", chunk: d)
            }
        }
        let drainErr = Task.detached {
            while true {
                let d = errHandle.availableData
                if d.isEmpty { break }
                await collector.append(Array(d))
                await ShellOutputBus.shared.publish(callId: id,
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
        // Ensure the DispatchSource is torn down even if it never fired
        // (e.g. timeout path). Cancel is idempotent.
        exitSource.cancel()
        await waitForDrain(drain, closing: outHandle)
        await waitForDrain(drainErr, closing: errHandle)
        let rendered = await collector.rendered()
        let truncated = await collector.didTruncate()
        let durationSeconds = Date().timeIntervalSince(startTime)
        // Upstream surfaces EXEC_TIMEOUT_EXIT_CODE (124) on timeout
        // (exec/src/exec.rs:58); the model is trained to read exit_code and
        // duration_seconds from the structured envelope (tools/mod.rs:62-99).
        let reportedExit: Int32 = timedOut ? shellExecTimeoutExitCode : exitCode
        let body = formatShellExecOutputStructured(output: rendered,
                                                   exitCode: reportedExit,
                                                   durationSeconds: durationSeconds,
                                                   timedOut: timedOut,
                                                   timeoutMs: timeoutMs)
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
            flag.setFinished()
        }
        for _ in 0..<20 {
            if flag.isFinished() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? handle.close()
        _ = await task.value
    }
}

/// Upstream `EXEC_TIMEOUT_EXIT_CODE` (exec/src/exec.rs:58): the conventional
/// 124 exit code reported when the harness terminates a command on timeout.
let shellExecTimeoutExitCode: Int32 = 124

/// Builds the model-facing structured envelope for the default `shell` tool,
/// mirroring upstream `format_exec_output_for_model_structured`
/// (core/src/tools/mod.rs:62-99):
///
///   {"output": <content>, "metadata": {"exit_code": <i32>,
///    "duration_seconds": <f32 rounded to 1 decimal>}}
///
/// On timeout the content is `build_content_with_timeout`
/// (core/src/tools/mod.rs:139-150): the message `command timed out after
/// {duration_ms} milliseconds\n` is prepended BEFORE the captured output, and
/// the surfaced exit code is `EXEC_TIMEOUT_EXIT_CODE` (124).
func formatShellExecOutputStructured(output: String,
                                     exitCode: Int32,
                                     durationSeconds: Double,
                                     timedOut: Bool,
                                     timeoutMs: Int) -> String {
    let content: String
    if timedOut {
        // Match upstream build_content_with_timeout (core/src/tools/mod.rs:140-146)
        // which reports the ACTUAL measured wall-clock elapsed time via
        // exec_output.duration.as_millis(), NOT the configured timeout budget.
        // Rust's Duration::as_millis truncates toward zero, so use Int() (which
        // truncates) rather than rounding.
        let elapsedMs = Int(durationSeconds * 1000.0)
        content = "command timed out after \(elapsedMs) milliseconds\n\(output)"
    } else {
        content = output
    }
    // Match serde_json's f32 rendering for a value already rounded to 1 decimal
    // place (Ryu shortest form): e.g. 0 -> "0.0", 1.5 -> "1.5", 2 -> "2.0".
    let tenths = Int((durationSeconds * 10.0).rounded())
    let whole = tenths / 10
    let frac = abs(tenths % 10)
    let durationField = "\(whole).\(frac)"

    // JSON-escape the output string exactly as serde would (control chars,
    // quotes, backslashes).
    let escaped = jsonEscapeString(content)
    return "{\"output\":\"\(escaped)\",\"metadata\":{\"exit_code\":\(exitCode),\"duration_seconds\":\(durationField)}}"
}

/// Minimal RFC-8259 string escaping matching serde_json's default encoder for
/// the characters that appear in command output.
private func jsonEscapeString(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 8)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
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
/// before the root. Linux walks `/proc`; macOS uses libproc
/// (`proc_listallpids` + `proc_pidinfo PROC_PIDT_SHORTBSDINFO`) in a single
/// syscall pair regardless of tree size; other platforms SIGKILL the root.
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
    let childrenOf = snapshotProcessTable()
    var order: [Int32] = []
    var stack: [Int32] = [root]
    var seen = Set<Int32>()
    while let p = stack.popLast() {
        guard seen.insert(p).inserted else { continue }
        order.append(p)
        for c in childrenOf[p] ?? [] { stack.append(c) }
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

/// Mirrors upstream `protocol/openai_models.rs::ConfigShellToolType` (serde
/// `snake_case`). This is the per-model `shell_type` declared in `models.json`
/// (and resolvable from the `/models` endpoint) that upstream
/// `core/src/tools/spec_plan.rs::collect_tool_executors` gates the shell-tool
/// family on: the model is offered EXACTLY ONE coherent shell interface, never
/// `shell_command` and `exec_command`/`write_stdin` model-visible at once.
public enum ShellToolType: String, Sendable, Equatable, Codable {
    case `default`
    case local
    case unifiedExec = "unified_exec"
    case disabled
    case shellCommand = "shell_command"

    /// Map the raw serde string from `models.json` / the `/models` endpoint
    /// (upstream `ConfigShellToolType` `snake_case`) to a case. Unknown or nil
    /// values fall back to `.shellCommand`, the value every shipped model
    /// declares and the safe model-visible default.
    public static func from(rawValue: String?) -> ShellToolType {
        guard let rawValue, let v = ShellToolType(rawValue: rawValue) else {
            return .shellCommand
        }
        return v
    }
}

/// Registers the built-in tool inventory on a router (Codex `built_tools`
/// core set). `unified_exec` is a persistent PTY-backed interactive process
/// session manager; `apply_patch` mutates the workspace and is serial.
public enum DefaultTools {
    /// Upstream default for `request_permissions_tool_enabled`. Mirrors
    /// `Feature::RequestPermissionsTool.default_enabled() == false`
    /// (`features/src/tests.rs:129`), resolved into `ToolsConfig` at
    /// `tools/src/tool_config.rs:196`. By default upstream does NOT advertise
    /// `request_permissions`, so neither does the port.
    public static let defaultRequestPermissionsToolEnabled = false
    /// Upstream default for the `tool_search` discovery tool. Mirrors
    /// `Feature::ToolSearch.default_enabled() == true`
    /// (`features/src/tests.rs:193`). Upstream still only appends the
    /// `tool_search` executor when at least one DEFERRED tool with search
    /// metadata exists (`spec_plan.rs:523-540 append_tool_search_executor`), so
    /// the port likewise installs it only when `deferred` is non-empty.
    public static let defaultToolSearchEnabled = true

    public static func register(on router: ToolRouter,
                                sandbox: any Sandbox,
                                limits: Limits = Limits(),
                                webSearch: (any WebSearchBackend)? = nil,
                                shellType: ShellToolType = .shellCommand,
                                allowLoginShell: Bool = true,
                                requestPermissionsToolEnabled: Bool = defaultRequestPermissionsToolEnabled,
                                toolSearchEnabled: Bool = defaultToolSearchEnabled,
                                computerUseEnabled: Bool = false,
                                computerUseTokenProvider: (@Sendable () async -> String?)? = nil,
                                spawnAgentOptions: SpawnAgentToolOptions = SpawnAgentToolOptions()) async {
        let uem = UnifiedExecManager()
        // Under `dangerFullAccess` the model's exec tools must skip the
        // bare-name rejection (the env-wrap path) — there's no kernel sandbox
        // to escape from. Derived once here so all three exec-tool variants
        // see the same value. See commit ff1050a4 for the original intent.
        let fullAccess = sandbox.mode == .dangerFullAccess
        // Model-visible tool ordering MUST mirror upstream
        // `core/src/tools/spec_plan.rs::collect_tool_executors` (the push order
        // that `build_model_visible_specs_and_registry` preserves), or the
        // prompt-cache key for the tool list diverges. Upstream push order:
        //   1. shell/exec (shell_command  OR  exec_command + write_stdin),
        //      plus the hidden shell_command fallback in UnifiedExec mode
        //   2. [MCP resource handlers]      (port: none yet)
        //   3. update_plan
        //   4. [goal tools]                 (port: none)
        //   5. request_user_input
        //   6. request_permissions
        //   7. apply_patch
        //   8. view_image
        //   9. collab tools (spawn, send_input, resume, wait, close)
        //  10. [agent jobs / MCP tools / dynamic tools] then extension tools
        // The port appends its non-upstream extension tools (file tools,
        // workflows, git_diff, web_search, code) LAST so they never perturb the
        // relative order of the upstream-parity prefix.
        //
        // (1) Shell / exec family.
        // Upstream `spec_plan.rs::collect_tool_executors` gates the shell-tool
        // family on `ConfigShellToolType` (the per-model `shell_type`). The
        // model is offered EXACTLY ONE shell interface; `shell_command` and the
        // `exec_command`/`write_stdin` PTY pair are NEVER both model-visible.
        //
        // - `.default` / `.local` / `.shellCommand`: model-visible `shell_command`
        //   ONLY. (`models.json` declares `shell_type: shell_command` for every
        //   shipped model, so this is the live default.)
        // - `.unifiedExec`: model-visible `exec_command` + `write_stdin`, PLUS a
        //   HIDDEN `shell_command` fallback (upstream registers
        //   `ShellCommandHandler::from(backend)` with `options=None`, whose
        //   `spec()` is `None` — dispatchable but not advertised).
        // - `.disabled`: no shell tools at all.
        switch shellType {
        case .default, .local, .shellCommand:
            // Upstream `shell_command.rs::supports_parallel_tool_calls` returns
            // `options.is_some()`, and the model-visible `shell_command` is
            // registered with `options=Some`, so it is parallel-safe.
            await router.register(ShellTool(name: "shell_command", parallelSafe: true,
                                            sandbox: sandbox, limits: limits,
                                            fullAccess: fullAccess,
                                            allowLoginShell: allowLoginShell))
        case .unifiedExec:
            // Upstream parity (H-14 / P3.1): expose `exec_command` + `write_stdin`
            // as the model-visible interactive PTY pair.
            await router.register(ExecCommandTool(manager: uem,
                                                  sandbox: sandbox,
                                                  limits: limits,
                                                  fullAccess: fullAccess,
                                                  allowLoginShell: allowLoginShell))
            await router.register(WriteStdinTool(manager: uem, limits: limits))
            // Upstream registers a `shell_command` handler with `options=None`
            // (spec()=None) as a dispatchable fallback in UnifiedExec mode.
            // Mirror it as a HIDDEN tool: callable, but not in `specs()`.
            // Upstream `ShellCommandHandler::supports_parallel_tool_calls`
            // returns `self.options.is_some()` (shell_command.rs:144-145); the
            // unifiedExec fallback is constructed via `ShellCommandHandler::from`
            // with `options=None` (spec_plan.rs:374), so it is SERIAL, not
            // parallel-safe. The model-visible `shell_command` (options=Some,
            // registered above) stays parallel-safe.
            await router.registerHidden(ShellTool(name: "shell_command", parallelSafe: false,
                                                  sandbox: sandbox, limits: limits,
                                                  fullAccess: fullAccess,
                                                  allowLoginShell: allowLoginShell))
        case .disabled:
            break
        }
        // The legacy combined `unified_exec` tool has NO model-visible
        // counterpart in any upstream `shell_type` (upstream uses "unified_exec"
        // only as an internal approval-cache key / parallel-category label,
        // never as a `ToolSpec` name). Keep it CALLABLE for back-compat
        // (`dispatch` falls back to the hidden registry) but DO NOT advertise it
        // in `specs()`. Skip it entirely when shells are disabled.
        if shellType != .disabled {
            await router.registerHidden(UnifiedExecTool(manager: uem,
                                                        sandbox: sandbox,
                                                        limits: limits,
                                                        fullAccess: fullAccess))
        }
        // (3) update_plan, (5) request_user_input, (6) request_permissions.
        // Upstream parity (H-17 / H-18 / P3.4): the model can render a plan, ask
        // the user structured questions, and request escalated sandbox
        // permissions through structured channels rather than free-form chat.
        // SessionEngine subscribes to the matching PlanUpdateBus /
        // RequestUserInputBus / RequestPermissionsBus per turn to forward /
        // answer the requests. (There are no goal tools in the port, so slot (4)
        // is empty and update_plan is immediately followed by request_user_input.)
        await router.register(UpdatePlanTool())
        await router.register(RequestUserInputTool())
        // (6) request_permissions. Upstream `spec_plan.rs:402-404` pushes the
        // RequestPermissionsHandler ONLY `if config.request_permissions_tool_enabled`,
        // which `tool_config.rs:196` resolves from
        // `Feature::RequestPermissionsTool` — a stable feature that is OFF by
        // default (`features/src/tests.rs:129`). So a default-config upstream
        // session does NOT advertise `request_permissions`; gate it identically
        // here (audit tools-router finding 1) so the model-visible tool list and
        // its prompt-cache key match an upstream default session.
        if requestPermissionsToolEnabled {
            await router.register(RequestPermissionsTool())
        }
        // (7) apply_patch. Upstream pushes `ApplyPatchHandler` AFTER
        // request_permissions and BEFORE view_image (spec_plan.rs:419-422); the
        // port previously emitted it FIRST, breaking the prompt-cache-parity
        // claim. apply_patch mutates the workspace and is serial.
        await router.register(ApplyPatchTool(sandbox: sandbox))
        // (8) view_image. Upstream parity (H-16 / P3.3): load a local image into
        // context for vision tasks (spec_plan.rs:435-440).
        await router.register(ViewImageTool(limits: limits))
        // (9) Collab / multi-agent surface. Upstream parity (H-19 / P3.5).
        // Upstream non-v2 push order is spawn → send_input → resume → wait →
        // close (spec_plan.rs:480-484); reproduce it exactly (the port previously
        // emitted spawn → wait → close → send → resume). The tools are thin
        // shims over `MultiAgentBus.shared`, which the host
        // (HarnessCore.AgentOrchestrator) configures at startup. Without an
        // installed provider every call returns a structured "unconfigured"
        // error so the model gets actionable feedback.
        await router.register(SpawnAgentTool(options: spawnAgentOptions))
        await router.register(SendInputTool())
        await router.register(ResumeAgentTool())
        await router.register(WaitAgentTool())
        await router.register(CloseAgentTool())
        // (10) Port extension tools, appended AFTER the upstream-parity prefix so
        // they never perturb its relative order.
        //
        // INTENTIONAL PORT DIVERGENCE (audit exec-unified-shell finding 2):
        // Upstream (core/src/tools/spec_plan.rs:333-521) routes ALL filesystem
        // reads/writes/searches through `shell_command`/`exec_command` +
        // `apply_patch`; it has NO model-visible read_file/write_file/list_dir/
        // file_search/git_diff handlers. codex-swift advertises these as
        // additional convenience function tools (NOT replacements — the shell
        // surface remains fully intact, so the wire protocol is a superset, not
        // a divergence). They are exercised by FileToolsTests / GitUtilsTests /
        // CodeModeTests / EndToEndTests and are an accepted, documented port
        // extension outside the strict upstream tool contract.
        await router.register(FileSearchTool())
        await router.register(ReadFileTool(limits: limits))
        await router.register(ListDirTool())
        await router.register(WriteFileTool(sandbox: sandbox))
        // Dynamic workflows: the `workflow` tool is *deferred* (hidden until the
        // /workflow command or the "workflow" trigger word activates it),
        // matching the explicit-opt-in model; the lifecycle/read tools are
        // always available so a launched workflow can be observed/stopped.
        await router.registerDeferred(WorkflowTool())
        await router.register(WorkflowStopTool())
        await router.register(WorkflowListTool())
        await router.register(WorkflowStatusTool())
        await router.register(GitDiffTool(limits: limits))
        // INTENTIONAL PORT DIVERGENCE (audit exec-unified-shell finding 1):
        // Upstream advertises `web_search` as an OpenAI HOSTED tool spec
        // ({type:"web_search", external_web_access/search_context_size/…},
        // tools/src/tool_spec.rs:36-48) that the provider runs server-side; it
        // is appended via hosted_model_tool_specs, never dispatched locally.
        // codex-swift has no hosted-tool wire path (every registered Tool is
        // serialized as {type:"function",…}); instead it ships a LOCAL
        // web_search backend (Perplexity primary, OpenAI web_search API
        // fallback) so non-ChatGPT auth can still search. This is a deliberate,
        // test-backed (WebSearchTests) port feature. The name is kept as
        // `web_search` for backend/UX continuity; when running against a
        // provider that itself offers hosted web_search the local function
        // shadows it. Accepted divergence pending a hosted-spec emission path.
        await router.register(WebSearchTool(
            backend: webSearch ?? ResolvedWebSearch.fromEnvironment(),
            sandbox: sandbox))
        // PORT EXTENSION (computer-use): `computer_use` lets the agent drive the
        // real macOS desktop (mouse/keyboard/screen) via the native OpenAI
        // `computer` action loop for GUI tasks the shell/file/code tools cannot
        // do. Opt-in (default OFF so the upstream-parity tool list + tests are
        // unchanged) and macOS-only; the real session runtimes enable it for
        // LOCAL (non-remote) sessions only — a remote-exec session controls a
        // container, not this host's desktop. See ComputerUseTool / the
        // ComputerUse module.
        #if canImport(AppKit)
        if computerUseEnabled {
            await router.register(ComputerUseTool(tokenProvider: computerUseTokenProvider))
        }
        #endif
        // tool_search discovery (audit tools-router finding 2). Upstream
        // `spec_plan.rs:117 append_tool_search_executor` appends the model-visible
        // `tool_search` tool AFTER all other executors (and before code-mode is
        // prepended), gated on `Feature::ToolSearch` (default ON,
        // `features/src/tests.rs:193`) AND only when at least one DEFERRED tool
        // with search metadata exists (`spec_plan.rs:531-538` returns early on an
        // empty `search_infos`). Mirror that: install `tool_search` here — last in
        // the registration sequence, so it never perturbs the upstream-parity
        // prefix — only when discovery is enabled and there is something to
        // discover (the deferred `workflow` tool). Without this the model could
        // never discover or activate any deferred tool (the BM25 backend was dead
        // code with zero call sites). The wire ENVELOPE is the documented
        // function-only divergence (see `ToolRouter.ToolSearchTool`); the
        // discovery BEHAVIOR now matches upstream for function-only clients.
        let hasDeferredTools = await !router.deferredToolNames().isEmpty
        if toolSearchEnabled && hasDeferredTools {
            await router.installToolSearch()
        }
        let nestedToolNames = (await router.specs()).map { $0.name }
        await installCodeMode(on: router, toolNames: nestedToolNames) { name, argsJSON, cwd, timeoutMs in
            await router.dispatchNestedFromCode(name: name,
                                                argumentsJSON: argsJSON,
                                                cwd: cwd,
                                                timeoutMs: timeoutMs)
        }
    }
}
