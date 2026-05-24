import Foundation

/// Lifecycle supervisor for the host-wide `codex-memory` child. One process
/// per host (the memory wiki is global, not per-Codex-session). Mirrors the
/// shape of the `codex-broker` supervision pattern: spawn on boot, log
/// stdout/stderr, restart with exponential backoff on crash, terminate
/// cleanly on daemon shutdown.
///
/// IPC is intentionally *not* wired: `codex-memory` exposes its tools via the
/// existing MCP HTTP server, which the model reaches directly through the
/// harness MCP proxy. codexd's only contract with the child is lifecycle.
public actor MemorySupervisor {
    public struct Config: Sendable {
        public var binaryPath: String
        public var args: [String]
        public var enabled: Bool
        public var maxBackoffSeconds: Double
        public init(binaryPath: String,
                    args: [String] = ["run"],
                    enabled: Bool = true,
                    maxBackoffSeconds: Double = 60) {
            self.binaryPath = binaryPath
            self.args = args
            self.enabled = enabled
            self.maxBackoffSeconds = maxBackoffSeconds
        }
    }

    public enum State: Sendable, Equatable {
        case stopped
        case running(pid: Int32, since: Date)
        case waiting(nextAttempt: Date)
        case disabled
    }

    public private(set) var state: State = .stopped
    private let config: Config
    private var process: Process?
    private var supervisorTask: Task<Void, Never>?
    /// Set to true by `stop()` so the supervisor loop doesn't race ahead and
    /// spawn a fresh child after cancellation. The loop checks this flag at
    /// every iteration boundary in addition to `Task.isCancelled`.
    private var stopping: Bool = false

    public init(config: Config) {
        self.config = config
        if !config.enabled {
            state = .disabled
        }
    }

    public func start() {
        guard config.enabled else { return }
        guard supervisorTask == nil else { return }
        let cfg = config
        supervisorTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled, await self?.shouldKeepRunning() == true {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: cfg.binaryPath)
                p.arguments = cfg.args
                // Inherit stdout/stderr so the daemon's log captures both
                // streams. A future revision can plumb a Pipe through
                // Observability if structured forwarding becomes desirable.
                p.standardOutput = FileHandle.standardOutput
                p.standardError = FileHandle.standardError
                // Termination handler signals an actor-local continuation so
                // the supervisor never has to call the blocking
                // `Process.waitUntilExit()` (which would peg a cooperative
                // thread for the entire child lifetime).
                let exitBox = ExitLatch()
                p.terminationHandler = { proc in
                    Task { await exitBox.signal(proc.terminationStatus) }
                }
                do {
                    try p.run()
                } catch {
                    await self?.setState(.waiting(nextAttempt: Date().addingTimeInterval(2)))
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                await self?.setRunning(pid: p.processIdentifier)
                await self?.holdProcess(p)
                _ = await exitBox.wait()
                guard !Task.isCancelled else { break }
                // Restart with capped exponential backoff.
                attempt = Swift.min(attempt + 1, 8)
                let delay = Swift.min(cfg.maxBackoffSeconds, pow(2.0, Double(attempt)))
                await self?.setState(.waiting(nextAttempt: Date().addingTimeInterval(delay)))
                try? await Task.sleep(for: .seconds(delay))
            }
            await self?.setState(.stopped)
        }
    }

    public func stop() async {
        // Flip the stopping flag first so the supervisor loop won't spawn a
        // fresh child if it's in a backoff window when we cancel.
        stopping = true
        let task = supervisorTask
        supervisorTask = nil
        task?.cancel()
        // Send SIGTERM to the currently-held child (if any), wait briefly
        // for graceful exit, then SIGKILL. We do this BEFORE awaiting the
        // task value so its `_ = await exitBox.wait()` can resolve.
        if let p = process, p.isRunning {
            p.terminate()
            try? await Task.sleep(for: .seconds(1))
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        // Wait for the supervisor task to fully unwind — this is the only
        // guarantee that no orphan Process is still scheduling itself.
        _ = await task?.value
        process = nil
        state = .stopped
    }

    /// Loop predicate: cooperate with `stop()` so a cancellation right after
    /// a backoff sleep doesn't re-spawn a fresh child.
    private func shouldKeepRunning() -> Bool { !stopping }

    public func current() -> State { state }

    // MARK: - private

    private func setState(_ next: State) { state = next }
    private func setRunning(pid: Int32) {
        state = .running(pid: pid, since: Date())
    }
    private func holdProcess(_ p: Process) {
        self.process = p
    }
}

/// One-shot async barrier signaled by a `Process.terminationHandler`. Holds
/// the exit status until a waiter arrives; the waiter parks on a
/// continuation that the signal callback resumes — never the blocking
/// `Process.waitUntilExit()`.
actor ExitLatch {
    private var status: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func signal(_ status: Int32) {
        if let w = waiter {
            waiter = nil
            w.resume(returning: status)
        } else {
            self.status = status
        }
    }

    func wait() async -> Int32 {
        if let s = status { return s }
        return await withCheckedContinuation { c in
            self.waiter = c
        }
    }
}

/// Convenience: derive a default `Config` by locating `codex-memory` next to
/// the running `codexd` binary. Falls back to `PATH` resolution and finally
/// the SwiftPM build path so dev runs work out of the box.
public extension MemorySupervisor.Config {
    static func bootstrap(enabled: Bool = false) -> MemorySupervisor.Config {
        let path = locateBinary() ?? "/usr/local/bin/codex-memory"
        return MemorySupervisor.Config(binaryPath: path, enabled: enabled)
    }

    private static func locateBinary() -> String? {
        // 1. Sibling of the current executable.
        let argv0 = CommandLine.arguments.first
            ?? ProcessInfo.processInfo.arguments.first ?? ""
        let dir = (argv0 as NSString).deletingLastPathComponent
        let sibling = dir + "/codex-memory"
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }
        // 2. SwiftPM debug build path during local dev.
        let cwd = FileManager.default.currentDirectoryPath
        let debug = cwd + "/.build/debug/codex-memory"
        if FileManager.default.isExecutableFile(atPath: debug) {
            return debug
        }
        return nil
    }
}
