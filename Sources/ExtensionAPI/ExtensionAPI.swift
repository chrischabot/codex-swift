import Foundation

public final class ExtensionData: @unchecked Sendable {
    public let levelId: String

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: any Sendable] = [:]

    public init(levelId: String) {
        self.levelId = levelId
    }

    public func get<T: Sendable>(_ type: T.Type = T.self) -> T? {
        lock.lock(); defer { lock.unlock() }
        return entries[ObjectIdentifier(type)] as? T
    }

    public func getOrInit<T: Sendable>(_ type: T.Type = T.self,
                                       _ initValue: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(type)
        if let existing = entries[key] as? T { return existing }
        let value = initValue()
        entries[key] = value
        return value
    }

    @discardableResult
    public func insert<T: Sendable>(_ value: T, as type: T.Type = T.self) -> T? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(type)
        let previous = entries[key] as? T
        entries[key] = value
        return previous
    }

    @discardableResult
    public func remove<T: Sendable>(_ type: T.Type = T.self) -> T? {
        lock.lock(); defer { lock.unlock() }
        return entries.removeValue(forKey: ObjectIdentifier(type)) as? T
    }
}

public enum PromptSlot: String, Sendable, Equatable {
    case developer
    case contextualUser
    case separateDeveloper
}

public struct PromptFragment: Sendable, Equatable {
    public var slot: PromptSlot
    public var text: String

    public init(slot: PromptSlot, text: String) {
        self.slot = slot
        self.text = text
    }
}

public struct ThreadStartInput<Config: Sendable>: Sendable {
    public var sessionStore: ExtensionData
    public var threadStore: ExtensionData
    public var config: Config

    public init(sessionStore: ExtensionData, threadStore: ExtensionData, config: Config) {
        self.sessionStore = sessionStore
        self.threadStore = threadStore
        self.config = config
    }
}

public struct ThreadResumeInput: Sendable {
    public var sessionStore: ExtensionData
    public var threadStore: ExtensionData
    public var threadId: String

    public init(sessionStore: ExtensionData, threadStore: ExtensionData, threadId: String) {
        self.sessionStore = sessionStore
        self.threadStore = threadStore
        self.threadId = threadId
    }
}

public struct ThreadStopInput: Sendable {
    public var sessionStore: ExtensionData
    public var threadStore: ExtensionData
    public var threadId: String

    public init(sessionStore: ExtensionData, threadStore: ExtensionData, threadId: String) {
        self.sessionStore = sessionStore
        self.threadStore = threadStore
        self.threadId = threadId
    }
}

public struct TurnStartInput: Sendable {
    public var threadStore: ExtensionData
    public var turnStore: ExtensionData
    public var turnId: String

    public init(threadStore: ExtensionData, turnStore: ExtensionData, turnId: String) {
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.turnId = turnId
    }
}

public struct TurnStopInput: Sendable {
    public var threadStore: ExtensionData
    public var turnStore: ExtensionData
    public var turnId: String

    public init(threadStore: ExtensionData, turnStore: ExtensionData, turnId: String) {
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.turnId = turnId
    }
}

public struct TurnAbortInput: Sendable {
    public var threadStore: ExtensionData
    public var turnStore: ExtensionData
    public var turnId: String
    public var reason: String

    public init(threadStore: ExtensionData, turnStore: ExtensionData,
                turnId: String, reason: String) {
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.turnId = turnId
        self.reason = reason
    }
}

public struct ConfigChangedInput<Config: Sendable>: Sendable {
    public var sessionStore: ExtensionData
    public var threadStore: ExtensionData
    public var previousConfig: Config
    public var newConfig: Config

    public init(sessionStore: ExtensionData, threadStore: ExtensionData,
                previousConfig: Config, newConfig: Config) {
        self.sessionStore = sessionStore
        self.threadStore = threadStore
        self.previousConfig = previousConfig
        self.newConfig = newConfig
    }
}

public struct TokenUsageCheckpoint: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int

    public init(inputTokens: Int, outputTokens: Int, totalTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public struct TokenUsageInput: Sendable {
    public var sessionStore: ExtensionData
    public var threadStore: ExtensionData
    public var turnStore: ExtensionData
    public var usage: TokenUsageCheckpoint

    public init(sessionStore: ExtensionData, threadStore: ExtensionData,
                turnStore: ExtensionData, usage: TokenUsageCheckpoint) {
        self.sessionStore = sessionStore
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.usage = usage
    }
}

public enum ApprovalReviewDecision: Sendable, Equatable {
    case approved
    case denied(message: String)
    case aborted(message: String)
}

/// Decision of a TOOL-DISPATCH gate (`toolDispatchGateContributor`). Unlike
/// `ApprovalReviewDecision` (an optional reviewer that can approve OR deny on the
/// request-* approval branches), this is a deny-only GATE consulted in front of
/// EVERY tool dispatch — including tools that never reach the approval path
/// (sandboxed-shell, in-writable-root patches, dynamic/MCP tools). It can only
/// `.deny` (block the dispatch) or `.abstain` (let the normal path decide); it
/// can never grant, so it cannot weaken the existing approval policy.
public enum ToolDispatchGateDecision: Sendable, Equatable {
    case deny(message: String)
    case abstain
}

public typealias ContextContribution =
    @Sendable (ExtensionData, ExtensionData) async -> [PromptFragment]
public typealias ApprovalReviewContribution =
    @Sendable (ExtensionData, ExtensionData, String) async -> ApprovalReviewDecision?
/// A tool-dispatch gate contributor. Receives the same stable
/// `method=…\nparams=…` prompt as `approvalReview` (keyed on the resolved tool
/// name, never the untrusted args). Return `.deny` to block, or `nil`/`.abstain`
/// to let the normal path decide. The first contributor to return a `.deny`
/// wins.
public typealias ToolDispatchGateContribution =
    @Sendable (ExtensionData, ExtensionData, String) async -> ToolDispatchGateDecision?

public final class ExtensionRegistryBuilder<Config: Sendable>: @unchecked Sendable {
    private var threadStartHandlers: [@Sendable (ThreadStartInput<Config>) -> Void] = []
    private var threadResumeHandlers: [@Sendable (ThreadResumeInput) -> Void] = []
    private var threadStopHandlers: [@Sendable (ThreadStopInput) -> Void] = []
    private var turnStartHandlers: [@Sendable (TurnStartInput) -> Void] = []
    private var turnStopHandlers: [@Sendable (TurnStopInput) -> Void] = []
    private var turnAbortHandlers: [@Sendable (TurnAbortInput) -> Void] = []
    private var configHandlers: [@Sendable (ConfigChangedInput<Config>) -> Void] = []
    private var tokenUsageHandlers: [@Sendable (TokenUsageInput) -> Void] = []
    private var contextHandlers: [ContextContribution] = []
    private var approvalReviewHandlers: [ApprovalReviewContribution] = []
    private var toolDispatchGateHandlers: [ToolDispatchGateContribution] = []

    public init() {}

    public func threadLifecycle(onStart: (@Sendable (ThreadStartInput<Config>) -> Void)? = nil,
                                onResume: (@Sendable (ThreadResumeInput) -> Void)? = nil,
                                onStop: (@Sendable (ThreadStopInput) -> Void)? = nil) {
        if let onStart { threadStartHandlers.append(onStart) }
        if let onResume { threadResumeHandlers.append(onResume) }
        if let onStop { threadStopHandlers.append(onStop) }
    }

    public func turnLifecycle(onStart: (@Sendable (TurnStartInput) -> Void)? = nil,
                              onStop: (@Sendable (TurnStopInput) -> Void)? = nil,
                              onAbort: (@Sendable (TurnAbortInput) -> Void)? = nil) {
        if let onStart { turnStartHandlers.append(onStart) }
        if let onStop { turnStopHandlers.append(onStop) }
        if let onAbort { turnAbortHandlers.append(onAbort) }
    }

    public func configContributor(_ handler: @escaping @Sendable (ConfigChangedInput<Config>) -> Void) {
        configHandlers.append(handler)
    }

    public func tokenUsageContributor(_ handler: @escaping @Sendable (TokenUsageInput) -> Void) {
        tokenUsageHandlers.append(handler)
    }

    public func contextContributor(_ handler: @escaping ContextContribution) {
        contextHandlers.append(handler)
    }

    public func approvalReviewContributor(_ handler: @escaping ApprovalReviewContribution) {
        approvalReviewHandlers.append(handler)
    }

    /// Register a deny-only TOOL-DISPATCH gate (see `ToolDispatchGateDecision`).
    /// Consulted in front of every tool dispatch, before the approval policy —
    /// the seam the channel owner-gate uses to block a non-owner's privileged
    /// action regardless of policy (sandboxed-shell, in-root patch, dynamic/MCP).
    public func toolDispatchGateContributor(_ handler: @escaping ToolDispatchGateContribution) {
        toolDispatchGateHandlers.append(handler)
    }

    public func build() -> ExtensionRegistry<Config> {
        ExtensionRegistry(
            threadStartHandlers: threadStartHandlers,
            threadResumeHandlers: threadResumeHandlers,
            threadStopHandlers: threadStopHandlers,
            turnStartHandlers: turnStartHandlers,
            turnStopHandlers: turnStopHandlers,
            turnAbortHandlers: turnAbortHandlers,
            configHandlers: configHandlers,
            tokenUsageHandlers: tokenUsageHandlers,
            contextHandlers: contextHandlers,
            approvalReviewHandlers: approvalReviewHandlers,
            toolDispatchGateHandlers: toolDispatchGateHandlers)
    }
}

public final class ExtensionRegistry<Config: Sendable>: @unchecked Sendable {
    private let threadStartHandlers: [@Sendable (ThreadStartInput<Config>) -> Void]
    private let threadResumeHandlers: [@Sendable (ThreadResumeInput) -> Void]
    private let threadStopHandlers: [@Sendable (ThreadStopInput) -> Void]
    private let turnStartHandlers: [@Sendable (TurnStartInput) -> Void]
    private let turnStopHandlers: [@Sendable (TurnStopInput) -> Void]
    private let turnAbortHandlers: [@Sendable (TurnAbortInput) -> Void]
    private let configHandlers: [@Sendable (ConfigChangedInput<Config>) -> Void]
    private let tokenUsageHandlers: [@Sendable (TokenUsageInput) -> Void]
    private let contextHandlers: [ContextContribution]
    private let approvalReviewHandlers: [ApprovalReviewContribution]
    private let toolDispatchGateHandlers: [ToolDispatchGateContribution]

    fileprivate init(threadStartHandlers: [@Sendable (ThreadStartInput<Config>) -> Void],
                     threadResumeHandlers: [@Sendable (ThreadResumeInput) -> Void],
                     threadStopHandlers: [@Sendable (ThreadStopInput) -> Void],
                     turnStartHandlers: [@Sendable (TurnStartInput) -> Void],
                     turnStopHandlers: [@Sendable (TurnStopInput) -> Void],
                     turnAbortHandlers: [@Sendable (TurnAbortInput) -> Void],
                     configHandlers: [@Sendable (ConfigChangedInput<Config>) -> Void],
                     tokenUsageHandlers: [@Sendable (TokenUsageInput) -> Void],
                     contextHandlers: [ContextContribution],
                     approvalReviewHandlers: [ApprovalReviewContribution],
                     toolDispatchGateHandlers: [ToolDispatchGateContribution]) {
        self.threadStartHandlers = threadStartHandlers
        self.threadResumeHandlers = threadResumeHandlers
        self.threadStopHandlers = threadStopHandlers
        self.turnStartHandlers = turnStartHandlers
        self.turnStopHandlers = turnStopHandlers
        self.turnAbortHandlers = turnAbortHandlers
        self.configHandlers = configHandlers
        self.tokenUsageHandlers = tokenUsageHandlers
        self.contextHandlers = contextHandlers
        self.approvalReviewHandlers = approvalReviewHandlers
        self.toolDispatchGateHandlers = toolDispatchGateHandlers
    }

    public func onThreadStart(_ input: ThreadStartInput<Config>) {
        for handler in threadStartHandlers { handler(input) }
    }

    public func onThreadResume(_ input: ThreadResumeInput) {
        for handler in threadResumeHandlers { handler(input) }
    }

    public func onThreadStop(_ input: ThreadStopInput) {
        for handler in threadStopHandlers { handler(input) }
    }

    public func onTurnStart(_ input: TurnStartInput) {
        for handler in turnStartHandlers { handler(input) }
    }

    public func onTurnStop(_ input: TurnStopInput) {
        for handler in turnStopHandlers { handler(input) }
    }

    public func onTurnAbort(_ input: TurnAbortInput) {
        for handler in turnAbortHandlers { handler(input) }
    }

    public func onConfigChanged(_ input: ConfigChangedInput<Config>) {
        for handler in configHandlers { handler(input) }
    }

    public func onTokenUsage(_ input: TokenUsageInput) {
        for handler in tokenUsageHandlers { handler(input) }
    }

    public func promptFragments(sessionStore: ExtensionData,
                                threadStore: ExtensionData) async -> [PromptFragment] {
        var fragments: [PromptFragment] = []
        for handler in contextHandlers {
            fragments.append(contentsOf: await handler(sessionStore, threadStore))
        }
        return fragments
    }

    public func approvalReview(sessionStore: ExtensionData,
                               threadStore: ExtensionData,
                               prompt: String) async -> ApprovalReviewDecision? {
        for handler in approvalReviewHandlers {
            if let decision = await handler(sessionStore, threadStore, prompt) {
                return decision
            }
        }
        return nil
    }

    /// Whether any tool-dispatch gate is installed. The engine checks this to
    /// skip the dispatch-gate seam entirely (byte-identical hot path) when no
    /// gate is registered — the common case.
    public var hasToolDispatchGate: Bool { !toolDispatchGateHandlers.isEmpty }

    /// Consult the tool-dispatch gates. The FIRST gate to return a non-nil
    /// decision wins (a `.deny` blocks, an `.abstain` lets the next gate / the
    /// normal path decide). Returns `.abstain` when no gate claims.
    public func toolDispatchGate(sessionStore: ExtensionData,
                                 threadStore: ExtensionData,
                                 prompt: String) async -> ToolDispatchGateDecision {
        for handler in toolDispatchGateHandlers {
            if let decision = await handler(sessionStore, threadStore, prompt) {
                return decision
            }
        }
        return .abstain
    }
}

public func emptyExtensionRegistry<Config: Sendable>(_: Config.Type = Config.self)
    -> ExtensionRegistry<Config> {
    ExtensionRegistryBuilder<Config>().build()
}
