import Foundation
import InfraPrimitives

#if os(macOS)

/// Native macOS Responses API SSE client.
///
/// This uses `URLSession` instead of spawning `curl`, so bearer credentials
/// live in request headers rather than process argv. It shares the exact
/// request-body builder with `OpenAIResponsesClient`, preserving
/// `prompt_cache_key`, transcript, tool schema, and `previous_response_id`
/// semantics across the portable and native transports.
public actor URLSessionResponsesClient: ModelClient {
    private let provider: ModelProvider
    private let env: [String: String]
    private let usageTracker: UsageTracker?
    private let explicitEndpoint: String?
    private let explicitBearer: String?
    private let maxOutputTokens: Int?
    private let streamCapacity: Int
    private let timeoutInterval: TimeInterval

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
        self.timeoutInterval = Self.timeoutInterval(from: clamped)
    }

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
        self.timeoutInterval = Self.timeoutInterval(from: clamped)
    }

    private static func timeoutInterval(from limits: Limits) -> TimeInterval {
        Swift.max(1, Swift.min(limits.turnDeadline.seconds, 24 * 3600))
    }

    public func stream(_ prompt: Prompt,
                       _ settings: ModelSettings) async throws -> ResponseStream {
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: maxOutputTokens,
            isAzureResponsesProvider: provider.isAzureResponsesProvider)
        let data = try JSONSerialization.data(withJSONObject: body)
        let urlString = explicitEndpoint ?? provider.responsesURL()
        guard let url = URL(string: urlString) else {
            throw ModelError("invalid Responses URL: \(urlString)", retryable: false)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let auth = explicitBearer.map({ "Bearer \($0)" })
            ?? provider.effectiveAuthHeader(env: env) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let turnState = settings.turnState {
            request.setValue(turnState, forHTTPHeaderField: "x-codex-turn-state")
        }
        // Per-turn metadata header (upstream `build_responses_headers`,
        // `client.rs:1651`, inserting `X_CODEX_TURN_METADATA_HEADER` =
        // "x-codex-turn-metadata" when `turn_metadata_header` is `Some`).
        if let turnMetadata = settings.turnMetadata {
            request.setValue(turnMetadata, forHTTPHeaderField: "x-codex-turn-metadata")
        }
        // Request-correlation / session-continuity headers (upstream
        // `endpoint/responses.rs:91-94` + `build_session_headers`,
        // `requests/headers.rs:5-14`): every REST Responses stream carries
        // `x-client-request-id` (= thread id), `session-id` (= session id), and
        // `thread-id` (= thread id). The port keys the session id off
        // `settings.sessionId`, falling back to `threadId` when the caller did
        // not thread a distinct session id, so the correlation headers are
        // always populated.
        let sessionIdHeader = settings.sessionId ?? settings.threadId
        request.setValue(settings.threadId,
                         forHTTPHeaderField: "x-client-request-id")
        request.setValue(sessionIdHeader, forHTTPHeaderField: "session-id")
        request.setValue(settings.threadId, forHTTPHeaderField: "thread-id")
        // Sub-agent source routing header (upstream
        // `endpoint/responses.rs:95-97` + `requests/headers.rs:16-31`): when
        // the turn originates from a sub-agent (review/compact/
        // memory_consolidation/collab_spawn), attach `x-openai-subagent` so the
        // backend can route/meter it distinctly. Omitted for primary turns.
        if let label = settings.subagentLabel, !label.isEmpty {
            request.setValue(label, forHTTPHeaderField: "x-openai-subagent")
        }
        for (k, v) in provider.resolvedHeaders(env: env) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let preparedRequest = request

        let cap = streamCapacity
        let tracker = usageTracker
        let timeout = timeoutInterval
        let idleTimeout = provider.streamIdleTimeout
        // Shared box so the SSE reader can write the server-assigned
        // `x-codex-turn-state` back for the turn loop to replay on the next
        // request (upstream OnceLock round-trip, responses.rs:55-62).
        let box = LastResponseBox()
        return StreamMapper.map(capacity: cap, lastResponse: box) {
            AsyncThrowingStream<ResponseEvent, any Error> { cont in
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = timeout
                config.timeoutIntervalForResource = timeout
                let session = URLSession(configuration: config)
                let task = Task {
                    await Self.readSSE(request: preparedRequest,
                                       session: session,
                                       tracker: tracker,
                                       lastResponse: box,
                                       idleTimeout: idleTimeout,
                                       continuation: cont)
                }
                cont.onTermination = { _ in
                    task.cancel()
                    session.invalidateAndCancel()
                }
            }
        }
    }

    /// Remote `/responses/compact` request (unary POST). Faithful to
    /// `compact_conversation_history`: derives the `CompactionInput` body from
    /// the same prompt/settings, POSTs it to `…/responses/compact`, and decodes
    /// `{ output: [ResponseItem] }`. Returns `nil` when the provider does not
    /// support remote compaction so the engine falls back to local compaction.
    public func compactConversationHistory(_ prompt: Prompt,
                                           _ settings: ModelSettings) async throws
    -> [RemoteCompaction.OutputMessage]? {
        guard provider.supportsRemoteCompaction else { return nil }
        // Upstream returns an empty transcript without a network round-trip when
        // the input is empty (`client.rs:441-443`).
        if prompt.input.isEmpty { return [] }

        let body = RemoteCompaction.buildRequestBody(prompt, settings)
        let data = try JSONSerialization.data(withJSONObject: body)
        let responsesURL = explicitEndpoint ?? provider.responsesURL()
        let urlString = RemoteCompaction.compactURL(fromResponsesURL: responsesURL)
        guard let url = URL(string: urlString) else {
            throw ModelError("invalid compact URL: \(urlString)", retryable: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = explicitBearer.map({ "Bearer \($0)" })
            ?? provider.effectiveAuthHeader(env: env) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        for (k, v) in provider.resolvedHeaders(env: env) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let preparedRequest = request

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = timeoutInterval
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (respData, response): (Data, URLResponse)
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

    private static func readSSE(
        request: URLRequest,
        session: URLSession,
        tracker: UsageTracker?,
        lastResponse: LastResponseBox,
        idleTimeout: Duration,
        continuation cont: AsyncThrowingStream<ResponseEvent, any Error>.Continuation
    ) async {
        defer { session.finishTasksAndInvalidate() }
        // Tracks the last server-effective model emitted so per-event
        // `response.headers` updates are deduped (upstream `last_server_model`,
        // responses.rs:447-459).
        var lastServerModel: String?
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                // Upstream emits one RateLimits event per metered family
                // (`parse_all_rate_limits` → one event per snapshot,
                // responses.rs:68-70). Record each discovered family and surface
                // EVERY snapshot as a `.rateLimits` event so the SessionEngine
                // can forward `account/rateLimits/updated`
                // (`bespoke_event_handling.rs:1571-1579`) for secondary / other
                // metered families too, not just the primary `codex` family.
                let snaps = orderedRateLimits(from: http)
                for snap in snaps {
                    await tracker?.recordRateLimits(snap)
                }
                // Pre-body header signals, emitted in upstream's exact order
                // (responses.rs:64-78): ServerModel, RateLimits, ModelsEtag,
                // ServerReasoningIncluded; and the `x-codex-turn-state`
                // round-trip capture.
                if (200..<300).contains(http.statusCode) {
                    if let model = headerValue(
                        ResponsesStreamParsing.openAIModelHeader, in: http),
                       !model.isEmpty {
                        // Emit the header-derived ServerModel but do NOT seed
                        // `lastServerModel`: upstream's `process_sse` starts
                        // with `last_server_model: None` (responses.rs:407),
                        // independent of the header emission during spawn
                        // (responses.rs:41-67). So an in-stream
                        // `response.headers` frame carrying the SAME model emits
                        // ServerModel a second time. Leave it nil to match.
                        cont.yield(.serverModel(model))
                    }
                    // One event per snapshot, codex family first (matching
                    // `orderedRateLimits`' discovery order), then the rest.
                    for snap in snaps {
                        cont.yield(.rateLimits(snap))
                    }
                    if let etag = headerValue(
                        ResponsesStreamParsing.xModelsEtagHeader, in: http),
                       !etag.isEmpty {
                        cont.yield(.modelsEtag(etag))
                    }
                    if headerValue(
                        ResponsesStreamParsing.xReasoningIncludedHeader,
                        in: http) != nil {
                        cont.yield(.serverReasoningIncluded(true))
                    }
                    if let ts = headerValue(
                        ResponsesStreamParsing.xCodexTurnStateHeader, in: http),
                       !ts.isEmpty {
                        await lastResponse.setTurnState(ts)
                    }
                }
                guard (200..<300).contains(http.statusCode) else {
                    let retryAfter = retryAfterDuration(from: http)
                    // Capture the error body so the diagnostic isn't lost.
                    var bodyBytes: [UInt8] = []
                    for try await b in bytes {
                        bodyBytes.append(b)
                        if bodyBytes.count > 4096 { break }
                    }
                    let bodyStr = String(decoding: bodyBytes, as: UTF8.self)
                        .prefix(1500)
                    FileHandle.standardError.write(Data(
                        "[catscan] OpenAI HTTP \(http.statusCode) body: \(bodyStr)\n".utf8))
                    cont.finish(throwing: ModelError(
                        "OpenAI HTTP \(http.statusCode): \(bodyStr)",
                        retryable: http.statusCode == 429 || http.statusCode >= 500,
                        httpStatus: http.statusCode,
                        retryAfter: retryAfter))
                    return
                }
            }

            var sawAny = false
            let iterBox = ByteIteratorBox(bytes.makeAsyncIterator())
            // Read the SSE stream a LINE at a time. The newline IS the line
            // terminator, so the line buffer never needs scanning, and we race
            // each LINE (not each byte) against the idle deadline. The previous
            // per-byte version was O(n²) — it re-scanned the whole growing buffer
            // with `Data.firstIndex(of: 0x0A)` after every appended byte — AND
            // spun up a task-group timer per byte. On long reasoning streams that
            // pinned a CPU core and choked event delivery, which presented as the
            // model "stalling" mid-turn and turns that never completed.
            while true {
                try Task.checkCancellation()
                let lineBytes: [UInt8]?
                do {
                    lineBytes = try await Self.readLine(iterBox, idleTimeout: idleTimeout)
                } catch is IdleTimeout {
                    cont.finish(throwing: ModelError(
                        "idle timeout waiting for SSE", retryable: true))
                    return
                }
                guard let lb = lineBytes else { break }          // EOF
                let line = String(decoding: lb, as: UTF8.self)   // trailing CR already stripped
                guard line.hasPrefix("data:") else { continue }
                var payload = String(line.dropFirst(5))
                if payload.hasPrefix(" ") { payload.removeFirst() }
                if payload.isEmpty || payload == "[DONE]" { continue }
                guard let pd = payload.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: pd))
                        as? [String: Any] else {
                    continue
                }
                sawAny = true
                if await mapEvent(obj, tracker: tracker,
                                  lastServerModel: &lastServerModel,
                                  continuation: cont) {
                    // mapEvent finished the stream itself (terminal event:
                    // completed / failed / incomplete). It already called
                    // cont.finish, so we just stop reading.
                    return
                }
            }
            guard sawAny else {
                cont.finish(throwing: ModelError("no SSE from OpenAI",
                                                 retryable: false))
                return
            }
            // We only reach here after the byte stream ended (EOF) WITHOUT a
            // terminal event — a terminal event (completed/failed/incomplete)
            // returns early above. Surface a retryable stream error so the
            // turn/retry loop reacts, matching upstream's "stream closed before
            // response.completed".
            cont.finish(throwing: ModelError(
                "stream closed before response.completed", retryable: true))
        } catch is CancellationError {
            cont.finish()
        } catch let e as ModelError {
            cont.finish(throwing: e)
        } catch {
            cont.finish(throwing: ModelError(
                "URLSession SSE failed: \(error)", retryable: true))
        }
    }

    /// Sentinel thrown by `withIdleTimeout` when the per-event SSE idle
    /// deadline elapses before the next byte arrives.
    private struct IdleTimeout: Error {}

    /// Mutable byte iterator wrapped for use across the idle-timeout task race.
    /// Only the reader child task ever touches `next()`, so the shared mutable
    /// state is sound despite `@unchecked Sendable`.
    private final class ByteIteratorBox: @unchecked Sendable {
        var iterator: URLSession.AsyncBytes.AsyncIterator
        init(_ iterator: URLSession.AsyncBytes.AsyncIterator) {
            self.iterator = iterator
        }
        func next() async throws -> UInt8? { try await iterator.next() }
    }

    /// Reads ONE SSE line (bytes up to, but excluding, '\n'; a trailing '\r' is
    /// stripped) and races the whole line read against the idle deadline. Throws
    /// `IdleTimeout` when the deadline elapses before the line completes; returns
    /// `nil` at end of stream (any unterminated trailing partial is dropped, as
    /// the previous newline-delimited parser did). Mirrors upstream's
    /// `timeout(idle_timeout, stream.next())` (responses.rs:410-434) but at line
    /// granularity, so a long stream creates one timer per line instead of one
    /// per byte, and the line is built incrementally with no buffer scan.
    private static func readLine(
        _ box: ByteIteratorBox,
        idleTimeout: Duration
    ) async throws -> [UInt8]? {
        try await withThrowingTaskGroup(of: [UInt8]?.self) { group in
            group.addTask {
                var line: [UInt8] = []
                while let b = try await box.next() {
                    if b == 0x0A {                              // newline terminates the line
                        if line.last == 0x0D { line.removeLast() }   // strip trailing CR
                        return line
                    }
                    line.append(b)
                }
                return nil                                      // EOF — drop any partial line
            }
            group.addTask {
                try await Task.sleep(for: idleTimeout)
                throw IdleTimeout()
            }
            defer { group.cancelAll() }
            // First child wins; the loser is cancelled by the defer. A thrown
            // IdleTimeout / CancellationError propagates.
            let result = try await group.next()
            return result ?? nil
        }
    }

    private static func mapEvent(
        _ obj: [String: Any],
        tracker: UsageTracker?,
        lastServerModel: inout String?,
        continuation cont: AsyncThrowingStream<ResponseEvent, any Error>.Continuation
    ) async -> Bool {
        // Upstream `ResponsesStreamEvent` has NO `error` field; a stray
        // top-level `{"error":{...}}` data frame with no recognized `type`
        // falls into `process_responses_event`'s `_ =>` arm — it is logged as
        // `trace!("unhandled")` and returns `Ok(None)`, i.e. ignored, and the
        // stream continues (responses.rs:266-394). We mirror that tolerance:
        // do NOT short-circuit the whole stream on a top-level `error` key.
        // Genuine errors arrive inside `response.failed` (handled below via
        // `classifyResponseFailed`).
        // Per-event server-model + verification signals (upstream
        // responses.rs:447-467). A `response.headers` map on the frame (or a
        // top-level `headers` map on websocket-metadata frames) can carry an
        // updated `openai-model` / `x-openai-model`; emit ServerModel when it
        // changes. `response.metadata` frames carry
        // `openai_verification_recommendation`.
        if let model = ResponsesStreamParsing.serverModelFromFrame(obj),
           model != lastServerModel {
            lastServerModel = model
            cont.yield(.serverModel(model))
        }
        if (obj["type"] as? String) == "response.metadata",
           let verifs = ResponsesStreamParsing.modelVerificationsFromFrame(obj),
           !verifs.isEmpty {
            cont.yield(.modelVerifications(verifs))
        }
        switch obj["type"] as? String ?? "" {
        case "response.created":
            // Upstream only emits Created when the frame carries a `response`
            // object (`responses.rs:307-311`).
            if obj["response"] != nil { cont.yield(.created) }
        case "response.output_text.delta":
            let id = obj["item_id"] as? String ?? "msg"
            let delta = obj["delta"] as? String ?? ""
            // Upstream (`responses.rs:275-279`) yields whenever `delta` is
            // present, even when it is an empty string. No non-emptiness guard.
            cont.yield(.agentDelta(itemId: id, delta: delta))
        case "response.reasoning_text.delta":
            // Upstream (`responses.rs:298-305`) only yields when BOTH `delta`
            // and `content_index` are present; a frame missing either produces
            // no event. Guard on index presence rather than defaulting to 0.
            let id = obj["item_id"] as? String ?? "reasoning"
            let delta = obj["delta"] as? String ?? ""
            guard let ci = Self.intIfPresent(obj["content_index"]) else { break }
            // Upstream emits even for empty deltas; only the index presence
            // guard above is required (`responses.rs:298-305`).
            cont.yield(.reasoningContentDelta(
                itemId: id, delta: delta, contentIndex: ci))
        case "response.reasoning_summary_text.delta":
            // Upstream (`responses.rs:291-297`) only yields when BOTH `delta`
            // and `summary_index` are present.
            let id = obj["item_id"] as? String ?? "reasoning"
            let delta = obj["delta"] as? String ?? ""
            guard let si = Self.intIfPresent(obj["summary_index"]) else { break }
            // Upstream emits even for empty deltas; only the index presence
            // guard above is required (`responses.rs:291-297`).
            cont.yield(.reasoningSummaryDelta(
                itemId: id, delta: delta, summaryIndex: si))
        case "response.reasoning_summary_part.added":
            // Upstream yields only when summary_index is present
            // (responses.rs:384-387).
            let id = obj["item_id"] as? String ?? "reasoning"
            guard let si = Self.intIfPresent(obj["summary_index"]) else { break }
            cont.yield(.reasoningSummaryPartAdded(itemId: id, summaryIndex: si))
        case "response.custom_tool_call_input.delta":
            // Upstream (`responses.rs:280-289`) has a branch ONLY for
            // `custom_tool_call_input.delta`; there is NO branch for
            // `function_call_arguments.delta` (it falls into the `_ =>` arm and
            // yields nothing — see `parses_tool_call_input_deltas`,
            // responses.rs:765-795). It resolves the item id as
            // `item_id ?? call_id`, carries `call_id`, and emits whenever a
            // resolved id is present — `Some("")` is still present in Rust, so
            // an empty-string delta with a valid id still emits.
            let callId = (obj["call_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let itemId = (obj["item_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? callId
            let delta = obj["delta"] as? String ?? ""
            if let itemId {
                cont.yield(.toolCallInputDelta(itemId: itemId, callId: callId,
                                               delta: delta))
            }
        case "response.output_item.added":
            if let item = obj["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                cont.yield(.outputItemAdded(itemId: item["id"] as? String ?? "",
                                            itemType: itemType))
                // Surface server-side tool items so they are not lost (upstream
                // deserializes EVERY ResponseItem here, responses.rs:376-382).
                if let ev = ResponsesStreamParsing.serverToolItemEvent(
                    item, done: false) {
                    cont.yield(ev)
                }
            }
        case "response.output_item.done":
            if let item = obj["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                if itemType == "message" {
                    let id = item["id"] as? String ?? "msg"
                    var text = ""
                    if let content = item["content"] as? [[String: Any]] {
                        for c in content {
                            if let s = c["text"] as? String { text += s }
                        }
                    }
                    cont.yield(.agentDone(itemId: id, text: text))
                } else if itemType == "function_call" {
                    let callId = item["call_id"] as? String ?? "call"
                    let name = item["name"] as? String ?? ""
                    let args = item["arguments"] as? String ?? "{}"
                    cont.yield(.toolCall(callId: callId, name: name,
                                         argumentsJSON: args))
                } else if itemType == "custom_tool_call" {
                    // Freeform tool result (apply_patch): `input` is the RAW
                    // patch envelope, not JSON. Route via the generic toolCall
                    // contract (handler accepts raw patch text). Upstream item
                    // shape protocol/src/models.rs:824.
                    let callId = item["call_id"] as? String ?? "call"
                    let name = item["name"] as? String ?? ""
                    let input = item["input"] as? String ?? ""
                    cont.yield(.toolCall(callId: callId, name: name,
                                         argumentsJSON: input))
                } else if itemType == "reasoning" {
                    // Reasoning item carrying encrypted chain-of-thought; surface
                    // it so the turn loop can persist + replay it (upstream
                    // OutputItemDone(ResponseItem::Reasoning), responses.rs:267).
                    let r = ResponsesStreamParsing.parseReasoningItem(item)
                    cont.yield(.reasoning(itemId: r.id, summary: r.summary,
                                          content: r.content,
                                          encryptedContent: r.encryptedContent))
                } else if let ev = ResponsesStreamParsing.serverToolItemEvent(
                    item, done: true) {
                    // Server-side tool items (local_shell_call, web_search_call,
                    // tool_search_call) — surface rather than drop (upstream
                    // deserializes EVERY ResponseItem, responses.rs:267-274).
                    cont.yield(ev)
                }
            }
        case "response.failed":
            // P6.2 / H-44: classify `error.code` (context_window_exceeded,
            // quota_exceeded, cyber_policy, server_is_overloaded, ...)
            // so the retry / turn layer can branch on stable identifiers.
            let resp = obj["response"] as? [String: Any]
            let err = resp?["error"] as? [String: Any]
            cont.finish(throwing: ModelClientErrorClassifier
                .classifyResponseFailed(err))
            return true
        case "response.incomplete":
            // P6.2 / H-43 + STATUS.md:624-629: when reason is
            // `max_output_tokens`, treat as terminal-completed so the
            // turn keeps its partial output + accurate usage accounting.
            // For any other reason (content_filter, etc.) fall through
            // to the retryable stream-error throw.
            let resp = obj["response"] as? [String: Any]
            if !ModelClientErrorClassifier.incompleteIsTerminalSuccess(resp) {
                cont.finish(throwing: ModelClientErrorClassifier
                    .classifyIncomplete(resp))
                return true
            }
            fallthrough
        case "response.completed":
            let resp = obj["response"] as? [String: Any]
            // Upstream (`responses.rs:358-374`) deserializes `response` into
            // `ResponseCompleted{ id: String (required), ... }` and returns a
            // stream error when it fails — a missing `id` is fatal. We mirror
            // that for genuine `response.completed` frames. The
            // `response.incomplete` → max_output_tokens soft-success
            // fallthrough is a documented codex-swift divergence
            // (STATUS.md:624-629): that payload has no `id`, so we synthesize
            // one there rather than erroring.
            let isGenuineCompleted =
                (obj["type"] as? String) == "response.completed"
            let parsedId = resp?["id"] as? String
            if isGenuineCompleted, parsedId == nil {
                cont.finish(throwing: ModelError(
                    "failed to parse ResponseCompleted: missing id",
                    retryable: true))
                return true
            }
            let id = parsedId ?? "resp"
            let usage = resp?["usage"] as? [String: Any]
            let total = intOf(usage?["total_tokens"])
            let details = usage?["input_tokens_details"] as? [String: Any]
            // P2.2 / H-05: reasoning-token breakdown.
            let outputDetails = usage?["output_tokens_details"] as? [String: Any]
            let snap = UsageSnapshot(
                inputTokens: intOf(usage?["input_tokens"]),
                cachedInputTokens: intOf(details?["cached_tokens"]),
                outputTokens: intOf(usage?["output_tokens"]),
                reasoningOutputTokens: intOf(outputDetails?["reasoning_tokens"]),
                totalTokens: total)
            await tracker?.recordUsage(snap)
            // `end_turn: Some(false)` from the payload signals continuation;
            // absent → ended (upstream fallback).
            let endTurn = (resp?["end_turn"] as? Bool) ?? true
            cont.yield(.completed(responseId: id, totalTokens: total,
                                  endTurn: endTurn, usage: snap))
            cont.finish()
            return true
        default:
            break
        }
        return false
    }

    private static func intOf(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return 0
    }


    /// Integer view that distinguishes "absent / null" (→ nil) from a present
    /// numeric value, matching upstream `Option<i64>` deserialization. A
    /// missing key or JSON `null` (`NSNull`) yields `nil`; a present number
    /// yields its `Int`. Used to gate reasoning-delta emission on the index
    /// being present (`responses.rs:291-305`).
    private static func intIfPresent(_ v: Any?) -> Int? {
        guard let v = v, !(v is NSNull) else { return nil }
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    private static func rateLimits(from response: HTTPURLResponse) -> [RateLimitSnapshot] {
        var dump = ""
        for (k, v) in response.allHeaderFields {
            dump += "\(k): \(v)\r\n"
        }
        return RateLimitSnapshot.parseAllRateLimits(headerDump: dump)
    }

    /// Rate-limit snapshots ordered codex-family-first, then the rest in their
    /// discovered order, mirroring upstream `parse_all_rate_limits`' ordering
    /// (`responses.rs:68-70` iterates the codex snapshot first, then secondary /
    /// other families). Used for both the tracker recording and the per-snapshot
    /// `.rateLimits` stream events so secondary families are surfaced too.
    private static func orderedRateLimits(from response: HTTPURLResponse)
    -> [RateLimitSnapshot] {
        let snaps = rateLimits(from: response)
        let codex = snaps.filter { $0.limitId == "codex" }
        let rest = snaps.filter { $0.limitId != "codex" }
        return codex + rest
    }

    private static func retryAfterDuration(from response: HTTPURLResponse) -> Duration? {
        guard let raw = headerValue("Retry-After", in: response) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed), seconds >= 0 {
            return .seconds(seconds)
        }
        if let date = retryAfterDateFormatter.date(from: trimmed) {
            return .seconds(Swift.max(0, date.timeIntervalSinceNow))
        }
        return nil
    }

    private static func headerValue(_ name: String,
                                    in response: HTTPURLResponse) -> String? {
        for (k, v) in response.allHeaderFields {
            if String(describing: k).caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: v)
            }
        }
        return nil
    }

    private static let retryAfterDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return f
    }()
}
#endif
