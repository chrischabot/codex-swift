import Foundation

// MARK: - Constants (port of the load-bearing numbers from the Claude feature)

/// Every constant here is faithful to the Claude Code "Dynamic Workflows"
/// feature (env-var names transformed `CLAUDE_CODE_*` → `CODEX_*`). See
/// docs/workflows/PORT_DESIGN.md §10 for the mapping table.
public enum WF {
    public static let agentCap = 1000                    // o7K
    public static let maxStallRetries = 5                // i7K
    public static let defaultStallMs = 180_000           // AG3
    public static let throttleSleepMs = 45_000           // throttle backoff
    public static let throttleMinOutputTokens = 50       // throttle heuristic
    public static let maxLogs = 1000                     // jG3
    public static let logRetentionFloor = 500            // F9K
    public static let maxScriptBytes = 524_288           // fC
    public static let previewLen = 400                   // n7K
    public static let progressDebounceMs = 16            // C
    public static let schemaNudges = 2                   // schema-mode nudges
    public static let runDeadlineSecs = 3600             // outer abort-based deadline
    public static let labelPreviewLen = 60
    public static let cacheKeyPrefix = "v2:"
    public static let runIdRegex = "^wf_[a-z0-9-]{6,}$"

    /// Local subagent concurrency: `min(16, max(2, cores-2))` (_G3).
    public static var concurrency: Int {
        Swift.min(16, Swift.max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    public static func agentCapMessage() -> String {
        "Workflow agent() call cap reached (\(agentCap)). Add a hard iteration cap or pass a token budget."
    }
    public static func budgetCapMessage(spent: Int, total: Int) -> String {
        "Workflow token budget exceeded (\(spent)/\(total) output tokens). Stopping further agent() calls; in-flight agents complete."
    }
}

// MARK: - agent() options

/// Parsed form of the JS `opts` object passed to `agent(prompt, opts)`.
public struct AgentOpts: Sendable, Equatable {
    public var label: String?
    public var phase: String?
    /// Raw JSON-Schema object string (the `schema` field), or nil.
    public var schemaJSON: String?
    public var model: String?
    public var isolation: String?       // "worktree" | "remote"
    public var agentType: String?
    public var stallMs: Int?

    public init(label: String? = nil, phase: String? = nil, schemaJSON: String? = nil,
                model: String? = nil, isolation: String? = nil,
                agentType: String? = nil, stallMs: Int? = nil) {
        self.label = label; self.phase = phase; self.schemaJSON = schemaJSON
        self.model = model; self.isolation = isolation; self.agentType = agentType
        self.stallMs = stallMs
    }

    /// Parse from a `[String: Any]` decoded from the JS opts object.
    public static func parse(_ dict: [String: Any]) -> AgentOpts {
        var o = AgentOpts()
        o.label = dict["label"] as? String
        o.phase = dict["phase"] as? String
        o.model = dict["model"] as? String
        o.isolation = dict["isolation"] as? String
        o.agentType = dict["agentType"] as? String
        if let s = dict["stallMs"] as? Int { o.stallMs = s }
        else if let d = dict["stallMs"] as? Double { o.stallMs = Int(d) }
        if let schema = dict["schema"] {
            // Re-serialize the schema object so we can both forward it to the
            // subagent tool and feed it into the cache key.
            if let data = try? JSONSerialization.data(withJSONObject: schema,
                                                      options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                o.schemaJSON = s
            }
        }
        return o
    }
}

// MARK: - Subagent spec & outcome

public struct WorkflowAgentSpec: Sendable {
    public var index: Int
    public var prompt: String
    public var opts: AgentOpts
    public var label: String
    public var phaseTitle: String
    public var phaseIndex: Int
    public var stallMs: Int
    public var cacheKey: String?
    public var defaultModel: String?
    public var cwd: String
    public var runId: String

    public init(index: Int, prompt: String, opts: AgentOpts, label: String,
                phaseTitle: String, phaseIndex: Int, stallMs: Int,
                cacheKey: String?, defaultModel: String?, cwd: String, runId: String) {
        self.index = index; self.prompt = prompt; self.opts = opts
        self.label = label; self.phaseTitle = phaseTitle; self.phaseIndex = phaseIndex
        self.stallMs = stallMs; self.cacheKey = cacheKey
        self.defaultModel = defaultModel; self.cwd = cwd; self.runId = runId
    }
}

/// Result of running one subagent. Mirrors the discrimination Claude's runner
/// returns: skipped → `null`, structured/text value, or a terminal throw.
public struct WorkflowAgentOutcome: Sendable {
    public enum Kind: Sendable, Equatable { case value, null, thrown }
    public var kind: Kind
    /// For `.value`: a JSON value string (object for schema mode, JSON-string
    /// for plain text). For `.thrown`: the error message.
    public var payloadJSON: String
    public var tokens: Int
    public var toolCalls: Int
    public var durationMs: Int
    public var attempts: Int

    public init(kind: Kind, payloadJSON: String, tokens: Int = 0, toolCalls: Int = 0,
                durationMs: Int = 0, attempts: Int = 1) {
        self.kind = kind; self.payloadJSON = payloadJSON; self.tokens = tokens
        self.toolCalls = toolCalls; self.durationMs = durationMs; self.attempts = attempts
    }

    public static func value(_ jsonString: String, tokens: Int = 0, toolCalls: Int = 0,
                             durationMs: Int = 0, attempts: Int = 1) -> WorkflowAgentOutcome {
        WorkflowAgentOutcome(kind: .value, payloadJSON: jsonString, tokens: tokens,
                             toolCalls: toolCalls, durationMs: durationMs, attempts: attempts)
    }
    public static func skipped() -> WorkflowAgentOutcome {
        WorkflowAgentOutcome(kind: .null, payloadJSON: "null")
    }
    public static func failure(_ message: String) -> WorkflowAgentOutcome {
        WorkflowAgentOutcome(kind: .thrown, payloadJSON: message)
    }
}

// MARK: - Workflow definition (discovery + registry)

public struct WorkflowDef: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case builtIn = "built-in"
        case admin
        case userSettings
        case projectSettings
    }
    public struct Phase: Sendable, Equatable {
        public var title: String
        public var detail: String?
        public var model: String?
        public init(title: String, detail: String? = nil, model: String? = nil) {
            self.title = title; self.detail = detail; self.model = model
        }
    }
    public var source: Source
    public var name: String
    public var description: String
    public var whenToUse: String?
    public var phases: [Phase]
    public var script: String
    public var filePath: String?

    public init(source: Source, name: String, description: String,
                whenToUse: String? = nil, phases: [Phase] = [],
                script: String, filePath: String? = nil) {
        self.source = source; self.name = name; self.description = description
        self.whenToUse = whenToUse; self.phases = phases; self.script = script
        self.filePath = filePath
    }
}

// MARK: - Journal

public enum JournalEntry: Sendable, Equatable {
    case started(key: String, agentId: Int)
    case result(key: String, agentId: Int, resultJSON: String)
}

public struct JournalIndex: Sendable {
    /// Last-wins result per cache key (the cached value, as a JSON string).
    public var results: [String: String]
    /// All `started` entries per key.
    public var started: [String: [Int]]
    public init(results: [String: String] = [:], started: [String: [Int]] = [:]) {
        self.results = results; self.started = started
    }
}

// MARK: - Progress events

public enum WorkflowProgress: Sendable {
    public enum AgentState: String, Sendable { case start, progress, done, error }
    case log(message: String)
    case phase(index: Int, title: String, kind: String?)
    case agent(index: Int, label: String, phaseIndex: Int, phaseTitle: String,
               state: AgentState, cached: Bool, skipped: Bool, error: String?,
               tokens: Int, toolCalls: Int, durationMs: Int, model: String?,
               attempt: Int, promptPreview: String)
}

// MARK: - Run result

public struct WorkflowRunResult: Sendable {
    public enum Status: String, Sendable { case completed, failed, killed }
    public var status: Status
    /// The workflow's JS return value, JSON-serialized (or nil).
    public var resultJSON: String?
    public var agentCount: Int
    public var logs: [String]
    public var failures: [String]
    public var durationMs: Int
    public var error: String?
    public var totalTokens: Int
    public var totalToolCalls: Int

    public init(status: Status, resultJSON: String?, agentCount: Int, logs: [String],
                failures: [String], durationMs: Int, error: String?,
                totalTokens: Int, totalToolCalls: Int) {
        self.status = status; self.resultJSON = resultJSON; self.agentCount = agentCount
        self.logs = logs; self.failures = failures; self.durationMs = durationMs
        self.error = error; self.totalTokens = totalTokens; self.totalToolCalls = totalToolCalls
    }
}

// MARK: - Shared run scope (concurrency / budget / agent-cap pool)

/// State shared across a workflow run *and all of its nested `workflow()`
/// children*: one concurrency semaphore, one token-budget pool + ceiling, and
/// one agent-count cap. A top-level run creates its own scope; a nested run
/// inherits the parent's, so `min(16,cores-2)` concurrency, the 1000-agent
/// runaway backstop, and the token budget are enforced across the whole tree
/// rather than reset per child (WORKFLOW.md: "The child shares this run's
/// concurrency cap, agent counter, abort signal, and token budget").
public final class WorkflowRunScope: @unchecked Sendable {
    /// Shared subagent concurrency limiter.
    let concurrency: WorkflowSemaphore
    /// The token ceiling (`null`/`nil` ⇒ no limit ⇒ `remaining()` is Infinity).
    public let budgetTotal: Int?

    private let lock = NSLock()
    private var _spent = 0
    private var _toolCalls = 0
    private var _agentStarts = 0

    public init(budgetTotal: Int?, concurrencyLimit: Int = WF.concurrency) {
        self.budgetTotal = budgetTotal
        self.concurrency = WorkflowSemaphore(concurrencyLimit)
    }

    func addSpend(tokens: Int, toolCalls: Int) {
        lock.lock(); _spent += tokens; _toolCalls += toolCalls; lock.unlock()
    }
    var spent: Int { lock.lock(); defer { lock.unlock() }; return _spent }
    var toolCalls: Int { lock.lock(); defer { lock.unlock() }; return _toolCalls }
    /// Atomically claim the next agent ordinal (used for both the display index
    /// and the runaway-cap check). Returns the 1-based ordinal.
    func nextAgentOrdinal() -> Int { lock.lock(); defer { lock.unlock() }; _agentStarts += 1; return _agentStarts }
    var agentCount: Int { lock.lock(); defer { lock.unlock() }; return _agentStarts }
}

// MARK: - Abort flag

/// Thread-safe abort latch shared between the orchestrator (`stop`) and the
/// engine pump / subagent runner.
public final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func set() { lock.lock(); flag = true; lock.unlock() }
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

// MARK: - Pulse (async signal for the engine pump)

/// A simple edge-triggered async signal: `wait()` suspends until the next
/// (or an already-pending) `poke()`. Used by the engine pump to wake when a
/// subagent resolves a promise.
public actor Pulse {
    private var pending = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func poke() {
        if waiters.isEmpty { pending = true; return }
        let ws = waiters; waiters.removeAll()
        for w in ws { w.resume() }
    }
    public func wait() async {
        if pending { pending = false; return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
