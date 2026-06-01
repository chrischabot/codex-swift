import XCTest
import Foundation
@testable import ModelClient
@testable import InfraPrimitives

/// P6.2 — H-43 + H-44 — Tests for `ModelClientErrorClassifier` plus a
/// live `URLSessionResponsesClient` end-to-end test that
/// `response.incomplete` is surfaced as a retryable error rather than a
/// successful turn.
///
/// Upstream reference:
/// `~/Projects/codex/codex-rs/codex-api/src/sse/responses.rs:312-356`
/// (`process_responses_event` for `response.failed` /
/// `response.incomplete`).
final class ResponseFailedClassificationTests: XCTestCase {

    // MARK: – Classifier unit tests (deterministic, no network).

    func testResponseIncompleteEmitsRetryableError() {
        let resp: [String: Any] = [
            "id": "resp_inc",
            "incomplete_details": ["reason": "max_output_tokens"]
        ]
        let err = ModelClientErrorClassifier.classifyIncomplete(resp)
        XCTAssertTrue(err.retryable,
                      "incomplete responses must be retryable so the retry loop re-issues the request")
        XCTAssertEqual(err.codexErrorCode, .incomplete)
        XCTAssertTrue(err.message.contains("max_output_tokens"),
                      "incomplete reason must be surfaced in the message: \(err.message)")
    }

    func testResponseIncompleteFallsBackToUnknownReason() {
        // No `incomplete_details` at all — upstream uses "unknown".
        let err = ModelClientErrorClassifier.classifyIncomplete(nil)
        XCTAssertTrue(err.retryable)
        XCTAssertEqual(err.codexErrorCode, .incomplete)
        XCTAssertTrue(err.message.contains("unknown"), err.message)
    }

    /// STATUS.md:624-629 — `max_output_tokens` is the one incomplete
    /// reason that gets peeled off as terminal-success so the partial
    /// usage is captured. Everything else still throws via
    /// `classifyIncomplete`.
    func testIncompleteIsTerminalSuccessOnlyMaxOutputTokens() {
        XCTAssertTrue(ModelClientErrorClassifier.incompleteIsTerminalSuccess([
            "incomplete_details": ["reason": "max_output_tokens"]
        ]))
        XCTAssertFalse(ModelClientErrorClassifier.incompleteIsTerminalSuccess([
            "incomplete_details": ["reason": "content_filter"]
        ]))
        XCTAssertFalse(ModelClientErrorClassifier.incompleteIsTerminalSuccess(nil))
        XCTAssertFalse(ModelClientErrorClassifier.incompleteIsTerminalSuccess([:]))
        XCTAssertFalse(ModelClientErrorClassifier.incompleteIsTerminalSuccess([
            "incomplete_details": [:]
        ]))
    }

    func testResponseFailedContextWindowExceededClassified() {
        let payload: [String: Any] = [
            "code": "context_length_exceeded",
            "message": "This model's maximum context length is 8192 tokens"
        ]
        let err = ModelClientErrorClassifier.classifyResponseFailed(payload)
        XCTAssertEqual(err.codexErrorCode, .contextWindowExceeded)
        XCTAssertTrue(err.retryable,
                      "context_window_exceeded is retryable so the turn loop can trim history (P6.3 hook)")
        XCTAssertEqual(err.httpStatus, 400)
    }

    func testResponseFailedQuotaExceededTerminal() {
        let payload: [String: Any] = [
            "code": "insufficient_quota",
            "message": "You exceeded your current quota"
        ]
        let err = ModelClientErrorClassifier.classifyResponseFailed(payload)
        XCTAssertEqual(err.codexErrorCode, .quotaExceeded)
        XCTAssertFalse(err.retryable, "quota_exceeded is terminal")
        XCTAssertEqual(err.httpStatus, 429)
        XCTAssertTrue(err.message.contains("quota"), err.message)
    }

    func testResponseFailedRateLimitedRetryable() {
        let payload: [String: Any] = [
            "code": "rate_limit_exceeded",
            "message": "Rate limit reached. Please try again in 1.5s."
        ]
        let err = ModelClientErrorClassifier.classifyResponseFailed(payload)
        XCTAssertEqual(err.codexErrorCode, .rateLimited)
        XCTAssertTrue(err.retryable, "rate_limit_exceeded is retryable")
        XCTAssertEqual(err.httpStatus, 429)
        XCTAssertNotNil(err.retryAfter, "retry-after parsed from message")
        XCTAssertEqual(err.retryAfter?.seconds ?? -1, 1.5, accuracy: 0.001)
    }

    func testResponseFailedRateLimitedHonorsMillisecondsHint() {
        let payload: [String: Any] = [
            "code": "rate_limit_exceeded",
            "message": "Try again in 500ms"
        ]
        let err = ModelClientErrorClassifier.classifyResponseFailed(payload)
        XCTAssertEqual(err.codexErrorCode, .rateLimited)
        XCTAssertNotNil(err.retryAfter)
        XCTAssertEqual(err.retryAfter?.seconds ?? -1, 0.5, accuracy: 0.001)
    }

    func testRetryAfterOnlyParsedForRateLimitCode() {
        // Upstream `try_parse_retry_after` (responses.rs:487-491) returns the
        // parsed delay ONLY when code == "rate_limit_exceeded". For any other
        // code — including missing/unknown codes — even a message embedding
        // "try again in N s" must yield retryAfter nil so the backoff path
        // drives timing.
        let msg = "Something failed. Please try again in 3s."

        let unknown = ModelClientErrorClassifier.classifyResponseFailed([
            "code": "some_other_code", "message": msg])
        XCTAssertNil(unknown.retryAfter,
                     "non-rate-limit code must NOT sniff retry-after from the message")

        let empty = ModelClientErrorClassifier.classifyResponseFailed([
            "message": msg])
        XCTAssertNil(empty.retryAfter,
                     "missing code must NOT sniff retry-after from the message")

        let rateLimited = ModelClientErrorClassifier.classifyResponseFailed([
            "code": "rate_limit_exceeded", "message": msg])
        XCTAssertEqual(rateLimited.retryAfter?.seconds ?? -1, 3.0, accuracy: 0.001,
                       "rate_limit_exceeded must still parse retry-after from the message")
    }

    func testResponseFailedCyberPolicyTerminal() {
        let payload: [String: Any] = [
            "code": "cyber_policy",
            "message": ""
        ]
        let err = ModelClientErrorClassifier.classifyResponseFailed(payload)
        XCTAssertEqual(err.codexErrorCode, .cyberPolicy)
        XCTAssertFalse(err.retryable, "cyber_policy is terminal")
        XCTAssertEqual(err.httpStatus, 400)
        // Empty message falls back to upstream's fixed string.
        XCTAssertTrue(err.message.contains("cybersecurity"), err.message)
    }

    func testResponseFailedServerOverloadedRetryable() {
        let payload: [String: Any] = [
            "code": "server_is_overloaded",
            "message": "The server is overloaded"
        ]
        let err = ModelClientErrorClassifier.classifyResponseFailed(payload)
        XCTAssertEqual(err.codexErrorCode, .serverOverloaded)
        XCTAssertTrue(err.retryable)
        XCTAssertEqual(err.httpStatus, 503)

        let slow = ModelClientErrorClassifier.classifyResponseFailed([
            "code": "slow_down",
            "message": "Please slow down"
        ])
        XCTAssertEqual(slow.codexErrorCode, .serverOverloaded,
                       "slow_down is an alias for server_is_overloaded")
        XCTAssertTrue(slow.retryable)
    }

    func testResponseFailedInvalidPromptTerminal() {
        let payload: [String: Any] = [
            "code": "invalid_prompt",
            "message": "Bad prompt"
        ]
        let err = ModelClientErrorClassifier.classifyResponseFailed(payload)
        XCTAssertEqual(err.codexErrorCode, .invalidRequest)
        XCTAssertFalse(err.retryable)
        XCTAssertEqual(err.httpStatus, 400)
    }

    func testResponseFailedUsageNotIncludedTerminal() {
        let payload: [String: Any] = [
            "code": "usage_not_included",
            "message": "Usage not included on this plan"
        ]
        let err = ModelClientErrorClassifier.classifyResponseFailed(payload)
        XCTAssertEqual(err.codexErrorCode, .usageNotIncluded)
        XCTAssertFalse(err.retryable)
    }

    func testResponseFailedUnknownCodeDefaultsToRetryableUnknown() {
        // Upstream's catch-all branch is `ApiError::Retryable { ... }`.
        // We mirror that and tag `.unknown` so callers can log it.
        let payload: [String: Any] = [
            "code": "some_brand_new_code",
            "message": "We need to wait a bit"
        ]
        let err = ModelClientErrorClassifier.classifyResponseFailed(payload)
        XCTAssertEqual(err.codexErrorCode, .unknown,
                       "unknown codes must fall through to .unknown rather than crashing")
        XCTAssertTrue(err.retryable,
                      "unknown codes default to retryable, matching upstream's Retryable variant")
        XCTAssertTrue(err.message.contains("some_brand_new_code"),
                      "the code is surfaced in the message so it can be diagnosed: \(err.message)")
    }

    func testResponseFailedMissingErrorObjectDefaultsToRetryable() {
        let err = ModelClientErrorClassifier.classifyResponseFailed(nil)
        XCTAssertEqual(err.codexErrorCode, .unknown)
        XCTAssertTrue(err.retryable,
                      "no error object → default retryable, mirroring upstream's fallback")
        // model-client v12 finding 3: when `response.error` is absent the
        // human-readable message must match upstream verbatim
        // (`codex-api/src/sse/responses.rs:314/343`).
        XCTAssertEqual(err.message, "response.failed event received")
    }

    func testResponseFailedEmptyErrorObjectUsesVerbatimMessage() {
        // An error object with no `message`/`code` (code "" branch) also falls
        // back to the verbatim upstream message.
        let err = ModelClientErrorClassifier.classifyResponseFailed([:])
        XCTAssertEqual(err.codexErrorCode, .unknown)
        XCTAssertTrue(err.retryable)
        XCTAssertEqual(err.message, "response.failed event received")
    }

    // MARK: – End-to-end: incomplete via URLSession SSE.

    #if os(macOS)
    /// Non-`max_output_tokens` reasons (e.g. `content_filter`) are still
    /// surfaced as retryable stream errors — upstream parity with the
    /// `ApiError::Stream` behavior. Only `max_output_tokens` gets the
    /// soft-success peel-off below.
    func testURLSessionResponsesClientResponseIncompleteContentFilterThrows()
    async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created"}

        data: {"type":"response.incomplete","response":{"id":"resp_inc","incomplete_details":{"reason":"content_filter"}}}

        """
        guard let (srv, port) = makeOneShotServer(dir, responseBody: evt)
        else { return XCTFail("could not start local server") }
        defer { srv.terminate() }

        let client = URLSessionResponsesClient(
            apiKey: "test",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        let r = await drainErrorLocal(client)
        XCTAssertTrue(r.errored, "non-max_output_tokens incomplete must still throw")
        XCTAssertTrue(r.isModelError, r.message)
        XCTAssertTrue(r.retryable)
        XCTAssertTrue(r.message.contains("content_filter")
                      || r.message.contains("Incomplete"), r.message)
    }

    /// STATUS.md:624-629 — `max_output_tokens` incomplete is the
    /// terminal-success peel-off: the SSE driver must yield `.completed`
    /// (with whatever usage was recorded) instead of throwing, so the
    /// turn keeps its partial output rather than retrying into the same
    /// budget wall forever.
    func testURLSessionResponsesClientResponseIncompleteMaxOutputTokensSoftSuccess()
    async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created"}

        data: {"type":"response.incomplete","response":{"id":"resp_max","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":12,"output_tokens":80,"total_tokens":92}}}

        """
        guard let (srv, port) = makeOneShotServer(dir, responseBody: evt)
        else { return XCTFail("could not start local server") }
        defer { srv.terminate() }

        let client = URLSessionResponsesClient(
            apiKey: "test",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        let r = await drainErrorLocal(client)
        XCTAssertFalse(r.errored,
                       "max_output_tokens must be soft-success (no throw): \(r.message)")
    }

    func testURLSessionResponsesClientResponseFailedQuotaExceededClassified()
    async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created"}

        data: {"type":"response.failed","response":{"id":"resp_q","error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}}

        """
        guard let (srv, port) = makeOneShotServer(dir, responseBody: evt)
        else { return XCTFail("could not start local server") }
        defer { srv.terminate() }

        let client = URLSessionResponsesClient(
            apiKey: "test",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        let r = await drainErrorLocal(client)
        XCTAssertTrue(r.errored)
        XCTAssertTrue(r.isModelError, r.message)
        XCTAssertFalse(r.retryable,
                       "quota_exceeded must be terminal")
        XCTAssertEqual(r.codexErrorCode, .quotaExceeded)
    }

    func testURLSessionResponsesClientResponseFailedContextWindowClassified()
    async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created"}

        data: {"type":"response.failed","response":{"id":"resp_c","error":{"code":"context_length_exceeded","message":"maximum context length is 8192 tokens"}}}

        """
        guard let (srv, port) = makeOneShotServer(dir, responseBody: evt)
        else { return XCTFail("could not start local server") }
        defer { srv.terminate() }

        let client = URLSessionResponsesClient(
            apiKey: "test",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        let r = await drainErrorLocal(client)
        XCTAssertTrue(r.errored)
        XCTAssertTrue(r.isModelError, r.message)
        XCTAssertEqual(r.codexErrorCode, .contextWindowExceeded,
                       "context_length_exceeded must be classified so the turn loop can trim history (P6.3)")
        XCTAssertTrue(r.retryable,
                      "context_window_exceeded is retryable upstream — the trim-and-retry loop relies on this")
    }
    #endif
}

// MARK: – Local helpers (kept private to this file to avoid name collisions
// with `OpenAIClientFailureTests`).

#if os(macOS)
private struct LocalErrorDrain: Sendable {
    var errored: Bool
    var isModelError: Bool
    var retryable: Bool
    var message: String
    var httpStatus: Int?
    var codexErrorCode: CodexErrorCode?
}

private func drainErrorLocal(_ client: any ModelClient) async -> LocalErrorDrain {
    do {
        let s = try await client.stream(
            Prompt(instructions: "x", input: [.userText("hi")]),
            ModelSettings(model: "gpt-4o-mini",
                          threadId: "thread-p62"))
        for try await _ in s.events {}
        return LocalErrorDrain(errored: false, isModelError: false,
                               retryable: false, message: "",
                               httpStatus: nil, codexErrorCode: nil)
    } catch let e as ModelError {
        return LocalErrorDrain(errored: true, isModelError: true,
                               retryable: e.retryable, message: e.message,
                               httpStatus: e.httpStatus,
                               codexErrorCode: e.codexErrorCode)
    } catch {
        return LocalErrorDrain(errored: true, isModelError: false,
                               retryable: false, message: "\(error)",
                               httpStatus: nil, codexErrorCode: nil)
    }
}

private func tmpDir() -> String {
    let p = NSTemporaryDirectory() + "p62-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

private func pyQuote(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
}

private func makeOneShotServer(_ dir: String, responseBody: String,
                               status: String = "200 OK")
-> (Process, Int)? {
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
        body = (\(pyQuote(responseBody))).encode()
        hdr = ("HTTP/1.1 \(status)\\r\\n"
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
#endif
