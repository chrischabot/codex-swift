import Foundation
import InfraPrimitives

/// Inputs assembled for one model request (Codex `Prompt.input` /
/// `ContextManager::for_prompt`). The full transcript is sent every request;
/// the server prompt cache (`prompt_cache_key`) + WS incremental delta make
/// re-sending cheap.
public enum PromptInput: Sendable, Equatable {
    case userText(String)
    case developerText(String)
    case assistantText(String)
    case toolOutput(callId: String, output: String)
}

/// One model-visible tool spec (Codex `ToolSpec` / `router.model_visible_specs()`).
/// `parametersJSON` is the JSON-Schema object string for the tool arguments.
/// `outputSchemaJSON` is an optional JSON-Schema object string describing the
/// tool's structured output payload. When set, codex-swift emits it as a
/// sibling of `parameters` on the per-tool Responses API definition (mirrors
/// the `output_schema` field of upstream `codex_tools::ResponsesApiTool` —
/// note that upstream marks the field `#[serde(skip)]` in its REST path and
/// instead routes structured-output enforcement through the prompt-level
/// `text.format` field; we keep the per-tool emission both for code-mode
/// parity and so structured output is genuinely declared on the wire when
/// the provider honours it).
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parametersJSON: String
    public var outputSchemaJSON: String?
    public init(name: String,
                description: String,
                parametersJSON: String,
                outputSchemaJSON: String? = nil) {
        self.name = name; self.description = description
        self.parametersJSON = parametersJSON
        self.outputSchemaJSON = outputSchemaJSON
    }
}

public struct Prompt: Sendable, Equatable {
    public var instructions: String
    public var input: [PromptInput]
    public var tools: [ToolSpec] = []
    public init(instructions: String, input: [PromptInput]) {
        self.instructions = instructions
        self.input = input
    }
    public init(instructions: String, input: [PromptInput], tools: [ToolSpec]) {
        self.instructions = instructions
        self.input = input
        self.tools = tools
    }
}

/// Per-request settings. `threadId` is the server prompt-cache key; `turnState`
/// is the sticky-routing token replayed within a turn and never across turns
/// (rework §7.5 / Codex `prompt_cache_key`, `x-codex-turn-state`).
///
/// The Responses API body fields below mirror upstream Codex (see
/// `~/Projects/codex/codex-rs/core/src/client.rs::build_responses_request` and
/// `codex-api/src/common.rs::ResponsesApiRequest`):
/// - `toolChoice` default `"auto"` so the server is allowed to call tools.
/// - `parallelToolCalls` default `false` matches upstream `Prompt::default()`
///   (`client_common.rs:56`) and the model-catalog default for
///   `supports_parallel_tool_calls`. The session glue threads
///   `model_info.supports_parallel_tool_calls` through to
///   `prompt.parallel_tool_calls`; until codex-swift maintains a model-info
///   catalog the safest default is `false` so we don't claim a capability the
///   model may not support. Callers that know the model supports it can pass
///   `parallelToolCalls: true`.
/// - `reasoningEffort` / `reasoningSummary` are forwarded as a `reasoning`
///   object only when `reasoningEffort` is non-nil. Reasoning-capable models
///   require this field to surface thought summaries and preserve encrypted
///   reasoning across turns. When neither is set, the builder still emits the
///   key as JSON `null` so the wire shape matches upstream
///   `ResponsesApiRequest.reasoning: Option<Reasoning>` (no
///   `skip_serializing_if` — serde always serializes `null` for `None`).
/// - `store` defaults to `false`; set to `true` for Azure Responses endpoints
///   (`provider.is_azure_responses_endpoint()` in upstream).
/// - `include` defaults to nil — the builder emits
///   `["reasoning.encrypted_content"]` automatically whenever reasoning is
///   active, matching upstream behaviour. Override to send an explicit set.
/// - `serviceTier` mirrors `service_tier` (e.g. `"auto"`, `"flex"`).
/// - `textVerbosity` produces the optional `text.verbosity` field (`"low"`,
///   `"medium"`, `"high"`).
/// - `clientMetadata` carries the per-request HTTP `client_metadata` map.
///   Upstream's REST `build_responses_request` puts ONLY
///   `x-codex-installation-id` into this map (`client.rs:760-763`).
///   `cli_version` / `originator` are NOT in upstream's REST `client_metadata`
///   — they appear in `session_meta` (rollout telemetry) and as
///   `originator` strings elsewhere, but NOT here. We honour that:
///   if `clientMetadata` is empty, the builder omits the field entirely
///   (upstream marks it `skip_serializing_if = Option::is_none`); when callers
///   want the installation id to be reported they pass it explicitly through
///   `CodexClientIdentity.installationIdKey`.
public struct ModelSettings: Sendable, Equatable {
    public var model: String
    public var threadId: String
    public var turnState: String?
    public var previousResponseId: String?

    // P6.1 — request-body parity fields (Codex Responses API).
    public var toolChoice: String
    public var parallelToolCalls: Bool
    public var reasoningEffort: String?
    public var reasoningSummary: String?
    public var store: Bool
    public var include: [String]?
    public var serviceTier: String?
    public var textVerbosity: String?
    public var clientMetadata: [String: String]

    public init(model: String,
                threadId: String,
                turnState: String? = nil,
                previousResponseId: String? = nil,
                toolChoice: String = "auto",
                parallelToolCalls: Bool = false,
                reasoningEffort: String? = nil,
                reasoningSummary: String? = nil,
                store: Bool = true,
                include: [String]? = nil,
                serviceTier: String? = nil,
                textVerbosity: String? = nil,
                clientMetadata: [String: String] = [:]) {
        self.model = model
        self.threadId = threadId
        self.turnState = turnState
        self.previousResponseId = previousResponseId
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.store = store
        self.include = include
        self.serviceTier = serviceTier
        self.textVerbosity = textVerbosity
        self.clientMetadata = clientMetadata
    }
}

/// Codex CLI identity strings used outside the per-request HTTP
/// `client_metadata` body field (e.g. rollout `session_meta`, telemetry
/// originator). Mirrors upstream `originator` plumbing in
/// `codex-rs/core/src/client.rs` and the rollout `session_meta`. These
/// constants are intentionally NOT injected into the Responses API
/// `client_metadata` body — upstream's REST `build_responses_request`
/// (`client.rs:760-763`) only includes `x-codex-installation-id` there.
public enum CodexClientIdentity {
    /// Public CLI version surfaced in rollout `session_meta` and in
    /// telemetry — NOT in the Responses API `client_metadata` body field.
    public static let cliVersion: String = "0.1.0"

    /// `originator` matches the rollout `session_meta.originator` and the
    /// internal `originator` string Codex uses to tag requests. NOT injected
    /// into the Responses API `client_metadata` body — see upstream
    /// `client.rs:760-763`.
    public static let originator: String = "codex-swift/\(cliVersion)"

    /// Upstream client_metadata key for the installation id. Same constant as
    /// `X_CODEX_INSTALLATION_ID_HEADER` in `core/src/client.rs`. Callers that
    /// have an installation id pass it via
    /// `ModelSettings.clientMetadata[CodexClientIdentity.installationIdKey]`.
    public static let installationIdKey: String = "x-codex-installation-id"

    /// Reads (or creates) the persistent installation id from
    /// `<codexHome>/installation_id`. Matches upstream
    /// `core/src/installation_id.rs::resolve_installation_id`: file is a UUID
    /// string; if it doesn't exist or contains a non-UUID, a fresh UUID is
    /// written. Returns `nil` only if file I/O fails — callers may then omit
    /// the installation id (upstream's REST body skips the field when the
    /// `Option<HashMap>` is `None`).
    public static func resolveInstallationId(codexHome: String) -> String? {
        let path = (codexHome as NSString)
            .appendingPathComponent("installation_id")
        let url = URL(fileURLWithPath: path)
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = UUID(uuidString: existing) {
            return parsed.uuidString.lowercased()
        }
        let fresh = UUID().uuidString.lowercased()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fresh.write(to: url, atomically: true, encoding: .utf8)
            return fresh
        } catch {
            return nil
        }
    }
}

/// Provider stream events (Codex `ResponseEvent` analog).
public enum ResponseEvent: Sendable, Equatable {
    case created
    case agentDelta(itemId: String, delta: String)
    case agentDone(itemId: String, text: String)
    case toolCall(callId: String, name: String, argumentsJSON: String)
    /// `usage` carries the breakdown (input / cached / output / reasoning)
    /// when the provider reports it; nil otherwise. Default-nil keeps every
    /// existing mock/test caller compatible. (F5: token-count breakdown.)
    case completed(responseId: String, totalTokens: Int, endTurn: Bool,
                   usage: UsageSnapshot? = nil)
}

public struct ModelError: Error, Sendable, Equatable {
    public let message: String
    public let retryable: Bool
    public let httpStatus: Int?
    public let retryAfter: Duration?
    /// Upstream-compatible classification of a `response.failed` SSE
    /// error.code (P6.2 / H-44). Mirrors `ApiError` variants from
    /// `codex-rs/codex-api/src/error.rs` so the turn loop can branch on
    /// well-known cases (e.g. `.contextWindowExceeded` triggers history
    /// trimming in P6.3). Values are the upstream-style code names
    /// (snake_case strings) rather than the raw OpenAI `error.code` so
    /// callers compare against stable Codex identifiers, not vendor wire
    /// codes that occasionally drift.
    public let codexErrorCode: CodexErrorCode?
    public init(_ message: String,
                retryable: Bool,
                httpStatus: Int? = nil,
                retryAfter: Duration? = nil,
                codexErrorCode: CodexErrorCode? = nil) {
        self.message = message
        self.retryable = retryable
        self.httpStatus = httpStatus
        self.retryAfter = retryAfter
        self.codexErrorCode = codexErrorCode
    }
}

/// Upstream-compatible classification for `response.failed` SSE bodies and
/// HTTP-level error payloads (P6.2 / H-44). Mirrors the variants of
/// `codex-rs/codex-api/src/error.rs::ApiError` that codex-swift cares about.
/// `unknown` is the graceful fallback when the server reports a code we do
/// not yet special-case.
public enum CodexErrorCode: String, Sendable, Equatable {
    case contextWindowExceeded = "context_window_exceeded"
    case quotaExceeded = "quota_exceeded"
    case usageNotIncluded = "usage_not_included"
    case cyberPolicy = "cyber_policy"
    case invalidRequest = "invalid_request"
    case serverOverloaded = "server_overloaded"
    case rateLimited = "rate_limited"
    case incomplete = "incomplete"
    case unknown = "unknown"
}

/// Shared classifier for SSE `response.failed` / `response.incomplete`
/// payloads (P6.2 / H-44 / H-43). Returns a `ModelError` whose
/// `retryable`, `httpStatus`, `retryAfter`, and `codexErrorCode` fields
/// mirror upstream `codex-api/src/sse/responses.rs::process_responses_event`.
public enum ModelClientErrorClassifier {
    /// Classifies a `response.failed` payload. `error` is the parsed
    /// `response.error` object from the SSE frame.
    public static func classifyResponseFailed(_ error: [String: Any]?)
    -> ModelError {
        let rawMessage = (error?["message"] as? String) ?? "response.failed"
        let code = (error?["code"] as? String) ?? ""
        // Upstream mapping (`codex-api/src/sse/responses.rs:312-345`):
        //   context_length_exceeded → ContextWindowExceeded (retryable=true
        //                              upstream — feeds trim-and-retry loop)
        //   insufficient_quota      → QuotaExceeded (terminal)
        //   usage_not_included      → UsageNotIncluded (terminal)
        //   cyber_policy            → CyberPolicy (terminal)
        //   invalid_prompt          → InvalidRequest (terminal)
        //   server_is_overloaded /
        //   slow_down               → ServerOverloaded (retryable)
        //   rate_limit_exceeded     → Retryable + retry-after parsed from
        //                              message ("try again in 1.5s")
        //   _                       → Retryable (default) with optional
        //                              retry-after if the message embeds one.
        switch code {
        case "context_length_exceeded", "context_window_exceeded":
            return ModelError(
                "context window exceeded: \(rawMessage)",
                retryable: true,
                httpStatus: 400,
                codexErrorCode: .contextWindowExceeded)
        case "insufficient_quota", "quota_exceeded":
            return ModelError(
                "quota exceeded: \(rawMessage)",
                retryable: false,
                httpStatus: 429,
                codexErrorCode: .quotaExceeded)
        case "usage_not_included":
            return ModelError(
                "usage not included: \(rawMessage)",
                retryable: false,
                httpStatus: 402,
                codexErrorCode: .usageNotIncluded)
        case "cyber_policy":
            let msg = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                ? "This request has been flagged for possible cybersecurity risk."
                : rawMessage
            return ModelError(
                msg,
                retryable: false,
                httpStatus: 400,
                codexErrorCode: .cyberPolicy)
        case "invalid_prompt":
            return ModelError(
                rawMessage.isEmpty ? "Invalid request." : rawMessage,
                retryable: false,
                httpStatus: 400,
                codexErrorCode: .invalidRequest)
        case "server_is_overloaded", "slow_down":
            return ModelError(
                "server overloaded: \(rawMessage)",
                retryable: true,
                httpStatus: 503,
                codexErrorCode: .serverOverloaded)
        case "rate_limit_exceeded":
            return ModelError(
                rawMessage,
                retryable: true,
                httpStatus: 429,
                retryAfter: parseRetryAfterFromMessage(rawMessage),
                codexErrorCode: .rateLimited)
        case "":
            // No code at all: default to retryable with retry-after sniff.
            return ModelError(
                rawMessage,
                retryable: true,
                retryAfter: parseRetryAfterFromMessage(rawMessage),
                codexErrorCode: .unknown)
        default:
            // Unknown but present code: upstream's catch-all branch is
            // `ApiError::Retryable { message, delay }`. We honour that
            // and tag the error as `.unknown` so callers can log it.
            return ModelError(
                rawMessage.isEmpty
                    ? "response.failed (\(code))"
                    : "\(rawMessage) (code: \(code))",
                retryable: true,
                retryAfter: parseRetryAfterFromMessage(rawMessage),
                codexErrorCode: .unknown)
        }
    }

    /// True when `response.incomplete` should be treated as a terminal
    /// success (yield `.completed` with partial usage) rather than thrown
    /// as a retryable stream error. Currently only
    /// `incomplete_details.reason == "max_output_tokens"` qualifies — the
    /// model produced as much text as the caller budgeted for, and
    /// retrying with the same budget would just loop. STATUS.md:624-629
    /// documents this as the intended invariant so token usage is
    /// captured for truncated turns. All other reasons (e.g.
    /// `content_filter`) continue to throw via `classifyIncomplete`.
    public static func incompleteIsTerminalSuccess(_ responseObj: [String: Any]?)
    -> Bool {
        guard let details = responseObj?["incomplete_details"]
            as? [String: Any],
              let reason = details["reason"] as? String else {
            return false
        }
        return reason == "max_output_tokens"
    }

    /// Classifies a `response.incomplete` payload. Upstream
    /// (`responses.rs:347-356`) treats every `incomplete` event as
    /// `ApiError::Stream("Incomplete response returned, reason: …")` and
    /// forwards it to the retry loop. We follow suit with
    /// `retryable: true` — except for the `max_output_tokens` case which
    /// `incompleteIsTerminalSuccess` peels off as soft-success.
    public static func classifyIncomplete(_ responseObj: [String: Any]?)
    -> ModelError {
        let reason: String = {
            if let details = responseObj?["incomplete_details"]
                as? [String: Any],
               let r = details["reason"] as? String,
               !r.isEmpty {
                return r
            }
            return "unknown"
        }()
        return ModelError(
            "Incomplete response returned, reason: \(reason)",
            retryable: true,
            codexErrorCode: .incomplete)
    }

    /// Best-effort parser for "try again in N s" / "N ms" snippets that
    /// some rate-limit error messages embed (upstream
    /// `try_parse_retry_after`). Returns nil when the message does not
    /// match the pattern.
    static func parseRetryAfterFromMessage(_ message: String) -> Duration? {
        // Pattern: try again in <number><unit> where unit ∈ {s, ms,
        // second(s)}. Case-insensitive.
        let lower = message.lowercased()
        guard let range = lower.range(of: "try again in") else { return nil }
        let rest = lower[range.upperBound...]
            .drop(while: { $0 == " " || $0 == "\t" })
        var numberChars: [Character] = []
        var idx = rest.startIndex
        while idx < rest.endIndex,
              rest[idx].isNumber || rest[idx] == "." {
            numberChars.append(rest[idx])
            idx = rest.index(after: idx)
        }
        guard !numberChars.isEmpty,
              let value = Double(String(numberChars)) else { return nil }
        var afterNumber = rest[idx...]
            .drop(while: { $0 == " " || $0 == "\t" })
        let unit: String
        if afterNumber.hasPrefix("ms") {
            unit = "ms"
        } else if afterNumber.hasPrefix("seconds") {
            unit = "s"
        } else if afterNumber.hasPrefix("second") {
            unit = "s"
        } else if afterNumber.hasPrefix("s") {
            unit = "s"
        } else {
            return nil
        }
        _ = afterNumber
        switch unit {
        case "ms":
            return .milliseconds(Int(value))
        default:
            return .seconds(value)
        }
    }
}

/// Captures the last completed response for WS-incremental / sticky routing
/// (`previous_response_id` + turn-state) — Codex `LastResponse`.
public actor LastResponseBox {
    public private(set) var responseId: String?
    public private(set) var turnState: String?
    public private(set) var totalTokens: Int = 0
    public init() {}
    public func record(responseId: String, totalTokens: Int) {
        self.responseId = responseId; self.totalTokens = totalTokens
    }
    public func setTurnState(_ s: String?) { if let s, turnState == nil { turnState = s } }
    public func snapshot() -> (String?, String?, Int) { (responseId, turnState, totalTokens) }
}

public struct ResponseStream: Sendable {
    public let events: AsyncThrowingStream<ResponseEvent, any Error>
    public let lastResponse: LastResponseBox
    public init(events: AsyncThrowingStream<ResponseEvent, any Error>, lastResponse: LastResponseBox) {
        self.events = events; self.lastResponse = lastResponse
    }
}

public protocol ModelClient: Sendable {
    /// Returns a turn-scoped stream. The implementation must apply the bounded
    /// stream mapper (consumer-dropped cancellation, capacity from `Limits`).
    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws -> ResponseStream
}
