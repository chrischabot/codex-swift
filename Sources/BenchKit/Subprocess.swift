import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var ok: Bool { exitCode == 0 && !timedOut }
}

/// Minimal async wrapper over `Foundation.Process`. stdout/stderr are redirected
/// to temp files (not pipes) so large, chatty test-suite output can never
/// deadlock on a full pipe buffer. Supports cwd/env/stdin and a hard timeout
/// (SIGTERM, then SIGKILL after a short grace).
public enum Subprocess {
    public static func run(_ executable: String,
                           _ args: [String],
                           cwd: String? = nil,
                           env: [String: String]? = nil,
                           stdin: String? = nil,
                           timeout: Duration? = nil) async -> ProcessResult {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("benchproc-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let outURL = scratch.appendingPathComponent("out")
        let errURL = scratch.appendingPathComponent("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { proc.environment = env }
        proc.standardOutput = try? FileHandle(forWritingTo: outURL)
        proc.standardError = try? FileHandle(forWritingTo: errURL)
        if let stdin {
            let inURL = scratch.appendingPathComponent("in")
            try? Data(stdin.utf8).write(to: inURL)
            proc.standardInput = try? FileHandle(forReadingFrom: inURL)
        }

        let timedOut = TimedOutFlag()
        let done = AsyncSemaphore()
        proc.terminationHandler = { _ in Task { await done.signal() } }

        do {
            try proc.run()
        } catch {
            return ProcessResult(exitCode: 127, stdout: "",
                                 stderr: "spawn failed: \(error)", timedOut: false)
        }

        let killer: Task<Void, Never>? = timeout.map { t in
            Task {
                try? await Task.sleep(for: t)
                if proc.isRunning {
                    await timedOut.set()
                    proc.terminate()                       // SIGTERM
                    try? await Task.sleep(for: .seconds(3))
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
            }
        }

        await done.wait()
        killer?.cancel()

        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return ProcessResult(exitCode: proc.terminationStatus,
                             stdout: out, stderr: err,
                             timedOut: await timedOut.value)
    }
}

private actor TimedOutFlag {
    private(set) var value = false
    func set() { value = true }
}

/// A one-shot async semaphore used to await process termination.
private actor AsyncSemaphore {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        signaled = true
        let w = waiters; waiters.removeAll()
        for c in w { c.resume() }
    }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
