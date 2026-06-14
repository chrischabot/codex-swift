import Foundation

/// Result of a child-process run (exit code + captured stdout/stderr).
public struct PGProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

/// Run a child process off the cooperative pool (on a detached thread) so the
/// blocking pipe reads never stall an actor's executor. Shared by
/// `PostgresLifecycle` and the test harness so the spawn/capture logic lives in
/// one place.
///
/// Caller note: ensure ongoing process output goes to a logfile (not the pipes)
/// — the captured pipes are read sequentially after exit, so they must stay under
/// the ~64 KB pipe buffer to avoid a deadlock.
public func runPGProcess(_ launchPath: String, _ args: [String]) async throws -> PGProcessResult {
    try await Task.detached(priority: .utility) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return PGProcessResult(exitCode: p.terminationStatus,
                               stdout: String(decoding: o, as: UTF8.self),
                               stderr: String(decoding: e, as: UTF8.self))
    }.value
}
