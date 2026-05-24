import Foundation
import InfraPrimitives
import Tools
import ProtocolModel
import WireProtocol

private final class HTTPProcBox: @unchecked Sendable {
    let process: Process
    let outHandle: FileHandle
    init(_ p: Process, _ h: FileHandle) { process = p; outHandle = h }
}

private final class ContBox: @unchecked Sendable {
    let cont: CheckedContinuation<String, any Error>
    init(_ c: CheckedContinuation<String, any Error>) { cont = c }
}

private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// One unit emitted by the streaming HTTP reader. Either the status code +
/// content-type (delivered first, before any body), one parsed JSON frame
/// (an SSE `data:` event or a single JSON object), or end-of-stream.
internal enum HttpStreamEvent: Sendable {
    case head(status: Int, contentType: String)
    case frame([String: JSONLite])
    case end
}

/// Streamable-HTTP JSON-RPC MCP client. Each request is an independent
/// `POST <url>` carried out by curl. The response is parsed as a single JSON
/// object or as Server-Sent Events (`data:` lines); the JSON-RPC object whose
/// `id` matches is selected. HTTP is connectionless here so `start()`/`stop()`
/// are no-ops.
///
/// Streaming model: the response body is consumed incrementally on a dedicated
/// OS thread using `FileHandle.availableData` against the curl stdout pipe,
/// rather than `readDataToEndOfFile()`. This matters for SSE responses where
/// the server may emit a frame (e.g. `elicitation/create`) and then hold the
/// connection open pending the client's reply. The reader parses SSE events
/// as their `\n\n` terminator arrives and forwards them up via an
/// `AsyncThrowingStream`, which lets `processResponse` reply to a server
/// request on a fresh connection without first draining the original.
public actor McpHttpClient: McpClientProtocol {
    public let config: McpServerConfig
    private let requestTimeout: Duration
    private let oauthStore: McpOAuthStore?
    private let env: [String: String]
    private let notificationSink: any McpNotificationSink
    private var nextId = 1
    private var initialized = false
    /// Single-flight reinitialization task. When an HTTP 404 (session
    /// expired) is observed, the first caller installs a Task here that
    /// re-runs the initialize handshake; concurrent callers `await` the
    /// same Task instead of each triggering their own re-init (parity
    /// with upstream `session_recovery_lock` semaphore in
    /// `reinitialize_after_session_expiry`).
    private var pendingReinit: Task<Void, any Error>?

    /// Initializes a Streamable-HTTP MCP client. If `requestTimeout` is
    /// `nil` (the new default), the per-call timeout is taken from
    /// `config.effectiveToolTimeout` — the upstream `tool_timeout_sec`
    /// (default **120s**; previously hardcoded to 30s).
    public init(_ config: McpServerConfig, requestTimeout: Duration? = nil,
                env: [String: String] = ProcessInfo.processInfo.environment,
                oauthStore: McpOAuthStore? = nil,
                notificationSink: (any McpNotificationSink)? = nil) {
        self.config = config
        if let requestTimeout {
            self.requestTimeout = requestTimeout
        } else {
            let secs = config.effectiveToolTimeout
            let whole = Swift.max(1, Int(secs.rounded(.up)))
            self.requestTimeout = .seconds(whole)
        }
        self.env = env
        self.oauthStore = oauthStore
        self.notificationSink = notificationSink ?? StderrMcpNotificationSink()
    }

    public func start() throws {}   // HTTP is connectionless.
    public func stop() async {}     // No persistent process.

    /// Test-only: number of times `reinitialize()` has run to completion.
    /// Asserts that concurrent 404 callers fold into a single recovery.
    public private(set) var reinitCount: Int = 0

    // MARK: - Auth precedence

    internal func authorizationHeader(env: [String: String]) -> String? {
        if let v = config.bearerTokenEnvVar, let val = env[v], !val.isEmpty {
            return "Bearer \(val)"
        }
        if let store = oauthStore,
           let t = store.load(server: config.name), !t.isExpired {
            return "Bearer \(t.accessToken)"
        }
        return nil
    }

    internal func authorizationHeaderForTesting() -> String? {
        authorizationHeader(env: env)
    }

    // MARK: - Response parsing (legacy buffered helpers, retained for tests)

    /// Buffered helper kept for the unit test `testSSEResponseExtractionByID`.
    /// Not used on the live transport — see `processResponse` for the
    /// streaming reader.
    internal static func parseRPCResponse(body: String,
                                          id: Int) -> [String: JSONLite]? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let first = trimmed.first, first == "{" || first == "[" {
            guard let d = trimmed.data(using: .utf8),
                  let v = try? JSONLite.parse(d),
                  case .object(let o) = v else { return nil }
            return o
        }
        for frame in extractJSONFrames(body: body) {
            if let idv = frame["id"], case .number(let n) = idv, Int(n) == id {
                return frame
            }
        }
        return nil
    }

    /// Buffered helper kept for tests that exercise the SSE framer offline.
    internal static func extractJSONFrames(body: String) -> [[String: JSONLite]] {
        var out: [[String: JSONLite]] = []
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return out }
        if let first = trimmed.first, first == "{" || first == "[" {
            if let d = trimmed.data(using: .utf8),
               let v = try? JSONLite.parse(d),
               case .object(let o) = v {
                out.append(o)
            }
            return out
        }
        for raw in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5))
                .trimmingCharacters(in: .whitespaces)
            guard let d = payload.data(using: .utf8),
                  let v = try? JSONLite.parse(d),
                  case .object(let o) = v else { continue }
            out.append(o)
        }
        return out
    }

    // MARK: - Request

    /// One pass through the request → curl → parse pipeline. Factored out
    /// so that we can retry exactly once after a session-expired 404,
    /// reusing all the header / param / id-bookkeeping logic for both
    /// attempts.
    private func curlArgs(for url: String) -> [String] {
        let secs = Int(requestTimeout.components.seconds)
        var args = ["curl", "-sS", "-N", "-i",
                    "--max-time", String(Swift.max(1, secs)),
                    "-X", "POST", url,
                    "-H", "Content-Type: application/json",
                    "-H", "Accept: application/json, text/event-stream"]
        if let auth = authorizationHeader(env: env) {
            args += ["-H", "Authorization: \(auth)"]
        }
        for k in config.httpHeaders.keys.sorted() {
            args += ["-H", "\(k): \(config.httpHeaders[k] ?? "")"]
        }
        // Upstream parity: `env_http_headers = { K = "ENV_VAR_NAME" }`
        // adds header `K: <env[ENV_VAR_NAME]>` if the named env var is
        // set and non-empty. Unset/empty vars are skipped silently — same
        // behavior as upstream which omits the header rather than sending
        // an empty value.
        if let envHeaders = config.envHttpHeaders {
            for k in envHeaders.keys.sorted() {
                guard let varName = envHeaders[k], !varName.isEmpty,
                      let value = env[varName], !value.isEmpty else { continue }
                args += ["-H", "\(k): \(value)"]
            }
        }
        // Note: `-i` (above) makes curl include the HTTP response status
        // line + headers in stdout. We parse them out incrementally —
        // this replaces the previous `-w "\n__HTTPSTATUS__:%{http_code}"`
        // trick, which only fires at curl exit and is therefore
        // incompatible with streaming SSE.
        args += ["--data-binary", "@-"]
        return args
    }

    /// Run a request and (if a JSON-RPC response is expected) return its
    /// matched `result` payload. This is the core dispatcher and the
    /// place where 404 → re-initialize → retry is implemented.
    /// `elicitationHandler` is honored when the server returns
    /// `elicitation/create` server requests in the response stream
    /// (H-49 / area-04 F5).
    private func request(method: String, params: Any,
                         expectResult: Bool,
                         elicitationHandler: McpElicitationHandler? = nil)
        async throws -> [String: JSONLite] {
        guard let url = config.url, !url.isEmpty else {
            throw McpError.transport("no url")
        }
        let id = nextId; nextId += 1
        var msg: [String: Any] = [
            "jsonrpc": "2.0", "method": method, "params": params,
        ]
        if expectResult { msg["id"] = id }
        let body = try JSONSerialization.data(withJSONObject: msg,
                                              options: [.sortedKeys])
        let args = curlArgs(for: url)

        if !expectResult {
            // Notifications: fire-and-forget. We still drive the stream
            // to completion so curl exits cleanly, but we don't inspect
            // the body. Errors are swallowed (parity with the previous
            // `_ = try? await runCurlPOST` behaviour).
            do {
                let stream = try await streamCurlPOST(args: args, body: body)
                for try await _ in stream {}
            } catch {
                // Intentionally ignored.
            }
            return [:]
        }

        // First attempt.
        do {
            return try await processStreamingResponse(
                stream: try await streamCurlPOST(args: args, body: body),
                id: id, elicitationHandler: elicitationHandler,
                url: url, method: method)
        } catch let McpError.transport(msg) where msg.hasPrefix("HTTP 404")
            && method != "initialize" {
            // Session expired. Run a single-flight reinitialize and
            // retry once. Subsequent 404s after a fresh re-init are
            // surfaced to the caller.
            try await reinitialize()
            let args2 = curlArgs(for: url)
            return try await processStreamingResponse(
                stream: try await streamCurlPOST(args: args2, body: body),
                id: id, elicitationHandler: elicitationHandler,
                url: url, method: method)
        }
    }

    /// Drive the streaming reader for one request. Dispatches notifications
    /// and elicitations as their frames arrive. Returns the matching
    /// JSON-RPC `result` payload when it appears in the stream.
    ///
    /// On HTTP 404 we throw `McpError.transport("HTTP 404")` so the caller
    /// can implement the single-flight session-recovery retry.
    private func processStreamingResponse(
        stream: AsyncThrowingStream<HttpStreamEvent, any Error>,
        id: Int,
        elicitationHandler: McpElicitationHandler?,
        url: String, method: String) async throws -> [String: JSONLite] {
        var matchedResult: [String: JSONLite]?
        var sawHead = false
        for try await event in stream {
            switch event {
            case .head(let status, _):
                sawHead = true
                if status >= 400 {
                    throw McpError.transport("HTTP \(status)")
                }
            case .frame(let frame):
                // Notifications: method present, id absent.
                if frame["id"] == nil, frame["method"] != nil {
                    if let notif = McpNotificationDecoder.decode(
                        server: config.name, object: frame) {
                        notificationSink.handle(notif)
                    }
                    continue
                }
                // Server-initiated request (elicitation/create has both
                // id + method). We must reply on `url` so the server
                // can correlate by JSON-RPC id at the application
                // layer.
                if case .string(let serverMethod)? = frame["method"],
                   case .number(let n)? = frame["id"] {
                    if serverMethod == "elicitation/create" {
                        let reqId = Int(n)
                        let result: JSONValue
                        if let handler = elicitationHandler {
                            let paramsValue: JSONValue
                            if let raw = frame["params"] {
                                paramsValue = McpClient.jsonLiteToValue(raw)
                            } else {
                                paramsValue = .object([:])
                            }
                            result = await handler(.int(Int64(reqId)), config.name,
                                                    paramsValue)
                                ?? .object(["action": .string("decline"),
                                            "content": .null,
                                            "_meta": .null])
                        } else {
                            // P7.2 follow-up: parity with the stdio
                            // path — when no handler is registered we
                            // must still reply with a `decline` so the
                            // server is not left waiting.
                            result = .object(["action": .string("decline"),
                                              "content": .null,
                                              "_meta": .null])
                        }
                        // Important: post the reply WITHOUT awaiting
                        // the original stream's completion. The
                        // server may be blocked on this reply before
                        // emitting the next frame.
                        try? await replyToServerRequest(url: url, id: reqId,
                                                         result: result)
                    }
                    continue
                }
                // Response to our request.
                if case .number(let n)? = frame["id"], Int(n) == id {
                    matchedResult = frame
                }
            case .end:
                break
            }
        }
        guard sawHead else {
            throw McpError.transport("no HTTP response")
        }
        guard let obj = matchedResult else {
            throw McpError.transport("no matching JSON-RPC response")
        }
        if let e = obj["error"], case .object(let eo) = e {
            let msg: String
            if case .string(let s)? = eo["message"] { msg = s } else { msg = "error" }
            throw McpError.server(msg)
        }
        if let r = obj["result"], case .object(let ro) = r { return ro }
        return [:]
    }

    /// Single-flight re-initialize. Concurrent callers awaiting a 404
    /// recovery all wait on the same Task so we never re-handshake more
    /// than once per expiry event (parity with the Rust
    /// `session_recovery_lock`).
    private func reinitialize() async throws {
        if let inflight = pendingReinit {
            try await inflight.value
            return
        }
        let task = Task<Void, any Error> { [weak self] in
            guard let self else { return }
            await self.markUninitialized()
            try await self.initialize()
            await self.bumpReinitCount()
        }
        pendingReinit = task
        defer { pendingReinit = nil }
        try await task.value
    }

    private func markUninitialized() { initialized = false }
    private func bumpReinitCount() { reinitCount += 1 }

    /// POST a JSON-RPC `result` response back to the server in reply to a
    /// server-initiated request (e.g. elicitation/create). The new
    /// connection is independent of the original request's connection;
    /// Streamable-HTTP correlates by message id at the application
    /// layer, not the transport.
    private func replyToServerRequest(url: String, id: Int,
                                       result: JSONValue) async throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": Self.jsonValueToAny(result),
        ]
        let body = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.sortedKeys])
        let args = curlArgs(for: url)
        // Drain — we don't care about the body for an outgoing reply,
        // but we must let the stream complete so curl exits.
        do {
            let stream = try await streamCurlPOST(args: args, body: body)
            for try await _ in stream {}
        } catch {
            // Reply post failures are not fatal; the original request's
            // stream still has to deliver our result frame.
        }
    }

    /// Convert a `JSONValue` (the rich elicitation result type) into
    /// `JSONSerialization`-compatible `Any` for posting back on the wire.
    private static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(jsonValueToAny(_:))
        case .object(let o):
            var dict = [String: Any](minimumCapacity: o.count)
            for (k, v) in o { dict[k] = jsonValueToAny(v) }
            return dict
        }
    }

    // MARK: - Streaming reader

    /// Launch curl for a POST and return an `AsyncThrowingStream` of
    /// `HttpStreamEvent`s. The producer runs on a dedicated OS thread
    /// that loops on `FileHandle.availableData`, parses HTTP headers
    /// once, then either accumulates a single JSON body or splits an SSE
    /// stream into `data:` events as they arrive.
    ///
    /// The stream completes when:
    ///   * curl exits (the body pipe reports EOF), or
    ///   * the curl watchdog elapses (`requestTimeout` + 3s grace), or
    ///   * the consumer stops iterating (the producer detects this via
    ///     the AsyncThrowingStream onTermination hook and terminates
    ///     the curl process).
    private func streamCurlPOST(args: [String], body: Data)
        async throws -> AsyncThrowingStream<HttpStreamEvent, any Error> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let inPipe = Pipe(); let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch { throw McpError.spawn("curl: \(error)") }
        let writeHandle = inPipe.fileHandleForWriting
        do {
            try writeHandle.write(contentsOf: body)
            try writeHandle.close()
        } catch {
            try? writeHandle.close()
        }
        let box = HTTPProcBox(p, outPipe.fileHandleForReading)
        let graceSecs = Swift.max(1, Int(requestTimeout.components.seconds)) + 3

        return AsyncThrowingStream<HttpStreamEvent, any Error> { continuation in
            let producer = Thread {
                Self.runStreamingReader(box: box, continuation: continuation)
            }
            producer.stackSize = 1 << 20
            producer.name = "ai.igent.codexkit.mcp.http.stream"
            producer.start()

            let watchdog = Thread {
                Thread.sleep(forTimeInterval: TimeInterval(graceSecs))
                if box.process.isRunning {
                    box.process.terminate()
                }
            }
            watchdog.stackSize = 1 << 20
            watchdog.name = "ai.igent.codexkit.mcp.http.stream.wd"
            watchdog.start()

            continuation.onTermination = { _ in
                // Consumer abandoned the stream; terminate curl so the
                // reader thread observes EOF promptly.
                if box.process.isRunning {
                    box.process.terminate()
                }
            }
        }
    }

    /// The streaming reader's main loop. Runs on `producer` (a non-actor
    /// OS thread) so blocking reads do not stall a cooperative executor.
    /// All state lives in locals; the only shared mutation is the
    /// `AsyncThrowingStream.Continuation` (which is itself thread-safe).
    private static func runStreamingReader(
        box: HTTPProcBox,
        continuation: AsyncThrowingStream<HttpStreamEvent, any Error>.Continuation
    ) {
        var headerBuf = Data()
        var bodyBuf = Data()         // For application/json: full body.
        var sseLineBuf = Data()      // For SSE: pending line bytes.
        var sseEventLines: [String] = []  // For SSE: lines of current event.
        var headersParsed = false
        var contentType = ""
        var isSSE = false

        while true {
            let chunk = box.outHandle.availableData
            if chunk.isEmpty {
                // EOF (process closed its stdout end of the pipe).
                break
            }
            var input = chunk
            // Header phase: keep accumulating until we see CRLFCRLF.
            if !headersParsed {
                headerBuf.append(input)
                if let split = Self.findHeaderTerminator(headerBuf) {
                    let headerBytes = headerBuf.prefix(split.terminatorStart)
                    let rest = headerBuf.suffix(
                        from: split.terminatorStart + split.terminatorLength)
                    let headerStr = String(decoding: headerBytes, as: UTF8.self)
                    let (status, ct) = Self.parseStatusAndContentType(headerStr)
                    contentType = ct
                    isSSE = ct.lowercased().hasPrefix("text/event-stream")
                    continuation.yield(.head(status: status, contentType: ct))
                    headersParsed = true
                    input = Data(rest)
                    headerBuf.removeAll(keepingCapacity: false)
                } else {
                    continue
                }
            }
            if input.isEmpty { continue }
            if isSSE {
                // Stream SSE: parse complete events as their blank-line
                // terminator arrives.
                sseLineBuf.append(input)
                while let nlRange = sseLineBuf.firstRange(of: Data([0x0A])) {
                    var lineBytes = sseLineBuf.prefix(nlRange.lowerBound)
                    sseLineBuf.removeSubrange(0..<nlRange.upperBound)
                    // Strip trailing CR (CRLF line endings).
                    if lineBytes.last == 0x0D {
                        lineBytes = lineBytes.dropLast()
                    }
                    let line = String(decoding: lineBytes, as: UTF8.self)
                    if line.isEmpty {
                        // Event terminator. Assemble the `data:` payload
                        // and parse it.
                        if !sseEventLines.isEmpty {
                            var payload = ""
                            for l in sseEventLines where l.hasPrefix("data:") {
                                let body = String(l.dropFirst(5))
                                    .trimmingCharacters(in: .whitespaces)
                                if !payload.isEmpty { payload += "\n" }
                                payload += body
                            }
                            sseEventLines.removeAll(keepingCapacity: true)
                            if !payload.isEmpty,
                               let d = payload.data(using: .utf8),
                               let v = try? JSONLite.parse(d),
                               case .object(let o) = v {
                                continuation.yield(.frame(o))
                            }
                        }
                    } else {
                        sseEventLines.append(line)
                    }
                }
            } else {
                bodyBuf.append(input)
            }
        }

        // EOF cleanup.
        if !headersParsed {
            // The connection closed before we even saw a complete header
            // block. Surface as an empty-response transport error.
            continuation.finish(throwing: McpError.transport("empty response"))
            if box.process.isRunning { box.process.terminate() }
            return
        }
        if isSSE {
            // Drain any pending event (e.g. server didn't send a final
            // blank line before closing).
            if !sseLineBuf.isEmpty {
                if sseLineBuf.last == 0x0D { sseLineBuf = sseLineBuf.dropLast() }
                let line = String(decoding: sseLineBuf, as: UTF8.self)
                if !line.isEmpty { sseEventLines.append(line) }
            }
            if !sseEventLines.isEmpty {
                var payload = ""
                for l in sseEventLines where l.hasPrefix("data:") {
                    let body = String(l.dropFirst(5))
                        .trimmingCharacters(in: .whitespaces)
                    if !payload.isEmpty { payload += "\n" }
                    payload += body
                }
                if !payload.isEmpty,
                   let d = payload.data(using: .utf8),
                   let v = try? JSONLite.parse(d),
                   case .object(let o) = v {
                    continuation.yield(.frame(o))
                }
            }
        } else {
            // Single JSON body.
            let trimmed = String(decoding: bodyBuf, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               let d = trimmed.data(using: .utf8),
               let v = try? JSONLite.parse(d) {
                if case .object(let o) = v {
                    continuation.yield(.frame(o))
                } else if case .array(let arr) = v {
                    // JSON-RPC batch response.
                    for el in arr {
                        if case .object(let o) = el {
                            continuation.yield(.frame(o))
                        }
                    }
                }
            }
        }
        if box.process.isRunning { box.process.terminate() }
        continuation.yield(.end)
        continuation.finish()
    }

    /// Locate the end of the HTTP header block (CRLFCRLF). Falls back to
    /// LFLF in case a peer emits LF-only line endings (HTTP/1.0 stubs
    /// like Python's `BaseHTTPRequestHandler` send CRLF, but be lenient).
    private static func findHeaderTerminator(_ data: Data)
        -> (terminatorStart: Int, terminatorLength: Int)? {
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        if let r = data.firstRange(of: crlfcrlf) {
            return (r.lowerBound, 4)
        }
        let lflf = Data([0x0A, 0x0A])
        if let r = data.firstRange(of: lflf) {
            return (r.lowerBound, 2)
        }
        return nil
    }

    /// Parse the HTTP status line + headers (CR-stripped, separated by
    /// LF). Returns the status code (0 on parse failure) and the
    /// `Content-Type` header value (empty string if absent).
    internal static func parseStatusAndContentType(_ headerBlock: String)
        -> (Int, String) {
        var status = 0
        var contentType = ""
        // First line is "HTTP/x.y NNN reason". Strip stray CRs.
        let lines = headerBlock
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return (0, "") }
        let parts = first.split(separator: " ", maxSplits: 2,
                                omittingEmptySubsequences: true)
        if parts.count >= 2, let code = Int(parts[1]) { status = code }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if name == "content-type" {
                contentType = value
                break
            }
        }
        return (status, contentType)
    }

    // MARK: - Protocol methods

    public func initialize() async throws {
        guard !initialized else { return }
        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "CodexKit", "version": "0.1"],
        ], expectResult: true)
        _ = try await request(method: "notifications/initialized",
                              params: [String: Any](), expectResult: false)
        initialized = true
    }

    public func listTools() async throws -> [McpToolSpec] {
        let r = try await request(method: "tools/list",
                                  params: [String: Any](), expectResult: true)
        guard let toolsVal = r["tools"], case .array(let arr) = toolsVal else {
            return []
        }
        return arr.compactMap { v in
            guard case .object(let t) = v,
                  case .string(let name)? = t["name"] else { return nil }
            let desc: String
            if case .string(let d)? = t["description"] { desc = d } else { desc = "" }
            let schema = t["inputSchema"].map { JSONLite.stringify($0) } ?? "{}"
            return McpToolSpec(name: name, description: desc, inputSchemaJSON: schema)
        }
    }

    public func callTool(_ name: String,
                         argumentsJSON: String,
                         elicitationHandler: McpElicitationHandler? = nil) async throws
        -> McpCallResult {
        let argsObject: Any
        if let d = argumentsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: d) {
            argsObject = parsed
        } else {
            argsObject = [String: Any]()
        }
        // H-49 / area-04 F5: wire the elicitation handler through to
        // `request`. If the server emits a mid-stream
        // `elicitation/create` server request, we invoke the handler
        // and POST the result back on the same URL.
        let r = try await request(method: "tools/call",
                                  params: ["name": name, "arguments": argsObject],
                                  expectResult: true,
                                  elicitationHandler: elicitationHandler)
        var text = ""
        if let content = r["content"], case .array(let items) = content {
            for it in items {
                if case .object(let o) = it,
                   case .string(let s)? = o["text"] { text += s }
            }
        }
        var isError = false
        if case .bool(let b)? = r["isError"] { isError = b }
        return McpCallResult(text: text, isError: isError)
    }

    public func readResource(uri: String) async throws -> [String: JSONLite] {
        try await request(method: "resources/read",
                          params: ["uri": uri],
                          expectResult: true)
    }
}
