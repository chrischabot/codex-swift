import Foundation
import InfraPrimitives
import WireProtocol

/// Inputs assembled for one model request (Codex `Prompt.input` /
/// `ContextManager::for_prompt`). The full transcript is sent every request;
/// the server prompt cache (`prompt_cache_key`) + WS incremental delta make
/// re-sending cheap.
public enum PromptInput: Sendable, Equatable {
    case userText(String)
    case developerText(String)
    case assistantText(String)
    /// A tool result replayed back into the next request's input. Mirrors
    /// upstream replaying the originating `ResponseItem::FunctionCall` (real
    /// `name` + `arguments`) immediately followed by its
    /// `ResponseItem::FunctionCallOutput` (`client_common.rs:65-82`,
    /// `protocol/src/models.rs:787-800`). The request builder serializes this
    /// as a `function_call` (`{type,name,arguments,call_id}`) + a
    /// `function_call_output` (`{type,call_id,output}`) pair so the API accepts
    /// the output (it requires a matching preceding call) AND the model sees
    /// WHICH tool produced the result across iterations.
    ///
    /// `name` is the REAL tool name (e.g. `shell`, `apply_patch`, `read_file`),
    /// not the prior fake `"tool"`. `argumentsJSON` is the call's arguments
    /// string; the Swift `ThreadItem` model unifies a tool call and its output
    /// into one `.commandExecution` / `.fileChange` entry that does NOT retain
    /// the original arguments string (a documented consequence of the unified
    /// item model — see `Rollout.swift:843-880`), so callers projecting from
    /// history pass `"{}"`. Callers that have the live arguments may pass them
    /// verbatim.
    case toolOutput(callId: String, name: String, argumentsJSON: String,
                    output: String)
    /// A reasoning item replayed back into the model input so encrypted
    /// chain-of-thought survives across turns (Codex `ResponseItem::Reasoning`,
    /// `protocol/src/models.rs:766-775`). `summary` is the list of
    /// `summary_text` strings; `content` is the list of `reasoning_text`
    /// strings; `encryptedContent` is the opaque `encrypted_content` token the
    /// server returned when `include == ["reasoning.encrypted_content"]`. The
    /// builder serializes this to
    /// `{"type":"reasoning","summary":[…],"content":[…],"encrypted_content":…}`
    /// (the upstream `id` field is `#[serde(skip_serializing)]`, so it is never
    /// sent). `content` is omitted from the wire when it contains no
    /// reasoning-text parts (upstream `should_serialize_reasoning_content`).
    case reasoning(summary: [String], content: [String], encryptedContent: String?)
}

/// Coerce a replayed `function_call` name to a valid OpenAI function identifier
/// (`^[A-Za-z0-9_-]+$`); invalid characters become `_`, an empty result becomes
/// `"tool"`. The Responses API 400s the WHOLE request on a malformed name, which
/// drops the entire turn — so this is the wire-boundary backstop for the request
/// builders (the semantic name is chosen upstream in `ContextManager.forPrompt`).
func sanitizedResponsesFunctionName(_ s: String) -> String {
    var chars: [Character] = []
    chars.reserveCapacity(s.count)
    for u in s.unicodeScalars {
        let v = u.value
        let ok = (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            || (0x30...0x39).contains(v) || v == 0x5F || v == 0x2D
        chars.append(ok ? Character(u) : "_")
    }
    return chars.isEmpty ? "tool" : String(chars)
}

/// One model-visible tool spec (Codex `ToolSpec` / `router.model_visible_specs()`).
/// `parametersJSON` is the JSON-Schema object string for the tool arguments.
/// `outputSchemaJSON` is an optional JSON-Schema object string describing the
/// tool's structured output payload. Upstream `codex_tools::ResponsesApiTool`
/// marks `output_schema` `#[serde(skip)]`, so it is NEVER serialized onto the
/// Responses API wire — it is retained only for internal code-mode validation
/// and structured-output enforcement (which upstream routes through the
/// prompt-level `text.format` field, not the per-tool definition). codex-swift
/// mirrors that: `outputSchemaJSON` is kept on the spec for internal use but is
/// not emitted in the per-tool request body.
///
/// `strict` mirrors upstream `ResponsesApiTool.strict` (`responses_api.rs:32`),
/// a NON-skippable bool that is always serialized on every function tool
/// (`{"type":"function","name","description","strict":<bool>,"parameters":…}`).
/// Upstream's tool builder defaults it to `false`; callers that produce a
/// strict JSON-schema tool set it `true`.
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parametersJSON: String
    public var outputSchemaJSON: String?
    /// Mirrors upstream `ResponsesApiTool.strict` — always serialized on a
    /// function tool. Defaults to `false` (upstream's builder default).
    public var strict: Bool
    /// When set, this tool is advertised to the Responses API as a Freeform
    /// custom-grammar tool (`{"type":"custom", …, "format":{…}}`) instead of a
    /// JSON function tool (`{"type":"function", …, "parameters":{…}}`). Mirrors
    /// upstream `codex_tools::ToolSpec::Freeform(FreeformTool)` /
    /// `core::tools::handlers::apply_patch_spec::create_apply_patch_freeform_tool`.
    /// `apply_patch` uses this so GPT-5 models can emit the raw patch envelope
    /// without wrapping it in JSON. `parametersJSON` is still retained for
    /// back-compat / code-mode parity but is NOT serialized for freeform tools.
    public var freeformFormat: FreeformToolFormat?
    public init(name: String,
                description: String,
                parametersJSON: String,
                outputSchemaJSON: String? = nil,
                strict: Bool = false,
                freeformFormat: FreeformToolFormat? = nil) {
        self.name = name; self.description = description
        self.parametersJSON = parametersJSON
        self.outputSchemaJSON = outputSchemaJSON
        self.strict = strict
        self.freeformFormat = freeformFormat
    }
}

/// Wire shape of `format` on a Freeform custom-grammar tool. Mirrors upstream
/// `codex_tools::FreeformToolFormat` (`tools/src/responses_api.rs:18-23`):
/// serializes as `{"type":"grammar","syntax":"lark","definition":"…"}`.
public struct FreeformToolFormat: Sendable, Equatable {
    public var type: String
    public var syntax: String
    public var definition: String
    public init(type: String, syntax: String, definition: String) {
        self.type = type; self.syntax = syntax; self.definition = definition
    }
}

public struct Prompt: Sendable, Equatable {
    public var instructions: String
    public var input: [PromptInput]
    public var tools: [ToolSpec] = []
    /// Optional structured-output JSON schema (Codex `Prompt.output_schema`,
    /// `client_common.rs:44-48`). When set, the request builder emits a
    /// `text.format = {type:"json_schema", name:"codex_output_schema",
    /// strict:<outputSchemaStrict>, schema:<outputSchema>}` object so the
    /// server validates the response against the schema (upstream
    /// `create_text_param_for_request`, `codex-api/src/common.rs:279-297`).
    /// `nil` (the default) omits the format entirely, matching the
    /// non-structured-output wire shape.
    public var outputSchema: JSONValue?
    /// Mirrors upstream `Prompt.output_schema_strict` (`client_common.rs:48`):
    /// the `strict` bool emitted on the `text.format` object. Only meaningful
    /// when `outputSchema` is set. Defaults to `false`, matching upstream's
    /// `Prompt::default()`.
    public var outputSchemaStrict: Bool = false
    public init(instructions: String, input: [PromptInput]) {
        self.instructions = instructions
        self.input = input
    }
    public init(instructions: String, input: [PromptInput], tools: [ToolSpec]) {
        self.instructions = instructions
        self.input = input
        self.tools = tools
    }
    public init(instructions: String,
                input: [PromptInput],
                tools: [ToolSpec],
                outputSchema: JSONValue?,
                outputSchemaStrict: Bool = false) {
        self.instructions = instructions
        self.input = input
        self.tools = tools
        self.outputSchema = outputSchema
        self.outputSchemaStrict = outputSchemaStrict
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
    /// The session id used for request-correlation headers. Mirrors upstream
    /// `ApiResponsesOptions.session_id` (`client.rs:966`), which seeds the
    /// `session-id` header via `build_session_headers`
    /// (`requests/headers.rs:5-14`). When `nil` the transport falls back to
    /// `threadId` so the correlation headers are still populated.
    public var sessionId: String?
    public var turnState: String?
    /// Per-turn metadata header value (`x-codex-turn-metadata`). When non-nil,
    /// every Responses API request (REST + WebSocket + curl) carries it. Mirrors
    /// upstream `client.rs` `build_responses_headers` / `build_ws_client_metadata`
    /// inserting `X_CODEX_TURN_METADATA_HEADER` when `turn_metadata_header` is
    /// `Some` (`client.rs:137`, `:648-655`, `:1651`). The value is the
    /// ASCII-only JSON produced by `TurnMetadataState.currentHeaderValue()`.
    public var turnMetadata: String?
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

    // Model-catalog capability gating (upstream `ModelInfo`, consumed by
    // `build_reasoning` / `build_responses_request`, `client.rs:690-742`).
    // These are resolved by the caller (e.g. SessionEngine reading
    // `models.json`) and threaded in so the request builders gate reasoning /
    // verbosity exactly as upstream does. They are TRI-STATE for backward
    // compatibility:
    //   - `supportsReasoningSummaries == nil` → the caller did not resolve a
    //     catalog entry; the builder falls back to the legacy heuristic
    //     ("reasoningEffort presence is the reasoning-capable signal").
    //   - `supportsReasoningSummaries == true`  → emit reasoning (defaulting
    //     effort to `defaultReasoningLevel` when the caller gave none).
    //   - `supportsReasoningSummaries == false` → suppress reasoning entirely,
    //     even if `reasoningEffort` is set (matches `build_reasoning` returning
    //     `None` for non-reasoning models).
    public var supportsReasoningSummaries: Bool?
    public var defaultReasoningLevel: String?
    /// Tri-state verbosity gate, same semantics as the reasoning gate. When
    /// `false`, `textVerbosity` is suppressed (upstream warns + drops it for
    /// models that do not `support_verbosity`).
    public var supportVerbosity: Bool?
    /// Sub-agent source label for the `x-openai-subagent` request header.
    /// Upstream attaches this header on every Responses stream request whose
    /// session originates from a sub-agent so the backend can route/meter
    /// those turns distinctly (`endpoint/responses.rs:95-97`). The label maps
    /// `SubAgentSource` → `review` / `compact` / `memory_consolidation` /
    /// `collab_spawn` / `<other>` (`requests/headers.rs:16-31`). `nil` for a
    /// primary (non-sub-agent) turn — the header is omitted.
    public var subagentLabel: String?
    /// Tri-state service-tier gate. Upstream filters the requested
    /// `service_tier` against `ModelInfo.supports_service_tier`
    /// (`client.rs:744-745`), dropping a tier the resolved model does not
    /// advertise before serialization. Semantics:
    ///   - `nil`  → the caller did not resolve a catalog entry; emit
    ///     `serviceTier` as-is (legacy behaviour).
    ///   - `true` → the model supports the requested tier; emit it.
    ///   - `false`→ the model does NOT support the requested tier; suppress
    ///     `service_tier` entirely (matches upstream's `filter`).
    public var supportsServiceTier: Bool?

    public init(model: String,
                threadId: String,
                sessionId: String? = nil,
                turnState: String? = nil,
                turnMetadata: String? = nil,
                previousResponseId: String? = nil,
                toolChoice: String = "auto",
                parallelToolCalls: Bool = false,
                reasoningEffort: String? = nil,
                reasoningSummary: String? = nil,
                store: Bool = false,
                include: [String]? = nil,
                serviceTier: String? = nil,
                textVerbosity: String? = nil,
                clientMetadata: [String: String] = [:],
                supportsReasoningSummaries: Bool? = nil,
                defaultReasoningLevel: String? = nil,
                supportVerbosity: Bool? = nil,
                supportsServiceTier: Bool? = nil,
                subagentLabel: String? = nil) {
        self.model = model
        self.threadId = threadId
        self.sessionId = sessionId
        self.turnState = turnState
        self.turnMetadata = turnMetadata
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
        self.supportsReasoningSummaries = supportsReasoningSummaries
        self.defaultReasoningLevel = defaultReasoningLevel
        self.supportVerbosity = supportVerbosity
        self.supportsServiceTier = supportsServiceTier
        self.subagentLabel = subagentLabel
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
    /// Upstream sources this from `env!("CARGO_PKG_VERSION")`
    /// (`rollout/src/recorder.rs:679`); the Swift port has no Cargo crate
    /// version so it carries the harness build version.
    public static let cliVersion: String = "0.1.0"

    /// Default `originator` identity for the Swift port. Mirrors upstream
    /// `DEFAULT_ORIGINATOR = "codex_cli_rs"`
    /// (`login/src/auth/default_client.rs:36`) — a BARE originator id, NOT a
    /// `"{id}/{version}"` string. The version is carried separately in
    /// `cliVersion` / `session_meta.cli_version`.
    public static let defaultOriginator: String = "codex_swift"

    /// Env var that overrides the originator at runtime. Faithful to upstream
    /// `CODEX_INTERNAL_ORIGINATOR_OVERRIDE_ENV_VAR`
    /// (`login/src/auth/default_client.rs:37`).
    public static let originatorOverrideEnvVar: String =
        "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"

    /// Resolves the effective originator value, honoring the
    /// `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` env var and falling back to
    /// `defaultOriginator`. Mirrors upstream `get_originator_value(None)`
    /// (`login/src/auth/default_client.rs:57-76`): a present-but-empty
    /// override is treated as set (upstream `env::var(...).ok()` returns
    /// `Some("")`, which then wins over the default), matching upstream
    /// precedence exactly.
    public static func resolveOriginator(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        env[originatorOverrideEnvVar] ?? defaultOriginator
    }

    /// `originator` matches the rollout `session_meta.originator` and the
    /// internal `originator` string Codex uses to tag requests. NOT injected
    /// into the Responses API `client_metadata` body — see upstream
    /// `client.rs:760-763`. Honors the override env var.
    public static var originator: String { resolveOriginator() }

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
    // --- Upstream `ResponseEvent` variants the parser previously DROPPED
    // (codex-api/src/common.rs). Surfacing them lets the SessionEngine emit
    // the matching v2 streaming notifications and accumulate tool-call input.
    /// `response.reasoning_summary_text.delta` — streaming reasoning summary.
    case reasoningSummaryDelta(itemId: String, delta: String, summaryIndex: Int)
    /// `response.reasoning_text.delta` — streaming reasoning content.
    case reasoningContentDelta(itemId: String, delta: String, contentIndex: Int)
    /// `response.reasoning_summary_part.added` — a new summary part started.
    case reasoningSummaryPartAdded(itemId: String, summaryIndex: Int)
    /// `response.function_call_arguments.delta` / `custom_tool_call_input.delta`.
    /// Mirrors upstream `ResponseEvent::ToolCallInputDelta { item_id, call_id,
    /// delta }` (`codex-api/src/sse/responses.rs:280-289`): `itemId` is resolved
    /// as `item_id ?? call_id`, and `callId` carries the raw `call_id` (which may
    /// be nil). The transport suppresses emission entirely when BOTH ids are
    /// absent, so `itemId` here is always a real server id (never a synthetic
    /// placeholder).
    case toolCallInputDelta(itemId: String, callId: String?, delta: String)
    /// `response.output_item.added` — an output item began (id + type).
    case outputItemAdded(itemId: String, itemType: String)
    /// A server-emitted output item that the turn loop does not execute locally
    /// but must not silently drop: `local_shell_call`, `web_search_call`, or
    /// `tool_search_call` (`response.output_item.done` / `.added`). Upstream
    /// deserializes EVERY `ResponseItem` variant into
    /// `ResponseEvent::OutputItemDone` / `OutputItemAdded`
    /// (`codex-api/src/sse/responses.rs:267-274`, `:376-382`); the Swift
    /// transport surfaces these less-common server-side tool items here so they
    /// are recorded rather than lost. `itemType` is the raw `item.type`;
    /// `itemId` is the item id (or its `call_id` fallback); `json` is the raw
    /// item object re-encoded to a JSON string for downstream inspection /
    /// recording. `done` distinguishes `output_item.done` (true) from
    /// `output_item.added` (false).
    case serverToolItem(itemType: String, itemId: String, json: String,
                        done: Bool)
    /// Server-effective model from the `OpenAI-Model` response header — may
    /// differ from the requested model when backend safety routing applies.
    case serverModel(String)
    /// `response.output_item.done` with `item.type == "reasoning"` — carries
    /// the (optionally encrypted) chain-of-thought so the turn loop can persist
    /// it and replay it into the next request's input (Codex
    /// `ResponseEvent::OutputItemDone(ResponseItem::Reasoning)`,
    /// `codex-api/src/sse/responses.rs:267-274`). `summary`/`content` are the
    /// flattened `summary_text` / `reasoning_text` strings; `encryptedContent`
    /// is the opaque `encrypted_content` token requested via
    /// `include: ["reasoning.encrypted_content"]`.
    case reasoning(itemId: String, summary: [String], content: [String],
                   encryptedContent: String?)
    /// Account-verification recommendation list parsed from a
    /// `response.metadata` frame's `openai_verification_recommendation`
    /// (Codex `ResponseEvent::ModelVerifications`, `common.rs:72-111`).
    case modelVerifications([String])
    /// Models-catalog ETag from the `X-Models-Etag` response header
    /// (Codex `ResponseEvent::ModelsEtag`).
    case modelsEtag(String)
    /// Server-side reasoning-token accounting flag from the presence of the
    /// `x-reasoning-included` response header (Codex
    /// `ResponseEvent::ServerReasoningIncluded`).
    case serverReasoningIncluded(Bool)
    /// A rate-limit snapshot observed for this turn (parsed from the response
    /// headers). Upstream pairs `rate_limits` with the `TokenCountEvent`
    /// (`protocol/src/protocol.rs` `TokenCountEvent.rate_limits`); the
    /// app-server then emits `account/rateLimits/updated` whenever it is
    /// present (`bespoke_event_handling.rs:1571-1579`). Surfacing it as a
    /// stream event lets the SessionEngine forward the notification alongside
    /// `tokenUsageUpdated`. The primary (`codex`) family snapshot is emitted.
    case rateLimits(RateLimitSnapshot)
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
        let rawMessage = (error?["message"] as? String) ?? "response.failed event received"
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
            // No code at all: default to retryable. Upstream
            // `try_parse_retry_after` (`responses.rs:487-491`) returns the
            // parsed delay ONLY when `code == Some("rate_limit_exceeded")`, so
            // a missing code yields `delay: None` and the backoff path drives
            // timing — we mirror that with `retryAfter: nil`.
            return ModelError(
                rawMessage,
                retryable: true,
                codexErrorCode: .unknown)
        default:
            // Unknown but present code: upstream's catch-all branch is
            // `ApiError::Retryable { message, delay }` where `delay` comes from
            // `try_parse_retry_after`, which only returns a value for
            // `rate_limit_exceeded`. For any other code it is `None`, so we
            // leave `retryAfter` nil and let the backoff path drive timing.
            return ModelError(
                rawMessage.isEmpty
                    ? "response.failed (\(code))"
                    : "\(rawMessage) (code: \(code))",
                retryable: true,
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

/// Resolves the `reasoning` object and `text.verbosity` for a request body,
/// faithfully porting upstream `build_reasoning` (`client.rs:690-707`) and the
/// verbosity gate in `build_responses_request` (`client.rs:727-742`).
///
/// The gating consults the model-catalog capability fields threaded through
/// `ModelSettings`. Those fields are tri-state (see `ModelSettings`):
///   - `supportsReasoningSummaries == true`  → emit reasoning, defaulting the
///     effort to `defaultReasoningLevel` when the caller gave none.
///   - `supportsReasoningSummaries == false` → suppress reasoning entirely.
///   - `supportsReasoningSummaries == nil`   → legacy fallback: reasoning is
///     emitted iff the caller supplied a non-empty `reasoningEffort` /
///     `reasoningSummary` (the pre-catalog heuristic, preserved so callers that
///     do not resolve a catalog entry keep their existing wire shape).
public enum ReasoningResolution {
    /// Returns the `reasoning` dict to serialize, or nil to emit `null`/omit.
    public static func resolveReasoning(_ settings: ModelSettings) -> [String: Any]? {
        let effort = settings.reasoningEffort.flatMap { $0.isEmpty ? nil : $0 }
        let summary = settings.reasoningSummary.flatMap { $0.isEmpty ? nil : $0 }
        switch settings.supportsReasoningSummaries {
        case .some(true):
            // Upstream emits the object whenever the model supports reasoning
            // summaries, defaulting effort to the catalog default.
            var reasoning: [String: Any] = [:]
            let resolvedEffort = effort
                ?? settings.defaultReasoningLevel.flatMap { $0.isEmpty ? nil : $0 }
            if let resolvedEffort { reasoning["effort"] = resolvedEffort }
            // Upstream maps `ReasoningSummaryConfig::None` → no summary key.
            if let summary, summary.lowercased() != "none" {
                reasoning["summary"] = summary
            }
            return reasoning
        case .some(false):
            // Non-reasoning model: `build_reasoning` returns None.
            return nil
        case .none:
            // Legacy heuristic: presence of effort/summary drives emission.
            var reasoning: [String: Any] = [:]
            if let effort { reasoning["effort"] = effort }
            if let summary { reasoning["summary"] = summary }
            return reasoning.isEmpty ? nil : reasoning
        }
    }

    /// Returns the verbosity string to serialize under `text.verbosity`, or nil
    /// when none / unsupported. Gated on `supportVerbosity` (tri-state).
    public static func resolveVerbosity(_ settings: ModelSettings) -> String? {
        let verbosity = settings.textVerbosity.flatMap { $0.isEmpty ? nil : $0 }
        switch settings.supportVerbosity {
        case .some(true), .none:
            // Supported (or unresolved → legacy passthrough): emit when set.
            return verbosity
        case .some(false):
            // Model does not support verbosity: drop it (upstream warns + None).
            return nil
        }
    }
}

/// Ports upstream `Prompt::get_formatted_input` / `reserialize_shell_outputs`
/// (`core/src/client_common.rs:65-175`). When a Freeform `apply_patch` custom
/// tool is present in the request, the prior shell / apply_patch tool outputs
/// in the transcript are rewritten from their JSON envelope
/// (`{"output":…,"metadata":{"exit_code":N,"duration_seconds":X}}`) into the
/// structured text the model expects:
///
/// ```text
/// Exit code: N
/// Wall time: X seconds
/// [Total output lines: N]
/// Output:
/// <output>
/// ```
///
/// Non-freeform (JSON function-tool) requests do NOT reserialize — matching
/// upstream's `is_freeform_apply_patch_tool_present` gate.
public enum FreeformApplyPatchFormatting {
    /// True when `tools` contains a Freeform tool named `apply_patch`
    /// (`client_common.rs:73-76`).
    public static func isFreeformApplyPatchToolPresent(_ tools: [ToolSpec]) -> Bool {
        tools.contains { $0.freeformFormat != nil && $0.name == "apply_patch" }
    }

    /// Rewrites a single tool-output string into the structured form when it
    /// parses as a shell-output JSON envelope; returns `nil` when it does not
    /// (so the caller leaves the original output untouched). Mirrors
    /// `parse_structured_shell_output` + `build_structured_output`
    /// (`client_common.rs:152-167`).
    public static func reserializeShellOutput(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              let output = obj["output"] as? String,
              let metadata = obj["metadata"] as? [String: Any] else {
            return nil
        }
        // `exit_code` (i32) and `duration_seconds` (f32) are required fields of
        // `ExecOutputMetadataJson`; absence means this is not a shell envelope.
        guard let exitCode = intFromJSON(metadata["exit_code"]),
              let durationSeconds = doubleFromJSON(metadata["duration_seconds"])
        else {
            return nil
        }
        var sections: [String] = []
        sections.append("Exit code: \(exitCode)")
        sections.append("Wall time: \(formatDurationSeconds(durationSeconds)) seconds")
        var body = output
        if let (stripped, totalLines) = stripTotalOutputHeader(output) {
            sections.append("Total output lines: \(totalLines)")
            body = stripped
        }
        sections.append("Output:")
        sections.append(body)
        return sections.joined(separator: "\n")
    }

    /// Mirrors `strip_total_output_header` (`client_common.rs:169-175`): when the
    /// output begins with `"Total output lines: <u32>\n"`, returns the remaining
    /// body (with one leading `\n` stripped) plus the parsed count.
    private static func stripTotalOutputHeader(_ output: String)
    -> (String, UInt32)? {
        let prefix = "Total output lines: "
        guard output.hasPrefix(prefix) else { return nil }
        let afterPrefix = output.dropFirst(prefix.count)
        guard let nl = afterPrefix.firstIndex(of: "\n") else { return nil }
        let totalSegment = afterPrefix[afterPrefix.startIndex..<nl]
        guard let totalLines = UInt32(totalSegment) else { return nil }
        var remainder = String(afterPrefix[afterPrefix.index(after: nl)...])
        if remainder.hasPrefix("\n") { remainder.removeFirst() }
        return (remainder, totalLines)
    }

    /// Renders the f32 wall time the way Rust's `{}` `Display` for `f32` does:
    /// an integral value prints without a fractional part (e.g. `2`), otherwise
    /// the shortest round-tripping decimal (e.g. `1.5`).
    private static func formatDurationSeconds(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        // Round-tripping shortest representation via Float, matching the f32
        // precision upstream serializes.
        return String(Float(value))
    }

    private static func intFromJSON(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private static func doubleFromJSON(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let i = v as? Int { return Double(i) }
        return nil
    }
}

/// Ports upstream `attach_item_ids` (`codex-api/src/requests/responses.rs:11-37`),
/// invoked by the Responses endpoint when `request.store &&
/// provider.is_azure_responses_endpoint()` (`endpoint/responses.rs:86-88`). It
/// zips the serialized `input` array with the originating `Prompt.input` items
/// and re-attaches each item's originating `id` (for the variants upstream
/// carries one: Reasoning / Message / WebSearchCall / FunctionCall /
/// ToolSearchCall / LocalShellCall / CustomToolCall) when present and
/// non-empty. The Swift `PromptInput` model does not currently surface per-item
/// ids, so `sourceId(for:)` returns nil for every case today and the pass is a
/// structural no-op; it preserves the exact zip-and-attach mechanics so the
/// Azure wire shape is reproduced once ids become available on `PromptInput`.
public enum AzureItemIDs {
    /// Returns the originating item id for a `PromptInput`, or nil when the
    /// variant does not carry one (matching upstream's `Some(id)` arms).
    static func sourceId(for input: PromptInput) -> String? {
        switch input {
        // `PromptInput` does not expose per-item ids today; reasoning's id is
        // deliberately `#[serde(skip_serializing)]` on the input path. No
        // variant carries an attachable id, so we return nil for all.
        case .userText, .developerText, .assistantText, .toolOutput,
             .reasoning:
            return nil
        }
    }

    /// Mutates the serialized `input` array in place, attaching the `id` from
    /// each source `PromptInput` where present and non-empty. The serialized
    /// `input` may contain MORE entries than `prompt.input` (e.g. a `.toolOutput`
    /// expands to a synthetic `function_call` + `function_call_output` pair), so
    /// this maps source ids onto the input array by source order only when the
    /// counts align — exactly mirroring upstream's positional `zip`, which
    /// assumes a 1:1 correspondence between `input` JSON entries and
    /// `original_items`.
    public static func attach(into body: inout [String: Any],
                              prompt: Prompt) {
        guard var items = body["input"] as? [[String: Any]] else { return }
        // Upstream `zip` truncates to the shorter of the two; we mirror that.
        let count = Swift.min(items.count, prompt.input.count)
        var mutated = false
        for i in 0..<count {
            guard let id = sourceId(for: prompt.input[i]),
                  !id.isEmpty else { continue }
            items[i]["id"] = id
            mutated = true
        }
        if mutated { body["input"] = items }
    }
}

/// Converts a `WireProtocol.JSONValue` into a Foundation object tree suitable
/// for `JSONSerialization` (the request builder serializes the assembled
/// `[String: Any]` body). Mirrors how upstream embeds a `serde_json::Value`
/// schema verbatim under `text.format.schema`.
enum JSONValueFoundation {
    static func toAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { toAny($0) }
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = toAny(v) }
            return out
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

    /// Unary remote-compaction request against the server-side `/compact`
    /// endpoint (`codex-rs/core/src/client.rs::compact_conversation_history`).
    ///
    /// Returns the parsed summary transcript (role-bearing message items) when
    /// the provider supports remote compaction, or `nil` when it does not — in
    /// which case the caller falls back to local prompt-driven compaction. The
    /// default implementation (see `RemoteCompaction.swift`) returns `nil` so
    /// existing clients/mocks remain unchanged; only the OpenAI / Azure-
    /// Responses transports override it.
    func compactConversationHistory(_ prompt: Prompt, _ settings: ModelSettings)
        async throws -> [RemoteCompaction.OutputMessage]?
}
