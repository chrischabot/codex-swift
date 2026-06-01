import Foundation
import InfraPrimitives

#if canImport(Network)
import Network

private final class WebSocketStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

/// Reference holder for the last server-effective model emitted on the WS
/// stream, so the per-frame dedupe survives across the `@Sendable mapEvent`
/// closure invocations (mirrors the HTTP transports' `lastServerModel`).
private final class LastServerModelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Production Responses-over-WebSocket transport (Codex `ws://` / UDS-WebSocket
/// data path). This is the macOS completion of the model transport
/// (STATUS.md P2-M1): on Apple it speaks the Responses API over a
/// `URLSessionWebSocketTask`, sending a `response.create` event as the opening
/// text frame and reading one JSON event per frame. The create payload,
/// `prompt_cache_key`, sticky turn-state, and `previous_response_id` share the
/// same construction as the portable `OpenAIResponsesClient`; WS-only framing
/// strips HTTP/SSE transport fields such as `stream`. The portable Linux build never compiles this file (no
/// `Network`); `OpenAIResponsesClient` (curl SSE) remains the portable client.
///
/// MACOS-COMPLETION: P2-M1 — incremental WS-delta is layered on this seam; the
/// v2 beta handshake, prewarm request shape, explicit no-zstd negotiation,
/// attestation header, 401→auth refresh wrapper, event mapping, and caching
/// contract below are complete/tested.
public actor WebSocketResponsesClient: ModelClient {
    public typealias AttestationProvider = @Sendable (_ threadId: String) async -> String?

    public struct Options: Sendable, Equatable {
        public var prewarm: Bool
        public var explicitNoZstd: Bool
        public init(prewarm: Bool = false, explicitNoZstd: Bool = true) {
            self.prewarm = prewarm
            self.explicitNoZstd = explicitNoZstd
        }
    }

    public struct RequestPlan: Sendable, Equatable {
        public var headers: [String: String]
        public var prewarmJSON: String?
        public var requestJSON: String
    }

    public static let betaHeaderValue = "responses_websockets=2026-02-06"
    public static let createEventType = "response.create"

    private let apiKey: String
    private let endpoint: URL
    private let maxOutputTokens: Int?
    private let streamCapacity: Int
    private let turnDeadline: Duration
    private let options: Options
    private let attestationProvider: AttestationProvider?

    public init(apiKey: String,
                endpoint: String = "wss://api.openai.com/v1/responses",
                maxOutputTokens: Int? = nil,
                limits: Limits = Limits(),
                options: Options = Options(),
                attestationProvider: AttestationProvider? = nil) {
        self.apiKey = apiKey
        self.endpoint = URL(string: endpoint)
            ?? URL(string: "wss://api.openai.com/v1/responses")!
        self.maxOutputTokens = maxOutputTokens
        let clamped = limits.clamped()
        self.streamCapacity = clamped.dataChannelDepth
        self.turnDeadline = clamped.turnDeadline
        self.options = options
        self.attestationProvider = attestationProvider
    }

    public static func buildRequestPlan(
        prompt: Prompt,
        settings: ModelSettings,
        apiKey: String,
        maxOutputTokens: Int?,
        options: Options = Options(),
        attestationHeader: String? = nil
    ) throws -> RequestPlan {
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: maxOutputTokens)
        let requestEvent = websocketCreateEvent(from: body)
        let requestJSON = try canonicalJSONString(requestEvent)
        var prewarmJSON: String?
        if options.prewarm {
            var prewarm = requestEvent
            prewarm["generate"] = false
            prewarmJSON = try canonicalJSONString(prewarm)
        }

        var headers: [String: String] = [
            "Authorization": "Bearer \(apiKey)",
            "OpenAI-Beta": betaHeaderValue,
        ]
        if options.explicitNoZstd {
            headers["Accept-Encoding"] = "identity"
        }
        if let turnState = settings.turnState {
            headers["x-codex-turn-state"] = turnState
        }
        // Per-turn metadata header (upstream `build_ws_client_metadata`,
        // `client.rs:648-655`, inserting `X_CODEX_TURN_METADATA_HEADER` =
        // "x-codex-turn-metadata" when `turn_metadata_header` is `Some`).
        if let turnMetadata = settings.turnMetadata {
            headers["x-codex-turn-metadata"] = turnMetadata
        }
        // Sub-agent source routing header (upstream
        // `endpoint/responses.rs:95-97` + `requests/headers.rs:16-31`):
        // review/compact/memory_consolidation/collab_spawn turns carry
        // `x-openai-subagent`; primary turns omit it.
        if let label = settings.subagentLabel, !label.isEmpty {
            headers["x-openai-subagent"] = label
        }
        if let attestationHeader, !attestationHeader.isEmpty {
            headers["x-oai-attestation"] = attestationHeader
        }
        return RequestPlan(headers: headers,
                           prewarmJSON: prewarmJSON,
                           requestJSON: requestJSON)
    }

    private static func canonicalJSONString(_ object: [String: Any]) throws -> String {
        // Upstream serde field ordering: sorted top-level/map keys, but
        // tool-definition schema objects keep the canonical `JsonSchema` order
        // (type-first) for OpenAI prompt-prefix cache parity (audit tools-router).
        let data = try OpenAIResponsesClient.serializeBody(object)
        return String(decoding: data, as: UTF8.self)
    }

    private static func websocketCreateEvent(from responseBody: [String: Any]) -> [String: Any] {
        var event = responseBody
        event["type"] = createEventType
        // Upstream's `ResponseCreateWsRequest` (codex-api/src/common.rs:216-240)
        // carries `pub stream: bool` with NO skip_serializing_if and copies it
        // from the request, so the WS create/prewarm payload always serializes
        // `"stream": true`. Keep it; remove only `background`, which upstream
        // never sets on the WS create event.
        event.removeValue(forKey: "background")
        return event
    }

    /// Remote `/responses/compact` request. Upstream's
    /// `compact_conversation_history` always uses the HTTP (`ReqwestTransport`)
    /// path — never the WebSocket — so even WS-streaming sessions issue the
    /// compact call over HTTPS. We mirror that: derive the HTTPS responses URL
    /// from the `wss://…/responses` endpoint, swap in `/responses/compact`, and
    /// POST the `CompactionInput` body. The built-in OpenAI WS endpoint always
    /// supports remote compaction, so no extra capability gate is needed here.
    public func compactConversationHistory(_ prompt: Prompt,
                                           _ settings: ModelSettings) async throws
    -> [RemoteCompaction.OutputMessage]? {
        if prompt.input.isEmpty { return [] }
        // wss://host/v1/responses → https://host/v1/responses/compact
        var httpURLString = endpoint.absoluteString
        if httpURLString.hasPrefix("wss://") {
            httpURLString = "https://" + httpURLString.dropFirst("wss://".count)
        } else if httpURLString.hasPrefix("ws://") {
            httpURLString = "http://" + httpURLString.dropFirst("ws://".count)
        }
        let compactURLString = RemoteCompaction.compactURL(
            fromResponsesURL: httpURLString)
        guard let url = URL(string: compactURLString) else {
            throw ModelError("invalid compact URL: \(compactURLString)",
                             retryable: false)
        }
        let body = RemoteCompaction.buildRequestBody(prompt, settings)
        let data = try JSONSerialization.data(withJSONObject: body)
        let timeout = Swift.max(1.0, turnDeadline.seconds)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }
        let respData: Data
        let response: URLResponse
        do {
            (respData, response) = try await session.data(for: request)
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
        let attestation = await attestationProvider?(settings.threadId)
        let plan = try Self.buildRequestPlan(prompt: prompt,
                                             settings: settings,
                                             apiKey: apiKey,
                                             maxOutputTokens: maxOutputTokens,
                                             options: options,
                                             attestationHeader: attestation)
        let key = apiKey
        let url = endpoint
        let cap = streamCapacity
        let headers = plan.headers
        let prewarmJSON = plan.prewarmJSON
        let requestJSON = plan.requestJSON
        let timeout = Swift.max(1.0, turnDeadline.seconds)

        return StreamMapper.map(capacity: cap) {
            AsyncThrowingStream<ResponseEvent, any Error> { cont in
                var req = URLRequest(url: url)
                req.timeoutInterval = timeout
                for (name, value) in headers {
                    req.setValue(value, forHTTPHeaderField: name)
                }
                let session = URLSession(configuration: .ephemeral)
                let task = session.webSocketTask(with: req)
                _ = key
                let state = WebSocketStreamState()
                // Tracks the last server-effective model so per-frame
                // `response.headers` updates are deduped (upstream
                // `last_server_model`, responses.rs:447-459). A reference box
                // keeps the value alive across the @Sendable mapEvent calls.
                let serverModelBox = LastServerModelBox()

                @Sendable func finish(_ error: (any Error)? = nil) {
                    state.markFinished()
                    if let error {
                        cont.finish(throwing: error)
                    } else {
                        cont.finish()
                    }
                }

                @Sendable func mapEvent(_ obj: [String: Any],
                                        suppressEvents: Bool) -> Bool {
                    if let err = obj["error"] as? [String: Any] {
                        let msg = (err["message"] as? String) ?? "OpenAI error"
                        finish(ModelError(msg,
                                          retryable: Self.isRetryableWebSocketProtocolError(msg)))
                        return true
                    }
                    // Per-frame server-model dedupe + verification signals
                    // (upstream responses.rs:447-467) — mirror the HTTP
                    // transports so backend safety-routing model changes and
                    // model-verification recommendations surface on WS too.
                    if !suppressEvents,
                       let model = ResponsesStreamParsing.serverModelFromFrame(obj),
                       model != serverModelBox.value {
                        serverModelBox.value = model
                        cont.yield(.serverModel(model))
                    }
                    if !suppressEvents,
                       (obj["type"] as? String) == "response.metadata",
                       let verifs = ResponsesStreamParsing.modelVerificationsFromFrame(obj),
                       !verifs.isEmpty {
                        cont.yield(.modelVerifications(verifs))
                    }
                    switch obj["type"] as? String ?? "" {
                    case "response.created":
                        // Upstream only emits Created when the frame carries a
                        // `response` object (`responses.rs:307-311`).
                        if !suppressEvents, obj["response"] != nil {
                            cont.yield(.created)
                        }
                    case "response.output_text.delta":
                        let id = obj["item_id"] as? String ?? "msg"
                        let d = obj["delta"] as? String ?? ""
                        if !suppressEvents, !d.isEmpty {
                            cont.yield(.agentDelta(itemId: id, delta: d))
                        }
                    case "response.reasoning_text.delta":
                        let id = obj["item_id"] as? String ?? "reasoning"
                        let d = obj["delta"] as? String ?? ""
                        if !suppressEvents, !d.isEmpty {
                            cont.yield(.reasoningContentDelta(
                                itemId: id, delta: d, contentIndex: intField(obj["content_index"])))
                        }
                    case "response.reasoning_summary_text.delta":
                        let id = obj["item_id"] as? String ?? "reasoning"
                        let d = obj["delta"] as? String ?? ""
                        if !suppressEvents, !d.isEmpty {
                            cont.yield(.reasoningSummaryDelta(
                                itemId: id, delta: d, summaryIndex: intField(obj["summary_index"])))
                        }
                    case "response.reasoning_summary_part.added":
                        let id = obj["item_id"] as? String ?? "reasoning"
                        if !suppressEvents {
                            cont.yield(.reasoningSummaryPartAdded(
                                itemId: id, summaryIndex: intField(obj["summary_index"])))
                        }
                    case "response.custom_tool_call_input.delta":
                        // Upstream (`responses.rs:280-289`) has a branch ONLY
                        // for `custom_tool_call_input.delta`; there is NO branch
                        // for `function_call_arguments.delta` (it falls into the
                        // `_ =>` arm and yields nothing — see
                        // `parses_tool_call_input_deltas`, responses.rs:765-795).
                        // It resolves the id as `item_id ?? call_id`, carries
                        // `call_id`, and emits whenever a resolved id is present
                        // — `Some("")` is still present in Rust, so an
                        // empty-string delta with a valid id still emits.
                        let callId = (obj["call_id"] as? String)
                            .flatMap { $0.isEmpty ? nil : $0 }
                        let itemId = (obj["item_id"] as? String)
                            .flatMap { $0.isEmpty ? nil : $0 } ?? callId
                        let d = obj["delta"] as? String ?? ""
                        if !suppressEvents, let itemId {
                            cont.yield(.toolCallInputDelta(
                                itemId: itemId, callId: callId, delta: d))
                        }
                    case "response.output_item.added":
                        if !suppressEvents, let it = obj["item"] as? [String: Any] {
                            cont.yield(.outputItemAdded(itemId: it["id"] as? String ?? "",
                                                        itemType: it["type"] as? String ?? ""))
                            // Surface server-side tool items (local_shell_call /
                            // web_search_call / tool_search_call) for parity with
                            // upstream's full ResponseItem coverage
                            // (responses.rs:376-382).
                            if let ev = ResponsesStreamParsing
                                .serverToolItemEvent(it, done: false) {
                                cont.yield(ev)
                            }
                        }
                    case "response.output_item.done":
                        if !suppressEvents, let it = obj["item"] as? [String: Any] {
                            let itype = it["type"] as? String ?? ""
                            if itype == "message" {
                                let id = it["id"] as? String ?? "msg"
                                var text = ""
                                if let content = it["content"] as? [[String: Any]] {
                                    for c in content {
                                        if let s = c["text"] as? String { text += s }
                                    }
                                }
                                cont.yield(.agentDone(itemId: id, text: text))
                            } else if itype == "function_call" {
                                let callId = it["call_id"] as? String ?? "call"
                                let name = it["name"] as? String ?? ""
                                let args = it["arguments"] as? String ?? "{}"
                                cont.yield(.toolCall(callId: callId, name: name,
                                                     argumentsJSON: args))
                            } else if itype == "custom_tool_call" {
                                // Freeform tool result (apply_patch): `input` is
                                // the RAW patch envelope, not JSON. Route via the
                                // generic toolCall contract. Upstream item shape
                                // protocol/src/models.rs:824.
                                let callId = it["call_id"] as? String ?? "call"
                                let name = it["name"] as? String ?? ""
                                let input = it["input"] as? String ?? ""
                                cont.yield(.toolCall(callId: callId, name: name,
                                                     argumentsJSON: input))
                            } else if itype == "reasoning" {
                                // Reasoning item carrying encrypted
                                // chain-of-thought; surface it so the turn loop
                                // can persist + replay it across turns (upstream
                                // OutputItemDone(ResponseItem::Reasoning),
                                // responses.rs:267). Without this the WS
                                // transport silently drops encrypted reasoning,
                                // diverging from the HTTP transports.
                                let r = ResponsesStreamParsing.parseReasoningItem(it)
                                cont.yield(.reasoning(
                                    itemId: r.id, summary: r.summary,
                                    content: r.content,
                                    encryptedContent: r.encryptedContent))
                            } else if let ev = ResponsesStreamParsing
                                .serverToolItemEvent(it, done: true) {
                                // Server-side tool items — surface rather than
                                // drop (upstream deserializes EVERY ResponseItem,
                                // responses.rs:267-274).
                                cont.yield(ev)
                            }
                        }
                    case "response.failed":
                        // P6.2 / H-44: classify upstream `error.code` so the
                        // retry / turn loop can branch on stable Codex
                        // identifiers (context_window_exceeded,
                        // quota_exceeded, cyber_policy, server_is_overloaded,
                        // ...).
                        let resp = obj["response"] as? [String: Any]
                        let err = resp?["error"] as? [String: Any]
                        finish(ModelClientErrorClassifier
                            .classifyResponseFailed(err))
                        return true
                    case "response.incomplete":
                        // P6.2 / H-43 + STATUS.md:624-629: WS path mirrors
                        // HTTP — `max_output_tokens` is soft-success (yield
                        // .completed with partial usage). Any other reason
                        // (content_filter, etc.) still throws retryable.
                        let respIncomplete = obj["response"] as? [String: Any]
                        if !ModelClientErrorClassifier
                            .incompleteIsTerminalSuccess(respIncomplete) {
                            finish(ModelClientErrorClassifier
                                .classifyIncomplete(respIncomplete))
                            return true
                        }
                        fallthrough
                    case "response.completed":
                        let resp = obj["response"] as? [String: Any]
                        // Upstream (`responses.rs:358-374`) deserializes
                        // `response` into `ResponseCompleted{ id: String
                        // (required), ... }` and returns a stream error when it
                        // fails — a missing `id` is fatal. The WS path uses the
                        // SAME `process_responses_event`
                        // (responses_websocket.rs:9-10,745), so we mirror that
                        // for genuine `response.completed` frames. The
                        // `response.incomplete` → max_output_tokens soft-success
                        // fallthrough is a documented codex-swift divergence
                        // (STATUS.md:624-629): that payload has no `id`, so we
                        // synthesize one there rather than erroring.
                        let isGenuineCompleted =
                            (obj["type"] as? String) == "response.completed"
                        let parsedId = resp?["id"] as? String
                        if isGenuineCompleted, parsedId == nil {
                            finish(ModelError(
                                "failed to parse ResponseCompleted: missing id",
                                retryable: true))
                            return true
                        }
                        let id = parsedId ?? "resp"
                        let usage = resp?["usage"] as? [String: Any]
                        let total = (usage?["total_tokens"] as? Int)
                            ?? Int((usage?["total_tokens"] as? Double) ?? 0)
                        let details = usage?["input_tokens_details"] as? [String: Any]
                        // P2.2 / H-05: reasoning-token breakdown.
                        let outputDetails = usage?["output_tokens_details"] as? [String: Any]
                        let snap = UsageSnapshot(
                            inputTokens: (usage?["input_tokens"] as? Int) ?? 0,
                            cachedInputTokens: (details?["cached_tokens"] as? Int) ?? 0,
                            outputTokens: (usage?["output_tokens"] as? Int) ?? 0,
                            reasoningOutputTokens: (outputDetails?["reasoning_tokens"] as? Int) ?? 0,
                            totalTokens: total)
                        if !suppressEvents {
                            // `end_turn: Some(false)` signals continuation;
                            // absent → ended (upstream fallback).
                            let endTurn = (resp?["end_turn"] as? Bool) ?? true
                            cont.yield(.completed(responseId: id, totalTokens: total,
                                                  endTurn: endTurn, usage: snap))
                            finish()
                        }
                        return true
                    default:
                        break
                    }
                    return false
                }

                @Sendable func receiveLoop(suppressEvents: Bool,
                                           onComplete: @escaping @Sendable () -> Void) {
                    task.receive { result in
                        switch result {
                        case .failure(let e):
                            finish(ModelError(
                                "websocket receive failed: \(e)", retryable: true))
                        case .success(let message):
                            let text: String
                            switch message {
                            case .string(let s): text = s
                            case .data(let d): text = String(decoding: d, as: UTF8.self)
                            @unknown default: text = ""
                            }
                            var done = false
                            if let pd = text.data(using: .utf8),
                               let obj = (try? JSONSerialization.jsonObject(with: pd))
                                as? [String: Any] {
                                done = mapEvent(obj, suppressEvents: suppressEvents)
                            } else {
                                finish(ModelError(
                                    "websocket received non-JSON frame",
                                    retryable: true))
                                return
                            }
                            if done {
                                onComplete()
                            } else {
                                receiveLoop(suppressEvents: suppressEvents,
                                            onComplete: onComplete)
                            }
                        }
                    }
                }

                @Sendable func sendRequest(_ json: String,
                                           suppressEvents: Bool,
                                           onComplete: @escaping @Sendable () -> Void) {
                    task.send(.string(json)) { err in
                        if let err {
                            finish(ModelError(
                                "websocket send failed: \(err)", retryable: true))
                            return
                        }
                        receiveLoop(suppressEvents: suppressEvents,
                                    onComplete: onComplete)
                    }
                }

                cont.onTermination = { _ in
                    if state.isFinished {
                        session.finishTasksAndInvalidate()
                    } else {
                        task.cancel(with: .goingAway, reason: nil)
                        session.invalidateAndCancel()
                    }
                }
                task.resume()
                if let prewarmJSON {
                    sendRequest(prewarmJSON, suppressEvents: true) {
                        sendRequest(requestJSON, suppressEvents: false) {}
                    }
                } else {
                    sendRequest(requestJSON, suppressEvents: false) {}
                }
            }
        }
    }

    private static func isRetryableWebSocketProtocolError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("websocket")
            || lower.contains("response.create")
            || lower.contains("response.create message")
    }
}

/// Tolerant Int extraction (Int or Double) for SSE numeric fields.
private func intField(_ v: Any?) -> Int {
    if let i = v as? Int { return i }
    if let d = v as? Double { return Int(d) }
    return 0
}
#endif
