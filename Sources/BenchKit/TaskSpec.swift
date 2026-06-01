import Foundation

/// A programming language covered by the deep-swe suite.
public enum BenchLanguage: String, Sendable, Codable, CaseIterable {
    case typescript, javascript, python, go, rust

    /// Best-effort normalization from the manifest/task.toml string.
    public init?(loose raw: String) {
        switch raw.lowercased() {
        case "typescript", "ts": self = .typescript
        case "javascript", "js": self = .javascript
        case "python", "py": self = .python
        case "go", "golang": self = .go
        case "rust", "rs": self = .rust
        default: return nil
        }
    }
}

/// A task category as declared by deep-swe.
public enum BenchCategory: String, Sendable, Codable {
    case featureRequest = "feature_request"
    case enhancement
    case bugfix
    case other

    public init(loose raw: String) {
        self = BenchCategory(rawValue: raw) ?? .other
    }
}

/// A single normalized deep-swe task: the union of `manifest.json` and the
/// per-task `task.toml`, plus resolved on-disk artifact paths. This is the
/// internal representation the rest of the runner consumes — callers never
/// touch the raw TOML/JSON again.
public struct TaskSpec: Sendable, Codable, Identifiable {
    // Identity / metadata
    public var id: String              // task_id (= directory name)
    public var extId: String           // ext_id (= prebuilt image tag)
    public var displayTitle: String
    public var displayDescription: String
    public var originalTitle: String
    public var category: BenchCategory
    public var language: BenchLanguage
    public var repo: String            // "owner/name" (from manifest)
    public var repositoryURL: String
    public var baseCommitHash: String

    // Resource / timeout envelope (from task.toml)
    public var verifierTimeoutSec: Double
    public var agentTimeoutSec: Double
    public var buildTimeoutSec: Double
    public var allowInternet: Bool
    public var cpus: Int
    public var memoryMB: Int
    public var storageMB: Int
    public var prebuiltImage: String   // public ECR amd64 image (fallback only)

    // On-disk artifact paths (absolute)
    public var taskDir: String
    public var instructionPath: String
    public var dockerfilePath: String
    public var testShPath: String      // outer verifier
    public var testPatchPath: String   // hidden tests
    public var solutionPatchPath: String
    public var solveShPath: String

    public var instruction: String {
        (try? String(contentsOfFile: instructionPath, encoding: .utf8)) ?? ""
    }
}
