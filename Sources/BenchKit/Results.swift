import Foundation

public enum AgentMode: String, Sendable, Codable {
    case agent       // codex-swift solves the task
    case reference   // apply solution.patch (harness self-test → expect reward 1)
    case empty       // no changes (harness self-test → expect reward 0)
}

public enum TaskStatus: String, Sendable, Codable {
    case passed, failed, error, timeout, skipped
}

/// Per-task agent run telemetry (populated for `.agent` mode).
public struct AgentRunInfo: Sendable, Codable {
    public var model: String
    public var turns: Int
    public var continuationRetries: Int   // empty-diff "keep going" nudges used
    public var inputTokens: Int
    public var cachedInputTokens: Int   // billed at the discounted cache rate
    public var outputTokens: Int
    public var totalTokens: Int
    public var costUSD: Double
    public var agentWallSec: Double
    public var diffBytes: Int
    public var completed: Bool       // turn reached completion vs timed out/interrupted
    public init(model: String, turns: Int = 0, continuationRetries: Int = 0, inputTokens: Int = 0,
                cachedInputTokens: Int = 0, outputTokens: Int = 0, totalTokens: Int = 0,
                costUSD: Double = 0, agentWallSec: Double = 0, diffBytes: Int = 0, completed: Bool = false) {
        self.model = model; self.turns = turns; self.continuationRetries = continuationRetries
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens; self.totalTokens = totalTokens; self.costUSD = costUSD
        self.agentWallSec = agentWallSec; self.diffBytes = diffBytes; self.completed = completed
    }
}

public struct QualityScore: Sendable, Codable {
    public var score: Double             // [0,1], gated on reward==1
    public var filesTouched: Int
    public var referenceFilesTouched: Int
    public var linesChanged: Int
    public var cleanliness: Double        // fraction of lint/format/typecheck checks that passed
    public var notes: String
}

public struct JudgeVerdict: Sendable, Codable {
    public var outcome: String            // "pass"/"fail"
    public var agreesWithVerifier: Bool
    public var failureMode: String
    public var rationale: String
    public var model: String
}

public struct TaskResult: Sendable, Codable {
    public var taskId: String
    public var attempt: Int = 1
    public var extId: String
    public var language: BenchLanguage
    public var category: BenchCategory
    public var mode: AgentMode
    public var status: TaskStatus
    public var reward: Int
    public var verifier: VerifierOutcome?
    public var agent: AgentRunInfo?
    public var quality: QualityScore?
    public var judge: JudgeVerdict?
    public var wallTimeSec: Double
    public var error: String?
}

public struct RunConfig: Sendable, Codable {
    public var runId: String
    public var mode: AgentMode
    public var model: String
    public var arch: String
    public var runtimeName: String
    public var concurrency: Int
    public var attempts: Int
    public var judge: Bool
    public var quality: Bool
    public var effort: String            // reasoning effort (low/medium/high/xhigh)
    public var seed: UInt64?
    public var selectedTaskIds: [String]
    public var startedAt: String         // ISO-8601 (stamped by caller)
    public var codexSwiftGitSHA: String

    public init(runId: String, mode: AgentMode, model: String, arch: String,
                runtimeName: String, concurrency: Int, attempts: Int, judge: Bool,
                quality: Bool, effort: String = "high", seed: UInt64?, selectedTaskIds: [String],
                startedAt: String, codexSwiftGitSHA: String) {
        self.runId = runId; self.mode = mode; self.model = model; self.arch = arch
        self.runtimeName = runtimeName; self.concurrency = concurrency; self.attempts = attempts
        self.judge = judge; self.quality = quality; self.effort = effort; self.seed = seed
        self.selectedTaskIds = selectedTaskIds; self.startedAt = startedAt
        self.codexSwiftGitSHA = codexSwiftGitSHA
    }
}

public struct RunResult: Sendable, Codable {
    public var config: RunConfig
    public var tasks: [TaskResult]
    public var score: ScoreSummary
    public var caveat: String
}
