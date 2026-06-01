import Foundation
import InfraPrimitives
import ModelClient

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)

/// A `ModelClient` that speaks the OpenAI **chat-completions** wire shape
/// (`POST {baseURL}/v1/chat/completions`) instead of the Responses API.
///
/// Why this exists (docs/extensions/ARCHITECTURE.md §7.4, D1, DEFERRED ITEM 3):
/// the codex-rs core deliberately tracks upstream and dropped chat-completions
/// support — `WireApi` has only `.responses` and `ModelProviderRegistry.load`
/// HARD-ERRORS on `wire_api="chat"`. So this client MUST NOT be plumbed through
/// `ModelProviderRegistry` or the agent's model path. Its sole consumer is
/// `LocalSmallModel`/`SmallModelService`, which is itself addon-only and never
/// participates in the agent's own model loop. That lets `SmallModel` target a
/// genuinely chat-only local endpoint (ollama / lmstudio / llama.cpp) or
/// OpenAI's `/v1/chat/completions`, paying local/cheap tokens for the Memory
/// Wiki's labeling/scoring rather than provider Responses-API tokens.
///
/// `LocalSmallModel` only consumes `.agentDelta` / `.agentDone` from the
/// stream (see `LocalSmallModel.collect`), so the mapping below is intentionally
/// minimal: no tool calls, no reasoning, no `previous_response_id`. We still
/// emit `.completed` at end-of-stream so the bounded `StreamMapper` records a
/// `LastResponse` and any future consumer sees a well-formed terminal event.
///
/// Transport mirrors `URLSessionResponsesClient`: `URLSession.bytes(for:)` so
/// the bearer credential lives in a request header (never process argv), the
/// stream is bounded by `Limits.dataChannelDepth`, and consumer cancellation
/// tears the upstream task down. macOS-only for the same reason that file is
/// (`URLSession.bytes(for:)` is a Darwin async API); `SmallModel` is local-only.
public actor ChatCompletionsClient: ModelClient {
    private let endpoint: String
    private let model: String
    private let apiKey: String?
    private let extraHeaders: [String: String]
    private let maxOutputTokens: Int?
    private let streamCapacity: Int
    private let timeoutInterval: TimeInterval

    /// - Parameters:
    ///   - baseURL: the server root, e.g. `http://localhost:11434` (ollama),
    ///     `http://localhost:1234` (lmstudio), or `https://api.openai.com`.
    ///     A trailing `/`, a trailing `/v1`, or a full
    ///     `…/v1/chat/completions` are all accepted and normalized to the
    ///     canonical `{root}/v1/chat/completions` endpoint.
    ///   - model: the model id sent as the request `"model"` field. Overridden
    ///     per-request by `ModelSettings.model` when that is non-empty.
    ///   - apiKey: optional bearer token. Local servers usually need none;
    ///     OpenAI requires it. When nil/empty no `Authorization` header is sent.
    ///   - headers: extra request headers (e.g. an org id).
    ///   - maxOutputTokens: optional `max_tokens` cap on the reply.
    ///   - limits: stream capacity + timeout source (single source of truth).
    public init(baseURL: String,
                model: String,
                apiKey: String? = nil,
                headers: [String: String] = [:],
                maxOutputTokens: Int? = nil,
                limits: Limits = Limits()) {
        self.endpoint = Self.normalizeEndpoint(baseURL)
        self.model = model
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (trimmedKey?.isEmpty == false) ? trimmedKey : nil
        self.extraHeaders = headers
        self.maxOutputTokens = maxOutputTokens
        let clamped = limits.clamped()
        self.streamCapacity = clamped.dataChannelDepth
        self.timeoutInterval = Swift.max(1, Swift.min(clamped.turnDeadline.seconds, 24 * 3600))
    }

    /// Normalize any of `{root}`, `{root}/`, `{root}/v1`, `{root}/v1/`,
    /// `{root}/v1/chat/completions` to `{root}/v1/chat/completions`.
    static func normalizeEndpoint(_ baseURL: String) -> String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1/chat/completions") { return s }
        if s.hasSuffix("/chat/completions") {
            // already an explicit chat endpoint under some other prefix — honor it
            return s
        }
        if s.hasSuffix("/v1") { return s + "/chat/completions" }
        return s + "/v1/chat/completions"
    }

    // MARK: - request body

    /// Build the chat-completions request JSON from a `Prompt`/`ModelSettings`.
    /// `prompt.instructions` (when non-empty) becomes a leading `system`
    /// message; each `prompt.input` entry maps to a `system`/`user`/`assistant`
    /// message (tool outputs are folded into a `user` message so the local
    /// model still sees them — chat-completions `tool` role needs a matching
    /// `tool_call_id` we don't track on this off-agent path). `stream: true`
    /// requests SSE. Tools are intentionally NOT forwarded — SmallModel runs
    /// tools-disabled sub-tasks.
    static func buildRequestBody(_ prompt: Prompt,
                                 _ settings: ModelSettings,
                                 model: String,
                                 maxOutputTokens: Int?) -> [String: Any] {
        var messages: [[String: Any]] = []
        let sys = prompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            messages.append(["role": "system", "content": prompt.instructions])
        }
        for item in prompt.input {
            switch item {
            case .userText(let t):
                messages.append(["role": "user", "content": t])
            case .developerText(let t):
                // chat-completions has no developer role; map to system.
                messages.append(["role": "system", "content": t])
            case .assistantText(let t):
                messages.append(["role": "assistant", "content": t])
            case .toolOutput(_, let output):
                messages.append(["role": "user", "content": output])
            case .reasoning(let summary, let content, _):
                // Chat-completions has no encrypted-reasoning replay slot; fold
                // any visible summary/content text into an assistant turn so the
                // model retains the gist, and drop the opaque encrypted token
                // (it is only meaningful to the Responses API).
                let text = (summary + content).filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if !text.isEmpty {
                    messages.append(["role": "assistant", "content": text])
                }
            }
        }
        let chosenModel = settings.model.isEmpty ? model : settings.model
        var body: [String: Any] = [
            "model": chosenModel,
            "messages": messages,
            "stream": true,
        ]
        if let cap = maxOutputTokens, cap > 0 {
            body["max_tokens"] = cap
        }
        return body
    }

    // MARK: - stream

    public func stream(_ prompt: Prompt,
                       _ settings: ModelSettings) async throws -> ResponseStream {
        let body = Self.buildRequestBody(prompt, settings,
                                         model: model, maxOutputTokens: maxOutputTokens)
        let data = try JSONSerialization.data(withJSONObject: body)
        guard let url = URL(string: endpoint) else {
            throw ModelError("invalid chat-completions URL: \(endpoint)", retryable: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let preparedRequest = request

        let cap = streamCapacity
        let timeout = timeoutInterval
        return StreamMapper.map(capacity: cap) {
            AsyncThrowingStream<ResponseEvent, any Error> { cont in
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = timeout
                config.timeoutIntervalForResource = timeout
                let session = URLSession(configuration: config)
                let task = Task {
                    await Self.readSSE(request: preparedRequest,
                                       session: session,
                                       continuation: cont)
                }
                cont.onTermination = { _ in
                    task.cancel()
                    session.invalidateAndCancel()
                }
            }
        }
    }

    /// Read the chat-completions SSE stream and translate it into
    /// `ResponseEvent`s. Mirrors the line-framing of
    /// `URLSessionResponsesClient.readSSE` but parses the chat-completions
    /// chunk shape (`choices[].delta.content`, `choices[].finish_reason`).
    private static func readSSE(
        request: URLRequest,
        session: URLSession,
        continuation cont: AsyncThrowingStream<ResponseEvent, any Error>.Continuation
    ) async {
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else {
                    var bodyBytes: [UInt8] = []
                    for try await b in bytes {
                        bodyBytes.append(b)
                        if bodyBytes.count > 4096 { break }
                    }
                    let bodyStr = String(decoding: bodyBytes, as: UTF8.self).prefix(1500)
                    cont.finish(throwing: ModelError(
                        "chat-completions HTTP \(http.statusCode): \(bodyStr)",
                        retryable: http.statusCode == 429 || http.statusCode >= 500,
                        httpStatus: http.statusCode))
                    return
                }
            }

            var buffer = Data()
            var accumulated = ""
            let itemId = "chat-msg"
            var sawAny = false
            var finished = false
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    let raw = String(decoding: lineData, as: UTF8.self)
                    let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                    guard line.hasPrefix("data:") else { continue }
                    var payload = String(line.dropFirst(5))
                    if payload.hasPrefix(" ") { payload.removeFirst() }
                    if payload.isEmpty { continue }
                    if payload == "[DONE]" {
                        finished = true
                        break
                    }
                    guard let pd = payload.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: pd))
                            as? [String: Any] else {
                        continue
                    }
                    sawAny = true
                    // Surface an error object the server may stream inline.
                    if let err = obj["error"] as? [String: Any] {
                        let msg = (err["message"] as? String) ?? "chat-completions error"
                        cont.finish(throwing: ModelError(msg, retryable: false))
                        return
                    }
                    let (delta, didFinish) = parseChunk(obj)
                    if !delta.isEmpty {
                        accumulated += delta
                        cont.yield(.agentDelta(itemId: itemId, delta: delta))
                    }
                    if didFinish { finished = true }
                }
                if finished { break }
            }
            // Emit a terminal agentDone + completed so collectors see the final
            // text and the StreamMapper records a LastResponse.
            guard sawAny || finished else {
                cont.finish(throwing: ModelError("no SSE from chat-completions endpoint",
                                                 retryable: false))
                return
            }
            cont.yield(.agentDone(itemId: itemId, text: accumulated))
            cont.yield(.completed(responseId: "chatcmpl", totalTokens: 0, endTurn: true))
            cont.finish()
        } catch is CancellationError {
            cont.finish()
        } catch let e as ModelError {
            cont.finish(throwing: e)
        } catch {
            cont.finish(throwing: ModelError(
                "chat-completions SSE failed: \(error)", retryable: true))
        }
    }

    /// Parse one streamed chat-completions chunk. Returns the content delta
    /// (possibly empty) and whether this chunk carried a non-null
    /// `finish_reason` (terminal). Tolerant of the small shape differences
    /// across ollama / lmstudio / OpenAI.
    static func parseChunk(_ obj: [String: Any]) -> (delta: String, finished: Bool) {
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else {
            return ("", false)
        }
        var delta = ""
        if let d = first["delta"] as? [String: Any],
           let c = d["content"] as? String {
            delta = c
        } else if let msg = first["message"] as? [String: Any],
                  let c = msg["content"] as? String {
            // Non-streaming servers (or a non-streamed chunk) put the whole
            // reply under `message.content`.
            delta = c
        }
        let finished = (first["finish_reason"] as? String).map { !$0.isEmpty } ?? false
        return (delta, finished)
    }
}
#endif
