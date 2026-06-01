import Foundation

/// Code-quality dimension (our extension; never folded into Pass@1). Compares
/// the agent's diff to the held-out reference solution for *focus* (touching
/// roughly the right surface, not sprawling), gated on the deterministic
/// verifier having passed. Lint/type-check integration is a future addition.
public struct QualityScorer: Sendable {
    public init() {}

    public func score(task: TaskSpec, modelPatchPath: String,
                      verifier: VerifierOutcome) -> QualityScore {
        let model = DiffStats(path: modelPatchPath)
        let reference = DiffStats(path: task.solutionPatchPath)

        // Focus: penalize diffs that touch far more files than the reference.
        // 1.0 when ≤ reference's file count, decaying toward 0 as it balloons.
        let focus: Double
        if reference.files == 0 || model.files == 0 {
            focus = model.files == 0 ? 0 : 0.5
        } else {
            let ratio = Double(model.files) / Double(reference.files)
            focus = ratio <= 1 ? 1.0 : max(0, 1.0 - (ratio - 1.0) / 4.0)
        }

        // Gate on reward: an unresolved task has no meaningful quality score.
        let base = verifier.reward == 1 ? 1.0 : 0.0
        let composite = verifier.reward == 1 ? (0.7 + 0.3 * focus) : 0.0

        return QualityScore(
            score: composite,
            filesTouched: model.files,
            referenceFilesTouched: reference.files,
            linesChanged: model.added + model.removed,
            cleanliness: base,
            notes: "focus=\(String(format: "%.2f", focus)) (model \(model.files) files vs reference \(reference.files))")
    }
}

/// Minimal unified-diff statistics from a `git diff` patch file.
struct DiffStats {
    var files = 0
    var added = 0
    var removed = 0

    init(path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var seen = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                let parts = line.split(separator: " ")
                if parts.count >= 4 { seen.insert(String(parts[3])) }   // b/<file>
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                removed += 1
            }
        }
        files = seen.count
    }
}
