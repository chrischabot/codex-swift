import Foundation

/// In-process bridge between the multi-agent tool surface
/// (`spawn_agent`, `wait_agent`, `close_agent`, `send_input`, `resume_agent`)
/// and the host-side orchestrator (`HarnessCore.AgentOrchestrator`). Upstream
/// parity (H-19 / P3.5; `codex-rs/core/src/tools/handlers/multi_agents`).
///
/// Wire model: the tools delegate every request to whichever provider the host
/// has installed on `MultiAgentBus.shared`; if no provider is installed the
/// tools fail with a structured error so the model gets actionable feedback
/// rather than silently succeeding. The bus shape matches the upstream handler
/// surface 1:1, returning the JSON payloads that the tools then wrap as the
/// upstream output schema (e.g. `{agent_id, nickname}` for `spawn_agent`).
///
/// Concurrency: `MultiAgentBus` is an actor, so install/unset/dispatch races
/// are deterministic. Providers are `@Sendable` closures so the host can wire
/// them up to its own actor-bound `AgentOrchestrator` without leaking that
/// actor's isolation into the tool layer.
public actor MultiAgentBus {
    public static let shared = MultiAgentBus()

    /// Upstream parity (`AgentStatus` in `codex-rs/protocol/src/protocol.rs`).
    /// `completed(_)` carries an optional final assistant message; `errored(_)`
    /// carries a required error string. Other variants are unit cases. JSON
    /// rendering matches the upstream `oneOf` schema:
    ///   * Unit cases → bare string (`"running"`, `"shutdown"`, …)
    ///   * `completed` → `{"completed": <string|null>}`
    ///   * `errored`   → `{"errored": <string>}`
    public enum AgentStatus: Sendable, Equatable {
        case pendingInit
        case running
        case interrupted
        case completed(String?)
        case errored(String)
        case shutdown
        case notFound

        /// Render as the upstream JSON-compatible value (string or object).
        public func jsonValue() -> Any {
            switch self {
            case .pendingInit: return "pending_init"
            case .running: return "running"
            case .interrupted: return "interrupted"
            case .shutdown: return "shutdown"
            case .notFound: return "not_found"
            case .completed(let s):
                return ["completed": s as Any? ?? NSNull()]
            case .errored(let s):
                return ["errored": s]
            }
        }
    }

    public struct SpawnRequest: Sendable {
        public var message: String?
        public var agentType: String?
        public var model: String?
        public var reasoningEffort: String?
        public var serviceTier: String?
        public var forkContext: Bool
        public var rawArgsJSON: String
        public init(message: String?, agentType: String?, model: String?,
                    reasoningEffort: String?, serviceTier: String?,
                    forkContext: Bool, rawArgsJSON: String) {
            self.message = message; self.agentType = agentType
            self.model = model; self.reasoningEffort = reasoningEffort
            self.serviceTier = serviceTier; self.forkContext = forkContext
            self.rawArgsJSON = rawArgsJSON
        }
    }

    public struct SpawnResponse: Sendable {
        public var agentId: String
        public var nickname: String?
        public init(agentId: String, nickname: String? = nil) {
            self.agentId = agentId; self.nickname = nickname
        }
    }

    public struct SendInputRequest: Sendable {
        public var target: String
        public var message: String?
        public var interrupt: Bool
        public var rawArgsJSON: String
        public init(target: String, message: String?, interrupt: Bool,
                    rawArgsJSON: String) {
            self.target = target; self.message = message
            self.interrupt = interrupt; self.rawArgsJSON = rawArgsJSON
        }
    }

    public struct WaitRequest: Sendable {
        public var targets: [String]
        public var timeoutMs: Int64
        public init(targets: [String], timeoutMs: Int64) {
            self.targets = targets; self.timeoutMs = timeoutMs
        }
    }

    public struct WaitResponse: Sendable {
        public var statusByAgent: [(String, AgentStatus)]
        public var timedOut: Bool
        public init(statusByAgent: [(String, AgentStatus)], timedOut: Bool) {
            self.statusByAgent = statusByAgent; self.timedOut = timedOut
        }
    }

    public enum MultiAgentError: Error, Sendable, Equatable {
        case unconfigured
        case invalidArguments(String)
        case agentNotFound(String)
        case other(String)
    }

    public typealias SpawnProvider = @Sendable (SpawnRequest) async throws -> SpawnResponse
    public typealias WaitProvider = @Sendable (WaitRequest) async throws -> WaitResponse
    public typealias CloseProvider = @Sendable (_ target: String) async throws -> AgentStatus
    public typealias SendInputProvider = @Sendable (SendInputRequest) async throws -> String
    public typealias ResumeProvider = @Sendable (_ id: String) async throws -> AgentStatus

    private var spawnProvider: SpawnProvider?
    private var waitProvider: WaitProvider?
    private var closeProvider: CloseProvider?
    private var sendInputProvider: SendInputProvider?
    private var resumeProvider: ResumeProvider?

    public init() {}

    public func installSpawn(_ p: @escaping SpawnProvider) { spawnProvider = p }
    public func installWait(_ p: @escaping WaitProvider) { waitProvider = p }
    public func installClose(_ p: @escaping CloseProvider) { closeProvider = p }
    public func installSendInput(_ p: @escaping SendInputProvider) { sendInputProvider = p }
    public func installResume(_ p: @escaping ResumeProvider) { resumeProvider = p }

    public func clearAll() {
        spawnProvider = nil
        waitProvider = nil
        closeProvider = nil
        sendInputProvider = nil
        resumeProvider = nil
    }

    public func spawn(_ req: SpawnRequest) async throws -> SpawnResponse {
        guard let p = spawnProvider else { throw MultiAgentError.unconfigured }
        return try await p(req)
    }

    public func wait(_ req: WaitRequest) async throws -> WaitResponse {
        guard let p = waitProvider else { throw MultiAgentError.unconfigured }
        return try await p(req)
    }

    public func close(target: String) async throws -> AgentStatus {
        guard let p = closeProvider else { throw MultiAgentError.unconfigured }
        return try await p(target)
    }

    public func sendInput(_ req: SendInputRequest) async throws -> String {
        guard let p = sendInputProvider else { throw MultiAgentError.unconfigured }
        return try await p(req)
    }

    public func resume(id: String) async throws -> AgentStatus {
        guard let p = resumeProvider else { throw MultiAgentError.unconfigured }
        return try await p(id)
    }

    /// Test/diagnostic: which providers are currently installed.
    public func installedProviders() -> Set<String> {
        var s: Set<String> = []
        if spawnProvider != nil { s.insert("spawn") }
        if waitProvider != nil { s.insert("wait") }
        if closeProvider != nil { s.insert("close") }
        if sendInputProvider != nil { s.insert("send_input") }
        if resumeProvider != nil { s.insert("resume") }
        return s
    }
}

/// Multi-agent timeout constants matching upstream
/// `codex-rs/core/src/config/mod.rs` defaults
/// (`DEFAULT_MULTI_AGENT_V2_*_WAIT_TIMEOUT_MS`).
public enum MultiAgentTimeouts {
    public static let defaultMs: Int64 = 30_000
    public static let minMs: Int64 = 10_000
    public static let maxMs: Int64 = 3600 * 1000
}
