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
        if let attestationHeader, !attestationHeader.isEmpty {
            headers["x-oai-attestation"] = attestationHeader
        }
        return RequestPlan(headers: headers,
                           prewarmJSON: prewarmJSON,
                           requestJSON: requestJSON)
    }

    private static func canonicalJSONString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func websocketCreateEvent(from responseBody: [String: Any]) -> [String: Any] {
        var event = responseBody
        event["type"] = createEventType
        event.removeValue(forKey: "stream")
        event.removeValue(forKey: "background")
        return event
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
                    switch obj["type"] as? String ?? "" {
                    case "response.created":
                        if !suppressEvents { cont.yield(.created) }
                    case "response.output_text.delta":
                        let id = obj["item_id"] as? String ?? "msg"
                        let d = obj["delta"] as? String ?? ""
                        if !suppressEvents, !d.isEmpty {
                            cont.yield(.agentDelta(itemId: id, delta: d))
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
                        let id = resp?["id"] as? String ?? "resp"
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
                            cont.yield(.completed(responseId: id, totalTokens: total,
                                                  endTurn: true, usage: snap))
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
#endif
