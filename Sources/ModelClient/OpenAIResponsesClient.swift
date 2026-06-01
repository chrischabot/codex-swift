import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InfraPrimitives

private final class CurlStreamState: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var outHandle: FileHandle?
    private var errHandle: FileHandle?
    private var cancelled = false

    func setReadHandles(out: FileHandle, err: FileHandle) {
        lock.lock()
        if cancelled {
            try? out.close()
            try? err.close()
        } else {
            outHandle = out
            errHandle = err
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let out = outHandle
        let err = errHandle
        outHandle = nil
        errHandle = nil
        if process.isRunning {
            process.terminate()
        }
        lock.unlock()

        // `FileHandle.availableData` can remain blocked after SIGTERM until the
        // pipe endpoint changes state. Closing the read handles gives cancelled
        // streams a deterministic wake-up path so XCTest does not wait forever
        // on a stray reader thread.
        try? out?.close()
        try? err?.close()
    }
}

/// Portable OpenAI Responses API client (`POST /v1/responses`, `stream:true`).
///
/// SSE is streamed by spawning `curl -sS -N` (ubiquitous on Linux + macOS,
/// `-N` disables buffering — ideal for SSE) and reading its stdout on a
/// dedicated OS thread that feeds an `AsyncThrowingStream`, mapped through
/// `StreamMapper` (bounded, consumer-dropped cancellation kills curl). This is
/// the portable live-test client. Curl receives sensitive headers through a
/// temporary 0600 config file rather than argv. On macOS,
/// `URLSessionResponsesClient` is the production SSE path; WebSocket
/// prewarm/attestation/zstd/401→broker refresh remain the P2-M1 completion
/// layer.
public actor OpenAIResponsesClient: ModelClient {
    private let provider: ModelProvider
    private let env: [String: String]
    private let usageTracker: UsageTracker?
    /// Set only by the legacy `init(apiKey:endpoint:)` to guarantee
    /// byte-identical URL + Authorization for existing callers.
    private let explicitEndpoint: String?
    private let explicitBearer: String?
    private let maxOutputTokens: Int?
    private let streamCapacity: Int
    private let requestTimeoutSeconds: Int

    /// Designated provider-based initializer.
    public init(provider: ModelProvider,
                maxOutputTokens: Int? = nil,
                limits: Limits = Limits(),
                env: [String: String] = ProcessInfo.processInfo.environment,
                usageTracker: UsageTracker? = nil) {
        self.provider = provider
        self.env = env
        self.usageTracker = usageTracker
        self.explicitEndpoint = nil
        self.explicitBearer = nil
        self.maxOutputTokens = maxOutputTokens
        let clamped = limits.clamped()
        self.streamCapacity = clamped.dataChannelDepth
        self.requestTimeoutSeconds = Self.transportTimeoutSeconds(clamped)
    }

    /// Legacy initializer — preserved byte-for-byte. Synthesizes an `openai`
    /// provider but uses `explicitEndpoint`/`explicitBearer` verbatim so the
    /// POST URL and `Authorization` header are exactly as before.
    public init(apiKey: String,
                endpoint: String = "https://api.openai.com/v1/responses",
                maxOutputTokens: Int? = nil,
                limits: Limits = Limits()) {
        var base = endpoint
        if base.hasSuffix("/responses") {
            base.removeLast("/responses".count)
        }
        self.provider = ModelProvider(
            id: "openai", name: "OpenAI", baseURL: base,
            envKey: nil, experimentalBearerToken: apiKey)
        self.env = [:]
        self.usageTracker = nil
        self.explicitEndpoint = endpoint
        self.explicitBearer = apiKey
        self.maxOutputTokens = maxOutputTokens
        let clamped = limits.clamped()
        self.streamCapacity = clamped.dataChannelDepth
        self.requestTimeoutSeconds = Self.transportTimeoutSeconds(clamped)
    }

    private static func transportTimeoutSeconds(_ limits: Limits) -> Int {
        Swift.max(1, Swift.min(Int(ceil(limits.turnDeadline.seconds)), 180))
    }

    private static func curlConfigValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Deterministic, offline-testable request body. `prompt_cache_key` is the
    /// thread id (Codex contract); developer/assistant roles and
    /// function-call-output replay are mapped faithfully.
    public static func buildRequestBody(_ prompt: Prompt, _ settings: ModelSettings,
                                        maxOutputTokens: Int?,
                                        isAzureResponsesProvider: Bool = false) -> [String: Any] {
        // Upstream `Prompt::get_formatted_input` (`client_common.rs:65-82`):
        // when a Freeform `apply_patch` custom tool is present, prior shell /
        // apply_patch tool outputs in the transcript are reserialized from the
        // JSON envelope into structured `Exit code:/Wall time:/Output:` text
        // before serialization. The transform is a no-op for outputs that are
        // not a shell-output JSON envelope (returns nil), so non-shell outputs
        // pass through unchanged.
        let reserializeFreeformShellOutputs =
            FreeformApplyPatchFormatting.isFreeformApplyPatchToolPresent(prompt.tools)
        var input: [[String: Any]] = []
        for item in prompt.input {
            switch item {
            case .userText(let t):
                input.append(["role": "user",
                              "content": [["type": "input_text", "text": t]]])
            case .developerText(let t):
                input.append(["role": "developer",
                              "content": [["type": "input_text", "text": t]]])
            case .assistantText(let t):
                input.append(["role": "assistant",
                              "content": [["type": "output_text", "text": t]]])
            case .toolOutput(let callId, let name, let argumentsJSON, let output):
                // Replay the originating function_call so the API accepts the
                // function_call_output (it requires a matching preceding call)
                // AND the model sees the REAL tool name + arguments it invoked
                // (upstream replays the verbatim `ResponseItem::FunctionCall`,
                // `protocol/src/models.rs:787-800`). `name` is the actual tool
                // name; `argumentsJSON` is the call's arguments string. The
                // upstream `function_call` shape is
                // `{type,name,arguments,call_id}` (`namespace` omitted when
                // absent, `id` is `#[serde(skip_serializing)]`).
                input.append(["type": "function_call", "call_id": callId,
                              "name": name, "arguments": argumentsJSON])
                let formattedOutput = reserializeFreeformShellOutputs
                    ? (FreeformApplyPatchFormatting
                        .reserializeShellOutput(output) ?? output)
                    : output
                input.append(["type": "function_call_output",
                              "call_id": callId, "output": formattedOutput])
            case .reasoning(let summary, let content, let encryptedContent):
                // Replay the reasoning item so encrypted chain-of-thought
                // survives across turns (Codex `ResponseItem::Reasoning`,
                // protocol/src/models.rs:766). The upstream `id` field is
                // `#[serde(skip_serializing)]` — never sent. `summary` and
                // `encrypted_content` are always serialized (the latter as
                // `null` when absent). `content` is omitted unless it carries
                // reasoning-text parts (`should_serialize_reasoning_content`).
                var item: [String: Any] = [
                    "type": "reasoning",
                    "summary": summary.map {
                        ["type": "summary_text", "text": $0]
                    },
                    "encrypted_content": encryptedContent.map { $0 as Any }
                        ?? NSNull(),
                ]
                if !content.isEmpty {
                    item["content"] = content.map {
                        ["type": "reasoning_text", "text": $0]
                    }
                }
                input.append(item)
            }
        }
        if input.isEmpty {
            input.append(["role": "user",
                          "content": [["type": "input_text", "text": " "]]])
        }
        // P6.1: Request body fields now mirror upstream Codex's
        // `ResponsesApiRequest` (`codex-rs/codex-api/src/common.rs` line 170)
        // populated by `build_responses_request`
        // (`codex-rs/core/src/client.rs` lines 709-766). Eight fields that
        // were previously missing — `tool_choice`, `parallel_tool_calls`,
        // `reasoning`, `store`, `include`, `service_tier`, `text`,
        // `client_metadata` — are now sent so reasoning-capable models surface
        // thought summaries, encrypted reasoning is preserved across turns,
        // and the server can call tools (default `tool_choice: "auto"`).
        // `previous_response_id` + `store: false` is incompatible — OpenAI
        // requires the prior response to have been stored (`store: true`)
        // before it can be referenced. Upstream's default of `store: false`
        // only works because its REST path doesn't chain via
        // `previous_response_id` (it relies on `prompt_cache_key` + full
        // transcript replay). Our turn loop DOES set `previousResponseId`
        // for sticky routing within a turn, so we must force `store: true`
        // whenever it's set. Callers that explicitly want `store: false`
        // for an un-chained call simply leave `previousResponseId` nil.
        //
        // Provider coupling mirrors upstream `build_responses_request`
        // (`core/src/client.rs:754` — `store: provider.is_azure_responses_endpoint()`):
        // standard OpenAI sends `store: false`; an Azure Responses endpoint
        // sends `store: true`. `ModelSettings.store` defaults to `false`
        // (matching the non-Azure default); the Azure provider forces it on
        // here so callers do not have to thread the provider kind through
        // settings.
        let effectiveStore = settings.previousResponseId != nil
            || isAzureResponsesProvider
            ? true : settings.store
        var body: [String: Any] = [
            "model": settings.model,
            "input": input,
            "stream": true,
            "prompt_cache_key": settings.threadId,
            "tool_choice": settings.toolChoice,
            "parallel_tool_calls": settings.parallelToolCalls,
            "store": effectiveStore,
        ]
        // `instructions` is `skip_serializing_if = "String::is_empty"`
        // upstream (`codex-api/src/common.rs:172-173`): omit the key entirely
        // when the instructions string is empty rather than sending `""`.
        if !prompt.instructions.isEmpty {
            body["instructions"] = prompt.instructions
        }
        if let previousResponseId = settings.previousResponseId {
            body["previous_response_id"] = previousResponseId
        }
        if !prompt.tools.isEmpty {
            body["tools"] = prompt.tools.map { spec -> [String: Any] in
                // Freeform custom-grammar tool (apply_patch): emit
                // `{"type":"custom","name","description","format":{…}}` instead
                // of a JSON function tool (upstream `ToolSpec::Freeform`).
                if let fmt = spec.freeformFormat {
                    return ["type": "custom", "name": spec.name,
                            "description": spec.description,
                            "format": ["type": fmt.type, "syntax": fmt.syntax,
                                       "definition": fmt.definition]]
                }
                let params = ((try? JSONSerialization.jsonObject(
                    with: Data(spec.parametersJSON.utf8))) as? [String: Any])
                    ?? ["type": "object", "additionalProperties": true]
                // Upstream `ResponsesApiTool` always serializes `strict` (a
                // non-skippable bool, `responses_api.rs:32`) and marks
                // `output_schema` `#[serde(skip)]` — so the wire shape is
                // `{"type":"function","name","description","strict":<bool>,
                // "parameters":…}` with NO output_schema. We mirror that
                // exactly: emit `strict`, never emit `output_schema`.
                let entry: [String: Any] = ["type": "function", "name": spec.name,
                                            "description": spec.description,
                                            "strict": spec.strict,
                                            "parameters": params]
                return entry
            }
        } else {
            // Upstream always serializes `tools: []` (non-skippable field).
            // Send an empty array rather than omitting so the wire shape
            // matches `ResponsesApiRequest::tools: Vec<Value>`.
            body["tools"] = [] as [Any]
        }
        // `max_output_tokens` is NOT part of upstream `ResponsesApiRequest`
        // (`codex-api/src/common.rs:169-190`); `build_responses_request` never
        // sets it. codex-swift keeps it as an intentional, OFF-BY-DEFAULT
        // non-upstream extension: `maxOutputTokens` is `nil` unless a caller /
        // config explicitly opts in to capping output, in which case the cap is
        // emitted. When nil (the default) the key is omitted, so the wire shape
        // matches upstream for every normal request.
        if let m = maxOutputTokens { body["max_output_tokens"] = m }

        // Reasoning + `include`, resolved exactly as upstream `build_reasoning`
        // (`client.rs:690-726`). See `ReasoningResolution` for the catalog
        // gating semantics. `include` defaults to
        // `["reasoning.encrypted_content"]` iff a reasoning object is emitted.
        //
        // Wire shape for `reasoning`: upstream's `ResponsesApiRequest.reasoning`
        // is `Option<Reasoning>` with NO `skip_serializing_if`
        // (`codex-api/src/common.rs:178`), so serde emits `"reasoning": null`
        // when the field is `None`. We mirror that by emitting `NSNull()` when
        // reasoning is inactive rather than omitting the key.
        let reasoning = ReasoningResolution.resolveReasoning(settings)
        if let reasoning {
            body["reasoning"] = reasoning
        } else {
            body["reasoning"] = NSNull()
        }
        let include: [String] = settings.include
            ?? (reasoning == nil ? [] : ["reasoning.encrypted_content"])
        body["include"] = include

        // `service_tier` is gated on model-catalog support exactly like
        // upstream (`client.rs:744-745`):
        // `service_tier.filter(|t| model_info.supports_service_tier(t))`.
        // When the caller resolved a catalog entry that does NOT advertise the
        // requested tier (`supportsServiceTier == false`), the field is dropped
        // before serialization. A `nil` gate preserves legacy behaviour
        // (emit as-is when a tier is set).
        if let tier = settings.serviceTier, !tier.isEmpty,
           settings.supportsServiceTier != false {
            body["service_tier"] = tier
        }

        // Optional `text` controls — verbosity gated on model support
        // (`client.rs:727-742`): when the catalog says the model does not
        // support verbosity, the field is dropped even if the caller set it.
        // Structured-output schema is carried as `text.format` mirroring
        // upstream `create_text_param_for_request` (`common.rs:279-297`):
        // the `text` object is emitted iff verbosity OR an output schema is
        // present; each sub-key (`verbosity`, `format`) is itself
        // `skip_serializing_if = Option::is_none`, so only present keys appear.
        var text: [String: Any] = [:]
        if let verbosity = ReasoningResolution.resolveVerbosity(settings) {
            text["verbosity"] = verbosity
        }
        if let schema = prompt.outputSchema {
            text["format"] = [
                "type": "json_schema",
                "name": "codex_output_schema",
                "strict": prompt.outputSchemaStrict,
                "schema": JSONValueFoundation.toAny(schema),
            ]
        }
        if !text.isEmpty {
            body["text"] = text
        }

        // `client_metadata` mirrors upstream's REST shape
        // (`client.rs:760-763`): the REST `build_responses_request` only puts
        // `x-codex-installation-id` into the map. `cli_version` /
        // `originator` are NOT in the REST body — they live in
        // `build_ws_client_metadata` (WebSocket path) and `session_meta`
        // (rollout telemetry).
        //
        // We therefore emit whatever caller-supplied keys are in
        // `settings.clientMetadata` verbatim. The field is
        // `skip_serializing_if = Option::is_none` upstream
        // (`common.rs:188`), so when no entries are supplied we omit the
        // field entirely instead of emitting fake defaults the server may
        // reject or count as drift.
        if !settings.clientMetadata.isEmpty {
            body["client_metadata"] = settings.clientMetadata
        }

        // Azure-only: when the request is stored on an Azure Responses endpoint,
        // re-attach the originating item ids to the serialized input array
        // (upstream `attach_item_ids`, `endpoint/responses.rs:86-88` +
        // `requests/responses.rs:11-37`). `effectiveStore` is forced true for
        // Azure above, so the gate collapses to `isAzureResponsesProvider` in
        // practice, but we keep both conditions to mirror upstream exactly.
        if effectiveStore && isAzureResponsesProvider {
            AzureItemIDs.attach(into: &body, prompt: prompt)
        }

        return body
    }

    /// Serialize a Responses request body to JSON bytes that match upstream's
    /// serde field ordering for the tool-definition subtree.
    ///
    /// `JSONSerialization.data(..., [.sortedKeys])` alphabetizes EVERY object's
    /// keys, which reorders each nested `JsonSchema` object to
    /// `{"description":…,"type":…}` (alphabetical) — the opposite of upstream's
    /// serde struct order, where `type` is the first field
    /// (`tools/src/json_schema.rs:33-55`: type, description, enum, items,
    /// properties, required, additionalProperties, anyOf). Upstream serializes
    /// each `ToolSpec` via `serde_json::to_value` preserving struct field order
    /// (`tools/src/tool_spec.rs:79-89`), so a string property serializes as
    /// `{"type":"string","description":…}`. To keep the tool-definition bytes
    /// byte-identical to upstream (OpenAI prompt-prefix cache parity), we emit
    /// every object's keys in sorted order EXCEPT schema objects inside each
    /// `tools[].parameters` subtree, whose keys follow the canonical
    /// `JsonSchema` serde order. `properties`/`client_metadata`-style maps keep
    /// alphabetical key order (upstream `BTreeMap`), and their schema *values*
    /// recurse with the canonical order.
    public static func serializeBody(_ body: [String: Any]) throws -> Data {
        var out = Data()
        out.reserveCapacity(4096)
        encodeJSON(body, scope: .plain, into: &out)
        return out
    }

    /// Ordering scope for the recursive encoder.
    private enum EncodeScope: Equatable {
        /// Object keys sorted alphabetically; children inherit `.plain` unless
        /// the key is `parameters` (a tool's schema root → `.schema`).
        case plain
        /// Object treated as a `JsonSchema`: keys follow the canonical serde
        /// field order; `properties` descends to `.propertyMap`, every other
        /// child descends to `.schema`.
        case schema
        /// A `properties` map: keys (property names) stay alphabetical, but each
        /// value is itself a `JsonSchema` (`.schema`).
        case propertyMap
    }

    /// Canonical serde field order for `JsonSchema` (`tools/src/json_schema.rs`).
    private static let jsonSchemaFieldOrder: [String] = [
        "type", "description", "enum", "items", "properties",
        "required", "additionalProperties", "anyOf",
    ]

    /// Recursive deterministic JSON encoder. In `.schema` scope the receiving
    /// object's keys are ordered by `jsonSchemaFieldOrder` (any remaining keys
    /// appended alphabetically); otherwise keys are alphabetical.
    private static func encodeJSON(_ value: Any, scope: EncodeScope, into out: inout Data) {
        switch value {
        case let dict as [String: Any]:
            out.append(UInt8(ascii: "{"))
            let keys: [String]
            switch scope {
            case .schema:
                let known = jsonSchemaFieldOrder.filter { dict[$0] != nil }
                let rest = dict.keys.filter { !jsonSchemaFieldOrder.contains($0) }.sorted()
                keys = known + rest
            case .plain, .propertyMap:
                keys = dict.keys.sorted()
            }
            var first = true
            for key in keys {
                guard let v = dict[key] else { continue }
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                encodeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                let childScope: EncodeScope
                switch scope {
                case .plain:
                    // A tool entry's `parameters` is the schema root.
                    childScope = (key == "parameters") ? .schema : .plain
                case .schema:
                    // Within a schema: `properties` is a name→schema map (its
                    // keys are property names, kept alphabetical), every other
                    // schema field (`items`, `anyOf` elements, …) is a schema.
                    childScope = (key == "properties") ? .propertyMap : .schema
                case .propertyMap:
                    // Each property value is itself a schema.
                    childScope = .schema
                }
                encodeJSON(v, scope: childScope, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        case let arr as [Any]:
            out.append(UInt8(ascii: "["))
            var first = true
            for element in arr {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                // Array elements inherit `.schema` (e.g. `anyOf`) but never
                // `.propertyMap`; a plain-scope array stays plain.
                let elementScope: EncodeScope = (scope == .plain) ? .plain : .schema
                encodeJSON(element, scope: elementScope, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case let s as String:
            encodeString(s, into: &out)
        case is NSNull:
            out.append(contentsOf: Array("null".utf8))
        case let n as NSNumber:
            encodeNumber(n, into: &out)
        default:
            // Fallback: round-trip through JSONSerialization for any exotic
            // leaf (should not occur for request bodies).
            if let d = try? JSONSerialization.data(withJSONObject: [value], options: []),
               d.count >= 2 {
                out.append(d.subdata(in: 1..<(d.count - 1)))
            } else {
                out.append(contentsOf: Array("null".utf8))
            }
        }
    }

    private static func encodeNumber(_ n: NSNumber, into out: inout Data) {
        // Match JSONSerialization's bool vs number distinction.
        let typeChar = n.objCType.pointee
        if typeChar == UInt8(ascii: "c") || typeChar == UInt8(ascii: "B") {
            // Could be a bool or a tiny int; treat the canonical Bool bridge.
            if n === (true as NSNumber) || n === (false as NSNumber)
                || CFGetTypeID(n) == CFBooleanGetTypeID() {
                out.append(contentsOf: Array((n.boolValue ? "true" : "false").utf8))
                return
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: [n], options: []),
           d.count >= 2 {
            out.append(d.subdata(in: 1..<(d.count - 1)))
        } else {
            out.append(contentsOf: Array("0".utf8))
        }
    }

    private static func encodeString(_ s: String, into out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: Array("\\\"".utf8))
            case "\\": out.append(contentsOf: Array("\\\\".utf8))
            case "\n": out.append(contentsOf: Array("\\n".utf8))
            case "\r": out.append(contentsOf: Array("\\r".utf8))
            case "\t": out.append(contentsOf: Array("\\t".utf8))
            case "\u{08}": out.append(contentsOf: Array("\\b".utf8))
            case "\u{0C}": out.append(contentsOf: Array("\\f".utf8))
            default:
                if scalar.value < 0x20 {
                    out.append(contentsOf: Array(String(format: "\\u%04x", scalar.value).utf8))
                } else {
                    out.append(contentsOf: Array(String(scalar).utf8))
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    /// Remote `/responses/compact` request (unary POST). Faithful to
    /// `compact_conversation_history`. Streaming uses curl SSE; this unary call
    /// uses `URLSession` (a non-streaming JSON POST works the same on Linux and
    /// macOS, and keeps bearer credentials out of process argv). Returns `nil`
    /// when the provider does not support remote compaction.
    public func compactConversationHistory(_ prompt: Prompt,
                                           _ settings: ModelSettings) async throws
    -> [RemoteCompaction.OutputMessage]? {
        guard provider.supportsRemoteCompaction else { return nil }
        if prompt.input.isEmpty { return [] }

        let body = RemoteCompaction.buildRequestBody(prompt, settings)
        // Byte-deterministic serialization with upstream serde field ordering:
        // sorted top-level/map keys, but tool-definition schema objects keep the
        // canonical `JsonSchema` order (type-first), preserving OpenAI
        // prompt-prefix cache hit-rate parity (audit tools-router).
        let data = try Self.serializeBody(body)
        let responsesURL = explicitEndpoint ?? provider.responsesURL()
        let urlString = RemoteCompaction.compactURL(fromResponsesURL: responsesURL)
        guard let url = URL(string: urlString) else {
            throw ModelError("invalid compact URL: \(urlString)", retryable: false)
        }
        let timeout = TimeInterval(requestTimeoutSeconds)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let authHeader: String? = {
            if let b = explicitBearer { return "Bearer \(b)" }
            return provider.effectiveAuthHeader(env: env)
        }()
        if let auth = authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        for (k, v) in provider.resolvedHeaders(env: env) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let preparedRequest = request

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }
        let respData: Data
        let response: URLResponse
        do {
            (respData, response) = try await session.data(for: preparedRequest)
        } catch {
            throw ModelError("compact request failed: \(error)", retryable: true)
        }
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let bodyStr = String(decoding: respData.prefix(1500), as: UTF8.self)
            throw ModelError(
                "compact HTTP \(http.statusCode): \(bodyStr)",
                retryable: http.statusCode == 429 || http.statusCode >= 500,
                httpStatus: http.statusCode)
        }
        return try RemoteCompaction.parseOutput(respData)
    }

    public func stream(_ prompt: Prompt,
                       _ settings: ModelSettings) async throws -> ResponseStream {
        let body = Self.buildRequestBody(
            prompt, settings,
            maxOutputTokens: maxOutputTokens,
            isAzureResponsesProvider: provider.isAzureResponsesProvider)
        // Byte-deterministic serialization with upstream serde field ordering:
        // sorted top-level/map keys, but tool-definition schema objects keep the
        // canonical `JsonSchema` order (type-first), preserving OpenAI
        // prompt-prefix cache hit-rate parity (audit tools-router).
        let data = try Self.serializeBody(body)
        let cap = streamCapacity
        let url = explicitEndpoint ?? provider.responsesURL()
        let authHeader: String? = {
            if let b = explicitBearer { return "Bearer \(b)" }
            return provider.effectiveAuthHeader(env: env)
        }()
        let extraHeaders = provider.resolvedHeaders(env: env)
        let headerDumpPath = NSTemporaryDirectory()
            + "codexkit-hdr-" + UUID().uuidString
        let curlConfigPath = NSTemporaryDirectory()
            + "codexkit-curl-" + UUID().uuidString
        let tracker = usageTracker
        let timeoutSecs = requestTimeoutSeconds
        // Shared box so the SSE reader can write the server-assigned
        // `x-codex-turn-state` back for the turn loop to replay (upstream
        // OnceLock round-trip, responses.rs:55-62).
        let box = LastResponseBox()

        @Sendable func intOf(_ v: Any?) -> Int {
            if let i = v as? Int { return i }
            if let d = v as? Double { return Int(d) }
            if let n = v as? NSNumber { return n.intValue }
            return 0
        }
        // Distinguishes absent / JSON-null (→ nil) from a present numeric
        // value, matching upstream `Option<i64>`. Used to gate reasoning-delta
        // emission on index presence (`responses.rs:291-305`).
        @Sendable func intIfPresent(_ v: Any?) -> Int? {
            guard let v = v, !(v is NSNull) else { return nil }
            if let i = v as? Int { return i }
            if let n = v as? NSNumber { return n.intValue }
            if let d = v as? Double { return Int(d) }
            return nil
        }

        return StreamMapper.map(capacity: cap, lastResponse: box) {
            AsyncThrowingStream<ResponseEvent, any Error> { cont in
                let recordTelemetry: @Sendable () -> Void = {
                    let dump = (try? String(
                        contentsOfFile: headerDumpPath,
                        encoding: .utf8)) ?? ""
                    // One snapshot per metered family
                    // (`parse_all_rate_limits`, responses.rs:68-70).
                    let snaps = RateLimitSnapshot.parseAllRateLimits(
                        headerDump: dump)
                    if let tracker = tracker, !snaps.isEmpty {
                        Task.detached {
                            for snap in snaps {
                                await tracker.recordRateLimits(snap)
                            }
                        }
                    }
                    // Surface EVERY snapshot as a stream event so the
                    // SessionEngine can forward `account/rateLimits/updated`
                    // (`bespoke_event_handling.rs:1571-1579`) for secondary /
                    // other metered families too — upstream emits one event per
                    // snapshot (`responses.rs:68-70`). Order codex-family first,
                    // then the rest, matching upstream's discovery order.
                    let codexSnaps = snaps.filter { $0.limitId == "codex" }
                    let restSnaps = snaps.filter { $0.limitId != "codex" }
                    for snap in codexSnaps + restSnaps {
                        cont.yield(.rateLimits(snap))
                    }
                    try? FileManager.default.removeItem(
                        atPath: headerDumpPath)
                    try? FileManager.default.removeItem(
                        atPath: curlConfigPath)
                }

                let state = CurlStreamState()
                let proc = state.process
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                let connectTimeout = Swift.max(1, Swift.min(20, timeoutSecs))
                var configLines = [
                    "header = \"Content-Type: application/json\"",
                    "header = \"Accept: text/event-stream\"",
                ]
                if let a = authHeader {
                    configLines.append(
                        "header = \"Authorization: \(Self.curlConfigValue(a))\"")
                }
                if let turnState = settings.turnState {
                    configLines.append(
                        "header = \"x-codex-turn-state: \(Self.curlConfigValue(turnState))\"")
                }
                // Per-turn metadata header (upstream `build_responses_headers`,
                // `client.rs:1651`, inserting `X_CODEX_TURN_METADATA_HEADER` =
                // "x-codex-turn-metadata" when `turn_metadata_header` is `Some`).
                if let turnMetadata = settings.turnMetadata {
                    configLines.append(
                        "header = \"x-codex-turn-metadata: \(Self.curlConfigValue(turnMetadata))\"")
                }
                // Request-correlation / session-continuity headers (upstream
                // `endpoint/responses.rs:91-94` + `build_session_headers`,
                // `requests/headers.rs:5-14`): `x-client-request-id` (= thread
                // id), `session-id` (= session id, falling back to thread id),
                // and `thread-id` (= thread id).
                let sessionIdHeader = settings.sessionId ?? settings.threadId
                configLines.append(
                    "header = \"x-client-request-id: \(Self.curlConfigValue(settings.threadId))\"")
                configLines.append(
                    "header = \"session-id: \(Self.curlConfigValue(sessionIdHeader))\"")
                configLines.append(
                    "header = \"thread-id: \(Self.curlConfigValue(settings.threadId))\"")
                // Sub-agent source routing header (upstream
                // `endpoint/responses.rs:95-97` + `requests/headers.rs:16-31`):
                // review/compact/memory_consolidation/collab_spawn turns carry
                // `x-openai-subagent`; primary turns omit it.
                if let label = settings.subagentLabel, !label.isEmpty {
                    configLines.append(
                        "header = \"x-openai-subagent: \(Self.curlConfigValue(label))\"")
                }
                for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) {
                    configLines.append(
                        "header = \"\(Self.curlConfigValue(k)): \(Self.curlConfigValue(v))\"")
                }
                let curlConfig = configLines.joined(separator: "\n") + "\n"
                do {
                    try curlConfig.write(toFile: curlConfigPath,
                                         atomically: true,
                                         encoding: .utf8)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: curlConfigPath)
                } catch {
                    recordTelemetry()
                    cont.finish(throwing: ModelError(
                        "failed to create curl config: \(error)",
                        retryable: false))
                    return
                }
                var args = ["curl", "-sS", "-N", "--no-buffer",
                            "--connect-timeout", "\(connectTimeout)",
                            "--max-time", "\(timeoutSecs)",
                            "-D", headerDumpPath,
                            "-K", curlConfigPath,
                            "-X", "POST", url]
                args += ["--data-binary", "@-"]
                proc.arguments = args
                let inPipe = Pipe()
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardInput = inPipe
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                cont.onTermination = { _ in
                    state.cancel()
                }
                do {
                    try proc.run()
                } catch {
                    recordTelemetry()
                    cont.finish(throwing: ModelError(
                        "failed to spawn curl: \(error)", retryable: false))
                    return
                }
                inPipe.fileHandleForWriting.write(data)
                try? inPipe.fileHandleForWriting.close()
                let outH = outPipe.fileHandleForReading
                let errH = errPipe.fileHandleForReading
                state.setReadHandles(out: outH, err: errH)
                let reader = Thread {
                    var buf = Data()
                    var sawAny = false
                    var sawCompleted = false
                    var emittedHeaderSignals = false
                    var lastServerModel: String?
                    while true {
                        let chunk = outH.availableData
                        if chunk.isEmpty { break }
                        buf.append(chunk)
                        while let nl = buf.firstIndex(of: 0x0A) {
                            let lineData = buf.subdata(in: buf.startIndex..<nl)
                            buf.removeSubrange(buf.startIndex...nl)
                            guard let raw = String(data: lineData, encoding: .utf8)
                            else { continue }
                            let line = raw.hasSuffix("\r")
                                ? String(raw.dropLast()) : raw
                            guard line.hasPrefix("data:") else { continue }
                            var payload = String(line.dropFirst(5))
                            if payload.hasPrefix(" ") { payload.removeFirst() }
                            if payload.isEmpty || payload == "[DONE]" { continue }
                            guard let pd = payload.data(using: .utf8),
                                  let obj = (try? JSONSerialization.jsonObject(
                                    with: pd)) as? [String: Any] else { continue }
                            sawAny = true
                            // Upstream `ResponsesStreamEvent` has no `error`
                            // field; a stray top-level `{"error":{...}}` frame
                            // with no recognized `type` is ignored and the
                            // stream continues (responses.rs:266-394, `_ =>`
                            // arm). Genuine errors arrive inside `response.failed`
                            // (handled below via classifyResponseFailed). We do
                            // NOT short-circuit the stream on a top-level
                            // `error` key.
                            // Header-derived stream signals are emitted lazily on
                            // the first parsed frame (curl has flushed the `-D`
                            // header dump by now). Mirrors the URLSession path's
                            // pre-body header emission (serverModel / modelsEtag /
                            // serverReasoningIncluded) and the turn-state capture.
                            if !emittedHeaderSignals {
                                emittedHeaderSignals = true
                                let dump = (try? String(
                                    contentsOfFile: headerDumpPath,
                                    encoding: .utf8)) ?? ""
                                let h = ResponsesStreamParsing
                                    .parseHeaderDump(dump)
                                if let model = h[ResponsesStreamParsing
                                    .openAIModelHeader.lowercased()],
                                   !model.isEmpty {
                                    lastServerModel = model
                                    cont.yield(.serverModel(model))
                                }
                                if let etag = h[ResponsesStreamParsing
                                    .xModelsEtagHeader.lowercased()],
                                   !etag.isEmpty {
                                    cont.yield(.modelsEtag(etag))
                                }
                                if h[ResponsesStreamParsing
                                    .xReasoningIncludedHeader.lowercased()]
                                    != nil {
                                    cont.yield(.serverReasoningIncluded(true))
                                }
                                if let ts = h[ResponsesStreamParsing
                                    .xCodexTurnStateHeader.lowercased()],
                                   !ts.isEmpty {
                                    let b = box
                                    Task { await b.setTurnState(ts) }
                                }
                            }
                            // Per-event server-model + verifications
                            // (responses.rs:447-467).
                            if let model = ResponsesStreamParsing
                                .serverModelFromFrame(obj),
                               model != lastServerModel {
                                lastServerModel = model
                                cont.yield(.serverModel(model))
                            }
                            if (obj["type"] as? String) == "response.metadata",
                               let verifs = ResponsesStreamParsing
                                .modelVerificationsFromFrame(obj),
                               !verifs.isEmpty {
                                cont.yield(.modelVerifications(verifs))
                            }
                            let type = obj["type"] as? String ?? ""
                            switch type {
                            case "response.created":
                                // Upstream only emits Created when the frame
                                // carries a `response` object
                                // (`responses.rs:307-311`). A bare
                                // `response.created` without one is ignored.
                                if obj["response"] != nil { cont.yield(.created) }
                            case "response.output_text.delta":
                                let id = obj["item_id"] as? String ?? "msg"
                                let d = obj["delta"] as? String ?? ""
                                // Upstream (`responses.rs:275-279`) emits
                                // whenever `delta` is present, even when empty.
                                cont.yield(.agentDelta(itemId: id, delta: d))
                            case "response.reasoning_text.delta":
                                // Upstream only yields when BOTH delta and
                                // content_index are present (responses.rs:298).
                                let id = obj["item_id"] as? String ?? "reasoning"
                                let d = obj["delta"] as? String ?? ""
                                guard let ci = intIfPresent(obj["content_index"])
                                else { continue }
                                // Upstream emits even for empty deltas; only the
                                // index presence guard is required.
                                cont.yield(.reasoningContentDelta(
                                    itemId: id, delta: d, contentIndex: ci))
                            case "response.reasoning_summary_text.delta":
                                // Upstream only yields when BOTH delta and
                                // summary_index are present (responses.rs:291).
                                let id = obj["item_id"] as? String ?? "reasoning"
                                let d = obj["delta"] as? String ?? ""
                                guard let si = intIfPresent(obj["summary_index"])
                                else { continue }
                                // Upstream emits even for empty deltas; only the
                                // index presence guard is required.
                                cont.yield(.reasoningSummaryDelta(
                                    itemId: id, delta: d, summaryIndex: si))
                            case "response.reasoning_summary_part.added":
                                // Upstream yields only when summary_index is
                                // present (responses.rs:384-387).
                                let id = obj["item_id"] as? String ?? "reasoning"
                                guard let si = intIfPresent(obj["summary_index"])
                                else { continue }
                                cont.yield(.reasoningSummaryPartAdded(
                                    itemId: id, summaryIndex: si))
                            case "response.custom_tool_call_input.delta":
                                // Upstream (`responses.rs:280-289`) has a branch
                                // ONLY for `custom_tool_call_input.delta`; there
                                // is NO branch for `function_call_arguments.delta`
                                // (it falls into the `_ =>` arm and yields
                                // nothing — see `parses_tool_call_input_deltas`,
                                // responses.rs:765-795). It resolves the id as
                                // `item_id ?? call_id`, carries `call_id`, and
                                // emits whenever a resolved id is present —
                                // `Some("")` is still present in Rust, so an
                                // empty-string delta with a valid id still emits.
                                let callId = (obj["call_id"] as? String)
                                    .flatMap { $0.isEmpty ? nil : $0 }
                                let itemId = (obj["item_id"] as? String)
                                    .flatMap { $0.isEmpty ? nil : $0 } ?? callId
                                let d = obj["delta"] as? String ?? ""
                                if let itemId {
                                    cont.yield(.toolCallInputDelta(
                                        itemId: itemId, callId: callId, delta: d))
                                }
                            case "response.output_item.added":
                                if let it = obj["item"] as? [String: Any] {
                                    let id = it["id"] as? String ?? ""
                                    let itype = it["type"] as? String ?? ""
                                    cont.yield(.outputItemAdded(itemId: id, itemType: itype))
                                    // Surface server-side tool items so they are
                                    // not lost (upstream deserializes EVERY
                                    // ResponseItem, responses.rs:376-382).
                                    if let ev = ResponsesStreamParsing
                                        .serverToolItemEvent(it, done: false) {
                                        cont.yield(ev)
                                    }
                                }
                            case "response.output_item.done":
                                if let it = obj["item"] as? [String: Any] {
                                    let itype = it["type"] as? String ?? ""
                                    if itype == "message" {
                                        let id = it["id"] as? String ?? "msg"
                                        var text = ""
                                        if let content = it["content"]
                                            as? [[String: Any]] {
                                            for c in content {
                                                if let s = c["text"] as? String {
                                                    text += s
                                                }
                                            }
                                        }
                                        cont.yield(.agentDone(itemId: id, text: text))
                                    } else if itype == "function_call" {
                                        let callId = it["call_id"]
                                            as? String ?? "call"
                                        let name = it["name"] as? String ?? ""
                                        let args = it["arguments"]
                                            as? String ?? "{}"
                                        cont.yield(.toolCall(callId: callId,
                                                             name: name,
                                                             argumentsJSON: args))
                                    } else if itype == "custom_tool_call" {
                                        // Freeform tool result (e.g.
                                        // apply_patch). `input` is the RAW patch
                                        // envelope, NOT JSON. Route it through
                                        // the generic toolCall contract; the
                                        // handler (ApplyPatchTool) accepts raw
                                        // patch text directly. Upstream item
                                        // shape: {type:"custom_tool_call",
                                        // call_id, name, input}
                                        // (protocol/src/models.rs:824).
                                        let callId = it["call_id"]
                                            as? String ?? "call"
                                        let name = it["name"] as? String ?? ""
                                        let input = it["input"] as? String ?? ""
                                        cont.yield(.toolCall(callId: callId,
                                                             name: name,
                                                             argumentsJSON: input))
                                    } else if itype == "reasoning" {
                                        // Reasoning item carrying encrypted
                                        // chain-of-thought; surface it so the
                                        // turn loop can persist + replay it
                                        // (upstream OutputItemDone(Reasoning),
                                        // responses.rs:267).
                                        let r = ResponsesStreamParsing
                                            .parseReasoningItem(it)
                                        cont.yield(.reasoning(
                                            itemId: r.id, summary: r.summary,
                                            content: r.content,
                                            encryptedContent: r.encryptedContent))
                                    } else if let ev = ResponsesStreamParsing
                                        .serverToolItemEvent(it, done: true) {
                                        // Server-side tool items
                                        // (local_shell_call, web_search_call,
                                        // tool_search_call) — surface rather than
                                        // drop (upstream deserializes EVERY
                                        // ResponseItem, responses.rs:267-274).
                                        cont.yield(ev)
                                    }
                                }
                            case "response.failed":
                                // P6.2 / H-44: classify `error.code` so the
                                // retry / turn loop can branch on
                                // context_window_exceeded, quota_exceeded,
                                // cyber_policy, server_is_overloaded, etc.
                                let resp = obj["response"] as? [String: Any]
                                let err = resp?["error"] as? [String: Any]
                                recordTelemetry()
                                cont.finish(throwing: ModelClientErrorClassifier
                                    .classifyResponseFailed(err))
                                return
                            case "response.incomplete":
                                // P6.2 / H-43 + STATUS.md:624-629: when reason
                                // is `max_output_tokens`, treat as
                                // terminal-completed so the turn keeps its
                                // partial output + accurate usage accounting.
                                // Other reasons (content_filter, etc.) fall
                                // through to the retryable stream-error path.
                                let respIncomplete =
                                    obj["response"] as? [String: Any]
                                if !ModelClientErrorClassifier
                                    .incompleteIsTerminalSuccess(respIncomplete) {
                                    recordTelemetry()
                                    cont.finish(throwing: ModelClientErrorClassifier
                                        .classifyIncomplete(respIncomplete))
                                    return
                                }
                                fallthrough
                            case "response.completed":
                                let resp = obj["response"] as? [String: Any]
                                // Upstream (responses.rs:358-374) requires a
                                // String `id` on response.completed; a missing
                                // one is a fatal stream error. The
                                // response.incomplete max_output_tokens
                                // soft-success fallthrough (documented
                                // divergence, STATUS.md:624-629) has no id, so
                                // synthesize one only there.
                                let isGenuineCompleted =
                                    (obj["type"] as? String) == "response.completed"
                                let parsedId = resp?["id"] as? String
                                if isGenuineCompleted, parsedId == nil {
                                    recordTelemetry()
                                    cont.finish(throwing: ModelError(
                                        "failed to parse ResponseCompleted: missing id",
                                        retryable: true))
                                    return
                                }
                                let id = parsedId ?? "resp"
                                let usage = resp?["usage"] as? [String: Any]
                                let total = intOf(usage?["total_tokens"])
                                let details = usage?["input_tokens_details"]
                                    as? [String: Any]
                                // P2.2 / H-05: extract reasoning token count
                                // from `output_tokens_details.reasoning_tokens`
                                // (OpenAI Responses shape) so the per-call
                                // delta carries the full upstream breakdown.
                                let outputDetails = usage?["output_tokens_details"]
                                    as? [String: Any]
                                let snap = UsageSnapshot(
                                    inputTokens: intOf(usage?["input_tokens"]),
                                    cachedInputTokens: intOf(
                                        details?["cached_tokens"]),
                                    outputTokens: intOf(usage?["output_tokens"]),
                                    reasoningOutputTokens: intOf(
                                        outputDetails?["reasoning_tokens"]),
                                    totalTokens: total)
                                if let tracker = tracker {
                                    Task.detached {
                                        await tracker.recordUsage(snap)
                                    }
                                }
                                // Upstream reads `end_turn` from the
                                // response.completed payload: `Some(false)`
                                // signals the model wants the turn to CONTINUE
                                // (needs_follow_up). Absent → fall back to
                                // "ended" (codex-api/src/sse/responses.rs:365).
                                let endTurn = (resp?["end_turn"] as? Bool) ?? true
                                cont.yield(.completed(responseId: id,
                                                      totalTokens: total,
                                                      endTurn: endTurn,
                                                      usage: snap))
                                sawCompleted = true
                                recordTelemetry()
                                cont.finish()
                                return
                            default:
                                continue
                            }
                        }
                    }
                    state.process.waitUntilExit()
                    if !sawAny {
                        let e = errH.readDataToEndOfFile()
                        let emsg = String(data: e, encoding: .utf8) ?? ""
                        recordTelemetry()
                        cont.finish(throwing: ModelError(
                            "no SSE from OpenAI (exit \(state.process.terminationStatus)): "
                            + "\(emsg.prefix(400))", retryable: false))
                        return
                    }
                    // Frames were seen but the stream closed before any terminal
                    // event (response.completed / .failed / terminal incomplete):
                    // surface a retryable stream error so the turn/retry loop
                    // reacts, matching upstream's "stream closed before
                    // response.completed" (responses.rs:422-428).
                    if !sawCompleted {
                        recordTelemetry()
                        cont.finish(throwing: ModelError(
                            "stream closed before response.completed",
                            retryable: true))
                        return
                    }
                    recordTelemetry()
                    cont.finish()
                }
                reader.stackSize = 1 << 20
                reader.name = "openai-sse-reader"
                reader.start()
            }
        }
    }
}
