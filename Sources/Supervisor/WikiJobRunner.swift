import Foundation

/// Spawns the `codex-memory` CLI as a child process for long-running wiki jobs
/// (ingest / research) and streams its `--progress` NDJSON stdout line-by-line, so
/// codexd can forward each line as a `wiki/job/event` / `wiki/job/done` WS
/// notification without itself depending on the heavy WikiResearch/WikiIngest +
/// inference assembly. The child inherits codexd's environment (OPENAI_API_KEY,
/// CODEX_MEMORY_* …) so research/ingest work exactly as the CLI does.
/// One-bit flag tracking whether a job emitted a terminal `type=result` line, so a
/// crashed child (no result) still gets a synthetic terminal `wiki/job/done`.
actor WikiJobFlag {
    private(set) var value = false
    func mark() { value = true }
}

public enum WikiJobRunner {
    /// Resolve the `codex-memory` binary: `CODEX_MEMORY_BIN` override, else next to
    /// the running codexd executable (the dev + installed layout co-locate them).
    public static func codexMemoryPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["CODEX_MEMORY_BIN"], !p.isEmpty { return p }
        let selfPath = CommandLine.arguments.first ?? "codexd"
        let dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
        return dir.appendingPathComponent("codex-memory").path
    }

    /// Run `codex-memory <args>` (the default executable), calling `onLine` for each
    /// stdout line as it arrives. Returns the exit code, or nil on spawn failure.
    public static func stream(args: [String],
                              onLine: @escaping @Sendable (String) async -> Void) async -> Int32? {
        await stream(executable: codexMemoryPath(), args: args, onLine: onLine)
    }

    /// Testable core: run an explicit `executable` with `args`, streaming each
    /// stdout line to `onLine`. Returns the exit code, or nil on spawn failure.
    public static func stream(executable path: String, args: [String],
                              onLine: @escaping @Sendable (String) async -> Void) async -> Int32? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { await onLine(trimmed) }
            }
        } catch { /* read error → fall through and reap */ }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
