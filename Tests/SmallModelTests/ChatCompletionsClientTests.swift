import XCTest
import Foundation
import Network
@testable import SmallModel
@testable import ModelClient

#if os(macOS)

/// Deterministic tests for `ChatCompletionsClient` (DEFERRED ITEM 3): the
/// chat-completions `ModelClient` that backs `SmallModel` against an
/// OpenAI-compatible local endpoint (ollama / lmstudio / OpenAI chat).
///
/// No network egress: request-mapping + chunk-parsing are pure-function tests,
/// and the end-to-end stream is exercised against an in-process `NWListener`
/// that replays canned SSE bytes on `127.0.0.1`. Proves both the request shape
/// (`{baseURL}/v1/chat/completions`, `messages`, `stream:true`) and the
/// response→`ResponseEvent` mapping (`agentDelta`/`agentDone`/`completed`) that
/// `LocalSmallModel.collect` consumes.
final class ChatCompletionsClientTests: XCTestCase {

    // MARK: - request mapping (pure)

    func testNormalizeEndpointAcceptsAllCommonForms() {
        let want = "http://localhost:11434/v1/chat/completions"
        XCTAssertEqual(ChatCompletionsClient.normalizeEndpoint("http://localhost:11434"), want)
        XCTAssertEqual(ChatCompletionsClient.normalizeEndpoint("http://localhost:11434/"), want)
        XCTAssertEqual(ChatCompletionsClient.normalizeEndpoint("http://localhost:11434/v1"), want)
        XCTAssertEqual(ChatCompletionsClient.normalizeEndpoint("http://localhost:11434/v1/"), want)
        XCTAssertEqual(
            ChatCompletionsClient.normalizeEndpoint("http://localhost:11434/v1/chat/completions"),
            want)
        // A trailing whitespace is trimmed.
        XCTAssertEqual(ChatCompletionsClient.normalizeEndpoint("  https://api.openai.com  "),
                       "https://api.openai.com/v1/chat/completions")
    }

    func testBuildRequestBodyMapsRolesAndModel() throws {
        let prompt = Prompt(instructions: "You are a classifier.",
                            input: [.userText("buy now!!!")])
        let settings = ModelSettings(model: "gpt-4o-mini", threadId: "smallmodel", store: false)
        let body = ChatCompletionsClient.buildRequestBody(
            prompt, settings, model: "fallback", maxOutputTokens: 256)

        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini",
                       "settings.model takes precedence over the construction default")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 256)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are a classifier.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "buy now!!!")
    }

    func testBuildRequestBodyOmitsEmptySystemAndUsesFallbackModel() throws {
        let prompt = Prompt(instructions: "   ",
                            input: [.developerText("ctx"),
                                    .assistantText("prior"),
                                    .toolOutput(callId: "c1", output: "tool said hi")])
        // Empty settings.model → fall back to the construction model id.
        let settings = ModelSettings(model: "", threadId: "t", store: false)
        let body = ChatCompletionsClient.buildRequestBody(
            prompt, settings, model: "local-small", maxOutputTokens: nil)

        XCTAssertEqual(body["model"] as? String, "local-small")
        XCTAssertNil(body["max_tokens"], "no cap → no max_tokens field")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        // No system message from blank instructions; developer→system,
        // assistant→assistant, toolOutput→user.
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "ctx")
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages[1]["content"] as? String, "prior")
        XCTAssertEqual(messages[2]["role"] as? String, "user")
        XCTAssertEqual(messages[2]["content"] as? String, "tool said hi")
    }

    // MARK: - chunk parsing (pure)

    func testParseChunkStreamingDelta() {
        let obj: [String: Any] = [
            "choices": [["delta": ["content": "Hel"], "finish_reason": NSNull()]]
        ]
        let (delta, finished) = ChatCompletionsClient.parseChunk(obj)
        XCTAssertEqual(delta, "Hel")
        XCTAssertFalse(finished)
    }

    func testParseChunkFinishReason() {
        let obj: [String: Any] = [
            "choices": [["delta": [String: Any](), "finish_reason": "stop"]]
        ]
        let (delta, finished) = ChatCompletionsClient.parseChunk(obj)
        XCTAssertEqual(delta, "")
        XCTAssertTrue(finished)
    }

    func testParseChunkNonStreamingMessageContent() {
        // Some servers (or a non-stream chunk) put the whole reply under
        // `message.content`.
        let obj: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": "full reply"]]]
        ]
        let (delta, finished) = ChatCompletionsClient.parseChunk(obj)
        XCTAssertEqual(delta, "full reply")
        XCTAssertFalse(finished)
    }

    func testParseChunkEmptyChoices() {
        XCTAssertEqual(ChatCompletionsClient.parseChunk(["choices": [[String: Any]]()]).delta, "")
        XCTAssertEqual(ChatCompletionsClient.parseChunk([:]).delta, "")
    }

    // MARK: - end-to-end stream over an in-process SSE server

    func testStreamMapsCannedSSEToResponseEvents() async throws {
        // Canned chat-completions SSE: three content deltas, a finish chunk,
        // then [DONE].
        let sse = """
        data: {"choices":[{"delta":{"role":"assistant","content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":", "}}]}

        data: {"choices":[{"delta":{"content":"world"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let server = try SSEStubServer(body: sse)
        defer { server.stop() }
        let port = try await server.start()

        let client = ChatCompletionsClient(
            baseURL: "http://127.0.0.1:\(port)", model: "stub-model")
        let stream = try await client.stream(
            Prompt(instructions: "sys", input: [.userText("hi")]),
            ModelSettings(model: "stub-model", threadId: "t", store: false))

        var deltas: [String] = []
        var done: String?
        var completed = false
        for try await ev in stream.events {
            switch ev {
            case .agentDelta(_, let d): deltas.append(d)
            case .agentDone(_, let t): done = t
            case .completed: completed = true
            default: break
            }
        }
        XCTAssertEqual(deltas, ["Hello", ", ", "world"])
        XCTAssertEqual(done, "Hello, world")
        XCTAssertTrue(completed, "stream must terminate with .completed")
    }

    func testLocalSmallModelJsonDecodesOverChatClient() async throws {
        // Prove SmallModelService.json works over the chat client end-to-end:
        // canned SSE streams a JSON object; LocalSmallModel.collect + decode
        // must yield the typed value.
        struct Label: Decodable, Equatable { let label: String; let score: Int }
        let sse = """
        data: {"choices":[{"delta":{"content":"{\\"label\\":"}}]}

        data: {"choices":[{"delta":{"content":"\\"spam\\",\\"score\\":3}"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let server = try SSEStubServer(body: sse)
        defer { server.stop() }
        let port = try await server.start()

        let svc = LocalSmallModel(
            model: ChatCompletionsClient(baseURL: "http://127.0.0.1:\(port)", model: "stub"),
            modelId: "stub")
        let r = try await svc.json(SmallTask(prompt: "classify", input: "x"), as: Label.self)
        XCTAssertEqual(r, Label(label: "spam", score: 3))
    }

    func testStreamSurfacesHttpErrorStatus() async throws {
        let server = try SSEStubServer(body: "{\"error\":{\"message\":\"model not found\"}}",
                                       status: 404, contentType: "application/json")
        defer { server.stop() }
        let port = try await server.start()

        let client = ChatCompletionsClient(baseURL: "http://127.0.0.1:\(port)", model: "missing")
        let stream = try await client.stream(
            Prompt(instructions: "", input: [.userText("hi")]),
            ModelSettings(model: "missing", threadId: "t", store: false))
        do {
            for try await _ in stream.events {}
            XCTFail("expected a thrown ModelError for HTTP 404")
        } catch let e as ModelError {
            XCTAssertEqual(e.httpStatus, 404)
            XCTAssertTrue(e.message.contains("404"))
        }
    }

    func testServerReceivesPostToChatCompletionsWithMessages() async throws {
        // Assert the REQUEST shape the server actually receives: method POST,
        // path /v1/chat/completions, and a body carrying a user message.
        let sse = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let server = try SSEStubServer(body: sse)
        defer { server.stop() }
        let port = try await server.start()

        let client = ChatCompletionsClient(
            baseURL: "http://127.0.0.1:\(port)/v1", model: "m", apiKey: "secret-key")
        let stream = try await client.stream(
            Prompt(instructions: "S", input: [.userText("payload-marker")]),
            ModelSettings(model: "m", threadId: "t", store: false))
        for try await _ in stream.events {}  // drain

        let req = try XCTUnwrap(server.lastRequest())
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/chat/completions")
        XCTAssertTrue(req.headers.contains { $0.lowercased() == "authorization: bearer secret-key" },
                      "bearer credential must be in a header, not argv")
        XCTAssertTrue(req.body.contains("payload-marker"),
                      "the user text must reach the wire body")
        XCTAssertTrue(req.body.contains("\"stream\""))
    }
}

// MARK: - in-process SSE stub server (NWListener, 127.0.0.1)

/// A minimal localhost HTTP/1.1 server that returns a fixed body once per
/// connection. Used to feed canned SSE bytes to `ChatCompletionsClient` with no
/// external dependency. Captures the first request line + headers + body for
/// request-shape assertions.
final class SSEStubServer: @unchecked Sendable {
    struct CapturedRequest { let method: String; let path: String
                             let headers: [String]; let body: String }

    private let listener: NWListener
    private let body: String
    private let status: Int
    private let contentType: String
    private let lock = NSLock()
    private var captured: CapturedRequest?
    private let queue = DispatchQueue(label: "sse-stub-server")

    init(body: String, status: Int = 200, contentType: String = "text/event-stream") throws {
        self.body = body
        self.status = status
        self.contentType = contentType
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params, on: .any)
    }

    /// Starts listening and resolves to the bound port.
    func start() async throws -> Int {
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = self.listener.port?.rawValue {
                        cont.resume(returning: Int(port))
                    } else {
                        cont.resume(throwing: ModelError("no listener port", retryable: false))
                    }
                case .failed(let err):
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    func lastRequest() -> CapturedRequest? {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        // URLSession sends request headers and the POST body in separate TCP
        // segments, so a single receive only sees the headers. Drain until we
        // have the full body (Content-Length bytes past the header terminator)
        // before replying, otherwise body-shape assertions race the response.
        receiveFullRequest(conn, accumulated: Data())
    }

    private func receiveFullRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self else { conn.cancel(); return }
            var acc = accumulated
            if let data { acc.append(data) }
            if !isComplete && !self.requestComplete(acc) {
                self.receiveFullRequest(conn, accumulated: acc)
                return
            }
            self.capture(acc)
            self.respond(conn)
        }
    }

    /// True once the accumulated bytes contain the header terminator AND at
    /// least `Content-Length` body bytes (or no body is declared).
    private func requestComplete(_ acc: Data) -> Bool {
        let raw = String(decoding: acc, as: UTF8.self)
        guard let headerRange = raw.range(of: "\r\n\r\n") else { return false }
        let head = String(raw[raw.startIndex..<headerRange.lowerBound])
        let bodyBytes = acc.count
            - (head.utf8.count + 4 /* CRLFCRLF */)
        let declared = head
            .components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("content-length:") })
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") }
            ?? 0
        return bodyBytes >= declared
    }

    private func respond(_ conn: NWConnection) {
        let header = "HTTP/1.1 \(status) OK\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Connection: close\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n"
        let payload = Data((header + body).utf8)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
        })
    }

    private func capture(_ acc: Data) {
        lock.lock(); defer { lock.unlock() }
        if captured != nil { return }
        let raw = String(decoding: acc, as: UTF8.self)
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let head = parts.first ?? ""
        let body = parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : ""
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let rlParts = requestLine.components(separatedBy: " ")
        captured = CapturedRequest(
            method: rlParts.first ?? "",
            path: rlParts.count > 1 ? rlParts[1] : "",
            headers: lines,
            body: body)
    }
}
#endif
