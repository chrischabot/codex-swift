import Foundation
import InfraPrimitives

/// One scripted step the mock emits.
public enum MockStep: Sendable, Equatable {
    case created
    case delta(itemId: String, String)
    case agentDone(itemId: String, String)
    case toolCall(callId: String, name: String, argumentsJSON: String)
    case completeEndTurn(responseId: String, tokens: Int)
    case completeContinue(responseId: String, tokens: Int)   // endTurn=false
    case failRetryable(String)
    case failTerminal(String)
    /// Mock the upstream `context_length_exceeded` / `context_window_exceeded`
    /// SSE `response.failed` classification — yields a `ModelError` with
    /// `codexErrorCode == .contextWindowExceeded` so the turn-loop
    /// trim-and-retry path (P6.3) can be exercised deterministically.
    case failContextWindow(String)
    case slowMillis(Int)
    /// Emit a rate-limit snapshot (upstream `TokenCountEvent.rate_limits`) so
    /// the SessionEngine's `account/rateLimits/updated` forwarding can be
    /// exercised deterministically.
    case rateLimits(RateLimitSnapshot)
}

public struct MockScenario: Sendable, Equatable {
    public var steps: [MockStep]
    public init(_ steps: [MockStep]) { self.steps = steps }

    /// A simple "say hello then end the turn" scenario.
    public static func hello(_ text: String = "Hello!") -> MockScenario {
        MockScenario([
            .created,
            .delta(itemId: "msg_1", text),
            .agentDone(itemId: "msg_1", text),
            .completeEndTurn(responseId: "resp_1", tokens: 12),
        ])
    }

    /// A severe deterministic turn: tool → follow-up-needed high token count
    /// → model compaction → tool → follow-up-needed high token count →
    /// compaction → final assistant delta. The high token counts force the
    /// Codex auto-compact ladder without needing a giant test prompt.
    public static func toolLoopCompactionSequence(repetitions: Int) -> [MockScenario] {
        var scenarios: [MockScenario] = []
        for i in 0..<max(1, repetitions) {
            scenarios.append(MockScenario([
                .created,
                .toolCall(callId: "tlc_\(i)_1", name: "list_dir", argumentsJSON: #"{"path":""}"#),
                .completeContinue(responseId: "tlc_resp_\(i)_1", tokens: 300_000),
            ]))
            scenarios.append(MockScenario([
                .created,
                .agentDone(itemId: "tlc_sum_\(i)_1", "TOOL LOOP SUMMARY \(i)-1"),
                .completeEndTurn(responseId: "tlc_resp_\(i)_2", tokens: 12),
            ]))
            scenarios.append(MockScenario([
                .created,
                .toolCall(callId: "tlc_\(i)_2", name: "list_dir", argumentsJSON: #"{"path":""}"#),
                .completeContinue(responseId: "tlc_resp_\(i)_3", tokens: 300_000),
            ]))
            scenarios.append(MockScenario([
                .created,
                .agentDone(itemId: "tlc_sum_\(i)_2", "TOOL LOOP SUMMARY \(i)-2"),
                .completeEndTurn(responseId: "tlc_resp_\(i)_4", tokens: 12),
            ]))
            scenarios.append(MockScenario([
                .created,
                .delta(itemId: "tlc_final_\(i)", "tool-loop compacted"),
                .agentDone(itemId: "tlc_final_\(i)", "tool-loop compacted"),
                .completeEndTurn(responseId: "tlc_resp_\(i)_5", tokens: 12),
            ]))
        }
        return scenarios
    }
}

public struct CapturedRequest: Sendable, Equatable {
    public let promptCacheKey: String   // == settings.threadId (Codex contract)
    public let turnState: String?
    public let previousResponseId: String?
    public let model: String
    public let inputCount: Int
    /// The text payload of every `PromptInput` that carries one (userText /
    /// developerText / assistantText / toolOutput). Lets tests assert which
    /// prompt extras — e.g. the goal-context budget-limit steering fragment —
    /// were injected into a given sampling request.
    public let inputTexts: [String]
}

/// Deterministic mock. Scenarios are consumed FIFO across calls so a test can
/// script "first attempt fails, retry succeeds". All requests are recorded so
/// caching/sticky-routing behavior can be asserted byte-exactly.
public actor MockModelClient: ModelClient {
    private var scenarios: [MockScenario]
    public private(set) var captured: [CapturedRequest] = []
    private let streamCapacity: Int

    public init(_ scenarios: [MockScenario], limits: Limits = Limits()) {
        self.scenarios = scenarios
        self.streamCapacity = limits.clamped().dataChannelDepth
    }
    public init(repeating scenario: MockScenario, times: Int, limits: Limits = Limits()) {
        self.scenarios = Array(repeating: scenario, count: times)
        self.streamCapacity = limits.clamped().dataChannelDepth
    }

    public func capturedRequests() -> [CapturedRequest] { captured }

    public func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream {
        captured.append(CapturedRequest(
            promptCacheKey: settings.threadId,
            turnState: settings.turnState,
            previousResponseId: settings.previousResponseId,
            model: settings.model,
            inputCount: prompt.input.count,
            inputTexts: prompt.input.compactMap { inp in
                switch inp {
                case .userText(let t), .developerText(let t), .assistantText(let t):
                    return t
                case .toolOutput(_, let o):
                    return o
                case .reasoning:
                    return nil
                }
            }))

        let scenario = scenarios.isEmpty ? MockScenario.hello() : scenarios.removeFirst()

        // A connect-time failure must surface from `stream()` itself so the
        // RetryingModelClient can see it (mirrors Codex stream-open failure).
        if let first = scenario.steps.first {
            switch first {
            case .failRetryable(let m): throw ModelError(m, retryable: true, httpStatus: 503)
            case .failTerminal(let m): throw ModelError(m, retryable: false, httpStatus: 400)
            case .failContextWindow(let m):
                throw ModelError(m, retryable: true, httpStatus: 400,
                                 codexErrorCode: .contextWindowExceeded)
            default: break
            }
        }

        let cap = streamCapacity
        return StreamMapper.map(capacity: cap) {
            AsyncThrowingStream<ResponseEvent, any Error> { cont in
                let task = Task {
                    do {
                        for step in scenario.steps {
                            if Task.isCancelled { break }
                            switch step {
                            case .created:
                                cont.yield(.created)
                            case .delta(let id, let d):
                                cont.yield(.agentDelta(itemId: id, delta: d))
                            case .agentDone(let id, let t):
                                cont.yield(.agentDone(itemId: id, text: t))
                            case .toolCall(let cid, let n, let a):
                                cont.yield(.toolCall(callId: cid, name: n, argumentsJSON: a))
                            case .completeEndTurn(let rid, let tk):
                                cont.yield(.completed(responseId: rid, totalTokens: tk, endTurn: true))
                            case .completeContinue(let rid, let tk):
                                cont.yield(.completed(responseId: rid, totalTokens: tk, endTurn: false))
                            case .failRetryable(let m):
                                throw ModelError(m, retryable: true, httpStatus: 503)
                            case .failTerminal(let m):
                                throw ModelError(m, retryable: false, httpStatus: 400)
                            case .failContextWindow(let m):
                                throw ModelError(m, retryable: true, httpStatus: 400,
                                                 codexErrorCode: .contextWindowExceeded)
                            case .slowMillis(let ms):
                                try await Task.sleep(for: .milliseconds(ms))
                            case .rateLimits(let snap):
                                cont.yield(.rateLimits(snap))
                            }
                        }
                        cont.finish()
                    } catch {
                        cont.finish(throwing: error)
                    }
                }
                cont.onTermination = { _ in task.cancel() }
            }
        }
    }
}
