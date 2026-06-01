import XCTest
import Foundation
@testable import ModelClient
@testable import InfraPrimitives

/// Spawns a one-shot local TCP server (via python3) that serves a single
/// fixed HTTP response, then returns its `127.0.0.1:<port>` base URL. The
/// server prints its chosen ephemeral port on stdout line 1.
private func oneShotServer(_ dir: String, responseBody: String,
                           extraHeaders: String = "",
                           status: String = "200 OK") -> (Process, Int)? {
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
        body = (\(jsonQuoted(responseBody))).encode()
        hdr = ("HTTP/1.1 \(status)\\r\\n"
               + \(jsonQuoted(extraHeaders)) +
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

private func oneShotCaptureServer(_ dir: String, responseBody: String,
                                  requestPath: String,
                                  status: String = "200 OK") -> (Process, Int)? {
    let script = dir + "/capture_srv.py"
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
        req = b""
        while b"\\r\\n\\r\\n" not in req:
            chunk = c.recv(4096)
            if not chunk:
                break
            req += chunk
        head, _, rest = req.partition(b"\\r\\n\\r\\n")
        clen = 0
        for line in head.split(b"\\r\\n"):
            if line.lower().startswith(b"content-length:"):
                try:
                    clen = int(line.split(b":", 1)[1].strip())
                except Exception:
                    clen = 0
        body = rest
        while len(body) < clen:
            chunk = c.recv(4096)
            if not chunk:
                break
            body += chunk
        open(\(jsonQuoted(requestPath)), "wb").write(head + b"\\r\\n\\r\\n" + body)
        resp_body = (\(jsonQuoted(responseBody))).encode()
        hdr = ("HTTP/1.1 \(status)\\r\\n"
               "Content-Type: text/event-stream\\r\\n"
               "Connection: close\\r\\n"
               "Content-Length: " + str(len(resp_body)) + "\\r\\n\\r\\n").encode()
        c.sendall(hdr + resp_body)
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

private func cancellableSSEServer(_ dir: String, closedPath: String) -> (Process, Int)? {
    let script = dir + "/cancel_srv.py"
    let py = """
    import socket, sys, time
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    sys.stdout.write(str(s.getsockname()[1]) + "\\n")
    sys.stdout.flush()
    try:
        c, _ = s.accept()
        c.recv(65536)
        hdr = ("HTTP/1.1 200 OK\\r\\n"
               "Content-Type: text/event-stream\\r\\n"
               "Connection: close\\r\\n\\r\\n").encode()
        c.sendall(hdr + b'data: {"type":"response.created","response":{"id":"r"}}\\n\\n')
        while True:
            time.sleep(0.1)
            try:
                c.sendall(b": keepalive\\n\\n")
            except Exception:
                open(\(jsonQuoted(closedPath)), "w").write("closed")
                break
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

private func hangingNoResponseServer(_ dir: String) -> (Process, Int)? {
    let script = dir + "/hang_srv.py"
    let py = """
    import socket, sys, time
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    sys.stdout.write(str(s.getsockname()[1]) + "\\n")
    sys.stdout.flush()
    try:
        c, _ = s.accept()
        c.recv(65536)
        time.sleep(30)
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

/// Minimal JSON string literal for embedding into the python source.
private func jsonQuoted(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
}

private func cfTmp() -> String {
    let p = NSTemporaryDirectory() + "clientfail-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

/// Sendable outcome of draining a client stream (avoids carrying a
/// non-Sendable `any Error` across the timeout task group).
private struct DrainResult: Sendable {
    var errored: Bool
    var isModelError: Bool
    var message: String
}

private struct EventDrainResult: Sendable {
    var events: [ResponseEvent]
    var errored: Bool
    var message: String
}

private struct ErrorDrainResult: Sendable {
    var errored: Bool
    var isModelError: Bool
    var retryable: Bool
    var message: String
    var httpStatus: Int?
    var retryAfterSeconds: Double?
}

/// Free function (not an XCTestCase method) so the timeout closure does not
/// capture non-Sendable `self`.
private func drainClient(_ client: OpenAIResponsesClient) async -> DrainResult {
    do {
        let s = try await client.stream(
            Prompt(instructions: "x", input: [.userText("hi")]),
            ModelSettings(model: "gpt-4o-mini", threadId: "t"))
        for try await _ in s.events {}
        return DrainResult(errored: false, isModelError: false, message: "")
    } catch let e as ModelError {
        return DrainResult(errored: true, isModelError: true, message: e.message)
    } catch {
        return DrainResult(errored: true, isModelError: false, message: "\(error)")
    }
}

private func drainEvents(_ client: any ModelClient) async -> EventDrainResult {
    do {
        let s = try await client.stream(
            Prompt(instructions: "x", input: [.userText("hi")]),
            ModelSettings(model: "gpt-4o-mini",
                          threadId: "thread-native",
                          turnState: "native-turn-state",
                          previousResponseId: "resp_native_prev"))
        var events: [ResponseEvent] = []
        for try await ev in s.events { events.append(ev) }
        return EventDrainResult(events: events, errored: false, message: "")
    } catch let e as ModelError {
        return EventDrainResult(events: [], errored: true, message: e.message)
    } catch {
        return EventDrainResult(events: [], errored: true, message: "\(error)")
    }
}

private func drainError(_ client: any ModelClient) async -> ErrorDrainResult {
    do {
        let s = try await client.stream(
            Prompt(instructions: "x", input: [.userText("hi")]),
            ModelSettings(model: "gpt-4o-mini",
                          threadId: "thread-native",
                          turnState: "native-turn-state",
                          previousResponseId: "resp_native_prev"))
        for try await _ in s.events {}
        return ErrorDrainResult(errored: false, isModelError: false,
                                retryable: false,
                                message: "", httpStatus: nil,
                                retryAfterSeconds: nil)
    } catch let e as ModelError {
        return ErrorDrainResult(errored: true, isModelError: true,
                                retryable: e.retryable,
                                message: e.message, httpStatus: e.httpStatus,
                                retryAfterSeconds: e.retryAfter?.seconds)
    } catch {
        return ErrorDrainResult(errored: true, isModelError: false,
                                retryable: false,
                                message: "\(error)", httpStatus: nil,
                                retryAfterSeconds: nil)
    }
}

private func processList() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "command"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Bounds an async operation so a hung client can never hang the test.
private func withTimeout<T: Sendable>(seconds: Double,
                                      _ op: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { g in
        g.addTask { await op() }
        g.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await g.next() ?? nil
        g.cancelAll()
        return first
    }
}

final class OpenAIClientFailureTests: XCTestCase {

    #if os(macOS)
    func testURLSessionResponsesClientStreamsLocalSSEAndSendsHeaders() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let requestPath = dir + "/request.bin"
        let evt = """
        data: {"type":"response.created","response":{"id":"resp_1"}}

        data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"HELLO"}

        data: {"type":"response.output_item.done","item":{"type":"message","id":"msg_1","content":[{"text":"HELLO"}]}}

        data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2,"input_tokens_details":{"cached_tokens":0}}}}

        """
        guard let (srv, port) = oneShotCaptureServer(
            dir, responseBody: evt, requestPath: requestPath)
        else { return XCTFail("could not start local capture server") }
        defer { srv.terminate() }

        let client = URLSessionResponsesClient(
            apiKey: "test-native-secret",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            maxOutputTokens: 7,
            limits: Limits())
        guard let result = await withTimeout(seconds: 25, {
            await drainEvents(client)
        }) else {
            return XCTFail("URLSession client hung on local SSE")
        }
        XCTAssertFalse(result.errored, result.message)
        XCTAssertTrue(result.events.contains(.created))
        XCTAssertTrue(result.events.contains(.agentDelta(itemId: "msg_1",
                                                        delta: "HELLO")))
        XCTAssertTrue(result.events.contains(.agentDone(itemId: "msg_1",
                                                       text: "HELLO")))
        // F5: usage breakdown is now populated; ignore it in the equality check
        // because the test fixture doesn't supply a specific UsageSnapshot.
        XCTAssertTrue(result.events.contains { ev in
            if case .completed(let rid, let total, let end, _) = ev {
                return rid == "resp_1" && total == 2 && end == true
            }
            return false
        })

        let req = try String(contentsOfFile: requestPath, encoding: .utf8)
        XCTAssertTrue(req.hasPrefix("POST /v1/responses HTTP/1.1"),
                      "native client posts to the Responses endpoint")
        XCTAssertTrue(req.contains("Authorization: Bearer test-native-secret"),
                      "credential is sent as an HTTP header")
        XCTAssertTrue(req.contains("\"prompt_cache_key\":\"thread-native\""),
                      "request body preserves the stable thread cache key")
        XCTAssertTrue(req.contains("x-codex-turn-state: native-turn-state"),
                      "native request preserves sticky turn-state as a header")
        XCTAssertFalse(req.contains("\"x_codex_turn_state\""),
                       "turn-state must not be sent as a Responses API body parameter")
        XCTAssertTrue(req.contains("\"previous_response_id\":\"resp_native_prev\""),
                      "native request body preserves within-turn previous_response_id")
        XCTAssertTrue(req.contains("\"max_output_tokens\":7"),
                      "request body preserves max output limit")
    }

    // Finding: a `response.created` frame WITHOUT a `response` object must NOT
    // emit `.created` (upstream responses.rs:307-311 gates Created on a
    // present `response`). The terminal `response.completed` still completes
    // the stream so the client returns cleanly.
    func testURLSessionResponseCreatedWithoutResponseIsNotEmitted() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created"}

        data: {"type":"response.output_text.delta","item_id":"m","delta":"HI"}

        data: {"type":"response.completed","response":{"id":"r1","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}

        """
        guard let (srv, port) = oneShotServer(dir, responseBody: evt) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let result = await withTimeout(seconds: 25, {
            await drainEvents(client)
        }) else { return XCTFail("client hung") }
        XCTAssertFalse(result.errored, result.message)
        XCTAssertFalse(result.events.contains(.created),
                       "bare response.created (no response object) must not emit .created")
        XCTAssertTrue(result.events.contains(.agentDelta(itemId: "m", delta: "HI")),
                      "subsequent frames must still be processed")
    }

    // Finding (v9): a reasoning-summary / reasoning-content delta frame that is
    // MISSING its index must NOT be emitted (upstream responses.rs:291-305
    // gates emission on both delta AND the index being present). A frame WITH
    // the index is emitted normally.
    func testURLSessionReasoningDeltaWithoutIndexIsDropped() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created","response":{"id":"r1"}}

        data: {"type":"response.reasoning_summary_text.delta","item_id":"r","delta":"NOINDEX"}

        data: {"type":"response.reasoning_summary_text.delta","item_id":"r","delta":"WITHINDEX","summary_index":2}

        data: {"type":"response.reasoning_text.delta","item_id":"r","delta":"CNOINDEX"}

        data: {"type":"response.reasoning_text.delta","item_id":"r","delta":"CWITHINDEX","content_index":1}

        data: {"type":"response.completed","response":{"id":"r1","usage":{"total_tokens":1}}}

        """
        guard let (srv, port) = oneShotServer(dir, responseBody: evt) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let result = await withTimeout(seconds: 25, {
            await drainEvents(client)
        }) else { return XCTFail("client hung") }
        XCTAssertFalse(result.errored, result.message)
        // The index-less summary delta must be dropped; the indexed one kept.
        XCTAssertFalse(result.events.contains { ev in
            if case .reasoningSummaryDelta(_, let d, _) = ev { return d == "NOINDEX" }
            return false
        }, "summary delta without summary_index must be dropped")
        XCTAssertTrue(result.events.contains { ev in
            if case .reasoningSummaryDelta(_, let d, let si) = ev {
                return d == "WITHINDEX" && si == 2
            }
            return false
        }, "summary delta with summary_index must be emitted")
        XCTAssertFalse(result.events.contains { ev in
            if case .reasoningContentDelta(_, let d, _) = ev { return d == "CNOINDEX" }
            return false
        }, "content delta without content_index must be dropped")
        XCTAssertTrue(result.events.contains { ev in
            if case .reasoningContentDelta(_, let d, let ci) = ev {
                return d == "CWITHINDEX" && ci == 1
            }
            return false
        }, "content delta with content_index must be emitted")
    }

    // Finding (v9): a `response.completed` frame whose `response` object lacks
    // a string `id` is a fatal stream error (upstream responses.rs:358-374
    // requires `id: String`); it must NOT silently default to "resp".
    func testURLSessionResponseCompletedMissingIdErrors() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created","response":{"id":"r1"}}

        data: {"type":"response.completed","response":{"usage":{"total_tokens":2}}}

        """
        guard let (srv, port) = oneShotServer(dir, responseBody: evt) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let result = await withTimeout(seconds: 25, {
            await drainEvents(client)
        }) else { return XCTFail("client hung") }
        XCTAssertTrue(result.errored,
                      "response.completed without id must surface a stream error")
        XCTAssertTrue(result.message.contains("ResponseCompleted"),
                      "error message must reference the parse failure: \(result.message)")
        XCTAssertFalse(result.events.contains { ev in
            if case .completed = ev { return true }
            return false
        }, "no .completed must be emitted for a malformed completed frame")
    }

    // Finding (v9): a well-formed `response.completed` (with id) still
    // completes normally — regression guard for the id-validation change.
    func testURLSessionResponseCompletedWithIdSucceeds() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created","response":{"id":"r1"}}

        data: {"type":"response.completed","response":{"id":"r1","usage":{"total_tokens":2}}}

        """
        guard let (srv, port) = oneShotServer(dir, responseBody: evt) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let result = await withTimeout(seconds: 25, {
            await drainEvents(client)
        }) else { return XCTFail("client hung") }
        XCTAssertFalse(result.errored, result.message)
        XCTAssertTrue(result.events.contains { ev in
            if case .completed(let rid, _, _, _) = ev { return rid == "r1" }
            return false
        })
    }

    // v10 finding: a stream that delivers frames but closes WITHOUT a
    // response.completed/failed must surface a retryable stream error
    // ("stream closed before response.completed"), not finish as success —
    // matching upstream process_sse Ok(None) (responses.rs:422-428) and test
    // error_when_missing_completed (responses.rs:701-727).
    func testURLSessionStreamClosedBeforeCompletedIsRetryableError() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created","response":{"id":"r1"}}

        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}

        """
        guard let (srv, port) = oneShotServer(dir, responseBody: evt) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let result = await withTimeout(seconds: 25, {
            await drainError(client)
        }) else { return XCTFail("client hung") }
        XCTAssertTrue(result.errored,
                      "truncated stream must surface a terminal error")
        XCTAssertTrue(result.retryable,
                      "stream-closed-before-completed must be retryable")
        XCTAssertEqual(result.message, "stream closed before response.completed",
                       "must match upstream ApiError::Stream message exactly")
    }

    // v10 finding: a stray top-level `{"error":{...}}` data frame (no
    // recognized `type`) must be IGNORED and the stream must continue, matching
    // upstream's `_ =>` unhandled arm (responses.rs:266-394). The downstream
    // response.completed still terminates the stream cleanly.
    func testURLSessionTopLevelErrorFrameIsIgnored() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created","response":{"id":"r1"}}

        data: {"error":{"message":"some transient provider noise"}}

        data: {"type":"response.completed","response":{"id":"r1","usage":{"total_tokens":3}}}

        """
        guard let (srv, port) = oneShotServer(dir, responseBody: evt) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let result = await withTimeout(seconds: 25, {
            await drainEvents(client)
        }) else { return XCTFail("client hung") }
        XCTAssertFalse(result.errored,
                       "top-level error frame must NOT abort the stream: \(result.message)")
        XCTAssertTrue(result.events.contains { ev in
            if case .completed(let rid, _, _, _) = ev { return rid == "r1" }
            return false
        }, "stream must reach response.completed despite the stray error frame")
    }

    // Finding (v9): the model client surfaces a `.rateLimits` event when the
    // response carries the codex rate-limit header family, so the SessionEngine
    // can forward `account/rateLimits/updated`
    // (bespoke_event_handling.rs:1571-1579).
    func testURLSessionEmitsRateLimitsEventFromHeaders() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.created","response":{"id":"r1"}}

        data: {"type":"response.completed","response":{"id":"r1","usage":{"total_tokens":1}}}

        """
        let headers = "x-codex-primary-used-percent: 37\r\n"
            + "x-codex-primary-window-minutes: 60\r\n"
        guard let (srv, port) = oneShotServer(
            dir, responseBody: evt, extraHeaders: headers) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let result = await withTimeout(seconds: 25, {
            await drainEvents(client)
        }) else { return XCTFail("client hung") }
        XCTAssertFalse(result.errored, result.message)
        XCTAssertTrue(result.events.contains { ev in
            if case .rateLimits(let snap) = ev {
                return snap.limitId == "codex" && snap.primary?.usedPercent == 37
            }
            return false
        }, "primary rate-limit snapshot must be surfaced as a .rateLimits event")
    }

    // v10 finding: pre-body header events must be emitted in upstream's order
    // — ServerModel BEFORE RateLimits (then ModelsEtag, ServerReasoningIncluded)
    // (spawn_response_stream, responses.rs:64-78).
    func testURLSessionHeaderSignalsOrderServerModelBeforeRateLimits() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = """
        data: {"type":"response.completed","response":{"id":"r1","usage":{"total_tokens":1}}}

        """
        let headers = "openai-model: gpt-5-effective\r\n"
            + "x-codex-primary-used-percent: 42\r\n"
        guard let (srv, port) = oneShotServer(
            dir, responseBody: evt, extraHeaders: headers) else {
            return XCTFail("could not start local server")
        }
        defer { srv.terminate() }
        let client = URLSessionResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let result = await withTimeout(seconds: 25, {
            await drainEvents(client)
        }) else { return XCTFail("client hung") }
        XCTAssertFalse(result.errored, result.message)
        let modelIdx = result.events.firstIndex { ev in
            if case .serverModel = ev { return true }; return false
        }
        let rateIdx = result.events.firstIndex { ev in
            if case .rateLimits = ev { return true }; return false
        }
        XCTAssertNotNil(modelIdx, "serverModel must be emitted")
        XCTAssertNotNil(rateIdx, "rateLimits must be emitted")
        if let m = modelIdx, let r = rateIdx {
            XCTAssertLessThan(m, r, "ServerModel must precede RateLimits (upstream order)")
        }
    }

    func testURLSessionResponsesClient429SurfacesRetryAfter() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let (srv, port) = oneShotServer(
            dir,
            responseBody: "rate limited",
            extraHeaders: "Retry-After: 0.25\r\n",
            status: "429 Too Many Requests")
        else { return XCTFail("could not start local 429 server") }
        defer { srv.terminate() }

        let client = URLSessionResponsesClient(
            apiKey: "test-native-secret",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let result = await withTimeout(seconds: 10, {
            await drainError(client)
        }) else {
            return XCTFail("URLSession client hung on local 429")
        }
        XCTAssertTrue(result.isModelError, result.message)
        XCTAssertEqual(result.httpStatus, 429)
        XCTAssertEqual(result.retryAfterSeconds ?? -1, 0.25, accuracy: 0.001)
    }

    func testURLSessionResponsesClientHonorsTurnDeadlineTimeout() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let (srv, port) = hangingNoResponseServer(dir)
        else { return XCTFail("could not start hanging SSE server") }
        defer { srv.terminate() }
        var limits = Limits()
        limits.turnDeadline = .seconds(1)
        let client = URLSessionResponsesClient(
            apiKey: "test-native-secret",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: limits)
        let start = MonotonicClock.now()
        guard let result = await withTimeout(seconds: 8, {
            await drainError(client)
        }) else {
            return XCTFail("URLSession client ignored the configured deadline")
        }
        let elapsed = MonotonicClock.now() - start
        XCTAssertTrue(result.errored, "hung server must surface an error")
        XCTAssertLessThan(elapsed, 7.5,
                          "URLSession deadline should prevent long hangs")
    }

    #if canImport(Network)
    func testWebSocketResponsesClientBadHandshakeFailsRetryablyWithoutHanging() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let (srv, port) = oneShotServer(
            dir,
            responseBody: "this is not a websocket upgrade",
            status: "200 OK")
        else { return XCTFail("could not start local bad-handshake server") }
        defer { srv.terminate() }

        var limits = Limits()
        limits.turnDeadline = .seconds(1)
        let client = WebSocketResponsesClient(
            apiKey: "test-ws-secret",
            endpoint: "ws://127.0.0.1:\(port)/v1/responses",
            limits: limits,
            options: .init(prewarm: false, explicitNoZstd: true))

        guard let result = await withTimeout(seconds: 8, {
            await drainError(client)
        }) else {
            return XCTFail("WebSocket client hung on a failed upgrade")
        }
        XCTAssertTrue(result.isModelError, result.message)
        XCTAssertTrue(result.retryable,
                      "failed WS handshakes must be retryable so HTTPS fallback can engage: \(result.message)")
        XCTAssertTrue(result.message.contains("websocket"), result.message)
    }
    #endif
    #endif

    func testGarbledSSEBodyYieldsCleanModelError() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let (srv, port) = oneShotServer(dir,
            responseBody: "data: this is not json\n\ndata: also-bad\n\ndata: [DONE]\n\n")
        else { return XCTFail("could not start local server") }
        defer { srv.terminate() }
        let client = OpenAIResponsesClient(
            apiKey: "test",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let r = await withTimeout(seconds: 25, { await drainClient(client) }) else {
            return XCTFail("client hung on garbled SSE (no timeout)")
        }
        XCTAssertTrue(r.errored, "garbled SSE must surface an error, not succeed")
        XCTAssertTrue(r.isModelError, "surfaced as a clean ModelError: \(r.message)")
    }

    // v10 finding: an SSE frame whose `type` is not recognized (here a
    // top-level `{"type":"error","error":{...}}` frame, which has NO matching
    // arm upstream) must be IGNORED — `process_responses_event` routes it to
    // the `_ =>` unhandled arm and returns Ok(None) (responses.rs:266-394),
    // the `ResponsesStreamEvent` struct has no `error` field, and genuine
    // errors arrive only inside `response.failed`. The stream then closes with
    // no terminal event, so the client surfaces the retryable
    // "stream closed before response.completed" (responses.rs:422-428) rather
    // than the frame's own message. This replaces the prior (divergent)
    // behavior that aborted non-retryably on any top-level `error` key.
    func testSSEUnhandledErrorFrameIsIgnoredThenStreamClosed() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let evt = "data: {\"type\":\"error\",\"error\":{\"message\":\"rate limited\"}}\n\n"
        guard let (srv, port) = oneShotServer(dir, responseBody: evt)
        else { return XCTFail("could not start local server") }
        defer { srv.terminate() }
        let client = OpenAIResponsesClient(
            apiKey: "test",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let r = await withTimeout(seconds: 25, { await drainClient(client) }) else {
            return XCTFail("client hung on SSE error event")
        }
        XCTAssertTrue(r.errored, "stream closed without a terminal event must error")
        XCTAssertTrue(r.isModelError, "expected ModelError: \(r.message)")
        XCTAssertEqual(r.message, "stream closed before response.completed",
                       "unrecognized frame is ignored; truncated stream surfaces the upstream message")
        XCTAssertFalse(r.message.contains("rate limited"),
                       "the stray frame's message must NOT be surfaced as a hard failure")
    }

    func testImmediatelyClosedConnectionYieldsCleanModelError() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let (srv, port) = oneShotServer(dir, responseBody: "")
        else { return XCTFail("could not start local server") }
        defer { srv.terminate() }
        let client = OpenAIResponsesClient(
            apiKey: "test",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        guard let r = await withTimeout(seconds: 25, { await drainClient(client) }) else {
            return XCTFail("client hung on closed connection")
        }
        XCTAssertTrue(r.errored, "an empty/closed response must surface an error")
        XCTAssertTrue(r.isModelError, "clean ModelError on no usable SSE: \(r.message)")
    }

    func testCurlSSECancellationClosesUpstreamConnection() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let closedPath = dir + "/closed.txt"
        guard let (srv, port) = cancellableSSEServer(dir, closedPath: closedPath)
        else { return XCTFail("could not start cancellable SSE server") }
        defer { srv.terminate() }
        let client = OpenAIResponsesClient(
            apiKey: "test",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        let stream = try await client.stream(
            Prompt(instructions: "x", input: [.userText("hi")]),
            ModelSettings(model: "gpt-4o-mini", threadId: "cancel-thread"))
        let signal = AsyncStream<Bool>.makeStream()
        let task = Task {
            var yielded = false
            do {
                for try await ev in stream.events {
                    if ev == .created && !yielded {
                        yielded = true
                        signal.continuation.yield(true)
                    }
                }
            } catch {
            }
        }
        let first = await withTimeout(seconds: 10) { () async -> Bool in
            for await value in signal.stream {
                return value
            }
            return false
        }
        XCTAssertEqual(first, true, "test server delivered the first SSE event")
        task.cancel()

        let taskEnded = await withTimeout(seconds: 10) { () async -> Bool in
            _ = await task.result
            return true
        }
        XCTAssertEqual(taskEnded, true, "cancelled SSE consumer task ended promptly")

        let closed = await withTimeout(seconds: 10) { () async -> Bool in
            while !FileManager.default.fileExists(atPath: closedPath) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return true
        }
        XCTAssertEqual(closed, true,
                       "ending iteration terminates curl and closes the SSE connection")
    }

    func testCurlDoesNotExposeBearerTokenInProcessArguments() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let closedPath = dir + "/closed.txt"
        guard let (srv, port) = cancellableSSEServer(dir, closedPath: closedPath)
        else { return XCTFail("could not start cancellable SSE server") }
        defer { srv.terminate() }
        let secret = "test-secret-not-in-argv-\(UUID().uuidString)"
        let client = OpenAIResponsesClient(
            apiKey: secret,
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: Limits())
        let stream = try await client.stream(
            Prompt(instructions: "x", input: [.userText("hi")]),
            ModelSettings(model: "gpt-4o-mini", threadId: "argv-thread"))
        let signal = AsyncStream<Bool>.makeStream()
        let task = Task {
            var yielded = false
            do {
                for try await ev in stream.events {
                    if ev == .created && !yielded {
                        yielded = true
                        signal.continuation.yield(true)
                    }
                }
            } catch {
            }
        }
        let first = await withTimeout(seconds: 10) { () async -> Bool in
            for await value in signal.stream {
                return value
            }
            return false
        }
        XCTAssertEqual(first, true, "test server delivered the first SSE event")
        let argv = processList()
        task.cancel()
        let taskEnded = await withTimeout(seconds: 10) { () async -> Bool in
            _ = await task.result
            return true
        }
        XCTAssertEqual(taskEnded, true,
                       "cancelled argv-redaction SSE consumer task ended promptly")
        XCTAssertFalse(argv.contains(secret),
                       "portable curl fallback must not expose bearer tokens in argv")
    }

    func testCurlSSETransportTimeoutYieldsCleanModelError() async throws {
        let dir = cfTmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        guard let (srv, port) = hangingNoResponseServer(dir)
        else { return XCTFail("could not start hanging SSE server") }
        defer { srv.terminate() }
        var limits = Limits()
        limits.turnDeadline = .seconds(1)
        let client = OpenAIResponsesClient(
            apiKey: "test",
            endpoint: "http://127.0.0.1:\(port)/v1/responses",
            limits: limits)
        guard let r = await withTimeout(seconds: 8, { await drainClient(client) }) else {
            return XCTFail("client ignored the transport timeout and hung")
        }
        XCTAssertTrue(r.errored, "transport timeout must surface as an error")
        XCTAssertTrue(r.isModelError, "timeout surfaces as a clean ModelError: \(r.message)")
    }
}
