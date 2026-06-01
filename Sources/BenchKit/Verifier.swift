import Foundation

public struct VerifierOutcome: Sendable, Codable {
    public var reward: Int            // 1 iff base==0 && new==0
    public var baseExit: Int?
    public var newExit: Int?
    public var verifierExit: Int32
    public var timedOut: Bool
    public var modelPatchBytes: Int
    public var log: String            // tail of the verifier output
}

/// Reproduces deep-swe grading by running the task's **own** outer
/// `tests/test.sh` inside the container (it captures model.patch, resets
/// test-touched files, applies `test.patch`, runs `test.sh base` + `new`, and
/// writes `reward.txt`). We add the one piece Pier's harness provides
/// implicitly: pre-creating `/logs/verifier` and `/logs/artifacts` on the
/// bind-mounted host side.
public struct Verifier: Sendable {
    public let runtime: any ContainerRuntime
    public init(runtime: any ContainerRuntime) { self.runtime = runtime }

    public func run(containerId: String, hostLogsDir: URL, task: TaskSpec) async -> VerifierOutcome {
        let fm = FileManager.default
        for sub in ["verifier", "artifacts"] {
            try? fm.createDirectory(at: hostLogsDir.appendingPathComponent(sub),
                                    withIntermediateDirectories: true)
        }
        // Clear any stale git lock the agent (or an interrupted git op) may have
        // left — otherwise the verifier's `git add -A` capture step aborts with
        // "Unable to create '/app/.git/index.lock'", spuriously failing the task.
        _ = await runtime.exec(containerId, workdir: "/app", env: [:],
                               command: ["bash", "-lc", "rm -f /app/.git/index.lock"],
                               timeout: .seconds(20))
        let r = await runtime.exec(containerId, workdir: "/app", env: [:],
                                   command: ["bash", "/tests/test.sh"],
                                   timeout: .seconds(task.verifierTimeoutSec))
        let combined = r.stdout + "\n" + r.stderr
        // Persist the full verifier output next to the artifacts.
        try? Data(combined.utf8).write(to: hostLogsDir.appendingPathComponent("verifier.log"))

        let rewardTxt = hostLogsDir.appendingPathComponent("verifier/reward.txt")
        let reward = (try? String(contentsOf: rewardTxt, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first.flatMap { $0 == "1" ? 1 : 0 } ?? 0

        let patchURL = hostLogsDir.appendingPathComponent("artifacts/model.patch")
        let patchBytes = ((try? fm.attributesOfItem(atPath: patchURL.path))?[.size] as? Int) ?? 0

        return VerifierOutcome(
            reward: reward,
            baseExit: Self.parseExit(combined, label: "Baseline exit code:"),
            newExit: Self.parseExit(combined, label: "New tests exit code:"),
            verifierExit: r.exitCode,
            timedOut: r.timedOut,
            modelPatchBytes: patchBytes,
            log: String(combined.suffix(4000)))
    }

    private static func parseExit(_ text: String, label: String) -> Int? {
        guard let range = text.range(of: label) else { return nil }
        let after = text[range.upperBound...].prefix(12)
        let digits = after.drop(while: { $0 == " " }).prefix(while: { $0.isNumber || $0 == "-" })
        return Int(digits)
    }
}
