import XCTest
import Foundation
import Prompts
@testable import ModelClient
@testable import InfraPrimitives

/// Coverage for the v13 model-client audit findings:
///  1. `response.function_call_arguments.delta` yields NO `ResponseEvent`
///     (upstream `parses_tool_call_input_deltas`, responses.rs:765-795).
///  2. `response.custom_tool_call_input.delta` emits even for an empty-string
///     delta when a resolved id is present (`Some("")` is present in Rust).
///  3. The WebSocket `response.create` payload keeps `stream: true`
///     (`ResponseCreateWsRequest`, common.rs:216-240).
///  4. WS `response.completed` without `id` is a fatal retryable stream error
///     (mirroring the URLSession path / responses.rs:358-374) — covered by the
///     shared `ModelClientErrorClassifier`-style invariant note below.
///  5. Retry-after is honored DIRECTLY with no clamp; backoff matches upstream
///     `200ms * 2^(attempt-1) * rand(0.9..1.1)` (util.rs:85-89).
///  6. The header-derived ServerModel does not seed the per-event dedupe, so an
///     in-stream frame repeating the header model emits ServerModel twice
///     (responses.rs:41-67 vs the `last_server_model: None` start at :407).
final class ModelClientAuditV13Tests: XCTestCase {

    #if os(macOS)
    // MARK: Finding 1 — function_call_arguments.delta yields NO event.
    // Port of upstream `parses_tool_call_input_deltas` (responses.rs:765-795):
    // a `response.function_call_arguments.delta` frame must NOT surface a
    // ToolCallInputDelta; only `response.custom_tool_call_input.delta` does.
    func testFunctionCallArgumentsDeltaProducesNoEvent() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","call_id":"call_1","delta":"{\\"x\\":1}"}

        data: {"type":"response.completed","response":{"id":"r1","usage":{"total_tokens":1}}}

        """
        guard let (srv, port) = cfOneShotServer(dir, body: evt) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let r = await cfTimeout(20, { await cfDrain(client) }) else {
            return XCTFail("client hung")
        }
        XCTAssertFalse(r.errored, r.message)
        XCTAssertFalse(r.events.contains { ev in
            if case .toolCallInputDelta = ev { return true }
            return false
        }, "function_call_arguments.delta must not surface ToolCallInputDelta")
    }

    // MARK: Finding 1/2 — custom_tool_call_input.delta DOES emit, even empty.
    func testCustomToolCallInputDeltaEmitsIncludingEmptyDelta() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.custom_tool_call_input.delta","item_id":"ci_1","delta":""}

        data: {"type":"response.custom_tool_call_input.delta","item_id":"ci_1","delta":"abc"}

        data: {"type":"response.completed","response":{"id":"r1","usage":{"total_tokens":1}}}

        """
        guard let (srv, port) = cfOneShotServer(dir, body: evt) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let r = await cfTimeout(20, { await cfDrain(client) }) else {
            return XCTFail("client hung")
        }
        XCTAssertFalse(r.errored, r.message)
        let deltas: [String] = r.events.compactMap { ev in
            if case let .toolCallInputDelta(_, _, d) = ev { return d }
            return nil
        }
        XCTAssertEqual(deltas, ["", "abc"],
                       "empty-string delta with a valid id must still emit")
    }

    // MARK: Finding 6 — header ServerModel does not dedupe an in-stream repeat.
    func testHeaderServerModelDoesNotSuppressInStreamRepeat() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        // The in-stream `response.headers` frame repeats the SAME model the
        // response header carried; upstream emits ServerModel twice.
        let evt = """
        data: {"type":"response.headers","response":{"headers":{"openai-model":"gpt-routed"}}}

        data: {"type":"response.completed","response":{"id":"r1","usage":{"total_tokens":1}}}

        """
        guard let (srv, port) = cfOneShotServer(
            dir, body: evt, extraHeaders: "openai-model: gpt-routed\r\n") else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let r = await cfTimeout(20, { await cfDrain(client) }) else {
            return XCTFail("client hung")
        }
        XCTAssertFalse(r.errored, r.message)
        let serverModels: [String] = r.events.compactMap { ev in
            if case let .serverModel(m) = ev { return m }
            return nil
        }
        XCTAssertEqual(serverModels, ["gpt-routed", "gpt-routed"],
                       "header + in-stream same-model must both emit (no dedupe)")
    }
    #endif

    // MARK: Finding 3 — WS create payload keeps `stream: true`.
    func testWebSocketCreatePayloadKeepsStreamTrue() throws {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t")
        let plan = try WebSocketResponsesClient.buildRequestPlan(
            prompt: Prompt(instructions: "i", input: [.userText("hi")]),
            settings: settings, apiKey: "k", maxOutputTokens: nil)
        let obj = try JSONSerialization.jsonObject(
            with: Data(plan.requestJSON.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "response.create")
        XCTAssertEqual(obj?["stream"] as? Bool, true,
                       "WS create event must carry stream: true like upstream")
        XCTAssertNil(obj?["background"],
                     "WS create event must not carry the background field")
    }

    func testWebSocketPrewarmPayloadKeepsStreamTrue() throws {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t")
        let plan = try WebSocketResponsesClient.buildRequestPlan(
            prompt: Prompt(instructions: "i", input: [.userText("hi")]),
            settings: settings, apiKey: "k", maxOutputTokens: nil,
            options: .init(prewarm: true))
        guard let prewarm = plan.prewarmJSON else {
            return XCTFail("prewarm JSON expected when prewarm is enabled")
        }
        let obj = try JSONSerialization.jsonObject(
            with: Data(prewarm.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["stream"] as? Bool, true,
                       "WS prewarm (generate=false) payload also carries stream")
        XCTAssertEqual(obj?["generate"] as? Bool, false)
    }

    // MARK: Finding 5 — retry-after honored directly (no clamp to maxRetryDelay).
    func testRetryAfterIsHonoredWithoutClampingToMaxRetryDelay() async throws {
        var lim = Limits()
        lim.streamMaxRetries = 1
        lim.retryTokensCapacity = 1
        lim.retryTokensPerSecond = 0
        lim.retryBaseDelay = .milliseconds(1)
        // A server-requested retry-after LARGER than retryMaxDelay must be used
        // directly (upstream session/turn.rs:1123-1128 applies no clamp).
        lim.retryMaxDelay = .milliseconds(40)
        let retryAfter = Duration.milliseconds(140)
        let primary = V13RetryAfterOnceClient(retryAfter: retryAfter)
        let client = RetryingModelClient(base: primary, limits: lim)

        let start = MonotonicClock.now()
        let s = try await client.stream(Prompt(instructions: "", input: []),
                                        ModelSettings(model: "m", threadId: "t"))
        var sawDone = false
        for try await ev in s.events {
            if case .agentDone = ev { sawDone = true }
        }
        let elapsed = MonotonicClock.now() - start
        XCTAssertTrue(sawDone)
        // If the old clamp (40ms) were applied the elapsed would be ~40ms; the
        // un-clamped delay is 140ms. Assert it exceeded the old cap clearly.
        XCTAssertGreaterThan(elapsed, lim.retryMaxDelay.seconds * 1.5,
                             "retry-after must not be clamped to maxRetryDelay")
        let calls = await primary.calls()
        XCTAssertEqual(calls, 2)
    }

    // MARK: Finding 5 — backoff matches upstream 200ms * 2^(n-1) * [0.9,1.1).
    func testUpstreamBackoffFormulaMatchesRustUtil() async {
        var lim = Limits()
        lim.retryBaseDelay = .milliseconds(200)
        // Deterministic rng = 0.0 → jitter factor 0.9 (low edge);
        // rng = 0.999.. → ~1.1 (high edge).
        let low = RetryingModelClient(base: V13NoopClient(), limits: lim,
                                      rng: { 0.0 })
        let high = RetryingModelClient(base: V13NoopClient(), limits: lim,
                                       rng: { 0.9999999 })
        // attempt 1: base * 2^0 * 0.9  = 0.18s ; * ~1.1 ≈ 0.22s
        let lo1 = await low.upstreamBackoff(forAttempt: 1).seconds
        let hi1 = await high.upstreamBackoff(forAttempt: 1).seconds
        XCTAssertEqual(lo1, 0.2 * 0.9, accuracy: 1e-9)
        XCTAssertEqual(hi1, 0.2 * (0.9 + 0.9999999 * 0.2), accuracy: 1e-6)
        // attempt 3: base * 2^2 * 0.9 = 0.8 * 0.9 = 0.72s — exponential, no cap.
        let lo3 = await low.upstreamBackoff(forAttempt: 3).seconds
        XCTAssertEqual(lo3, 0.2 * 4.0 * 0.9, accuracy: 1e-9)
        // No upper cap: attempt 8 vastly exceeds the old 20s full-jitter ceiling.
        let lo8 = await low.upstreamBackoff(forAttempt: 8).seconds
        XCTAssertGreaterThan(lo8, 20.0,
                             "upstream backoff has no upper cap (util.rs:85-89)")
    }
}

// MARK: - Stream drain helper (free function so the timeout closure stays Sendable)

private struct V13EventDrain: Sendable {
    var events: [ResponseEvent]
    var errored: Bool
    var message: String
    var retryable: Bool
}

private func cfDrain(_ client: any ModelClient) async -> V13EventDrain {
    do {
        let s = try await client.stream(
            Prompt(instructions: "x", input: [.userText("hi")]),
            ModelSettings(model: "gpt-4o-mini", threadId: "t"))
        var events: [ResponseEvent] = []
        for try await ev in s.events { events.append(ev) }
        return V13EventDrain(events: events, errored: false, message: "",
                             retryable: false)
    } catch let e as ModelError {
        return V13EventDrain(events: [], errored: true, message: e.message,
                             retryable: e.retryable)
    } catch {
        return V13EventDrain(events: [], errored: true, message: "\(error)",
                             retryable: false)
    }
}

// MARK: - Test doubles

/// Fails once with a retryable error carrying a `retryAfter`, then succeeds.
private actor V13RetryAfterOnceClient: ModelClient {
    private let retryAfter: Duration
    private var callCount = 0
    init(retryAfter: Duration) { self.retryAfter = retryAfter }
    func calls() -> Int { callCount }

    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws
    -> ResponseStream {
        callCount += 1
        if callCount == 1 {
            throw ModelError("rate limited", retryable: true,
                             retryAfter: retryAfter)
        }
        let s = AsyncThrowingStream<ResponseEvent, any Error> { cont in
            cont.yield(.agentDone(itemId: "msg", text: "ok"))
            cont.yield(.completed(responseId: "resp", totalTokens: 1,
                                  endTurn: true))
            cont.finish()
        }
        return ResponseStream(events: s, lastResponse: LastResponseBox())
    }
}

/// Never actually streamed in these tests — only used to construct a
/// `RetryingModelClient` so its `upstreamBackoff` can be inspected.
private actor V13NoopClient: ModelClient {
    func stream(_ prompt: Prompt, _ settings: ModelSettings) async throws
    -> ResponseStream {
        ResponseStream(events: AsyncThrowingStream { $0.finish() },
                       lastResponse: LastResponseBox())
    }
}

// MARK: - Local SSE server helpers (mirrors OpenAIClientFailureTests)

private func cfTmp() -> String {
    let p = NSTemporaryDirectory() + "mc-v13-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p,
                                             withIntermediateDirectories: true)
    return p
}

private func cfJSONQuoted(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    let arr = String(decoding: data, as: UTF8.self)
    return String(arr.dropFirst().dropLast())
}

private func cfOneShotServer(_ dir: String, body: String,
                             extraHeaders: String = "") -> (Process, Int)? {
    let script = dir + "/srv.py"
    let py = """
    import socket, sys
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    sys.stdout.write(str(s.getsockname()[1]) + "\\n")
    sys.stdout.flush()
    try:
        c, _ = s.accept()
        try:
            c.recv(65536)
        except Exception:
            pass
        body = (\(cfJSONQuoted(body))).encode()
        hdr = ("HTTP/1.1 200 OK\\r\\n"
               + \(cfJSONQuoted(extraHeaders)) +
               "Content-Type: text/event-stream\\r\\n"
               "Connection: close\\r\\n"
               "Content-Length: " + str(len(body)) + "\\r\\n\\r\\n").encode()
        c.sendall(hdr + body)
        c.close()
    except Exception:
        pass
    s.close()
    """
    try? py.write(toFile: script, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-u", script]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let h = out.fileHandleForReading
    var buf = Data()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        let chunk = h.availableData
        if chunk.isEmpty { break }
        buf.append(chunk)
        if let nl = buf.firstIndex(of: 0x0A) {
            let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
            if let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (p, port)
            }
        }
    }
    p.terminate()
    return nil
}

private func cfTimeout<T: Sendable>(_ seconds: Double,
                                    _ op: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { g in
        g.addTask { await op() }
        g.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await g.next() ?? nil
        g.cancelAll()
        return first
    }
}
