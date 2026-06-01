import Foundation

/// In-process bridge between the model-facing workflow tool surface
/// (`workflow`, `workflow_stop`, `workflow_list`, `workflow_status`) and the
/// host-side `WorkflowOrchestrator` (in the `Workflows` module). Mirrors the
/// `MultiAgentBus` seam 1:1: the value-type tools delegate to whichever
/// providers the host installs on `WorkflowBus.shared`; if none are installed
/// the tools fail with a structured "not configured" error rather than
/// silently succeeding.
///
/// This is the faithful analog of Claude Code's `WorkflowTool.call` →
/// `runWorkflow` detached launch: `launch` registers a detached run and
/// returns immediately with `{runId, taskId, status:"async_launched"}`.
public actor WorkflowBus {
    public static let shared = WorkflowBus()

    /// Request to launch (or resume) a workflow run. Exactly one of
    /// `script`/`name`/`scriptPath` should be set (validated host-side).
    public struct LaunchRequest: Sendable {
        public var script: String?
        public var name: String?
        public var scriptPath: String?
        /// The `args` global, passed verbatim as a JSON value string
        /// (e.g. `"\"question\""`, `"[1,2]"`, `"{...}"`, or `nil`).
        public var argsJSON: String?
        public var resumeFromRunId: String?
        public var cwd: String
        /// Output-token ceiling for `budget` (the codex analog of the turn's
        /// `+500k` directive). `nil` ⇒ no limit ⇒ `budget.remaining()` Infinity.
        /// Shared across the run and all nested `workflow()` children.
        public var budget: Int?
        public init(script: String? = nil, name: String? = nil,
                    scriptPath: String? = nil, argsJSON: String? = nil,
                    resumeFromRunId: String? = nil, cwd: String, budget: Int? = nil) {
            self.script = script; self.name = name; self.scriptPath = scriptPath
            self.argsJSON = argsJSON; self.resumeFromRunId = resumeFromRunId
            self.cwd = cwd; self.budget = budget
        }
    }

    public struct LaunchResponse: Sendable {
        public var runId: String
        public var taskId: String
        public var status: String        // "async_launched"
        public var summary: String?
        public var transcriptDir: String?
        public var scriptPath: String?
        public init(runId: String, taskId: String, status: String = "async_launched",
                    summary: String? = nil, transcriptDir: String? = nil,
                    scriptPath: String? = nil) {
            self.runId = runId; self.taskId = taskId; self.status = status
            self.summary = summary; self.transcriptDir = transcriptDir
            self.scriptPath = scriptPath
        }
    }

    /// Result of `validateInput` (port of the 6-code validation ladder).
    public struct Validation: Sendable, Equatable {
        public var ok: Bool
        public var errorCode: Int?
        public var message: String?
        public init(ok: Bool, errorCode: Int? = nil, message: String? = nil) {
            self.ok = ok; self.errorCode = errorCode; self.message = message
        }
        public static let valid = Validation(ok: true)
    }

    public enum WorkflowError: Error, Sendable, Equatable {
        case unconfigured
        case launchFailed(String)
    }

    public typealias ValidateProvider = @Sendable (LaunchRequest) async -> Validation
    public typealias LaunchProvider = @Sendable (LaunchRequest) async throws -> LaunchResponse
    public typealias StopProvider = @Sendable (_ idOrRunId: String) async -> String
    public typealias ListProvider = @Sendable () async -> String
    public typealias StatusProvider = @Sendable (_ runId: String) async -> String

    private var validateProvider: ValidateProvider?
    private var launchProvider: LaunchProvider?
    private var stopProvider: StopProvider?
    private var listProvider: ListProvider?
    private var statusProvider: StatusProvider?

    public init() {}

    public func installValidate(_ p: @escaping ValidateProvider) { validateProvider = p }
    public func installLaunch(_ p: @escaping LaunchProvider) { launchProvider = p }
    public func installStop(_ p: @escaping StopProvider) { stopProvider = p }
    public func installList(_ p: @escaping ListProvider) { listProvider = p }
    public func installStatus(_ p: @escaping StatusProvider) { statusProvider = p }

    public func clearAll() {
        validateProvider = nil; launchProvider = nil; stopProvider = nil
        listProvider = nil; statusProvider = nil
    }

    public var isConfigured: Bool { launchProvider != nil }

    public func validate(_ req: LaunchRequest) async -> Validation {
        guard let p = validateProvider else {
            return Validation(ok: false, errorCode: 6,
                              message: "workflow: orchestrator not configured")
        }
        return await p(req)
    }

    public func launch(_ req: LaunchRequest) async throws -> LaunchResponse {
        guard let p = launchProvider else { throw WorkflowError.unconfigured }
        return try await p(req)
    }

    public func stop(_ idOrRunId: String) async -> String {
        guard let p = stopProvider else { return "workflow: orchestrator not configured" }
        return await p(idOrRunId)
    }

    public func list() async -> String {
        guard let p = listProvider else { return "workflow: orchestrator not configured" }
        return await p()
    }

    public func status(_ runId: String) async -> String {
        guard let p = statusProvider else { return "workflow: orchestrator not configured" }
        return await p(runId)
    }
}
