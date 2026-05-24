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
            prompt, settings, maxOutputTokens: maxOutputTokens)
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
        for (k, v) in provider.resolvedHeaders(env: env) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let preparedRequest = request

        let cap = streamCapacity
        let tracker = usageTracker
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
                                       tracker: tracker,
                                       continuation: cont)
                }
                cont.onTermination = { _ in
                    task.cancel()
                    session.invalidateAndCancel()
                }
            }
        }
    }

    private static func readSSE(
        request: URLRequest,
        session: URLSession,
        tracker: UsageTracker?,
        continuation cont: AsyncThrowingStream<ResponseEvent, any Error>.Continuation
    ) async {
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                if let snap = rateLimits(from: http) {
                    await tracker?.recordRateLimits(snap)
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

            var buffer = Data()
            var sawAny = false
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
                    if payload.isEmpty || payload == "[DONE]" { continue }
                    guard let pd = payload.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: pd))
                            as? [String: Any] else {
                        continue
                    }
                    sawAny = true
                    if await mapEvent(obj, tracker: tracker, continuation: cont) {
                        return
                    }
                }
            }
            guard sawAny else {
                cont.finish(throwing: ModelError("no SSE from OpenAI",
                                                 retryable: false))
                return
            }
            cont.finish()
        } catch is CancellationError {
            cont.finish()
        } catch let e as ModelError {
            cont.finish(throwing: e)
        } catch {
            cont.finish(throwing: ModelError(
                "URLSession SSE failed: \(error)", retryable: true))
        }
    }

    private static func mapEvent(
        _ obj: [String: Any],
        tracker: UsageTracker?,
        continuation cont: AsyncThrowingStream<ResponseEvent, any Error>.Continuation
    ) async -> Bool {
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "OpenAI error"
            cont.finish(throwing: ModelError(msg, retryable: false))
            return true
        }
        switch obj["type"] as? String ?? "" {
        case "response.created":
            cont.yield(.created)
        case "response.output_text.delta":
            let id = obj["item_id"] as? String ?? "msg"
            let delta = obj["delta"] as? String ?? ""
            if !delta.isEmpty { cont.yield(.agentDelta(itemId: id, delta: delta)) }
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
            let id = resp?["id"] as? String ?? "resp"
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
            cont.yield(.completed(responseId: id, totalTokens: total,
                                  endTurn: true, usage: snap))
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

    private static func rateLimits(from response: HTTPURLResponse) -> RateLimitSnapshot? {
        var dump = ""
        for (k, v) in response.allHeaderFields {
            dump += "\(k): \(v)\r\n"
        }
        return RateLimitSnapshot.parseRateLimits(headerDump: dump)
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
