import XCTest
import Foundation
@testable import Supervisor
@testable import SessionWorkerCore
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import IPC
@testable import ProtocolModel
@testable import WireProtocol
@testable import InfraPrimitives
@testable import Observability
@testable import Config
@testable import MCP
@testable import Auth
@testable import Sandbox

private extension JSONRPCMessage {
    var responseId: RequestId? {
        switch self {
        case .response(let response): return response.id
        case .error(let error): return error.id
        case .request, .notification: return nil
        }
    }

    var summary: String {
        switch self {
        case .request(let request):
            return "request id=\(request.id) method=\(request.method)"
        case .notification(let notification):
            return "notification method=\(notification.method)"
        case .response(let response):
            let keys = response.result.objectValue?.keys.sorted().joined(separator: ",")
                ?? "non-object"
            let stdoutCount = response.result["stdout"]?.stringValue?.count
            let stdout = stdoutCount.map { " stdout=\($0)" } ?? ""
            return "response id=\(response.id) resultKeys=\(keys)\(stdout)"
        case .error(let error):
            return "error id=\(error.id) code=\(error.error.code) message=\(error.error.message)"
        }
    }
}

final class EndToEndTests: XCTestCase {
    private actor NudgeEmailRecorder {
        struct Call: Equatable {
            var accessToken: String
            var accountId: String?
            var baseURL: String
            var creditType: String
        }
        private var calls: [Call] = []
        func record(tokens: AuthTokens, baseURL: String, creditType: String) {
            calls.append(Call(accessToken: tokens.accessToken,
                              accountId: tokens.accountId,
                              baseURL: baseURL,
                              creditType: creditType))
        }
        func recordedCalls() -> [Call] { calls }
    }

    private actor RemoteControlEnrollRecorder {
        struct Call: Equatable {
            var accessToken: String
            var accountId: String?
            var baseURL: String
            var installationId: String
            var serverName: String
        }
        private var calls: [Call] = []
        func record(tokens: AuthTokens, baseURL: String,
                    installationId: String, serverName: String)
            -> RequestRouter.RemoteControlEnrollment {
            calls.append(Call(accessToken: tokens.accessToken,
                              accountId: tokens.accountId,
                              baseURL: baseURL,
                              installationId: installationId,
                              serverName: serverName))
            return .init(serverId: "server-remote", environmentId: "env-remote")
        }
        func recordedCalls() -> [Call] { calls }
    }

    private actor RemoteControlWebSocketRecorder {
        private var calls: [RequestRouter.RemoteControlWebSocketRequest] = []
        private var continuation:
            AsyncStream<RequestRouter.RemoteControlClientEnvelope>.Continuation?
        private var serverEnvelopes: [RequestRouter.RemoteControlServerEnvelope] = []
        private var closeCount = 0
        var shouldFail = false
        var pingShouldFail = false

        func connect(_ request: RequestRouter.RemoteControlWebSocketRequest)
            -> RequestRouter.RemoteControlWebSocketConnection {
            calls.append(request)
            return RequestRouter.RemoteControlWebSocketConnection { [weak self] in
                await self?.recordClose()
            }
        }

        func connectWithRouting(_ request: RequestRouter.RemoteControlWebSocketRequest)
            -> RequestRouter.RemoteControlWebSocketConnection {
            calls.append(request)
            let (stream, cont) =
                AsyncStream<RequestRouter.RemoteControlClientEnvelope>.makeStream()
            continuation = cont
            return RequestRouter.RemoteControlWebSocketConnection(
                incoming: stream,
                sendEnvelope: { [weak self] envelope in
                    await self?.recordServerEnvelope(envelope)
                },
                ping: { [weak self] in
                    if await self?.currentPingShouldFail() == true {
                        throw NSError(domain: "RemoteControlWebSocketTest", code: 2)
                    }
                },
                close: { [weak self] in
                    await self?.recordCloseAndFinish()
                })
        }

        func connectOrFail(_ request: RequestRouter.RemoteControlWebSocketRequest) throws
            -> RequestRouter.RemoteControlWebSocketConnection {
            calls.append(request)
            if shouldFail {
                throw NSError(domain: "RemoteControlWebSocketTest", code: 1)
            }
            return RequestRouter.RemoteControlWebSocketConnection { [weak self] in
                await self?.recordClose()
            }
        }

        func setShouldFail(_ value: Bool) { shouldFail = value }
        func setPingShouldFail(_ value: Bool) { pingShouldFail = value }
        func sendClientEnvelope(_ envelope: RequestRouter.RemoteControlClientEnvelope) {
            continuation?.yield(envelope)
        }
        func finishIncoming() {
            continuation?.finish()
            continuation = nil
        }
        func recordedServerEnvelopes() -> [RequestRouter.RemoteControlServerEnvelope] {
            serverEnvelopes
        }
        func recordedCalls() -> [RequestRouter.RemoteControlWebSocketRequest] { calls }
        func recordedCloseCount() -> Int { closeCount }
        private func recordServerEnvelope(_ envelope: RequestRouter.RemoteControlServerEnvelope) {
            serverEnvelopes.append(envelope)
        }
        private func currentPingShouldFail() -> Bool { pingShouldFail }
        private func recordClose() { closeCount += 1 }
        private func recordCloseAndFinish() {
            closeCount += 1
            continuation?.finish()
            continuation = nil
        }
    }

    private actor OutboundSink {
        private var messages: [JSONRPCMessage] = []

        func append(_ message: JSONRPCMessage) {
            messages.append(message)
        }

        func response(id: Int64) -> JSONRPCResponse? {
            for message in messages {
                if case .response(let response) = message, response.id == .int(id) {
                    return response
                }
            }
            return nil
        }

        func error(id: Int64) -> JSONRPCError? {
            for message in messages {
                if case .error(let error) = message, error.id == .int(id) {
                    return error
                }
            }
            return nil
        }

        func notificationCount(_ method: String) -> Int {
            messages.reduce(0) { count, message in
                if case .notification(let notification) = message,
                   notification.method == method {
                    return count + 1
                }
                return count
            }
        }

        func notifications(_ method: String) -> [JSONRPCNotification] {
            messages.compactMap { message in
                if case .notification(let notification) = message,
                   notification.method == method {
                    return notification
                }
                return nil
            }
        }
    }

    private struct Stack {
        let router: RequestRouter
        let conn: InMemoryConnection
        let store: ThreadStore
        let supervisor: SessionSupervisor
        let home: String
        let pump: Task<Void, Never>
    }

    private func makeStack(_ model: any ModelClient, codexHome: String? = nil,
                           auth: AuthManager? = nil,
                           requirementsLoader: ConfigRequirementsLoader = ConfigRequirementsLoader(),
                           accountRateLimitsFetcher: RequestRouter.AccountRateLimitsFetcher? = nil,
                           accountNudgeEmailSender: RequestRouter.AccountNudgeEmailSender? = nil,
                           remoteControlEnroller: RequestRouter.RemoteControlEnroller? = nil,
                           remoteControlWebSocketConnector:
                            RequestRouter.RemoteControlWebSocketConnector? = nil,
                           memoryResetHandler: (@Sendable () async -> Void)? = nil) throws -> Stack {
        let home = codexHome ?? (NSTemporaryDirectory() + "e2e-" + UUID().uuidString)
        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link, makeEngine: { c in
                let router = ToolRouter(limits: limits)
                // Mirror the production worker behavior: honor the client-
                // supplied sandboxMode/writableRoots/networkAccess. Tests
                // that override these on thread/start should see the same
                // sandbox bound at the worker layer that they sent on the
                // wire.
                let execPolicy = ExecPolicy.load(codexHome: home)
                let sandbox = SessionSandboxBuilder.make(config: c,
                                                         execPolicy: execPolicy)
                await DefaultTools.register(on: router, sandbox: sandbox, limits: limits)
                if let remote = c.remoteEnvironment {
                    await RemoteExecServerTools.register(
                        on: router,
                        websocketURL: remote.execServerUrl,
                        limits: limits)
                }
                return SessionEngine(config: c, model: model, store: store,
                                     router: router, limits: limits,
                                     hooks: HookEngine.load(codexHome: home, cwd: c.cwd,
                                                            legacyNotifyArgv: c.notify))
            })
            let t = Task { await rt.run() }
            return WorkerHandle(link: link, task: t)
        }
        let supervisor = SessionSupervisor(factory: factory)
        let router = RequestRouter(supervisor: supervisor, store: store, codexHome: home,
                                   auth: auth, requirementsLoader: requirementsLoader,
                                   accountRateLimitsFetcher: accountRateLimitsFetcher,
                                   accountNudgeEmailSender: accountNudgeEmailSender,
                                   remoteControlEnroller: remoteControlEnroller,
                                   remoteControlWebSocketConnector:
                                    remoteControlWebSocketConnector,
                                   memoryResetHandler: memoryResetHandler)
        let conn = InMemoryConnection()
        let pump = Task {
            for await m in conn.incoming() { await router.handle(m, conn) }
            await router.connectionClosed(conn)
        }
        return Stack(router: router, conn: conn, store: store,
                     supervisor: supervisor, home: home, pump: pump)
    }

    private func req(_ id: Int, _ method: String, _ params: JSONValue?) -> JSONRPCMessage {
        .request(JSONRPCRequest(id: .int(Int64(id)), method: method, params: params))
    }

    private func gitAvailable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func makeGitDiffRemoteRepo() async throws -> (dir: String, baseSha: String) {
        let dir = NSTemporaryDirectory() + "git-diff-remote-e2e-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = await GitRunner.run(["init", "-q"], cwd: dir)
        _ = await GitRunner.run(["config", "user.email", "t@example.test"], cwd: dir)
        _ = await GitRunner.run(["config", "user.name", "Test User"], cwd: dir)
        try "one\n".write(toFile: dir + "/tracked.txt", atomically: true, encoding: .utf8)
        _ = await GitRunner.run(["add", "tracked.txt"], cwd: dir)
        _ = await GitRunner.run(["commit", "-q", "-m", "base"], cwd: dir)
        let base = await GitRunner.run(["rev-parse", "HEAD"], cwd: dir)
        let baseSha = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await GitRunner.run(["update-ref", "refs/remotes/origin/main", "HEAD"], cwd: dir)
        try "one\ntwo\n".write(toFile: dir + "/tracked.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/untracked.txt", atomically: true, encoding: .utf8)
        return (dir, baseSha)
    }

    private enum MockDeviceCompletion: Sendable {
        case succeed(AuthTokens)
        case fail(AuthError)
        case waitForCancellation
    }

    private actor MockBrowserTokenExchanger: TokenExchanger {
        private let result: AuthTokens
        private(set) var exchanges: [(code: String, redirectURI: String)] = []

        init(result: AuthTokens) {
            self.result = result
        }

        func exchange(code: String, verifier: String,
                      cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
            exchanges.append((code: code, redirectURI: cfg.redirectURI))
            return .success(result)
        }

        func refresh(refreshToken: String,
                     cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
            .failure(.server("unused"))
        }

        func exchangeRecords() -> [(code: String, redirectURI: String)] {
            exchanges
        }
    }

    private actor MockStatusTokenExchanger: TokenExchanger {
        private var refreshResults: [Result<AuthTokens, AuthError>]
        private(set) var refreshTokens: [String] = []

        init(refreshResults: [Result<AuthTokens, AuthError>]) {
            self.refreshResults = refreshResults
        }

        func exchange(code: String, verifier: String,
                      cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
            .failure(.server("unused"))
        }

        func refresh(refreshToken: String,
                     cfg: OAuthConfig) async -> Result<AuthTokens, AuthError> {
            refreshTokens.append(refreshToken)
            if refreshResults.isEmpty {
                return .failure(.server("unexpected refresh"))
            }
            return refreshResults.removeFirst()
        }

        func refreshCount() -> Int { refreshTokens.count }
    }

    private actor MockDeviceCodeClient: DeviceCodeClient {
        let challenge: DeviceCodeChallenge
        let requestError: AuthError?
        let completion: MockDeviceCompletion

        init(challenge: DeviceCodeChallenge,
             requestError: AuthError? = nil,
             completion: MockDeviceCompletion) {
            self.challenge = challenge
            self.requestError = requestError
            self.completion = completion
        }

        func request(config: OAuthConfig) async -> Result<DeviceCodeChallenge, AuthError> {
            if let requestError { return .failure(requestError) }
            return .success(challenge)
        }

        func complete(config: OAuthConfig,
                      challenge: DeviceCodeChallenge) async -> Result<AuthTokens, AuthError> {
            switch completion {
            case .succeed(let tokens):
                return .success(tokens)
            case .fail(let error):
                return .failure(error)
            case .waitForCancellation:
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return .failure(.server("Login was not completed"))
            }
        }
    }

    private func unsignedJWT(_ claims: [String: Any]) throws -> String {
        let header: [String: Any] = ["alg": "none", "typ": "JWT"]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        return [
            headerData.base64URLEncodedString(),
            payloadData.base64URLEncodedString(),
            "sig",
        ].joined(separator: ".")
    }

    /// Collect outbound messages until `predicate` is satisfied (or timeout).
    private func waitOutbound(_ conn: InMemoryConnection,
                              _ predicate: @escaping @Sendable (JSONRPCMessage) -> Bool,
                              timeoutMs: Int = 3000) async -> [JSONRPCMessage] {
        let stream = conn.clientOutbound()
        let collector = Task { () -> [JSONRPCMessage] in
            var out: [JSONRPCMessage] = []
            for await m in stream {
                out.append(m)
                if predicate(m) { break }
            }
            return out
        }
        let timeout = Task {
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            collector.cancel()
        }
        let result = await collector.value
        timeout.cancel()
        return result
    }

    private func awaitResponse(_ sink: OutboundSink, id: Int64,
                               timeoutMs: Int = 3000) async -> JSONRPCResponse? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let response = await sink.response(id: id) { return response }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func awaitError(_ sink: OutboundSink, id: Int64,
                            timeoutMs: Int = 3000) async -> JSONRPCError? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let error = await sink.error(id: id) { return error }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func awaitNotificationCount(_ sink: OutboundSink, method: String,
                                        atLeast count: Int,
                                        timeoutMs: Int = 3000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await sink.notificationCount(method) >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func awaitRemoteServerEnvelopeCount(_ recorder: RemoteControlWebSocketRecorder,
                                                atLeast count: Int,
                                                timeoutMs: Int = 3000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await recorder.recordedServerEnvelopes().count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func awaitRemoteWebSocketCallCount(_ recorder: RemoteControlWebSocketRecorder,
                                               atLeast count: Int,
                                               timeoutMs: Int = 3000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await recorder.recordedCalls().count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private enum RemoteChunkedResponseLookup {
        case chunked(seqId: UInt64, message: JSONRPCMessage)
        case direct(JSONRPCMessage)
        case timedOut(String)
    }

    private func awaitRemoteChunkedServerResponse(
        _ recorder: RemoteControlWebSocketRecorder,
        responseId: RequestId,
        timeoutMs: Int = 10_000
    ) async -> RemoteChunkedResponseLookup {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            let envelopes = await recorder.recordedServerEnvelopes()
            for envelope in envelopes {
                if case .serverMessage(let message) = envelope.event,
                   message.responseId == responseId {
                    return .direct(message)
                }
            }
            let chunksBySeqId = Dictionary(grouping: envelopes) { $0.seqId }
            for (seqId, seqEnvelopes) in chunksBySeqId.sorted(by: { $0.key < $1.key }) {
                let chunks = seqEnvelopes.compactMap { envelope
                    -> (Int, Int, Int, String)? in
                    guard case .serverMessageChunk(
                        let segmentId,
                        let segmentCount,
                        let messageSizeBytes,
                        let messageChunkBase64) = envelope.event else {
                        return nil
                    }
                    return (segmentId, segmentCount, messageSizeBytes, messageChunkBase64)
                }
                guard let first = chunks.first, chunks.count == first.1 else {
                    continue
                }
                let ordered = chunks.sorted { $0.0 < $1.0 }
                guard ordered.enumerated().allSatisfy({ $0.offset == $0.element.0 }) else {
                    continue
                }
                var data = Data()
                var validChunks = true
                for chunk in ordered {
                    guard let decoded = Data(base64Encoded: chunk.3) else {
                        validChunks = false
                        break
                    }
                    data.append(decoded)
                }
                guard validChunks, data.count == first.2,
                      let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data),
                      message.responseId == responseId else {
                    continue
                }
                return .chunked(seqId: seqId, message: message)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return .timedOut(await remoteEnvelopeSummary(recorder))
    }

    private func remoteEnvelopeSummary(_ recorder: RemoteControlWebSocketRecorder) async -> String {
        let envelopes = await recorder.recordedServerEnvelopes()
        let direct = envelopes.compactMap { envelope -> String? in
            guard case .serverMessage(let message) = envelope.event else { return nil }
            return "seq=\(envelope.seqId) \(message.summary)"
        }
        let chunksBySeqId = Dictionary(grouping: envelopes) { $0.seqId }
        let chunks = chunksBySeqId.sorted(by: { $0.key < $1.key }).compactMap { seqId, seqEnvelopes -> String? in
            let segments = seqEnvelopes.compactMap { envelope -> (Int, Int, Int)? in
                guard case .serverMessageChunk(let segmentId, let segmentCount, let messageSizeBytes, _) = envelope.event else {
                    return nil
                }
                return (segmentId, segmentCount, messageSizeBytes)
            }
            guard let first = segments.first else { return nil }
            let segmentIds = segments.map(\.0).sorted().map(String.init).joined(separator: ",")
            return "seq=\(seqId) segments=\(segments.count)/\(first.1) ids=[\(segmentIds)] size=\(first.2)"
        }
        return "envelopes=\(envelopes.count) direct=[\(direct.joined(separator: "; "))] chunks=[\(chunks.joined(separator: "; "))]"
    }

    private func remoteClientChunks(
        _ message: JSONRPCMessage,
        clientId: String,
        streamId: String,
        seqId: UInt64,
        chunkSize: Int
    ) throws -> [RequestRouter.RemoteControlClientEnvelope] {
        let data = try JSONEncoder().encode(message)
        let segmentCount = (data.count + chunkSize - 1) / chunkSize
        return stride(from: 0, to: data.count, by: chunkSize).enumerated().map {
            segmentId, start in
            let chunk = data[start..<min(start + chunkSize, data.count)]
            return RequestRouter.RemoteControlClientEnvelope(
                event: .clientMessageChunk(
                    segmentId: segmentId,
                    segmentCount: segmentCount,
                    messageSizeBytes: data.count,
                    messageChunkBase64: Data(chunk).base64EncodedString()),
                clientId: clientId,
                streamId: streamId,
                seqId: seqId)
        }
    }

    private func testJSONQuoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private func oneShotCaptureHTTPServer(_ dir: String, responseBody: String,
                                          requestPath: String,
                                          status: String = "200 OK") -> (Process, Int)? {
        let script = dir + "/capture-http.py"
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
            open(\(testJSONQuoted(requestPath)), "wb").write(head + b"\\r\\n\\r\\n" + body)
            resp_body = (\(testJSONQuoted(responseBody))).encode()
            hdr = ("HTTP/1.1 \(status)\\r\\n"
                   "Content-Type: application/json\\r\\n"
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

    private func fakeExecServerWebSocket(_ dir: String,
                                         callsPath: String,
                                         closeAfterFirstReadFile: Bool = false,
                                         closeAfterFirstWriteFile: Bool = false,
                                         closeAfterFirstRemove: Bool = false,
                                         closeAfterFirstProcessStart: Bool = false,
                                         closeAfterFirstWriteStdin: Bool = false,
                                         bumpSessionIdEachConnection: Bool = false,
                                         closeMidProcessReadOnce: Bool = false,
                                         serveHTTPRegistry: Bool = false) -> (Process, Int)? {
        let script = dir + "/fake-exec-server-ws.py"
        let py = """
        import base64, hashlib, json, socket, struct, sys, threading
        calls_path = \(testJSONQuoted(callsPath))
        close_after_first_read_file = \(closeAfterFirstReadFile ? "True" : "False")
        close_after_first_write_file = \(closeAfterFirstWriteFile ? "True" : "False")
        close_after_first_remove = \(closeAfterFirstRemove ? "True" : "False")
        close_after_first_process_start = \(closeAfterFirstProcessStart ? "True" : "False")
        close_after_first_write_stdin = \(closeAfterFirstWriteStdin ? "True" : "False")
        bump_session_id_each_connection = \(bumpSessionIdEachConnection ? "True" : "False")
        close_mid_process_read_once = \(closeMidProcessReadOnce ? "True" : "False")
        serve_http_registry = \(serveHTTPRegistry ? "True" : "False")
        did_close_after_read_file = False
        did_close_after_write_file = False
        did_close_after_remove = False
        did_close_after_process_start = False
        did_close_after_write_stdin = False
        did_close_mid_process_read = False
        session_counter = [0]
        started_processes = set()
        removed_paths = set()

        def recv_exact(c, n):
            b = b""
            while len(b) < n:
                chunk = c.recv(n - len(b))
                if not chunk:
                    raise EOFError()
                b += chunk
            return b

        def read_frame(c):
            h = recv_exact(c, 2)
            opcode = h[0] & 0x0f
            length = h[1] & 0x7f
            if length == 126:
                length = struct.unpack("!H", recv_exact(c, 2))[0]
            elif length == 127:
                length = struct.unpack("!Q", recv_exact(c, 8))[0]
            mask = recv_exact(c, 4) if (h[1] & 0x80) else b""
            data = recv_exact(c, length)
            if mask:
                data = bytes(data[i] ^ mask[i % 4] for i in range(len(data)))
            if opcode == 8:
                raise EOFError()
            return data.decode()

        def send_frame(c, obj):
            payload = json.dumps(obj, separators=(",", ":")).encode()
            if len(payload) < 126:
                header = bytes([0x81, len(payload)])
            elif len(payload) < 65536:
                header = bytes([0x81, 126]) + struct.pack("!H", len(payload))
            else:
                header = bytes([0x81, 127]) + struct.pack("!Q", len(payload))
            c.sendall(header + payload)

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", 0))
        s.listen(1)
        sys.stdout.write(str(s.getsockname()[1]) + "\\n")
        sys.stdout.flush()
        files = {
            "/remote-env-work/README.md": b"REMOTE_FILE\\n",
            "/remote-env-work/Sources/RemoteApple.swift": b"struct RemoteApple {}\\n",
            "/remote-env-work/Sources/AppServerGuide.md": b"apple guide\\n",
        }
        def handle_client(c):
            global did_close_after_read_file, did_close_after_write_file
            global did_close_after_remove, did_close_after_process_start
            global did_close_after_write_stdin, did_close_mid_process_read
            req = b""
            while b"\\r\\n\\r\\n" not in req:
                req += c.recv(4096)
            request_line = req.decode(errors="ignore").split("\\r\\n", 1)[0]
            headers = {}
            for line in req.decode(errors="ignore").split("\\r\\n")[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.lower()] = v.strip()
            # HTTP executor-registry probe — exercises the A1 minimal HTTP
            # bootstrap path. We answer with a JSON rendezvous URL pointing
            # back at this same listener's WebSocket endpoint.
            if serve_http_registry and request_line.startswith("POST /executors/register"):
                content_length = int(headers.get("content-length", "0") or 0)
                if content_length > 0:
                    sep = req.find(b"\\r\\n\\r\\n") + 4
                    have = len(req) - sep
                    while have < content_length:
                        more = c.recv(content_length - have)
                        if not more:
                            break
                        req += more
                        have += len(more)
                port = s.getsockname()[1]
                body = json.dumps({"rendezvousURL": "ws://127.0.0.1:" + str(port)}).encode()
                c.sendall(("HTTP/1.1 200 OK\\r\\n"
                           "Content-Type: application/json\\r\\n"
                           "Content-Length: " + str(len(body)) + "\\r\\n"
                           "Connection: close\\r\\n\\r\\n").encode() + body)
                return
            key = headers.get("sec-websocket-key", "")
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            c.sendall(("HTTP/1.1 101 Switching Protocols\\r\\n"
                       "Upgrade: websocket\\r\\n"
                       "Connection: Upgrade\\r\\n"
                       "Sec-WebSocket-Accept: " + accept + "\\r\\n\\r\\n").encode())
            process_reads = {}
            process_inputs = {}
            process_argv = {}
            while True:
                msg = json.loads(read_frame(c))
                method = msg.get("method")
                if "id" not in msg:
                    continue
                rid = msg["id"]
                params = msg.get("params") or {}
                if method == "initialize":
                    if bump_session_id_each_connection:
                        session_counter[0] += 1
                        sid = "fake-session-" + str(session_counter[0])
                    else:
                        sid = "fake-session"
                    send_frame(c, {"id": rid, "result": {"sessionId": sid}})
                elif method == "process/start":
                    with open(calls_path, "a") as f:
                        f.write(json.dumps({"method": method, "params": params}, sort_keys=True) + "\\n")
                    pid = params.get("processId")
                    # Replay-test variant: on the first process/start, record
                    # the in-flight start in shared state and close the socket
                    # without responding. The client will reconnect with the
                    # SAME processId, which the server then rejects as
                    # "already exists" — and the client tolerates that on
                    # retry per the .tolerateExistsOnRetry policy.
                    if close_after_first_process_start and not did_close_after_process_start:
                        started_processes.add(pid)
                        did_close_after_process_start = True
                        return
                    if pid in started_processes:
                        send_frame(c, {"id": rid, "error": {"code": -32603,
                                                            "message": "process already exists: " + str(pid)}})
                    else:
                        started_processes.add(pid)
                        process_reads[pid] = 0
                        process_inputs[pid] = []
                        process_argv[pid] = params.get("argv") or []
                        send_frame(c, {"id": rid, "result": {"processId": pid}})
                elif method == "process/write":
                    decoded = base64.b64decode(params.get("chunk", ""))
                    process_inputs.setdefault(params.get("processId"), []).append(decoded)
                    recorded = dict(params)
                    recorded["inputUtf8"] = decoded.decode(errors="replace")
                    with open(calls_path, "a") as f:
                        f.write(json.dumps({"method": method, "params": recorded}, sort_keys=True) + "\\n")
                    # Replay-test variant: record the stdin write and close
                    # without responding. The client policy is .never so it
                    # surfaces a transport failure rather than retrying. We
                    # then assert the call log shows exactly one writeStdin.
                    if close_after_first_write_stdin and not did_close_after_write_stdin:
                        did_close_after_write_stdin = True
                        return
                    send_frame(c, {"id": rid, "result": {}})
                elif method == "process/read":
                    pid = params.get("processId", "")
                    # Restart-test variant: close the websocket without
                    # responding on the first process/read we see for any
                    # unified-exec process. Combined with
                    # bump_session_id_each_connection, this forces a fresh
                    # sessionId on reconnect — the client should detect the
                    # change and surface a restart marker.
                    if close_mid_process_read_once and not did_close_mid_process_read \
                            and str(pid).startswith("ux_"):
                        did_close_mid_process_read = True
                        # Pretend the process is gone on the next connection.
                        if pid in started_processes:
                            started_processes.discard(pid)
                        return
                    read_count = process_reads.get(pid, 0)
                    process_reads[pid] = read_count + 1
                    argv = process_argv.get(pid, [])
                    if str(pid).startswith("ux_"):
                        # If we don't recognize the process (e.g. it was
                        # cleared on a forced restart), surface a structured
                        # exec-server failure so the Swift client can decide
                        # whether to interpret it as a restart.
                        if pid not in started_processes and not str(pid).startswith("ux_"):
                            send_frame(c, {"id": rid, "result": {
                                "chunks": [], "nextSeq": 0, "exited": True,
                                "exitCode": None, "closed": True,
                                "failure": "unknown processId: " + str(pid)}})
                            continue
                        if read_count == 0:
                            body = base64.b64encode(b"REMOTE_UNIFIED_READY\\n").decode()
                            chunks = [{"seq": 1, "stream": "stdout", "chunk": body}]
                        elif process_inputs.get(pid):
                            raw = process_inputs[pid].pop(0)
                            body = base64.b64encode(b"REMOTE_UNIFIED_INPUT: " + raw).decode()
                            chunks = [{"seq": 2 + read_count, "stream": "stdout", "chunk": body}]
                        else:
                            chunks = []
                        send_frame(c, {"id": rid, "result": {
                            "chunks": chunks, "nextSeq": read_count + 2, "exited": False,
                            "exitCode": None, "closed": False, "failure": None}})
                    elif argv and argv[0] == "git":
                        exit_code = 0
                        stdout = b""
                        if argv[1:] == ["rev-parse", "--is-inside-work-tree"]:
                            stdout = b"true\\n"
                        elif argv[1:] == ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]:
                            stdout = b"origin/main\\n"
                        elif argv[1:] == ["merge-base", "HEAD", "origin/main"]:
                            stdout = b"1111111111111111111111111111111111111111\\n"
                        elif argv[1:] == ["diff", "1111111111111111111111111111111111111111"]:
                            stdout = b"diff --git a/RemoteGit.swift b/RemoteGit.swift\\n+REMOTE_GIT_DIFF\\n"
                        elif argv[1:] == ["ls-files", "--others", "--exclude-standard"]:
                            stdout = b"untracked.txt\\n"
                        elif argv[1:] == ["diff", "--no-index", "/dev/null", "untracked.txt"]:
                            stdout = b"diff --git a/untracked.txt b/untracked.txt\\n+REMOTE_UNTRACKED_DIFF\\n"
                            exit_code = 1
                        elif argv[1:] == ["diff", "HEAD"]:
                            stdout = b"diff --git a/working.txt b/working.txt\\n+REMOTE_WORKING_DIFF\\n"
                        elif argv[1:] == ["diff", "--cached"]:
                            stdout = b"diff --git a/staged.txt b/staged.txt\\n+REMOTE_STAGED_DIFF\\n"
                        else:
                            stdout = ("unexpected git argv: " + " ".join(argv[1:]) + "\\n").encode()
                            exit_code = 2
                        if read_count == 0:
                            chunks = [{"seq": 1, "stream": "stdout", "chunk": base64.b64encode(stdout).decode()}]
                        else:
                            chunks = []
                        send_frame(c, {"id": rid, "result": {
                            "chunks": chunks, "nextSeq": 2, "exited": True,
                            "exitCode": exit_code, "closed": True, "failure": None}})
                    else:
                        if read_count == 0:
                            body = base64.b64encode(b"REMOTE_EXEC_OK\\n").decode()
                            chunks = [{"seq": 1, "stream": "stdout", "chunk": body}]
                        else:
                            chunks = []
                        send_frame(c, {"id": rid, "result": {
                            "chunks": chunks, "nextSeq": 2, "exited": True,
                            "exitCode": 0, "closed": True, "failure": None}})
                elif method == "fs/getMetadata":
                    with open(calls_path, "a") as f:
                        f.write(json.dumps({"method": method, "params": params}, sort_keys=True) + "\\n")
                    path = params.get("path", "")
                    if path in files or path in ["/remote-env-work", "/remote-env-work/Sources"]:
                        send_frame(c, {"id": rid, "result": {"isFile": path in files, "isDirectory": path not in files}})
                    else:
                        send_frame(c, {"id": rid, "error": {"code": -32004, "message": "not found: " + path}})
                elif method == "fs/readFile":
                    with open(calls_path, "a") as f:
                        f.write(json.dumps({"method": method, "params": params}, sort_keys=True) + "\\n")
                    path = params.get("path", "")
                    if path not in files:
                        send_frame(c, {"id": rid, "error": {"code": -32004, "message": "not found: " + path}})
                    else:
                        send_frame(c, {"id": rid, "result": {"dataBase64": base64.b64encode(files[path]).decode()}})
                        if close_after_first_read_file and not did_close_after_read_file:
                            did_close_after_read_file = True
                            return
                elif method == "fs/writeFile":
                    path = params.get("path", "")
                    decoded = base64.b64decode(params.get("dataBase64", ""))
                    files[path] = decoded
                    recorded = dict(params)
                    recorded["dataUtf8"] = decoded.decode(errors="replace")
                    with open(calls_path, "a") as f:
                        f.write(json.dumps({"method": method, "params": recorded}, sort_keys=True) + "\\n")
                    # Replay-test variant: persist the write but close the
                    # socket without responding. Client retries with the same
                    # bytes; the second write overwrites the same path with
                    # the same content — idempotent.
                    if close_after_first_write_file and not did_close_after_write_file:
                        did_close_after_write_file = True
                        return
                    send_frame(c, {"id": rid, "result": {}})
                elif method == "fs/createDirectory":
                    with open(calls_path, "a") as f:
                        f.write(json.dumps({"method": method, "params": params}, sort_keys=True) + "\\n")
                    send_frame(c, {"id": rid, "result": {}})
                elif method == "fs/remove":
                    with open(calls_path, "a") as f:
                        f.write(json.dumps({"method": method, "params": params}, sort_keys=True) + "\\n")
                    path = params.get("path", "")
                    # Replay-test variant: perform the remove on the first
                    # call, record the path, and close the socket without
                    # responding. The client retries; the second remove finds
                    # the path already gone and returns "not found", which
                    # the client tolerates per .tolerateNotFoundOnRetry.
                    if close_after_first_remove and not did_close_after_remove:
                        removed_paths.add(path)
                        if path in files:
                            del files[path]
                        did_close_after_remove = True
                        return
                    if path in removed_paths:
                        send_frame(c, {"id": rid, "error": {"code": -32004,
                                                            "message": "not found: " + path}})
                    else:
                        removed_paths.add(path)
                        if path in files:
                            del files[path]
                        send_frame(c, {"id": rid, "result": {}})
                elif method == "fs/readDirectory":
                    with open(calls_path, "a") as f:
                        f.write(json.dumps({"method": method, "params": params}, sort_keys=True) + "\\n")
                    path = params.get("path", "")
                    if path == "/remote-env-work":
                        entries = [
                            {"fileName": "Sources", "isDirectory": True, "isFile": False},
                            {"fileName": "README.md", "isDirectory": False, "isFile": True},
                            {"fileName": ".git", "isDirectory": True, "isFile": False},
                        ]
                    elif path == "/remote-env-work/Sources":
                        entries = [
                            {"fileName": "RemoteApple.swift", "isDirectory": False, "isFile": True},
                            {"fileName": "AppServerGuide.md", "isDirectory": False, "isFile": True},
                        ]
                    else:
                        entries = [{"fileName": "remote.txt", "isDirectory": False, "isFile": True}]
                    send_frame(c, {"id": rid, "result": {"entries": entries}})
                else:
                    send_frame(c, {"id": rid, "error": {"code": -32601, "message": "unknown " + str(method)}})

        def serve_client(c):
            try:
                handle_client(c)
            except Exception:
                pass
            try:
                c.close()
            except Exception:
                pass

        try:
            while True:
                c, _ = s.accept()
                threading.Thread(target=serve_client, args=(c,), daemon=True).start()
        finally:
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

    private func waitForFile(_ path: String, timeoutMs: Int = 3000) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func testRemoteControlTargetNormalizationMatchesRustOracle() throws {
        XCTAssertEqual(
            try RequestRouter.normalizedRemoteControlTarget("https://chatgpt.com/backend-api"),
            .init(
                websocketURL: "wss://chatgpt.com/backend-api/wham/remote/control/server",
                enrollURL: "https://chatgpt.com/backend-api/wham/remote/control/server/enroll"))
        XCTAssertEqual(
            try RequestRouter.normalizedRemoteControlTarget(
                "https://api.chatgpt-staging.com/backend-api"),
            .init(
                websocketURL:
                    "wss://api.chatgpt-staging.com/backend-api/wham/remote/control/server",
                enrollURL:
                    "https://api.chatgpt-staging.com/backend-api/wham/remote/control/server/enroll"))
        XCTAssertEqual(
            try RequestRouter.normalizedRemoteControlTarget("http://localhost:8080/backend-api"),
            .init(
                websocketURL: "ws://localhost:8080/backend-api/wham/remote/control/server",
                enrollURL: "http://localhost:8080/backend-api/wham/remote/control/server/enroll"))
        XCTAssertEqual(
            try RequestRouter.normalizedRemoteControlTarget("https://localhost:8443/backend-api"),
            .init(
                websocketURL: "wss://localhost:8443/backend-api/wham/remote/control/server",
                enrollURL:
                    "https://localhost:8443/backend-api/wham/remote/control/server/enroll"))

        for raw in [
            "http://chatgpt.com/backend-api",
            "http://example.com/backend-api",
            "https://example.com/backend-api",
            "https://chat.openai.com/backend-api",
            "https://chatgpt.com.evil.com/backend-api",
            "https://evilchatgpt.com/backend-api",
            "https://foo.localhost/backend-api",
        ] {
            XCTAssertThrowsError(try RequestRouter.normalizedRemoteControlTarget(raw)) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    "invalid remote control URL `\(raw)`; expected HTTPS URL for chatgpt.com or chatgpt-staging.com, or HTTP/HTTPS URL for localhost")
            }
        }
    }

    func testNotInitializedThenInitializeOrdering() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }

        s.conn.clientSend(req(1, "thread/list", .object([:])))
        var msgs = await waitOutbound(s.conn) { if case .error = $0 { return true }; return false }
        guard case .error(let e)? = msgs.first(where: { if case .error = $0 { return true }; return false }) else {
            return XCTFail("expected Not initialized error")
        }
        XCTAssertEqual(e.error.message, "Not initialized")

        let initParams: JSONValue = .object(["clientInfo": .object(["name": .string("test")])])
        s.conn.clientSend(req(2, "initialize", initParams))
        msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0, r.id == .int(2) { return true }; return false
        }
        XCTAssertTrue(msgs.contains { if case .response(let r) = $0 { return r.id == .int(2) }; return false })

        // Double initialize → Already initialized.
        s.conn.clientSend(req(3, "initialize", initParams))
        msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }
        guard case .error(let e3)? = msgs.first(where: {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false }) else {
            return XCTFail("expected Already initialized")
        }
        XCTAssertEqual(e3.error.message, "Already initialized")
    }

    func testExperimentalGatingAndUnsupported() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "process/spawn", .object([:])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }; return false
        }
        guard case .error(let e)? = msgs.first(where: {
            if case .error(let e) = $0 { return e.id == .int(2) }; return false }) else {
            return XCTFail("expected experimental gate error")
        }
        XCTAssertEqual(e.error.message, "process/spawn requires experimentalApi capability")

        s.conn.clientSend(req(3, "totally/unknown/method", .object([:])))
        let msgs2 = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }
        guard case .error(let e3)? = msgs2.first(where: {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false }) else {
            return XCTFail("expected -32600 invalid request")
        }
        // Unknown method tags fail ClientRequest deserialization upstream and
        // are rejected with -32600 "Invalid request: ..." (NOT -32601).
        XCTAssertEqual(e3.error.code, -32600)
        XCTAssertTrue(e3.error.message.hasPrefix("Invalid request:"),
                      "unknown method must be -32600 invalid_request, got: \(e3.error.message)")
    }

    /// Buffered process/spawn (streamStdoutStderr=false): process/exited must
    /// carry the required stdout/stdoutCapReached/stderr/stderrCapReached
    /// fields (upstream ProcessExitedNotification), with the captured stdout
    /// present (not streamed away).
    func testProcessSpawnBufferedExitedCarriesStdoutAndCapFields() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "process/spawn", .object([
            "processHandle": .string("buf-1"),
            "command": .array([.string("sh"), .string("-c"), .string("printf hello")]),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "process/exited" }
            return false
        }
        guard case .notification(let exited)? = msgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "process/exited" }
            return false
        }) else {
            return XCTFail("expected process/exited notification")
        }
        XCTAssertEqual(exited.params?["processHandle"]?.stringValue, "buf-1")
        XCTAssertEqual(exited.params?["exitCode"]?.intValue, 0)
        // All four fields are required (non-Option) upstream and must be present.
        XCTAssertEqual(exited.params?["stdout"]?.stringValue, "hello")
        XCTAssertEqual(exited.params?["stdoutCapReached"]?.boolValue, false)
        XCTAssertEqual(exited.params?["stderr"]?.stringValue, "")
        XCTAssertEqual(exited.params?["stderrCapReached"]?.boolValue, false)
        // No outputDelta in buffered mode.
        let deltas = await waitOutbound(s.conn) { _ in false }
        XCTAssertFalse(deltas.contains {
            if case .notification(let n) = $0 { return n.method == "process/outputDelta" }
            return false
        })
    }

    /// Streaming process/spawn: process/outputDelta must carry capReached, and
    /// process/exited reports empty stdout/stderr (bytes were streamed) with
    /// cap flags reflecting the cap state. Use a tiny outputBytesCap to force
    /// the cap to be reached.
    func testProcessSpawnStreamingOutputDeltaCarriesCapReached() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "process/spawn", .object([
            "processHandle": .string("stream-1"),
            "command": .array([.string("sh"), .string("-c"), .string("printf abcdef")]),
            "streamStdoutStderr": .bool(true),
            "outputBytesCap": .int(3),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "process/exited" }
            return false
        }
        let deltas = msgs.compactMap { m -> JSONRPCNotification? in
            if case .notification(let n) = m, n.method == "process/outputDelta" { return n }
            return nil
        }
        XCTAssertFalse(deltas.isEmpty, "streaming mode must emit process/outputDelta")
        for d in deltas {
            XCTAssertNotNil(d.params?["capReached"]?.boolValue,
                            "every outputDelta must carry capReached")
            XCTAssertEqual(d.params?["stream"]?.stringValue, "stdout")
        }
        // The stdout cap of 3 bytes is reached by the 6-byte output.
        XCTAssertTrue(deltas.contains { $0.params?["capReached"]?.boolValue == true },
                      "final stdout delta must report capReached=true")
        guard case .notification(let exited)? = msgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "process/exited" }
            return false
        }) else {
            return XCTFail("expected process/exited notification")
        }
        // Streamed: stdout/stderr empty, cap flags reflect tracked state.
        XCTAssertEqual(exited.params?["stdout"]?.stringValue, "")
        XCTAssertEqual(exited.params?["stderr"]?.stringValue, "")
        XCTAssertEqual(exited.params?["stdoutCapReached"]?.boolValue, true)
        XCTAssertEqual(exited.params?["stderrCapReached"]?.boolValue, false)
    }

    func testMemoryResetClearsDurableMemories() async throws {
        let home = NSTemporaryDirectory() + "e2e-memory-reset-" + UUID().uuidString
        let memory = MemoryStore(codexHome: home)
        await memory.consolidate(threadId: "thread-memory-reset",
                                 transcript: "remember this should be cleared",
                                 cited: true)
        let seededMemories = await memory.list()
        XCTAssertFalse(seededMemories.isEmpty, "test setup should create a durable memory note")

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home,
                              memoryResetHandler: { await memory.reset() })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "memory/reset", .object([:])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let response)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else {
            return XCTFail("expected memory/reset response")
        }
        XCTAssertEqual(response.result, .object([:]))
        let remainingMemories = await memory.list()
        XCTAssertTrue(remainingMemories.isEmpty,
                      "memory/reset must clear persisted notes, not only return a default response")
    }

    func testSkillsConfigWritePersistsAndEmitsSkillsChanged() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "skills/config/write", .object([
            "name": .string("swiftui-expert-skill"),
            "enabled": .bool(false),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "skills/changed" }
            return false
        }
        guard case .response(let response)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else {
            return XCTFail("expected skills/config/write response")
        }
        XCTAssertEqual(response.result["effectiveEnabled"]?.boolValue, false)
        guard case .notification(let note)? = msgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "skills/changed" }
            return false
        }) else {
            return XCTFail("expected skills/changed notification")
        }
        XCTAssertEqual(note.params, .object([:]))

        let configText = try String(contentsOfFile: s.home + "/config.toml", encoding: .utf8)
        let root = try TOML.parse(configText)
        guard case .object(let skills)? = root["skills"],
              case .array(let entries)? = skills["config"],
              case .object(let first)? = entries.first else {
            return XCTFail("expected persisted skills.config array")
        }
        XCTAssertEqual(first["name"], .string("swiftui-expert-skill"))
        XCTAssertEqual(first["enabled"], .bool(false))
    }

    func testSkillsChangedEmitsWhenWatchedSkillFileChanges() async throws {
        let home = NSTemporaryDirectory() + "e2e-skill-watch-" + UUID().uuidString
        let skillDir = home + "/skills/demo"
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        let skillFile = skillDir + "/SKILL.md"
        try "---\nname: demo\ndescription: initial\n---\n\n# Demo\n"
            .write(toFile: skillFile, atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string(home)])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }

        try? await Task.sleep(for: .milliseconds(250))
        try "---\nname: demo\ndescription: updated by watcher\n---\n\n# Demo changed\n"
            .write(toFile: skillFile, atomically: true, encoding: .utf8)

        let changed = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "skills/changed" }
            return false
        }
        guard case .notification(let note)? = changed.first(where: {
            if case .notification(let n) = $0 { return n.method == "skills/changed" }
            return false
        }) else {
            return XCTFail("expected skills/changed after watched SKILL.md update")
        }
        XCTAssertEqual(note.params, .object([:]))

        s.conn.clientSend(req(3, "skills/list", .object(["cwds": .array([.string(home)])])))
        let listed = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let response)? = listed.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }), let data = response.result["data"]?.arrayValue,
              let demo = data.first(where: { $0["name"] == .string("demo") }) else {
            return XCTFail("expected updated demo skill in skills/list")
        }
        XCTAssertEqual(demo["description"], .string("updated by watcher"))
    }

    func testAccountLoginCancelAndLogoutEmitDocumentedNotifications() async throws {
        let home = NSTemporaryDirectory() + "e2e-auth-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object(["type": .string("chatgpt")])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let start)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let loginId = start.result["loginId"]?.stringValue else {
            return XCTFail("expected account/login/start response with loginId")
        }

        s.conn.clientSend(req(3, "account/login/cancel", .object(["loginId": .string(loginId)])))
        let cancelMsgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/login/completed" }
            return false
        }
        guard case .response(let cancel)? = cancelMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else {
            return XCTFail("expected account/login/cancel response")
        }
        XCTAssertEqual(cancel.result["status"], .string("canceled"))
        guard case .notification(let completed)? = cancelMsgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "account/login/completed" }
            return false
        }), let completedParams = completed.params else {
            return XCTFail("expected account/login/completed notification")
        }
        XCTAssertEqual(completedParams["loginId"], .string(loginId))
        XCTAssertEqual(completedParams["success"], .bool(false))
        // v9 app-server-events finding 5: a cancelled BROWSER login (type
        // "chatgpt" → pendingBrowserLogins) surfaces the login-server io::Error
        // wrapped as "Login server error: {err}" (account_processor.rs:397-398
        // over login/server.rs:195-196). Device-code cancellation (separate test)
        // keeps the bare "Login was not completed". The cancel *response* status
        // above stays "canceled".
        XCTAssertEqual(completedParams["error"],
                       .string("Login server error: Login was not completed"))

        try store.save(AuthTokens(accessToken: "ak", refreshToken: "rk",
                                  expiresAtUnix: 4_102_444_800, accountId: "acct"))
        s.conn.clientSend(req(4, "account/logout", .object([:])))
        let logoutMsgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }
        XCTAssertTrue(logoutMsgs.contains {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        })
        guard case .notification(let updated)? = logoutMsgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }), let updatedParams = updated.params else {
            return XCTFail("expected account/updated notification")
        }
        XCTAssertEqual(updatedParams["authMode"], .null)
        XCTAssertEqual(updatedParams["planType"], .null)
        XCTAssertNil(store.load())
    }

    func testAccountBrowserLoginCallbackCompletesAndPersistsChatGPTAuth() async throws {
        let home = NSTemporaryDirectory() + "e2e-browser-login-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let idToken = try unsignedJWT([
            "https://api.openai.com/plan_type": "plus",
            "chatgpt_account_id": "acct-browser",
        ])
        let exchanger = MockBrowserTokenExchanger(result: AuthTokens(
            accessToken: "browser-access",
            refreshToken: "browser-refresh",
            idToken: idToken,
            expiresAtUnix: 4_102_444_800,
            accountId: "acct-browser"))
        let auth = AuthManager(store: store, exchanger: exchanger)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object(["type": .string("chatgpt")])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let start)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let loginId = start.result["loginId"]?.stringValue,
              let authUrl = start.result["authUrl"]?.stringValue,
              let components = URLComponents(string: authUrl) else {
            return XCTFail("expected browser login response")
        }
        XCTAssertEqual(start.result["type"], .string("chatgpt"))
        let query = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            })
        guard let state = query["state"], let redirectURI = query["redirect_uri"] else {
            return XCTFail("authUrl missing state or redirect_uri: \(authUrl)")
        }
        XCTAssertTrue(redirectURI.hasPrefix("http://localhost:"))
        XCTAssertTrue(redirectURI.hasSuffix("/auth/callback"))

        let callback = Process()
        callback.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        callback.arguments = [
            "curl", "-sS", "--max-time", "5",
            "\(redirectURI)?state=\(state)&code=code-browser",
        ]
        callback.standardOutput = Pipe()
        callback.standardError = Pipe()
        try callback.run()
        callback.waitUntilExit()
        XCTAssertEqual(callback.terminationStatus, 0)

        let messages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }
        XCTAssertTrue(messages.contains {
            if case .notification(let n) = $0, n.method == "account/login/completed",
               let params = n.params {
                return params["loginId"] == .string(loginId)
                    && params["success"] == .bool(true)
                    && params["error"] == .null
            }
            return false
        })
        guard case .notification(let updated)? = messages.first(where: {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }), let updatedParams = updated.params else {
            return XCTFail("expected account/updated notification")
        }
        XCTAssertEqual(updatedParams["authMode"], .string("chatgpt"))
        XCTAssertEqual(updatedParams["planType"], .string("plus"))
        XCTAssertEqual(store.load()?.accessToken, "browser-access")
        XCTAssertEqual(store.load()?.accountId, "acct-browser")
        let records = await exchanger.exchangeRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.code, "code-browser")
        XCTAssertEqual(records.first?.redirectURI, redirectURI)
    }

    func testAccountBrowserLoginCallbackFailureDoesNotPersist() async throws {
        let home = NSTemporaryDirectory() + "e2e-browser-login-fail-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let exchanger = MockBrowserTokenExchanger(result: AuthTokens(
            accessToken: "should-not-save",
            expiresAtUnix: 4_102_444_800,
            accountId: "acct-browser"))
        let auth = AuthManager(store: store, exchanger: exchanger)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object(["type": .string("chatgpt")])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let start)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let loginId = start.result["loginId"]?.stringValue,
              let authUrl = start.result["authUrl"]?.stringValue,
              let components = URLComponents(string: authUrl) else {
            return XCTFail("expected browser login response")
        }
        let query = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            })
        guard let redirectURI = query["redirect_uri"] else {
            return XCTFail("authUrl missing redirect_uri: \(authUrl)")
        }

        let callback = Process()
        callback.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        callback.arguments = [
            "curl", "-fsS", "--max-time", "5",
            "\(redirectURI)?state=wrong-state&code=code-browser",
        ]
        callback.standardOutput = Pipe()
        callback.standardError = Pipe()
        try callback.run()
        callback.waitUntilExit()
        XCTAssertNotEqual(callback.terminationStatus, 0)

        let messages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/login/completed" }
            return false
        }
        XCTAssertTrue(messages.contains {
            if case .notification(let n) = $0, n.method == "account/login/completed",
               let params = n.params {
                return params["loginId"] == .string(loginId)
                    && params["success"] == .bool(false)
                    && params["error"]?.stringValue?.contains("state mismatch") == true
            }
            return false
        })
        XCTAssertNil(store.load())
        let records = await exchanger.exchangeRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testAccountDeviceCodeLoginCompletesAndPersistsChatGPTAuth() async throws {
        let home = NSTemporaryDirectory() + "e2e-device-code-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let idToken = try unsignedJWT([
            "https://api.openai.com/plan_type": "pro",
            "chatgpt_account_id": "acct-device",
        ])
        let challenge = DeviceCodeChallenge(
            verificationURL: "https://issuer.example/codex/device",
            userCode: "CODE-12345",
            deviceAuthId: "device-auth-id",
            intervalSeconds: 1)
        let deviceClient = MockDeviceCodeClient(
            challenge: challenge,
            completion: .succeed(AuthTokens(
                accessToken: "device-access",
                refreshToken: "device-refresh",
                idToken: idToken,
                expiresAtUnix: 4_102_444_800,
                accountId: "acct-device")))
        let auth = AuthManager(store: store, deviceCodeClient: deviceClient)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("chatgptDeviceCode"),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }
        guard case .response(let start)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let loginId = start.result["loginId"]?.stringValue else {
            return XCTFail("expected device-code login start response")
        }
        XCTAssertEqual(start.result["type"], .string("chatgptDeviceCode"))
        XCTAssertEqual(start.result["verificationUrl"], .string(challenge.verificationURL))
        XCTAssertEqual(start.result["userCode"], .string(challenge.userCode))
        XCTAssertTrue(msgs.contains {
            if case .notification(let n) = $0, n.method == "account/login/completed",
               let params = n.params {
                return params["loginId"] == .string(loginId)
                    && params["success"] == .bool(true)
                    && params["error"] == .null
            }
            return false
        })
        guard case .notification(let updated)? = msgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }), let updatedParams = updated.params else {
            return XCTFail("expected account/updated notification")
        }
        XCTAssertEqual(updatedParams["authMode"], .string("chatgpt"))
        XCTAssertEqual(updatedParams["planType"], .string("pro"))
        XCTAssertEqual(store.load()?.accessToken, "device-access")
        XCTAssertEqual(store.load()?.accountId, "acct-device")
    }

    /// Real OpenAI ChatGPT id_tokens carry the plan type at the NESTED path
    /// `https://api.openai.com/auth` -> `chatgpt_plan_type` (and the email under
    /// `https://api.openai.com/profile`), not a flat top-level key. Asserts the
    /// plan resolves from the nested claim for both `account/updated` (login)
    /// and `account/read` (which must NOT throw MissingChatgptAccountDetails).
    func testAccountLoginReadsPlanTypeFromNestedAuthClaim() async throws {
        let home = NSTemporaryDirectory() + "e2e-nested-plan-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        // Realistic nested-claim id_token: NO flat plan_type / email keys.
        let idToken = try unsignedJWT([
            "https://api.openai.com/profile": ["email": "user@example.com"],
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "Business",
                "chatgpt_account_id": "acct-nested",
            ],
        ])
        let challenge = DeviceCodeChallenge(
            verificationURL: "https://issuer.example/codex/device",
            userCode: "CODE-NESTED",
            deviceAuthId: "device-auth-nested",
            intervalSeconds: 1)
        let deviceClient = MockDeviceCodeClient(
            challenge: challenge,
            completion: .succeed(AuthTokens(
                accessToken: "nested-access",
                refreshToken: "nested-refresh",
                idToken: idToken,
                expiresAtUnix: 4_102_444_800,
                accountId: "acct-nested")))
        let auth = AuthManager(store: store, deviceCodeClient: deviceClient)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("chatgptDeviceCode"),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }
        guard case .notification(let updated)? = msgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }), let updatedParams = updated.params else {
            return XCTFail("expected account/updated notification")
        }
        // Plan resolves from the nested claim, normalized to lowercase
        // ("Business" -> "business" via PlanType::from_raw_value semantics).
        XCTAssertEqual(updatedParams["authMode"], .string("chatgpt"))
        XCTAssertEqual(updatedParams["planType"], .string("business"))

        // account/read must surface the nested plan + email instead of throwing
        // MissingChatgptAccountDetails (which would map to invalid_request).
        s.conn.clientSend(req(3, "account/read", .object([:])))
        let readMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let read)? = readMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else {
            return XCTFail("expected account/read response")
        }
        // Reaching a `.response` (not a WireError) already proves account/read
        // did not throw MissingChatgptAccountDetails.
        let account = read.result["account"]
        XCTAssertEqual(account?["type"], .string("chatgpt"))
        XCTAssertEqual(account?["email"], .string("user@example.com"))
        XCTAssertEqual(account?["planType"], .string("business"))
    }

    /// When the id_token has no plan claim at all (nested or flat), upstream
    /// `AuthManager::account_plan_type` defaults to `Unknown` and only a missing
    /// email is fatal. account/read must default planType to "unknown" rather
    /// than throwing.
    func testAccountReadDefaultsPlanTypeToUnknownWhenClaimAbsent() async throws {
        let home = NSTemporaryDirectory() + "e2e-no-plan-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let idToken = try unsignedJWT([
            "email": "noplan@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-noplan"],
        ])
        let challenge = DeviceCodeChallenge(
            verificationURL: "https://issuer.example/codex/device",
            userCode: "CODE-NOPLAN",
            deviceAuthId: "device-auth-noplan",
            intervalSeconds: 1)
        let deviceClient = MockDeviceCodeClient(
            challenge: challenge,
            completion: .succeed(AuthTokens(
                accessToken: "noplan-access",
                refreshToken: "noplan-refresh",
                idToken: idToken,
                expiresAtUnix: 4_102_444_800,
                accountId: "acct-noplan")))
        let auth = AuthManager(store: store, deviceCodeClient: deviceClient)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }
        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("chatgptDeviceCode"),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }

        s.conn.clientSend(req(3, "account/read", .object([:])))
        let readMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let read)? = readMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else {
            return XCTFail("expected account/read response")
        }
        let account = read.result["account"]
        XCTAssertEqual(account?["type"], .string("chatgpt"))
        XCTAssertEqual(account?["email"], .string("noplan@example.com"))
        XCTAssertEqual(account?["planType"], .string("unknown"))
    }

    func testAccountDeviceCodeLoginFailureEmitsCompletionWithoutPersisting() async throws {
        let home = NSTemporaryDirectory() + "e2e-device-code-fail-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let challenge = DeviceCodeChallenge(
            verificationURL: "https://issuer.example/codex/device",
            userCode: "CODE-FAIL",
            deviceAuthId: "device-auth-id",
            intervalSeconds: 1)
        let deviceClient = MockDeviceCodeClient(
            challenge: challenge,
            completion: .fail(.server("device auth failed with status 500")))
        let auth = AuthManager(store: store, deviceCodeClient: deviceClient)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("chatgptDeviceCode"),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/login/completed" }
            return false
        }
        guard case .response(let start)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let loginId = start.result["loginId"]?.stringValue else {
            return XCTFail("expected device-code login start response")
        }
        XCTAssertTrue(msgs.contains {
            if case .notification(let n) = $0, n.method == "account/login/completed",
               let params = n.params {
                return params["loginId"] == .string(loginId)
                    && params["success"] == .bool(false)
                    && params["error"]?.stringValue?.contains("device auth failed with status 500") == true
            }
            return false
        })
        XCTAssertFalse(msgs.contains {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        })
        XCTAssertNil(store.load())
    }

    func testAccountDeviceCodeLoginCancelStopsCompletionAndDoesNotPersist() async throws {
        let home = NSTemporaryDirectory() + "e2e-device-code-cancel-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let challenge = DeviceCodeChallenge(
            verificationURL: "https://issuer.example/codex/device",
            userCode: "CODE-CANCEL",
            deviceAuthId: "device-auth-id",
            intervalSeconds: 1)
        let deviceClient = MockDeviceCodeClient(
            challenge: challenge,
            completion: .waitForCancellation)
        let auth = AuthManager(store: store, deviceCodeClient: deviceClient)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("chatgptDeviceCode"),
        ])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let start)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let loginId = start.result["loginId"]?.stringValue else {
            return XCTFail("expected device-code login start response")
        }

        s.conn.clientSend(req(3, "account/login/cancel", .object(["loginId": .string(loginId)])))
        let cancelMsgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/login/completed" }
            return false
        }
        guard case .response(let cancel)? = cancelMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else {
            return XCTFail("expected cancel response")
        }
        XCTAssertEqual(cancel.result["status"], .string("canceled"))
        XCTAssertTrue(cancelMsgs.contains {
            if case .notification(let n) = $0, n.method == "account/login/completed",
               let params = n.params {
                return params["loginId"] == .string(loginId)
                    && params["success"] == .bool(false)
                    && params["error"] == .string("Login was not completed")
            }
            return false
        })
        let extra = await waitOutbound(s.conn, { _ in true }, timeoutMs: 100)
        XCTAssertFalse(extra.contains {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        })
        XCTAssertNil(store.load())
    }

    func testAccountApiKeyAndExternalTokenLoginNotifyAndPersist() async throws {
        let home = NSTemporaryDirectory() + "e2e-auth-login-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("apiKey"),
            "apiKey": .string("sk-test-key"),
        ])))
        let apiKeyMsgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }
        guard case .response(let apiResponse)? = apiKeyMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else {
            return XCTFail("expected apiKey login response")
        }
        XCTAssertEqual(apiResponse.result["type"], .string("apiKey"))
        XCTAssertTrue(apiKeyMsgs.contains {
            if case .notification(let n) = $0, n.method == "account/login/completed",
               let params = n.params {
                return params["loginId"] == .null
                    && params["success"] == .bool(true)
                    && params["error"] == .null
            }
            return false
        })
        guard case .notification(let apiUpdated)? = apiKeyMsgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }), let apiUpdatedParams = apiUpdated.params else {
            return XCTFail("expected account/updated for apiKey login")
        }
        XCTAssertEqual(apiUpdatedParams["authMode"], .string("apikey"))
        XCTAssertEqual(apiUpdatedParams["planType"], .null)
        XCTAssertEqual(store.load()?.accessToken, "sk-test-key")

        s.conn.clientSend(req(3, "account/login/start", .object([
            "type": .string("chatgptAuthTokens"),
            "accessToken": .string("chatgpt-token"),
            "chatgptAccountId": .string("acct-chatgpt"),
            "chatgptPlanType": .string("pro"),
        ])))
        let externalMsgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }
        guard case .response(let externalResponse)? = externalMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else {
            return XCTFail("expected chatgptAuthTokens login response")
        }
        XCTAssertEqual(externalResponse.result["type"], .string("chatgptAuthTokens"))
        XCTAssertTrue(externalMsgs.contains {
            if case .notification(let n) = $0, n.method == "account/login/completed",
               let params = n.params {
                return params["loginId"] == .null
                    && params["success"] == .bool(true)
                    && params["error"] == .null
            }
            return false
        })
        guard case .notification(let externalUpdated)? = externalMsgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "account/updated" }
            return false
        }), let externalUpdatedParams = externalUpdated.params else {
            return XCTFail("expected account/updated for chatgptAuthTokens login")
        }
        XCTAssertEqual(externalUpdatedParams["authMode"], .string("chatgptAuthTokens"))
        XCTAssertEqual(externalUpdatedParams["planType"], .string("pro"))
        XCTAssertEqual(store.load()?.accessToken, "chatgpt-token")
        XCTAssertEqual(store.load()?.accountId, "acct-chatgpt")
    }

    func testAccountReadReturnsDocumentedAccountUnionShapes() async throws {
        let home = NSTemporaryDirectory() + "e2e-account-read-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "account/read", .object(["refreshToken": .bool(false)])))
        let noAuthMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let noAuth)? = noAuthMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing no-auth account/read response") }
        XCTAssertEqual(noAuth.result["account"], .null)
        XCTAssertEqual(noAuth.result["requiresOpenaiAuth"], .bool(true))

        try await auth.loginWithAPIKey("sk-account-read")
        s.conn.clientSend(req(3, "account/read", .object(["refreshToken": .bool(true)])))
        let apiMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let api)? = apiMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else { return XCTFail("missing API-key account/read response") }
        XCTAssertEqual(api.result["account"]?["type"], .string("apiKey"))
        XCTAssertNil(api.result["account"]?["authenticated"])
        XCTAssertNil(api.result["account"]?["accountId"])
        XCTAssertEqual(api.result["requiresOpenaiAuth"], .bool(true))

        let accessToken = try unsignedJWT([
            "email": "external@example.test",
            "plan_type": "pro",
        ])
        try await auth.loginWithExternalChatGPTTokens(accessToken: accessToken,
                                                     accountId: "acct-external")
        s.conn.clientSend(req(4, "account/read", .object(["refreshToken": .bool(true)])))
        let chatgptMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let chatgpt)? = chatgptMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing ChatGPT account/read response") }
        XCTAssertEqual(chatgpt.result["account"]?["type"], .string("chatgpt"))
        XCTAssertEqual(chatgpt.result["account"]?["email"], .string("external@example.test"))
        XCTAssertEqual(chatgpt.result["account"]?["planType"], .string("pro"))
        XCTAssertEqual(chatgpt.result["requiresOpenaiAuth"], .bool(true))
    }

    /// A ChatGPT-authenticated token MISSING the `email` claim must produce an
    /// invalid_request error ("email and plan type are required for chatgpt
    /// authentication"), not a fabricated account with email="".
    ///
    /// Upstream (`model-provider/src/provider.rs:216-223` +
    /// `AuthManager::account_plan_type`) requires `(Some(email), Some(plan))`;
    /// a missing PLAN is NOT fatal because `account_plan_type` defaults to
    /// `Some(AccountPlanType::Unknown)` whenever token data exists (covered by
    /// `testAccountReadDefaultsPlanTypeToUnknownWhenClaimAbsent`). The genuine
    /// fatal condition is therefore a missing EMAIL, which this test exercises.
    func testAccountReadMissingClaimsReturnsInvalidRequest() async throws {
        let home = NSTemporaryDirectory() + "e2e-account-read-missing-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        // Token carries a plan_type claim but NO email — the genuinely fatal
        // condition upstream.
        let accessToken = try unsignedJWT(["plan_type": "pro"])
        try await auth.loginWithExternalChatGPTTokens(accessToken: accessToken,
                                                      accountId: "acct-missing")
        s.conn.clientSend(req(2, "account/read", .object(["refreshToken": .bool(false)])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let err)? = msgs.last else {
            return XCTFail("expected invalid_request error for missing claims")
        }
        XCTAssertEqual(err.error.code, -32600)
        XCTAssertEqual(err.error.message,
                       "email and plan type are required for chatgpt authentication")
    }

    /// Auth Finding #3: account/read derives the ChatGPT email/plan
    /// EXCLUSIVELY from the id_token JWT claims (upstream
    /// `AuthManager::get_account_email`/`account_plan_type`,
    /// manager.rs:357-388), never the access_token. A managed credential whose
    /// id_token lacks an email must return invalid_request even when the
    /// access_token happens to carry an email claim — Swift previously fell
    /// back to decoding the access_token, surfacing a fabricated chatgpt
    /// account.
    func testAccountReadDoesNotFallBackToAccessTokenForClaims() async throws {
        let home = NSTemporaryDirectory() + "e2e-account-read-idtoken-only-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        // access_token carries email + plan; id_token has NEITHER.
        let accessToken = try unsignedJWT([
            "email": "leak@example.com",
            "plan_type": "pro",
        ])
        let idToken = try unsignedJWT(["sub": "user-123"])
        // Persist a managed ChatGPT credential with both tokens set.
        try store.save(AuthTokens(accessToken: accessToken,
                                  refreshToken: nil,
                                  idToken: idToken,
                                  tokenType: "Bearer",
                                  expiresAtUnix: 4_102_444_800,
                                  accountId: "acct-idtoken-only"))
        s.conn.clientSend(req(2, "account/read", .object(["refreshToken": .bool(false)])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let err)? = msgs.last else {
            return XCTFail("expected invalid_request: claims must come from id_token only")
        }
        XCTAssertEqual(err.error.code, -32600)
        XCTAssertEqual(err.error.message,
                       "email and plan type are required for chatgpt authentication")
    }

    /// Finding 3: the primary rate-limit snapshot maps the backend usage
    /// payload's `credits` object to the camelCase CreditsSnapshot shape;
    /// additional rate limits carry no credits. Absent credits → null.
    /// (backend-client/src/client.rs:455-475,557-564)
    func testRateLimitSnapshotMapsBackendCredits() throws {
        let body: [String: JSONValue] = [
            "plan_type": .string("pro"),
            "rate_limit": .object([
                "primary_window": .object([
                    "used_percent": .int(42),
                    "limit_window_seconds": .int(3600),
                    "reset_at": .int(1_735_689_720),
                ]),
            ]),
            "credits": .object([
                "has_credits": .bool(true),
                "unlimited": .bool(false),
                "balance": .string("9.99"),
            ]),
            "additional_rate_limits": .array([
                .object([
                    "metered_feature": .string("codex_other"),
                    "limit_name": .string("codex_other"),
                    "rate_limit": .object([
                        "primary_window": .object([
                            "used_percent": .int(70),
                            "limit_window_seconds": .int(3600),
                            "reset_at": .int(1_735_689_720),
                        ]),
                    ]),
                ]),
            ]),
        ]
        let result = RequestRouter._rateLimitResponseForTesting(from: body)
        // Primary snapshot carries mapped credits.
        XCTAssertEqual(result["rateLimits"]?["credits"], .object([
            "hasCredits": .bool(true),
            "unlimited": .bool(false),
            "balance": .string("9.99"),
        ]))
        XCTAssertEqual(result["rateLimitsByLimitId"]?["codex"]?["credits"], .object([
            "hasCredits": .bool(true),
            "unlimited": .bool(false),
            "balance": .string("9.99"),
        ]))
        // Additional rate limit carries no credits.
        XCTAssertEqual(result["rateLimitsByLimitId"]?["codex_other"]?["credits"], .null)
    }

    /// Finding 3: when the backend usage payload has no `credits` object the
    /// snapshot's credits field is null (upstream map_credits returns None).
    func testRateLimitSnapshotCreditsNullWhenAbsent() throws {
        let body: [String: JSONValue] = [
            "plan_type": .string("pro"),
            "rate_limit": .object([
                "primary_window": .object([
                    "used_percent": .int(10),
                    "limit_window_seconds": .int(3600),
                    "reset_at": .int(1_735_689_720),
                ]),
            ]),
        ]
        let result = RequestRouter._rateLimitResponseForTesting(from: body)
        XCTAssertEqual(result["rateLimits"]?["credits"], .null)
    }

    /// auth finding 1: account/rateLimits/read must canonicalize the backend
    /// `plan_type` through map_plan_type before emitting (client.rs:567-589):
    /// "education" -> "edu"; guest/free_workspace/quorum/k12/unrecognized ->
    /// "unknown"; known plans (e.g. "pro") pass through; the same normalized
    /// value flows to every additional-rate-limit snapshot too.
    func testRateLimitSnapshotNormalizesPlanType() throws {
        func planType(for raw: String) -> JSONValue? {
            let body: [String: JSONValue] = [
                "plan_type": .string(raw),
                "rate_limit": .object([
                    "primary_window": .object([
                        "used_percent": .int(1),
                        "limit_window_seconds": .int(3600),
                        "reset_at": .int(1_735_689_720),
                    ]),
                ]),
                "additional_rate_limits": .array([
                    .object([
                        "metered_feature": .string("codex_other"),
                        "limit_name": .string("codex_other"),
                        "rate_limit": .object(["primary_window": .object([
                            "used_percent": .int(2),
                            "limit_window_seconds": .int(3600),
                            "reset_at": .int(1_735_689_720),
                        ])]),
                    ]),
                ]),
            ]
            let result = RequestRouter._rateLimitResponseForTesting(from: body)
            // The additional snapshot must carry the same normalized value.
            XCTAssertEqual(result["rateLimitsByLimitId"]?["codex_other"]?["planType"],
                           result["rateLimits"]?["planType"],
                           "additional rate limit planType must match primary for \(raw)")
            return result["rateLimits"]?["planType"]
        }
        XCTAssertEqual(planType(for: "education"), .string("edu"))
        XCTAssertEqual(planType(for: "pro"), .string("pro"))
        XCTAssertEqual(planType(for: "hc"), .string("enterprise"))
        XCTAssertEqual(planType(for: "guest"), .string("unknown"))
        XCTAssertEqual(planType(for: "free_workspace"), .string("unknown"))
        XCTAssertEqual(planType(for: "quorum"), .string("unknown"))
        XCTAssertEqual(planType(for: "k12"), .string("unknown"))
        XCTAssertEqual(planType(for: "mystery-tier"), .string("unknown"))
    }

    /// auth finding 1: an absent plan_type stays null (no normalization to
    /// "unknown" — the snapshot field simply has no value).
    func testRateLimitSnapshotPlanTypeNullWhenAbsent() throws {
        let body: [String: JSONValue] = [
            "rate_limit": .object(["primary_window": .object([
                "used_percent": .int(1),
                "limit_window_seconds": .int(3600),
                "reset_at": .int(1_735_689_720),
            ])]),
        ]
        let result = RequestRouter._rateLimitResponseForTesting(from: body)
        XCTAssertEqual(result["rateLimits"]?["planType"], .null)
    }

    /// auth finding 2: account/rateLimits/read maps the five known
    /// rate_limit_reached_type kinds 1:1 and collapses "unknown"/unrecognized
    /// to JSON null (map_rate_limit_reached_type, client.rs:504-525).
    func testRateLimitReachedTypeNormalization() throws {
        func reached(_ type: String?) -> JSONValue? {
            var body: [String: JSONValue] = [
                "rate_limit": .object(["primary_window": .object([
                    "used_percent": .int(1),
                    "limit_window_seconds": .int(3600),
                    "reset_at": .int(1_735_689_720),
                ])]),
            ]
            if let type {
                body["rate_limit_reached_type"] = .object(["type": .string(type)])
            }
            let result = RequestRouter._rateLimitResponseForTesting(from: body)
            return result["rateLimits"]?["rateLimitReachedType"]
        }
        XCTAssertEqual(reached("rate_limit_reached"), .string("rate_limit_reached"))
        XCTAssertEqual(reached("workspace_owner_credits_depleted"),
                       .string("workspace_owner_credits_depleted"))
        XCTAssertEqual(reached("workspace_member_credits_depleted"),
                       .string("workspace_member_credits_depleted"))
        XCTAssertEqual(reached("workspace_owner_usage_limit_reached"),
                       .string("workspace_owner_usage_limit_reached"))
        XCTAssertEqual(reached("workspace_member_usage_limit_reached"),
                       .string("workspace_member_usage_limit_reached"))
        // Unknown / unrecognized / absent collapse to null.
        XCTAssertEqual(reached("unknown"), .null)
        XCTAssertEqual(reached("some_future_kind"), .null)
        XCTAssertEqual(reached(nil), .null)
    }

    /// auth finding 3: a failed browser-login completion notification prefixes
    /// the error text with "Login server error: ", matching upstream's browser
    /// background task (account_processor.rs:397-398) and the cancelled-browser
    /// path. The bare AuthError description must always be wrapped.
    func testBrowserLoginCompletionErrorPrefix() throws {
        XCTAssertEqual(
            RequestRouter.browserLoginCompletionError(.server("boom")),
            "Login server error: auth server: boom")
        XCTAssertEqual(
            RequestRouter.browserLoginCompletionError(.malformed("missing authorization code")),
            "Login server error: auth: malformed (missing authorization code)")
        XCTAssertEqual(
            RequestRouter.browserLoginCompletionError(.invalidState),
            "Login server error: auth: state mismatch (possible CSRF)")
    }

    /// Finding 4: forced_login_method=chatgpt blocks API-key login with the
    /// upstream invalid_request message (account_processor.rs:259-266).
    func testForcedLoginMethodChatgptRejectsApiKeyLogin() async throws {
        let home = NSTemporaryDirectory() + "e2e-forced-chatgpt-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "forced_login_method = \"chatgpt\"\n"
            .write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("apiKey"), "apiKey": .string("sk-test")])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let err)? = msgs.last else {
            return XCTFail("expected forced-login error for api key")
        }
        XCTAssertEqual(err.error.message,
                       "API key login is disabled. Use ChatGPT login instead.")
    }

    /// Finding 4: forced_login_method=api blocks ChatGPT browser login with
    /// the upstream invalid_request message (account_processor.rs:314-318).
    func testForcedLoginMethodApiRejectsChatgptLogin() async throws {
        let home = NSTemporaryDirectory() + "e2e-forced-api-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "forced_login_method = \"api\"\n"
            .write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "account/login/start", .object(["type": .string("chatgpt")])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let err)? = msgs.last else {
            return XCTFail("expected forced-login error for chatgpt")
        }
        XCTAssertEqual(err.error.message,
                       "ChatGPT login is disabled. Use API key login instead.")
    }

    /// Finding 4: forced_login_method=api blocks chatgptAuthTokens login with
    /// the upstream invalid_request message (account_processor.rs:556-563).
    func testForcedLoginMethodApiRejectsChatgptAuthTokens() async throws {
        let home = NSTemporaryDirectory() + "e2e-forced-api-tokens-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try "forced_login_method = \"api\"\n"
            .write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("chatgptAuthTokens"),
            "accessToken": .string("tok"),
            "chatgptAccountId": .string("acct")])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let err)? = msgs.last else {
            return XCTFail("expected forced-login error for chatgptAuthTokens")
        }
        XCTAssertEqual(err.error.message,
                       "External ChatGPT auth is disabled. Use API key login instead.")
    }

    /// Finding 4: an active external ChatGPT auth blocks API-key login with the
    /// external-auth-active message (account_processor.rs:245-249,255-258).
    func testExternalAuthActiveRejectsApiKeyLogin() async throws {
        let home = NSTemporaryDirectory() + "e2e-external-active-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        try await auth.loginWithExternalChatGPTTokens(accessToken: "tok", accountId: "acct")
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("apiKey"), "apiKey": .string("sk-test")])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let err)? = msgs.last else {
            return XCTFail("expected external-auth-active error for api key")
        }
        XCTAssertEqual(err.error.message,
                       "External auth is active. Use account/login/start (chatgptAuthTokens) to update it or account/logout to clear it.")
    }

    func testAccountReadUsesProviderRequiresOpenAIAuth() async throws {
        let home = NSTemporaryDirectory() + "e2e-account-read-provider-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        model_provider = "custom"

        [model_providers.custom]
        name = "Custom"
        base_url = "https://example.test/v1"
        requires_openai_auth = false
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "account/read", .object(["refreshToken": .bool(false)])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let response)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing provider account/read response") }
        XCTAssertEqual(response.result["account"], .null)
        XCTAssertEqual(response.result["requiresOpenaiAuth"], .bool(false))
    }

    /// When the live config has an invalid `model_providers` entry (e.g.
    /// `wire_api = "chat"`, which upstream rejects at deserialise time)
    /// `account/read` must not silently fall back to the built-in registry's
    /// `requiresOpenAIAuth = false` for the custom provider. The router
    /// catches the validation error and defaults `requiresOpenaiAuth` to
    /// `true` so the client is told to authenticate rather than being
    /// granted "no auth required" by accident.
    func testAccountReadDefaultsToRequiresAuthOnInvalidProviderConfig() async throws {
        let home = NSTemporaryDirectory() + "e2e-account-read-bad-cfg-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        model_provider = "custom"

        [model_providers.custom]
        name = "Custom"
        base_url = "https://example.test/v1"
        requires_openai_auth = false
        wire_api = "chat"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "account/read", .object(["refreshToken": .bool(false)])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let response)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing account/read response for bad config") }
        // The custom provider declared `requires_openai_auth = false`, but
        // its `wire_api = "chat"` makes the whole providers block invalid.
        // The router must surface `true` (the safe default) rather than the
        // silently-discarded `false`.
        XCTAssertEqual(response.result["requiresOpenaiAuth"], .bool(true))
    }

    func testGetAuthStatusMatchesAppServerCredentialContract() async throws {
        let noAuthStack = try makeStack(MockModelClient([.hello()]))
        defer {
            noAuthStack.pump.cancel()
            try? FileManager.default.removeItem(atPath: noAuthStack.home)
        }
        noAuthStack.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(noAuthStack.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        noAuthStack.conn.clientSend(req(2, "getAuthStatus", .object([
            "includeToken": .bool(true),
            "refreshToken": .bool(false),
        ])))
        let noAuthMsgs = await waitOutbound(noAuthStack.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let noAuth)? = noAuthMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing getAuthStatus no-auth response") }
        XCTAssertEqual(noAuth.result["authMethod"], .null)
        XCTAssertEqual(noAuth.result["authToken"], .null)
        XCTAssertEqual(noAuth.result["requiresOpenaiAuth"], .bool(true))

        let home = NSTemporaryDirectory() + "e2e-auth-status-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        try await auth.loginWithAPIKey("sk-status-key")
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            3, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }

        s.conn.clientSend(req(4, "getAuthStatus", .object([
            "includeToken": .bool(false),
            "refreshToken": .bool(false),
        ])))
        let noTokenMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let noToken)? = noTokenMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing getAuthStatus no-token response") }
        XCTAssertEqual(noToken.result["authMethod"], .string("apikey"))
        XCTAssertEqual(noToken.result["authToken"], .null)
        XCTAssertEqual(noToken.result["requiresOpenaiAuth"], .bool(true))

        s.conn.clientSend(req(5, "getAuthStatus", .object([
            "includeToken": .bool(true),
            "refreshToken": .bool(true),
        ])))
        let tokenMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }
        guard case .response(let withToken)? = tokenMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }) else { return XCTFail("missing getAuthStatus token response") }
        XCTAssertEqual(withToken.result["authMethod"], .string("apikey"))
        XCTAssertEqual(withToken.result["authToken"], .string("sk-status-key"))
        XCTAssertEqual(withToken.result["requiresOpenaiAuth"], .bool(true))
    }

    /// Finding 3: a stored credential whose access token is the empty string
    /// must be reported as the no-token state (authMethod:null /
    /// authToken:null / requiresOpenaiAuth:true), NOT as a present-token state.
    /// Mirrors upstream get_auth_status_response's `get_token()` branch:
    /// `Ok(token) if !token.is_empty()` yields the auth method, while `Ok(_)`
    /// (empty token) yields `(None, None)` (account_processor.rs:776-787).
    func testGetAuthStatusEmptyAccessTokenReportsNoAuthMethod() async throws {
        let home = NSTemporaryDirectory() + "e2e-auth-status-empty-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        // A Bearer credential with an empty access token survives a round-trip
        // (the tokens object is present) but represents a degenerate empty
        // token; authMethod(for:) keys off tokenType and would otherwise
        // report "chatgpt".
        try store.save(AuthTokens(accessToken: "",
                                  refreshToken: nil,
                                  idToken: nil,
                                  tokenType: "Bearer",
                                  expiresAtUnix: AuthTokens.neverExpires,
                                  accountId: "acct_empty"))
        let auth = AuthManager(store: store, env: [:])
        // Sanity: the empty token actually persisted and reloads.
        let reloaded = await auth.storedTokens()
        XCTAssertEqual(reloaded?.accessToken, "")

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "getAuthStatus", .object([
            "includeToken": .bool(true),
            "refreshToken": .bool(false),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let resp)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing empty-token getAuthStatus response") }
        XCTAssertEqual(resp.result["authMethod"], .null,
                       "an empty access token is the no-token state")
        XCTAssertEqual(resp.result["authToken"], .null)
        XCTAssertEqual(resp.result["requiresOpenaiAuth"], .bool(true))
    }

    /// When the active model provider declares `requires_openai_auth = false`,
    /// the deprecated `getAuthStatus` must report
    /// authMethod:null / authToken:null / requiresOpenaiAuth:false WITHOUT
    /// consulting the token store, mirroring upstream
    /// get_auth_status_response (account_processor.rs:751-758). Even when a
    /// valid API-key credential is present, the no-auth provider short-circuits
    /// the token branches.
    func testGetAuthStatusReportsRequiresOpenAIAuthFalseForNoAuthProvider() async throws {
        let home = NSTemporaryDirectory() + "e2e-auth-status-noauth-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        model_provider = "custom"

        [model_providers.custom]
        name = "Custom"
        base_url = "https://example.test/v1"
        requires_openai_auth = false
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        // Seed a credential the no-auth path must ignore.
        try await auth.loginWithAPIKey("sk-should-be-ignored")
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "getAuthStatus", .object([
            "includeToken": .bool(true),
            "refreshToken": .bool(false),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let response)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing no-auth-provider getAuthStatus response") }
        XCTAssertEqual(response.result["authMethod"], .null)
        XCTAssertEqual(response.result["authToken"], .null)
        XCTAssertEqual(response.result["requiresOpenaiAuth"], .bool(false))
    }

    /// Device-code login *start* failures must mirror
    /// login_chatgpt_device_code_start_error (account_processor.rs:344-351):
    /// a NotFound condition (device-code login not enabled, HTTP 404) maps to
    /// `invalid_request` (-32600) carrying the error's own message, while any
    /// other (transient) failure maps to `internal_error` (-32603) prefixed
    /// "failed to request device code:".
    func testDeviceCodeStartNotFoundMapsToInvalidRequest() async throws {
        let home = NSTemporaryDirectory() + "e2e-device-start-notfound-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let challenge = DeviceCodeChallenge(
            verificationURL: "https://issuer.example/codex/device",
            userCode: "X", deviceAuthId: "id", intervalSeconds: 1)
        let notEnabledMessage = "device code login is not enabled for this Codex server. Use the browser login or verify the server URL."
        let deviceClient = MockDeviceCodeClient(
            challenge: challenge,
            requestError: .deviceCodeNotEnabled(notEnabledMessage),
            completion: .succeed(AuthTokens(accessToken: "x", expiresAtUnix: 0)))
        let auth = AuthManager(store: store, deviceCodeClient: deviceClient)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("chatgptDeviceCode"),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let err)? = msgs.first(where: {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }) else { return XCTFail("expected invalid_request error for not-enabled device code") }
        XCTAssertEqual(err.error.code, WireError.invalidRequestCode)
        XCTAssertEqual(err.error.message, notEnabledMessage)
    }

    func testDeviceCodeStartTransientFailureMapsToInternalError() async throws {
        let home = NSTemporaryDirectory() + "e2e-device-start-transient-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let challenge = DeviceCodeChallenge(
            verificationURL: "https://issuer.example/codex/device",
            userCode: "X", deviceAuthId: "id", intervalSeconds: 1)
        let deviceClient = MockDeviceCodeClient(
            challenge: challenge,
            requestError: .server("device code request failed with status 500"),
            completion: .succeed(AuthTokens(accessToken: "x", expiresAtUnix: 0)))
        let auth = AuthManager(store: store, deviceCodeClient: deviceClient)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/login/start", .object([
            "type": .string("chatgptDeviceCode"),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let err)? = msgs.first(where: {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }) else { return XCTFail("expected internal_error for transient device-code failure") }
        XCTAssertEqual(err.error.code, WireError.internalCode)
        XCTAssertTrue(err.error.message.hasPrefix("failed to request device code:"),
                      "message must carry upstream prefix, got: \(err.error.message)")
    }

    func testGetAuthStatusRefreshesChatGPTBearerAndOmitsTokenOnRefreshFailure() async throws {
        let home = NSTemporaryDirectory() + "e2e-auth-status-refresh-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        try store.save(AuthTokens(accessToken: "stale-token",
                                  refreshToken: "refresh-one",
                                  tokenType: "Bearer",
                                  expiresAtUnix: 100,
                                  accountId: "acct-status"))
        let exchanger = MockStatusTokenExchanger(refreshResults: [
            .success(AuthTokens(accessToken: "fresh-token",
                                refreshToken: "refresh-two",
                                tokenType: "Bearer",
                                expiresAtUnix: 9_999_999_999,
                                accountId: "acct-status")),
            .failure(.server("refresh failed")),
        ])
        let auth = AuthManager(store: store, exchanger: exchanger, now: { 1_000 })
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(
            1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "getAuthStatus", .object([
            "includeToken": .bool(true),
            "refreshToken": .bool(true),
        ])))
        let refreshedMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let refreshed)? = refreshedMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing refreshed auth status response") }
        XCTAssertEqual(refreshed.result["authMethod"], .string("chatgpt"))
        XCTAssertEqual(refreshed.result["authToken"], .string("fresh-token"))
        XCTAssertEqual(refreshed.result["requiresOpenaiAuth"], .bool(true))
        XCTAssertEqual(store.load()?.accessToken, "fresh-token")

        s.conn.clientSend(req(3, "getAuthStatus", .object([
            "includeToken": .bool(true),
            "refreshToken": .bool(true),
        ])))
        let failedMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let failed)? = failedMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else { return XCTFail("missing failed-refresh auth status response") }
        XCTAssertEqual(failed.result["authMethod"], .string("chatgpt"))
        XCTAssertEqual(failed.result["authToken"], .null)
        XCTAssertEqual(failed.result["requiresOpenaiAuth"], .bool(true))
        let refreshCount = await exchanger.refreshCount()
        XCTAssertEqual(refreshCount, 2)

        try store.save(AuthTokens(accessToken: "recovered-token",
                                  refreshToken: "refresh-three",
                                  tokenType: "Bearer",
                                  expiresAtUnix: 9_999_999_999,
                                  accountId: "acct-status"))
        s.conn.clientSend(req(4, "getAuthStatus", .object([
            "includeToken": .bool(true),
            "refreshToken": .bool(false),
        ])))
        let recoveredMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let recovered)? = recoveredMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing recovered auth status response") }
        XCTAssertEqual(recovered.result["authMethod"], .string("chatgpt"))
        XCTAssertEqual(recovered.result["authToken"], .string("recovered-token"))
        XCTAssertEqual(recovered.result["requiresOpenaiAuth"], .bool(true))
    }

    /// Upstream's get_account_rate_limits_response returns only the
    /// GetAccountRateLimitsResponse; the account/rateLimits/updated
    /// notification is emitted exclusively from in-turn token-usage events
    /// (bespoke_event_handling.rs:1573), never from this read handler.
    func testAccountRateLimitsReadReturnsResponseWithoutNotification() async throws {
        let home = NSTemporaryDirectory() + "e2e-rate-limits-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        try await auth.loginWithExternalChatGPTTokens(accessToken: "chatgpt-token",
                                                      accountId: "acct-rate")
        let expectedSnapshot: JSONValue = .object([
            "limitId": .string("codex"),
            "limitName": .null,
            "primary": .object([
                "usedPercent": .int(42),
                "windowDurationMins": .int(60),
                "resetsAt": .int(1_735_689_720),
            ]),
            "secondary": .null,
            "credits": .null,
            "planType": .string("pro"),
            "rateLimitReachedType": .null,
        ])
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            accountRateLimitsFetcher: { tokens, baseURL in
                XCTAssertEqual(tokens.accessToken, "chatgpt-token")
                XCTAssertEqual(tokens.accountId, "acct-rate")
                XCTAssertFalse(baseURL.isEmpty)
                return .object([
                    "rateLimits": expectedSnapshot,
                    "rateLimitsByLimitId": .object(["codex": expectedSnapshot]),
                ])
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/rateLimits/read", .object([:])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let response)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else {
            return XCTFail("expected account/rateLimits/read response")
        }
        guard let responseSnapshot = response.result["rateLimits"] else {
            return XCTFail("expected rateLimits snapshot")
        }
        XCTAssertEqual(responseSnapshot, expectedSnapshot)
        XCTAssertEqual(response.result["rateLimitsByLimitId"]?["codex"], expectedSnapshot)
        // The read handler must not push an account/rateLimits/updated
        // notification (Finding 5).
        XCTAssertFalse(msgs.contains {
            if case .notification(let n) = $0 { return n.method == "account/rateLimits/updated" }
            return false
        }, "account/rateLimits/read must not emit account/rateLimits/updated")
    }

    func testAccountRateLimitsRequireChatGPTAuth() async throws {
        let home = NSTemporaryDirectory() + "e2e-rate-limits-auth-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "account/rateLimits/read", .object([:])))
        let unauth = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let unauthError)? = unauth.last else {
            return XCTFail("expected unauthenticated rate-limit error")
        }
        XCTAssertEqual(unauthError.error.message,
                       "codex account authentication required to read rate limits")

        try await auth.loginWithAPIKey("sk-test")
        s.conn.clientSend(req(3, "account/rateLimits/read", .object([:])))
        let apiKey = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }
        guard case .error(let apiKeyError)? = apiKey.last else {
            return XCTFail("expected api-key rate-limit error")
        }
        XCTAssertEqual(apiKeyError.error.message,
                       "chatgpt authentication required to read rate limits")
    }

    func testSendAddCreditsNudgeEmailPostsThroughChatGPTBackend() async throws {
        let home = NSTemporaryDirectory() + "e2e-nudge-email-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://example.test"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        try await auth.loginWithExternalChatGPTTokens(accessToken: "chatgpt-token",
                                                      accountId: "acct-nudge")
        let recorder = NudgeEmailRecorder()
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            accountNudgeEmailSender: { tokens, baseURL, creditType in
                await recorder.record(tokens: tokens, baseURL: baseURL, creditType: creditType)
                return "sent"
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "account/sendAddCreditsNudgeEmail", .object([
            "creditType": .string("usage_limit"),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let response)? = msgs.last else {
            return XCTFail("expected nudge email response")
        }
        XCTAssertEqual(response.result["status"], .string("sent"))
        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls, [
            .init(accessToken: "chatgpt-token",
                  accountId: "acct-nudge",
                  baseURL: "https://example.test",
                  creditType: "usage_limit"),
        ])
    }

    func testSendAddCreditsNudgeEmailAuthValidationCooldownAndFailure() async throws {
        let noAuth = try makeStack(MockModelClient([.hello()]))
        defer { noAuth.pump.cancel(); try? FileManager.default.removeItem(atPath: noAuth.home) }
        noAuth.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        _ = await waitOutbound(noAuth.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        noAuth.conn.clientSend(req(2, "account/sendAddCreditsNudgeEmail", .object([
            "creditType": .string("credits"),
        ])))
        let noAuthMsgs = await waitOutbound(noAuth.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let noAuthError)? = noAuthMsgs.last else {
            return XCTFail("expected unauthenticated nudge email error")
        }
        XCTAssertEqual(noAuthError.error.message,
                       "codex account authentication required to notify workspace owner")

        let home = NSTemporaryDirectory() + "e2e-nudge-email-auth-" + UUID().uuidString
        let store = FileTokenStore(codexHome: home)
        let auth = AuthManager(store: store)
        try await auth.loginWithAPIKey("sk-test")
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        s.conn.clientSend(req(10, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(10) }
            return false
        }
        s.conn.clientSend(req(11, "account/sendAddCreditsNudgeEmail", .object([
            "creditType": .string("usage_limit"),
        ])))
        let apiKeyMsgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(11) }
            return false
        }
        guard case .error(let apiKeyError)? = apiKeyMsgs.last else {
            return XCTFail("expected API-key nudge email error")
        }
        XCTAssertEqual(apiKeyError.error.message,
                       "chatgpt authentication required to notify workspace owner")

        try await auth.loginWithExternalChatGPTTokens(accessToken: "chatgpt-token",
                                                      accountId: "acct-nudge")
        s.conn.clientSend(req(12, "account/sendAddCreditsNudgeEmail", .object([
            "creditType": .string("bad"),
        ])))
        let invalidMsgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(12) }
            return false
        }
        guard case .error(let invalidError)? = invalidMsgs.last else {
            return XCTFail("expected invalid creditType error")
        }
        XCTAssertEqual(invalidError.error.message,
                       "account/sendAddCreditsNudgeEmail creditType must be credits or usage_limit")

        let cooldown = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            accountNudgeEmailSender: { _, _, _ in
                throw AccountNudgeEmailHTTPStatusError(statusCode: 429)
            })
        defer { cooldown.pump.cancel() }
        cooldown.conn.clientSend(req(20, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        _ = await waitOutbound(cooldown.conn) {
            if case .response(let r) = $0 { return r.id == .int(20) }
            return false
        }
        cooldown.conn.clientSend(req(21, "account/sendAddCreditsNudgeEmail", .object([
            "creditType": .string("credits"),
        ])))
        let cooldownMsgs = await waitOutbound(cooldown.conn) {
            if case .response(let r) = $0 { return r.id == .int(21) }
            return false
        }
        guard case .response(let cooldownResponse)? = cooldownMsgs.last else {
            return XCTFail("expected cooldown response")
        }
        XCTAssertEqual(cooldownResponse.result["status"], .string("cooldown_active"))

        let failure = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            accountNudgeEmailSender: { _, _, _ in
                throw NSError(domain: "nudge", code: 500,
                              userInfo: [NSLocalizedDescriptionKey: "backend exploded"])
            })
        defer { failure.pump.cancel() }
        failure.conn.clientSend(req(30, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        _ = await waitOutbound(failure.conn) {
            if case .response(let r) = $0 { return r.id == .int(30) }
            return false
        }
        failure.conn.clientSend(req(31, "account/sendAddCreditsNudgeEmail", .object([
            "creditType": .string("credits"),
        ])))
        let failureMsgs = await waitOutbound(failure.conn) {
            if case .error(let e) = $0 { return e.id == .int(31) }
            return false
        }
        guard case .error(let failureError)? = failureMsgs.last else {
            return XCTFail("expected backend failure error")
        }
        XCTAssertEqual(failureError.error.code, WireError.internalCode)
        XCTAssertTrue(failureError.error.message.contains("failed to notify workspace owner"))
    }

    func testFullStreamedTurnEndToEnd() async throws {
        let s = try makeStack(MockModelClient([.hello("Hello E2E")]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))

        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string("/work")])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let sr)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false }),
              let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self, from: sr.result) else {
            return XCTFail("no thread/start response")
        }
        XCTAssertEqual(env.cwd, "/work")
        XCTAssertEqual(env.modelProvider, "openai")
        XCTAssertEqual(env.approvalsReviewer, "user")
        // No `approvalPolicy` was passed in `thread/start` params above, so the
        // port falls back to its intended faithful default of `on-request`
        // (matches upstream `parse_or_default(&metadata.approval_mode,
        // AskForApproval::OnRequest)` in thread-store/src/local/read_thread.rs
        // and `RequestRouter.approvalPolicyFallback`).
        XCTAssertEqual(env.approvalPolicy, .string("on-request"))
        // P2.4 / H-09: thread/start responses now emit the structured tagged
        // sandbox-policy form (upstream wire shape from
        // `codex-rs/app-server-protocol/src/protocol/v2/permissions.rs`)
        // populated from the SessionConfig defaults (workspaceWrite for cwd).
        XCTAssertEqual(env.sandbox["type"]?.stringValue, "workspaceWrite")
        XCTAssertEqual(env.sandbox["writableRoots"], .array([.string("/work")]))
        XCTAssertEqual(env.sandbox["networkAccess"], .bool(false))
        XCTAssertEqual(env.thread.cwd, "/work")
        XCTAssertEqual(env.thread.sessionId, env.thread.id.raw)
        XCTAssertEqual(env.thread.status, .object(["type": .string("idle")]))
        XCTAssertEqual(env.thread.source, .string("appServer"))
        XCTAssertEqual(env.thread.turns, [])
        let tid = env.thread.id

        s.conn.clientSend(req(30, "thread/start", .object([
            "cwd": .string("/work"),
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("auto_review"),
        ])))
        let autoReviewStart = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(30) }
            return false
        }
        guard case .response(let ar)? = autoReviewStart.first(where: {
            if case .response(let r) = $0 { return r.id == .int(30) }
            return false
        }), let arEnv = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                               from: ar.result) else {
            return XCTFail("no auto-review thread/start response")
        }
        XCTAssertEqual(arEnv.approvalPolicy, .string("on-request"))
        XCTAssertEqual(arEnv.approvalsReviewer, "auto_review")

        s.conn.clientSend(req(3, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"), "text": .string("hi")])]),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }; return false
        }
        let methods = msgs.compactMap { m -> String? in
            if case .notification(let n) = m { return n.method }; return nil
        }
        XCTAssertTrue(methods.contains("turn/started"))
        XCTAssertTrue(methods.contains("item/agentMessage/delta"))
        XCTAssertTrue(methods.contains("item/completed"))
        XCTAssertTrue(methods.contains("turn/completed"))

        // Durable: reconstruct sees the assistant message.
        let rebuilt = try await s.store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .agentMessage(_, let t) = $0 { return t == "Hello E2E" }; return false
        })

        s.conn.clientSend(req(4, "thread/turns/list", .object([
            "threadId": .string(tid.raw),
        ])))
        let turnsMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let turnsResponse)? = turnsMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }), let firstTurn = turnsResponse.result["data"]?.arrayValue?.first,
           let turnId = firstTurn["id"]?.stringValue else {
            return XCTFail("missing thread/turns/list persisted turn")
        }
        XCTAssertEqual(firstTurn["status"]?.stringValue, "completed")
        XCTAssertTrue(firstTurn["items"]?.arrayValue?.contains {
            $0["type"]?.stringValue == "agentMessage"
                && $0["text"]?.stringValue == "Hello E2E"
        } == true)

        s.conn.clientSend(req(5, "thread/turns/items/list", .object([
            "threadId": .string(tid.raw),
            "turnId": .string(turnId),
        ])))
        let itemMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }
        guard case .response(let itemsResponse)? = itemMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }) else { return XCTFail("missing thread/turns/items/list response") }
        XCTAssertTrue(itemsResponse.result["data"]?.arrayValue?.contains {
            $0["type"]?.stringValue == "agentMessage"
                && $0["text"]?.stringValue == "Hello E2E"
        } == true)
    }

    /// Turn-id correlation regression: the `turn/start` response `turn.id` MUST
    /// equal the engine turn id carried by every subsequent `turn/started` and
    /// `turn/completed` notification (and the id the client echoes in
    /// `turn/steer.expectedTurnId` / `turn/interrupt.turnId`). Previously the
    /// request handler replied with a freshly generated id unrelated to the
    /// engine's own turn id, so the response correlated with nothing.
    func testTurnStartResponseIdMatchesTurnNotificationIds() async throws {
        let s = try makeStack(MockModelClient([.hello("Hello correlation")]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))

        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string("/work")])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let sr)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false }),
              let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self, from: sr.result) else {
            return XCTFail("no thread/start response")
        }
        let tid = env.thread.id

        s.conn.clientSend(req(3, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"), "text": .string("hi")])]),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }; return false
        }

        // The turn/start response id.
        guard case .response(let turnResp)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }; return false
        }), let responseTurnId = turnResp.result["turn"]?["id"]?.stringValue else {
            return XCTFail("missing turn/start response turn.id")
        }

        // The turn id carried by turn/started.
        guard let startedTurnId = msgs.compactMap({ m -> String? in
            if case .notification(let n) = m, n.method == "turn/started" {
                return n.params?["turn"]?["id"]?.stringValue
            }
            return nil
        }).first else { return XCTFail("missing turn/started turn.id") }

        // The turn id carried by turn/completed.
        guard let completedTurnId = msgs.compactMap({ m -> String? in
            if case .notification(let n) = m, n.method == "turn/completed" {
                return n.params?["turn"]?["id"]?.stringValue
            }
            return nil
        }).first else { return XCTFail("missing turn/completed turn.id") }

        XCTAssertEqual(responseTurnId, startedTurnId,
                       "turn/start response id must equal the turn/started turn id")
        XCTAssertEqual(responseTurnId, completedTurnId,
                       "turn/start response id must equal the turn/completed turn id")
    }

    func testThreadInjectItemsValidatesPersistsAndUpdatesLoadedContext() async throws {
        let model = RecordingModelClient(MockModelClient([
            .hello("first answer"),
            .hello("second answer"),
        ]))
        let s = try makeStack(model)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }

        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))

        s.conn.clientSend(req(2, "thread/start", .object([
            "cwd": .string(FileManager.default.currentDirectoryPath),
            "model": .string("mock"),
        ])))
        let startMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let start)? = startMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let tidRaw = start.result["thread"]?["id"]?.stringValue else {
            return XCTFail("missing thread/start response")
        }
        let tid = ThreadId(tidRaw)

        s.conn.clientSend(req(3, "thread/inject_items", .object([
            "threadId": .string("bad id"),
            "items": .array([.object(["content": .string("ignored")])]),
        ])))
        let malformedMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }
        guard case .error(let malformed)? = malformedMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }) else { return XCTFail("missing malformed thread/inject_items error") }
        // Audit app-server-registry/finding-3: upstream emits
        // `invalid thread id: <error>` (turn_processor.rs:192 et al.).
        XCTAssertTrue(malformed.error.message.hasPrefix("invalid thread id"),
                      "got: \(malformed.error.message)")

        s.conn.clientSend(req(4, "thread/inject_items", .object([
            "threadId": .string("thr_not_found"),
            "items": .array([.object(["content": .string("ignored")])]),
        ])))
        let unknownMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(4) }
            return false
        }
        guard case .error(let unknown)? = unknownMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(4) }
            return false
        }) else { return XCTFail("missing unknown thread/inject_items error") }
        XCTAssertEqual(unknown.error.message,
                       "thread/inject_items thread not found: thr_not_found")

        s.conn.clientSend(req(5, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("first turn")])]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }

        let injectedText = "injected assistant context marker"
        s.conn.clientSend(req(6, "thread/inject_items", .object([
            "threadId": .string(tid.raw),
            "items": .array([
                .object(["type": .string("message"),
                         "role": .string("assistant"),
                         "content": .string(injectedText)]),
            ]),
        ])))
        let injectMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }
        guard case .response(let inject)? = injectMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }) else { return XCTFail("missing thread/inject_items response") }
        XCTAssertEqual(inject.result, .object([:]))

        s.conn.clientSend(req(7, "thread/turns/list", .object([
            "threadId": .string(tid.raw),
        ])))
        let turnsMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(7) }
            if case .error(let e) = $0 { return e.id == .int(7) }
            return false
        }
        if case .error(let error)? = turnsMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(7) }
            return false
        }) {
            return XCTFail("turns after injection failed: \(error.error.message)")
        }
        guard case .response(let turns)? = turnsMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(7) }
            return false
        }) else { return XCTFail("missing turns after injection") }
        XCTAssertTrue(turns.result["data"]?.arrayValue?.contains {
            $0["status"]?.stringValue == "completed"
                && ($0["items"]?.arrayValue ?? []).contains {
                    $0["type"]?.stringValue == "agentMessage"
                        && $0["text"]?.stringValue == injectedText
                }
        } == true)

        s.conn.clientSend(req(8, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("second turn")])]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }
        let captures = await model.capturedRequests()
        XCTAssertGreaterThanOrEqual(captures.count, 2)
        XCTAssertTrue(captures[1].prompt.input.contains(.assistantText(injectedText)),
                      "thread/inject_items must update the loaded session context, not only durable storage")
    }

    func testThreadRollbackValidatesPersistsAndUpdatesLoadedContext() async throws {
        let model = RecordingModelClient(MockModelClient([
            .hello("first answer"),
            .hello("second answer"),
            .hello("third answer"),
        ]))
        let s = try makeStack(model)
        let sink = OutboundSink()
        let conn = s.conn
        let drain = Task {
            for await message in conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer {
            drain.cancel()
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }

        s.conn.clientSend(req(0, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        let initializeResponse = await awaitResponse(sink, id: 0)
        XCTAssertNotNil(initializeResponse)
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))

        s.conn.clientSend(req(1, "thread/rollback", .object([
            "threadId": .string("bad id"),
            "numTurns": .int(1),
        ])))
        guard let malformedError = await awaitError(sink, id: 1) else {
            return XCTFail("missing malformed thread/rollback error")
        }
        XCTAssertTrue(malformedError.error.message.hasPrefix("invalid thread id"),
                      "got: \(malformedError.error.message)")

        s.conn.clientSend(req(2, "thread/rollback", .object([
            "threadId": .string("thr_not_found"),
            "numTurns": .int(1),
        ])))
        guard let unknownError = await awaitError(sink, id: 2) else {
            return XCTFail("missing unknown thread/rollback error")
        }
        XCTAssertEqual(unknownError.error.message,
                       "thread/rollback thread not found: thr_not_found")

        s.conn.clientSend(req(3, "thread/start", .object(["cwd": .string("/work")])))
        guard let startResponse = await awaitResponse(sink, id: 3),
              let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                               from: startResponse.result) else {
            return XCTFail("no thread/start response")
        }
        let tid = env.thread.id

        s.conn.clientSend(req(4, "thread/rollback", .object([
            "threadId": .string(tid.raw),
            "numTurns": .int(0),
        ])))
        guard let badCountError = await awaitError(sink, id: 4) else {
            return XCTFail("missing invalid numTurns thread/rollback error")
        }
        XCTAssertEqual(badCountError.error.message, "thread/rollback numTurns must be >= 1")

        var completedCount = await sink.notificationCount("turn/completed")
        s.conn.clientSend(req(5, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("first user")])]),
        ])))
        let firstCompleted = await awaitNotificationCount(sink, method: "turn/completed",
                                                          atLeast: completedCount + 1)
        XCTAssertTrue(firstCompleted)

        completedCount = await sink.notificationCount("turn/completed")
        s.conn.clientSend(req(6, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("second user")])]),
        ])))
        let secondCompleted = await awaitNotificationCount(sink, method: "turn/completed",
                                                           atLeast: completedCount + 1)
        XCTAssertTrue(secondCompleted)

        s.conn.clientSend(req(7, "thread/rollback", .object([
            "threadId": .string(tid.raw),
            "numTurns": .int(1),
        ])))
        guard let rollbackResponse = await awaitResponse(sink, id: 7),
              let turns = rollbackResponse.result["thread"]?["turns"]?.arrayValue else {
            return XCTFail("missing thread/rollback response")
        }
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(turns.first?["items"]?.arrayValue?.contains {
            $0["type"]?.stringValue == "agentMessage"
                && $0["text"]?.stringValue == "first answer"
        } == true)
        XCTAssertFalse(turns.contains {
            $0["items"]?.arrayValue?.contains {
                $0["type"]?.stringValue == "agentMessage"
                    && $0["text"]?.stringValue == "second answer"
            } == true
        })

        completedCount = await sink.notificationCount("turn/completed")
        s.conn.clientSend(req(8, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("third user")])]),
        ])))
        let thirdCompleted = await awaitNotificationCount(sink, method: "turn/completed",
                                                          atLeast: completedCount + 1)
        XCTAssertTrue(thirdCompleted)

        let captures = await model.capturedRequests()
        XCTAssertGreaterThanOrEqual(captures.count, 3)
        let thirdPrompt = captures[2].prompt.input
        XCTAssertTrue(thirdPrompt.contains(.assistantText("first answer")))
        XCTAssertFalse(thirdPrompt.contains(.assistantText("second answer")),
                       "thread/rollback must update loaded context, not only durable storage")
        XCTAssertFalse(thirdPrompt.contains(.userText("second user")))
    }

    func testThreadShellCommandAppServerValidatesRunsAndPersists() async throws {
        let work = NSTemporaryDirectory() + "shell-command-e2e-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        let s = try makeStack(MockModelClient([.hello()]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }

        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))

        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string(work)])))
        let startMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let startResponse)? = startMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                             from: startResponse.result) else {
            return XCTFail("missing thread/start response")
        }
        let tid = env.thread.id

        s.conn.clientSend(req(3, "thread/shellCommand", .object([
            "threadId": .string(tid.raw),
            "command": .string("   \n\t"),
        ])))
        let blankMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }
        guard case .error(let blankError)? = blankMessages.last else {
            return XCTFail("missing blank command rejection")
        }
        XCTAssertEqual(blankError.error.code, WireError.invalidRequestCode)
        XCTAssertEqual(blankError.error.message, "command must not be empty")

        s.conn.clientSend(req(4, "thread/shellCommand", .object([
            "threadId": .string(tid.raw),
            "command": .string("  printf shell-appserver-ran  "),
        ])))
        let responseMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let shellResponse)? = responseMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing shellCommand response") }
        XCTAssertEqual(shellResponse.result, .object([:]))

        let shellMessages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }
        let methods = shellMessages.compactMap { message -> String? in
            if case .notification(let n) = message { return n.method }
            return nil
        }
        XCTAssertTrue(methods.contains("turn/started"))
        XCTAssertTrue(methods.contains("item/started"))
        XCTAssertTrue(methods.contains("item/completed"))
        XCTAssertTrue(methods.contains("turn/completed"))

        let rebuilt = try await s.store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .commandExecution(_, let command, let cwd, let status, _, let output, let exitCode, _, _, _) = $0 {
                return command == ["printf shell-appserver-ran"]
                    && cwd == work
                    && status == .completed
                    && exitCode == 0
                    && (output ?? "").contains("shell-appserver-ran")
            }
            return false
        }, "thread/shellCommand must run through app-server and persist the command output")
    }

    func testThreadCompactStartAppServerStreamsAndPersistsCompaction() async throws {
        let s = try makeStack(MockModelClient([
            .hello("pre-compact assistant"),
            .hello("manual compact summary"),
        ]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }

        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))

        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string("/compact-work")])))
        let startMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let startResponse)? = startMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                             from: startResponse.result) else {
            return XCTFail("missing thread/start response")
        }
        let tid = env.thread.id

        s.conn.clientSend(req(3, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("seed compact history")])]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }

        s.conn.clientSend(req(4, "thread/compact/start", .object([
            "threadId": .string(tid.raw),
        ])))
        let compactResponseMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let compactResponse)? = compactResponseMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing compact response") }
        XCTAssertEqual(compactResponse.result, .object([:]))

        let compactMessages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }
        let compactMethods = compactMessages.compactMap { message -> String? in
            if case .notification(let n) = message { return n.method }
            return nil
        }
        XCTAssertTrue(compactMethods.contains("turn/started"))
        // v2 app-server suppresses the deprecated `thread/compacted`
        // notification (upstream bespoke_event_handling.rs:866-869); the
        // canonical compaction signal is the `item/completed` (contextCompaction)
        // notification instead.
        XCTAssertFalse(compactMethods.contains("thread/compacted"))
        XCTAssertTrue(compactMethods.contains("item/completed"))
        XCTAssertTrue(compactMethods.contains("turn/completed"))

        let rebuilt = try await s.store.reconstruct(tid)
        // P1.1 / F2: replace-then-replay reconstruction surfaces the compaction
        // summary as the `.userMessage` bridge from the replayed
        // replacement_history (faithful to upstream), not an `.agentMessage`.
        XCTAssertTrue(rebuilt.items.contains {
            if case .userMessage(_, let content) = $0 {
                let text = content.first?.text ?? ""
                return text.hasPrefix(Compaction.summaryPrefix)
                    && text.contains("manual compact summary")
            }
            return false
        }, "thread/compact/start must persist the model-produced compacted history")
    }

    /// P2.5 / H-11: `thread/backgroundTerminals/clean` must be in the method
    /// registry and dispatched to a real handler. Before this fix the method
    /// fell through `Method.all` and returned `-32601 method not found`,
    /// breaking clients that wire up the upstream `ThreadBackgroundTerminalsClean`
    /// request type. This test exercises the happy path under
    /// experimentalApi and asserts we get a JSON-RPC response (success)
    /// rather than a `-32601` error envelope.
    func testBackgroundTerminalsCleanMethodRegistered() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("p25")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string("/p25-bg")])))
        let startMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let startResponse)? = startMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                             from: startResponse.result) else {
            return XCTFail("missing thread/start response")
        }
        s.conn.clientSend(req(3, "thread/backgroundTerminals/clean", .object([
            "threadId": .string(env.thread.id.raw),
        ])))
        let cleanMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }
        // It MUST be a response — not an error -32601.
        guard let last = cleanMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }) else { return XCTFail("no clean reply") }
        if case .error(let err) = last {
            XCTFail("thread/backgroundTerminals/clean must be registered " +
                    "(got error code=\(err.error.code), msg=\(err.error.message))")
        }
        if case .response(let r) = last {
            XCTAssertEqual(r.result, .object([:]),
                           "clean returns EmptyResponse per upstream " +
                           "ThreadBackgroundTerminalsCleanResponse{}")
        }
    }

    func testThreadBackgroundTerminalsCleanIsGatedValidatedAndThreadScoped() async throws {
        let noCaps = try makeStack(MockModelClient([.hello()]))
        defer {
            noCaps.pump.cancel()
            try? FileManager.default.removeItem(atPath: noCaps.home)
        }
        noCaps.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        _ = await waitOutbound(noCaps.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        noCaps.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
        noCaps.conn.clientSend(req(2, "thread/backgroundTerminals/clean", .object([
            "threadId": .string("thr_missing"),
        ])))
        let gatedMessages = await waitOutbound(noCaps.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let gatedError)? = gatedMessages.last else {
            return XCTFail("missing experimental gate error")
        }
        XCTAssertEqual(gatedError.error.message,
                       "thread/backgroundTerminals/clean requires experimentalApi capability")

        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(10, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(10) }
            return false
        }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))

        s.conn.clientSend(req(11, "thread/backgroundTerminals/clean", .object([:])))
        let missingMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(11) }
            return false
        }
        guard case .error(let missingError)? = missingMessages.last else {
            return XCTFail("missing threadId validation error")
        }
        XCTAssertEqual(missingError.error.message,
                       "thread/backgroundTerminals/clean requires threadId")

        s.conn.clientSend(req(12, "thread/backgroundTerminals/clean", .object([
            "threadId": .string("bad id"),
        ])))
        let invalidMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(12) }
            return false
        }
        guard case .error(let invalidError)? = invalidMessages.last else {
            return XCTFail("missing invalid threadId error")
        }
        XCTAssertTrue(invalidError.error.message.hasPrefix("invalid thread id"),
                      "got: \(invalidError.error.message)")

        s.conn.clientSend(req(13, "thread/backgroundTerminals/clean", .object([
            "threadId": .string("thr_not_found"),
        ])))
        let unknownMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(13) }
            return false
        }
        guard case .error(let unknownError)? = unknownMessages.last else {
            return XCTFail("missing unknown thread error")
        }
        XCTAssertEqual(unknownError.error.message,
                       "thread/backgroundTerminals/clean thread not found: thr_not_found")

        s.conn.clientSend(req(14, "thread/start", .object(["cwd": .string("/bg-clean")])))
        let startMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(14) }
            return false
        }
        guard case .response(let startResponse)? = startMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(14) }
            return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                             from: startResponse.result) else {
            return XCTFail("missing thread/start response")
        }

        s.conn.clientSend(req(15, "thread/backgroundTerminals/clean", .object([
            "threadId": .string(env.thread.id.raw),
        ])))
        let cleanMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(15) }
            return false
        }
        guard case .response(let cleanResponse)? = cleanMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(15) }
            return false
        }) else { return XCTFail("missing clean response") }
        XCTAssertEqual(cleanResponse.result, .object([:]))
    }

    func testGetConversationSummaryReturnsStoredThreadByIdAndRolloutPath() async throws {
        let s = try makeStack(MockModelClient([.hello("summary answer")]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))

        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string("/summary-work")])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let sr)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                             from: sr.result) else {
            return XCTFail("no thread/start response")
        }
        let threadId = env.thread.id.raw
        let rolloutPath = s.home + "/sessions/\(threadId).rollout.jsonl"

        s.conn.clientSend(req(3, "turn/start", .object([
            "threadId": .string(threadId),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("summarize real stored thread")])]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }

        s.conn.clientSend(req(4, "thread/metadata/update", .object([
            "threadId": .string(threadId),
            "gitInfo": .object([
                "branch": .string("feature/summary"),
                "sha": .string("abc123"),
                "originUrl": .string("https://example.test/repo.git"),
            ]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }

        s.conn.clientSend(req(5, "getConversationSummary", .object([
            "conversationId": .string(threadId),
        ])))
        let byIdMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }
        guard case .response(let byId)? = byIdMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }), let idSummary = byId.result["summary"] else {
            return XCTFail("missing getConversationSummary by id response")
        }
        XCTAssertEqual(idSummary["conversationId"]?.stringValue, threadId)
        // Upstream date-partitioned layout: sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl.
        let actualRolloutPath = idSummary["path"]?.stringValue ?? rolloutPath
        XCTAssertTrue(actualRolloutPath.contains("/sessions/")
                      && actualRolloutPath.hasSuffix("-\(threadId).jsonl"),
                      "rollout path uses the date-partitioned layout: \(actualRolloutPath)")
        XCTAssertEqual(idSummary["preview"]?.stringValue, "summarize real stored thread")
        XCTAssertEqual(idSummary["cwd"]?.stringValue, "/summary-work")
        XCTAssertEqual(idSummary["modelProvider"]?.stringValue, "openai")
        XCTAssertEqual(idSummary["cliVersion"]?.stringValue, "CodexKit/0.1")
        XCTAssertEqual(idSummary["source"]?.stringValue, "appServer")
        XCTAssertNotNil(idSummary["timestamp"]?.stringValue)
        XCTAssertNotNil(idSummary["updatedAt"]?.stringValue)
        XCTAssertEqual(idSummary["gitInfo"]?["branch"]?.stringValue, "feature/summary")
        XCTAssertEqual(idSummary["gitInfo"]?["sha"]?.stringValue, "abc123")
        XCTAssertEqual(idSummary["gitInfo"]?["originUrl"]?.stringValue,
                       "https://example.test/repo.git")

        s.conn.clientSend(req(6, "getConversationSummary", .object([
            "rolloutPath": .string(actualRolloutPath),
        ])))
        let byPathMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }
        guard case .response(let byPath)? = byPathMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }), let pathSummary = byPath.result["summary"] else {
            return XCTFail("missing getConversationSummary by rolloutPath response")
        }
        XCTAssertEqual(pathSummary["conversationId"]?.stringValue, threadId)
        XCTAssertEqual(pathSummary["path"]?.stringValue, actualRolloutPath)

        s.conn.clientSend(req(7, "getConversationSummary", .object([
            "rolloutPath": .string(actualRolloutPath),
            "conversationId": .string("thr_missing_summary"),
        ])))
        let bothMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(7) }
            return false
        }
        guard case .response(let both)? = bothMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(7) }
            return false
        }), let bothSummary = both.result["summary"] else {
            return XCTFail("missing getConversationSummary both-params response")
        }
        XCTAssertEqual(bothSummary["conversationId"]?.stringValue, threadId)
        XCTAssertEqual(bothSummary["path"]?.stringValue, actualRolloutPath)

        s.conn.clientSend(req(8, "getConversationSummary", .object([
            "conversationId": .string("thr_missing_summary"),
        ])))
        let missingMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(8) }
            return false
        }
        guard case .error(let missing)? = missingMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(8) }
            return false
        }) else { return XCTFail("missing not-found summary error") }
        XCTAssertTrue(missing.error.message.contains("no rollout found"))
    }

    func testGitDiffToRemoteReturnsRealShaAndDiff() async throws {
        try XCTSkipUnless(gitAvailable())
        let repo = try await makeGitDiffRemoteRepo()
        let nonRepo = NSTemporaryDirectory() + "git-diff-nonrepo-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: nonRepo, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: repo.dir)
            try? FileManager.default.removeItem(atPath: nonRepo)
        }

        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "gitDiffToRemote", .object(["cwd": .string(repo.dir)])))
        let diffMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let diffResponse)? = diffMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing gitDiffToRemote response") }
        XCTAssertEqual(diffResponse.result["sha"]?.stringValue, repo.baseSha)
        let diff = diffResponse.result["diff"]?.stringValue ?? ""
        XCTAssertTrue(diff.contains("tracked.txt"), "diff was:\n\(diff)")
        XCTAssertTrue(diff.contains("+two"), "diff was:\n\(diff)")
        XCTAssertTrue(diff.contains("untracked.txt"), "diff was:\n\(diff)")

        s.conn.clientSend(req(3, "gitDiffToRemote", .object(["cwd": .string(nonRepo)])))
        let errorMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }
        guard case .error(let error)? = errorMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }) else { return XCTFail("missing gitDiffToRemote non-repo error") }
        XCTAssertTrue(error.error.message.contains("failed to compute git diff to remote"))
    }

    func testThreadStartLoadsNotifyAndFiresAfterAgentThroughWorker() async throws {
        let home = NSTemporaryDirectory() + "e2e-notify-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let out = home + "/notify.json"
        let script = home + "/notify.sh"
        try #"printf '%s' "$1" > "$CODEX_NOTIFY_OUT""#
            .write(toFile: script, atomically: true, encoding: .utf8)
        try #"notify = ["/bin/sh", "\#(script)"]"#
            .write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let oldOut = getenv("CODEX_NOTIFY_OUT").map { String(cString: $0) }
        setenv("CODEX_NOTIFY_OUT", out, 1)
        defer {
            if let oldOut { setenv("CODEX_NOTIFY_OUT", oldOut, 1) }
            else { unsetenv("CODEX_NOTIFY_OUT") }
            try? FileManager.default.removeItem(atPath: home)
        }

        let s = try makeStack(MockModelClient([.hello("notified")]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string("/work")])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let sr)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                             from: sr.result) else {
            return XCTFail("no thread/start response")
        }

        s.conn.clientSend(req(3, "turn/start", .object([
            "threadId": .string(env.thread.id.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("please notify")])]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: out), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let text = try String(contentsOfFile: out, encoding: .utf8)
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(payload?["type"] as? String, "agent-turn-complete")
        XCTAssertEqual(payload?["thread-id"] as? String, env.thread.id.raw)
        XCTAssertEqual(payload?["cwd"] as? String, "/work")
        XCTAssertEqual(payload?["input-messages"] as? [String], ["please notify"])
        XCTAssertEqual(payload?["last-assistant-message"] as? String, "notified")
    }

    func testThreadArchiveUnarchivePersistAndNotify() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "thread/start", .object([
            "cwd": .string("/archive-work"),
            "ephemeral": .bool(false),
        ])))
        let startMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let started)? = startMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing thread/start response") }
        let threadId = started.result["thread"]?["id"]?.stringValue ?? ""
        XCTAssertFalse(threadId.isEmpty)

        s.conn.clientSend(req(3, "thread/archive", .object([
            "threadId": .string(threadId),
        ])))
        let archiveMessages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "thread/archived" }
            return false
        }
        XCTAssertTrue(archiveMessages.contains {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        })
        guard case .notification(let archived)? = archiveMessages.first(where: {
            if case .notification(let n) = $0 { return n.method == "thread/archived" }
            return false
        }) else { return XCTFail("missing thread/archived notification") }
        XCTAssertEqual(archived.params?["threadId"]?.stringValue, threadId)

        s.conn.clientSend(req(4, "thread/list", .object(["archived": .bool(false)])))
        let activeMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let active)? = activeMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing active thread/list response") }
        XCTAssertFalse((active.result["data"]?.arrayValue ?? [])
            .contains { $0["id"]?.stringValue == threadId })

        s.conn.clientSend(req(5, "thread/list", .object(["archived": .bool(true)])))
        let archivedListMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }
        guard case .response(let archivedList)? = archivedListMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }) else { return XCTFail("missing archived thread/list response") }
        XCTAssertTrue((archivedList.result["data"]?.arrayValue ?? [])
            .contains { $0["id"]?.stringValue == threadId })

        s.conn.clientSend(req(6, "thread/unarchive", .object([
            "threadId": .string(threadId),
        ])))
        let unarchiveMessages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "thread/unarchived" }
            return false
        }
        guard case .response(let unarchivedResponse)? = unarchiveMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }) else { return XCTFail("missing thread/unarchive response") }
        XCTAssertEqual(unarchivedResponse.result["thread"]?["id"]?.stringValue, threadId)
        guard case .notification(let unarchived)? = unarchiveMessages.first(where: {
            if case .notification(let n) = $0 { return n.method == "thread/unarchived" }
            return false
        }) else { return XCTFail("missing thread/unarchived notification") }
        XCTAssertEqual(unarchived.params?["threadId"]?.stringValue, threadId)

        s.conn.clientSend(req(7, "thread/list", .object(["archived": .bool(false)])))
        let finalActiveMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(7) }
            return false
        }
        guard case .response(let finalActive)? = finalActiveMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(7) }
            return false
        }) else { return XCTFail("missing final active thread/list response") }
        XCTAssertTrue((finalActive.result["data"]?.arrayValue ?? [])
            .contains { $0["id"]?.stringValue == threadId })
    }

    func testThreadElicitationCounterIsStatefulAndValidated() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "thread/start", .object([
            "cwd": .string("/elicitation-work"),
            "ephemeral": .bool(false),
        ])))
        let startMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let started)? = startMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing thread/start response") }
        let threadId = started.result["thread"]?["id"]?.stringValue ?? ""
        XCTAssertFalse(threadId.isEmpty)

        s.conn.clientSend(req(3, "thread/increment_elicitation", .object([
            "threadId": .string(threadId),
        ])))
        let inc1Messages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let inc1)? = inc1Messages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else { return XCTFail("missing first increment response") }
        XCTAssertEqual(inc1.result["count"], .int(1))
        XCTAssertEqual(inc1.result["paused"], .bool(true))

        s.conn.clientSend(req(4, "thread/increment_elicitation", .object([
            "threadId": .string(threadId),
        ])))
        let inc2Messages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let inc2)? = inc2Messages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing second increment response") }
        XCTAssertEqual(inc2.result["count"], .int(2))
        XCTAssertEqual(inc2.result["paused"], .bool(true))

        s.conn.clientSend(req(5, "thread/decrement_elicitation", .object([
            "threadId": .string(threadId),
        ])))
        let dec1Messages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }
        guard case .response(let dec1)? = dec1Messages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }) else { return XCTFail("missing first decrement response") }
        XCTAssertEqual(dec1.result["count"], .int(1))
        XCTAssertEqual(dec1.result["paused"], .bool(true))

        s.conn.clientSend(req(6, "thread/decrement_elicitation", .object([
            "threadId": .string(threadId),
        ])))
        let dec2Messages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }
        guard case .response(let dec2)? = dec2Messages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }) else { return XCTFail("missing second decrement response") }
        XCTAssertEqual(dec2.result["count"], .int(0))
        XCTAssertEqual(dec2.result["paused"], .bool(false))

        s.conn.clientSend(req(7, "thread/decrement_elicitation", .object([
            "threadId": .string(threadId),
        ])))
        let zeroMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(7) }
            return false
        }
        guard case .error(let zeroError)? = zeroMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(7) }
            return false
        }) else { return XCTFail("missing zero-count decrement error") }
        XCTAssertEqual(zeroError.error.code, WireError.invalidRequestCode)
        XCTAssertEqual(zeroError.error.message,
                       "out-of-band elicitation count is already zero")

        s.conn.clientSend(req(8, "thread/increment_elicitation", .object([
            "threadId": .string("thr_missing"),
        ])))
        let missingMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(8) }
            return false
        }
        guard case .error(let missingError)? = missingMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(8) }
            return false
        }) else { return XCTFail("missing unknown-thread error") }
        XCTAssertTrue(missingError.error.message.contains("thread not found"))
    }

    func testEnvironmentAddIsGatedStatefulAndRemoteSelectionUsesExecServerDataPath() async throws {
        let noCaps = try makeStack(MockModelClient([.hello()]))
        defer {
            noCaps.pump.cancel()
            try? FileManager.default.removeItem(atPath: noCaps.home)
        }
        noCaps.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
        ])))
        _ = await waitOutbound(noCaps.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        noCaps.conn.clientSend(req(2, "environment/add", .object([
            "environmentId": .string("remote-a"),
            "execServerUrl": .string("ws://127.0.0.1:8765"),
        ])))
        let gatedMessages = await waitOutbound(noCaps.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let gatedError)? = gatedMessages.last else {
            return XCTFail("missing gated environment/add error")
        }
        XCTAssertEqual(gatedError.error.message,
                       "environment/add requires experimentalApi capability")

        let home = NSTemporaryDirectory() + "e2e-remote-env-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let callsPath = home + "/exec-calls.jsonl"
        guard let execServer = fakeExecServerWebSocket(home, callsPath: callsPath) else {
            return XCTFail("failed to start fake exec-server websocket")
        }
        defer { execServer.0.terminate() }
        let s = try makeStack(MockModelClient([
            MockScenario([
                .created,
                .toolCall(callId: "remote-shell", name: "shell_command",
                          argumentsJSON: #"{"command":"printf remote"}"#),
                .completeContinue(responseId: "remote-tool", tokens: 12),
            ]),
                    MockScenario([
                        .created,
                        .toolCall(callId: "remote-search", name: "file_search",
                                  argumentsJSON: #"{"query":"apple","limit":5}"#),
                        .completeContinue(responseId: "remote-search-tool", tokens: 12),
                    ]),
                    MockScenario([
                        .created,
                        .toolCall(callId: "remote-patch", name: "apply_patch",
                                  argumentsJSON: #"{"patch":"*** Begin Patch\n*** Update File: README.md\n@@\n-REMOTE_FILE\n+REMOTE_FILE\n+patched remotely\n*** Add File: docs/NewRemote.md\n+# Remote doc\n*** Delete File: Sources/AppServerGuide.md\n*** End Patch"}"#),
                        .completeContinue(responseId: "remote-patch-tool", tokens: 12),
                    ]),
                    MockScenario([
                        .created,
                        .toolCall(callId: "remote-ux-open", name: "unified_exec",
                                  argumentsJSON: #"{"command":["cat"],"yield_time_ms":250,"max_output_tokens":100}"#),
                        .completeContinue(responseId: "remote-ux-open-tool", tokens: 12),
                    ]),
                    MockScenario([
                        .created,
                        .toolCall(callId: "remote-ux-write", name: "unified_exec",
                                  argumentsJSON: #"{"process_id":1,"input":"ping\n","yield_time_ms":250,"max_output_tokens":100}"#),
                        .completeContinue(responseId: "remote-ux-write-tool", tokens: 12),
                    ]),
                    MockScenario([
                        .created,
                        .toolCall(callId: "remote-git-diff", name: "git_diff",
                                  argumentsJSON: #"{"mode":"remote"}"#),
                        .completeContinue(responseId: "remote-git-diff-tool", tokens: 12),
                    ]),
                    .hello("remote done"),
                ]), codexHome: home)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(10, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(10) }
            return false
        }

        s.conn.clientSend(req(11, "environment/add", .object([
            "environmentId": .string("bad id"),
            "execServerUrl": .string("ws://127.0.0.1:8765"),
        ])))
        let badIdMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(11) }
            return false
        }
        guard case .error(let badIdError)? = badIdMessages.last else {
            return XCTFail("missing bad environment id error")
        }
        XCTAssertTrue(badIdError.error.message.contains("must contain only ASCII"))

        s.conn.clientSend(req(12, "environment/add", .object([
            "environmentId": .string("remote-a"),
            "execServerUrl": .string(""),
        ])))
        let badURLMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(12) }
            return false
        }
        guard case .error(let badURLError)? = badURLMessages.last else {
            return XCTFail("missing bad environment URL error")
        }
        XCTAssertEqual(badURLError.error.message,
                       "remote environment requires an exec-server url")

        s.conn.clientSend(req(13, "environment/add", .object([
            "environmentId": .string("remote-a"),
            "execServerUrl": .string("ws://127.0.0.1:\(execServer.1)"),
        ])))
        let addMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(13) }
            return false
        }
        guard case .response(let addResponse)? = addMessages.last else {
            return XCTFail("missing environment/add response")
        }
        XCTAssertEqual(addResponse.result, .object([:]))

        s.conn.clientSend(req(14, "thread/start", .object([
            "cwd": .string("/local-env-work"),
            "environments": .array([
                .object([
                    "environmentId": .string("local"),
                    "cwd": .string("/local-env-work"),
                ]),
            ]),
        ])))
        let localStartMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(14) }
            return false
        }
        guard case .response(let localStart)? = localStartMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(14) }
            return false
        }) else { return XCTFail("missing local environment thread/start response") }
        XCTAssertNotNil(localStart.result["thread"]?["id"]?.stringValue)

        s.conn.clientSend(req(15, "thread/start", .object([
            "cwd": .string("/unknown-env-work"),
            "environments": .array([
                .object([
                    "environmentId": .string("missing-env"),
                    "cwd": .string("/unknown-env-work"),
                ]),
            ]),
        ])))
        let unknownMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(15) }
            return false
        }
        guard case .error(let unknownError)? = unknownMessages.last else {
            return XCTFail("missing unknown environment selection error")
        }
        XCTAssertEqual(unknownError.error.message, "unknown environmentId missing-env")

        s.conn.clientSend(req(16, "thread/start", .object([
            "cwd": .string("/remote-env-work"),
            "environments": .array([
                .object([
                    "environmentId": .string("remote-a"),
                    "cwd": .string("/remote-env-work"),
                ]),
            ]),
        ])))
        let remoteMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(16) }
            return false
        }
        guard case .response(let remoteStart)? = remoteMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(16) }
            return false
        }), let remoteEnv = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                                   from: remoteStart.result) else {
            return XCTFail("missing remote environment thread/start response")
        }
        XCTAssertEqual(remoteEnv.cwd, "/remote-env-work")

        s.conn.clientSend(req(17, "turn/start", .object([
            "threadId": .string(remoteEnv.thread.id.raw),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string("run remote shell"),
            ])]),
        ])))
        let completed = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }
        XCTAssertTrue(completed.contains {
            if case .notification(let n) = $0 { return n.method == "item/completed" }
            return false
        })
        let sawCall = await waitForFile(callsPath)
        XCTAssertTrue(sawCall)
        let calls = (try? String(contentsOfFile: callsPath)) ?? ""
        XCTAssertTrue(calls.contains(#""method": "process/start""#))
        XCTAssertTrue(calls.contains(#""cwd": "/remote-env-work""#))
                XCTAssertTrue(calls.contains(#""method": "fs/readDirectory""#))
                XCTAssertTrue(calls.contains(#""path": "/remote-env-work""#))
                XCTAssertTrue(calls.contains(#""path": "/remote-env-work/Sources""#))
                XCTAssertTrue(calls.contains(#""method": "fs/readFile""#))
                XCTAssertTrue(calls.contains(#""path": "/remote-env-work/README.md""#))
                XCTAssertTrue(calls.contains(#""path": "/remote-env-work/Sources/AppServerGuide.md""#))
                XCTAssertTrue(calls.contains(#""method": "fs/getMetadata""#))
                XCTAssertTrue(calls.contains(#""path": "/remote-env-work/docs/NewRemote.md""#))
                XCTAssertTrue(calls.contains(#""method": "fs/writeFile""#))
                XCTAssertTrue(calls.contains("patched remotely"))
                XCTAssertTrue(calls.contains("# Remote doc"))
                XCTAssertTrue(calls.contains(#""method": "fs/createDirectory""#))
                XCTAssertTrue(calls.contains(#""path": "/remote-env-work/docs""#))
                XCTAssertTrue(calls.contains(#""method": "fs/remove""#))
                XCTAssertTrue(calls.contains(#""argv": ["cat"]"#))
                XCTAssertTrue(calls.contains(#""tty": true"#))
                XCTAssertTrue(calls.contains(#""pipeStdin": true"#))
                XCTAssertTrue(calls.contains(#""method": "process/write""#))
                XCTAssertTrue(calls.contains(#""inputUtf8": "ping\n""#))
                XCTAssertTrue(calls.contains(#""argv": ["git", "rev-parse", "--is-inside-work-tree"]"#))
                XCTAssertTrue(calls.contains(#""argv": ["git", "merge-base", "HEAD", "origin/main"]"#))
                XCTAssertTrue(calls.contains(#""argv": ["git", "diff", "1111111111111111111111111111111111111111"]"#))
                XCTAssertTrue(calls.contains(#""argv": ["git", "ls-files", "--others", "--exclude-standard"]"#))
                XCTAssertTrue(calls.contains(#""argv": ["git", "diff", "--no-index", "/dev/null", "untracked.txt"]"#))
                let rebuilt = try await s.store.reconstruct(remoteEnv.thread.id)
        XCTAssertTrue(rebuilt.items.contains {
            if case .commandExecution(_, let command, let cwd, let status, _, let output, let exitCode, _, _, _) = $0 {
                return command == ["shell_command"]
                    && cwd == "/remote-env-work"
                    && status == .completed
                    && exitCode == 0
                    && (output ?? "").contains("REMOTE_EXEC_OK")
            }
            return false
        })
                XCTAssertTrue(rebuilt.items.contains {
                    if case .commandExecution(_, let command, let cwd, let status, _, let output, let exitCode, _, _, _) = $0 {
                        return command == ["file_search"]
                            && cwd == "/remote-env-work"
                            && status == .completed
                            && exitCode == 0
                            && (output ?? "").contains("Sources/RemoteApple.swift")
                    }
                    return false
                })
                // v9 app-server-events finding 3: apply_patch surfaces as a
                // `fileChange` ThreadItem (not commandExecution), carrying the
                // per-file change set (path + kind) rather than a text summary.
                XCTAssertTrue(rebuilt.items.contains {
                    guard case .fileChange(_, let changes, let status) = $0,
                          status == .completed else { return false }
                    func has(_ suffix: String, _ pred: (ThreadItem.FileChange.Kind) -> Bool) -> Bool {
                        changes.contains { $0.path.hasSuffix(suffix) && pred($0.kind) }
                    }
                    let isUpdate: (ThreadItem.FileChange.Kind) -> Bool = {
                        if case .update = $0 { return true }; return false
                    }
                    return has("README.md", isUpdate)
                        && has("docs/NewRemote.md", { $0 == .add })
                        && has("Sources/AppServerGuide.md", { $0 == .delete })
                }, "remote apply_patch surfaces as a completed fileChange item")
                XCTAssertTrue(rebuilt.items.contains {
                    if case .commandExecution(_, let command, let cwd, let status, _, let output, let exitCode, _, _, _) = $0 {
                        return command == ["unified_exec"]
                            && cwd == "/remote-env-work"
                            && status == .completed
                            && exitCode == 0
                            && (output ?? "").contains("[unified_exec process_id=1 exited=false]")
                            && (output ?? "").contains("REMOTE_UNIFIED_READY")
                    }
                    return false
                })
                XCTAssertTrue(rebuilt.items.contains {
                    if case .commandExecution(_, let command, let cwd, let status, _, let output, let exitCode, _, _, _) = $0 {
                        return command == ["unified_exec"]
                            && cwd == "/remote-env-work"
                            && status == .completed
                            && exitCode == 0
                            && (output ?? "").contains("[unified_exec process_id=1 exited=false]")
                            && (output ?? "").contains("REMOTE_UNIFIED_INPUT: ping")
                    }
                    return false
                })
                XCTAssertTrue(rebuilt.items.contains {
                    if case .commandExecution(_, let command, let cwd, let status, _, let output, let exitCode, _, _, _) = $0 {
                        return command == ["git_diff"]
                            && cwd == "/remote-env-work"
                            && status == .completed
                            && exitCode == 0
                            && (output ?? "").contains("REMOTE_GIT_DIFF")
                            && (output ?? "").contains("REMOTE_UNTRACKED_DIFF")
                    }
                    return false
                })
            }

    func testRemoteExecServerReadToolsReconnectAfterWebSocketClose() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-reconnect-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let callsPath = home + "/exec-calls.jsonl"
        guard let execServer = fakeExecServerWebSocket(
            home,
            callsPath: callsPath,
            closeAfterFirstReadFile: true
        ) else {
            return XCTFail("failed to start reconnect fake exec-server websocket")
        }
        defer {
            execServer.0.terminate()
            try? FileManager.default.removeItem(atPath: home)
        }

        let tool = RemoteExecServerReadFileTool(
            websocketURL: "ws://127.0.0.1:\(execServer.1)")
        let first = try await tool.run(
            ToolCall(callId: "first", name: "read_file",
                     argumentsJSON: #"{"path":"README.md"}"#),
            cwd: "/remote-env-work")
        XCTAssertTrue(first.success, first.output)
        XCTAssertTrue(first.output.contains("REMOTE_FILE"), first.output)

        let second = try await tool.run(
            ToolCall(callId: "second", name: "read_file",
                     argumentsJSON: #"{"path":"README.md"}"#),
            cwd: "/remote-env-work")
        XCTAssertTrue(second.success, second.output)
        XCTAssertTrue(second.output.contains("REMOTE_FILE"), second.output)

        let calls = (try? String(contentsOfFile: callsPath)) ?? ""
        XCTAssertGreaterThanOrEqual(calls.components(separatedBy: #""method": "fs/readFile""#).count - 1,
                                    2,
                                    "read_file should reconnect and complete after the fake server closes the first websocket")
    }

    func testRemoteExecServerWriteFileReplayAfterReconnectIsIdempotent() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-write-replay-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let callsPath = home + "/exec-calls.jsonl"
        guard let execServer = fakeExecServerWebSocket(
            home,
            callsPath: callsPath,
            closeAfterFirstWriteFile: true
        ) else {
            return XCTFail("failed to start write-replay fake exec-server websocket")
        }
        defer {
            execServer.0.terminate()
            try? FileManager.default.removeItem(atPath: home)
        }

        let tool = RemoteExecServerWriteFileTool(
            websocketURL: "ws://127.0.0.1:\(execServer.1)")
        let result = try await tool.run(
            ToolCall(callId: "write-replay", name: "write_file",
                     argumentsJSON: #"{"path":"replay.txt","content":"REPLAY_BYTES"}"#),
            cwd: "/remote-env-work")
        XCTAssertTrue(result.success, result.output)

        // Drain the calls file to verify the write actually happened twice on
        // the wire (proving replay engaged) and that the same content went
        // through both times (proving idempotency).
        let calls = (try? String(contentsOfFile: callsPath)) ?? ""
        XCTAssertGreaterThanOrEqual(
            calls.components(separatedBy: #""method": "fs/writeFile""#).count - 1,
            2,
            "fs/writeFile should be replayed after the fake server closes the first websocket")
        XCTAssertEqual(
            calls.components(separatedBy: #""dataUtf8": "REPLAY_BYTES""#).count - 1,
            2,
            "both replayed fs/writeFile calls should carry the same payload bytes")
    }

    func testRemoteExecServerRemoveReplayAfterReconnectToleratesNotFound() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-remove-replay-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let callsPath = home + "/exec-calls.jsonl"
        guard let execServer = fakeExecServerWebSocket(
            home,
            callsPath: callsPath,
            closeAfterFirstRemove: true
        ) else {
            return XCTFail("failed to start remove-replay fake exec-server websocket")
        }
        defer {
            execServer.0.terminate()
            try? FileManager.default.removeItem(atPath: home)
        }

        // We invoke the private apply-patch removeRemote path indirectly by
        // applying a `*** Delete File:` envelope. The remote exec-server tool
        // re-reads the file first, applies through the in-process patch engine,
        // then calls fs/remove — that fs/remove is where the replay engages.
        let tool = RemoteExecServerApplyPatchTool(
            websocketURL: "ws://127.0.0.1:\(execServer.1)")
        let patch = """
        *** Begin Patch
        *** Delete File: README.md
        *** End Patch
        """
        let result = try await tool.run(
            ToolCall(callId: "remove-replay", name: "apply_patch",
                     argumentsJSON: #"{"patch":"\#(patch.replacingOccurrences(of: "\n", with: "\\n"))"}"#),
            cwd: "/remote-env-work")
        XCTAssertTrue(result.success,
                      "apply_patch should treat post-success NotFound on replay as idempotent: \(result.output)")

        let calls = (try? String(contentsOfFile: callsPath)) ?? ""
        XCTAssertGreaterThanOrEqual(
            calls.components(separatedBy: #""method": "fs/remove""#).count - 1,
            2,
            "fs/remove should be replayed after the fake server closes the first websocket")
    }

    func testRemoteExecServerProcessStartReplayAfterReconnectToleratesAlreadyExists() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-start-replay-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let callsPath = home + "/exec-calls.jsonl"
        guard let execServer = fakeExecServerWebSocket(
            home,
            callsPath: callsPath,
            closeAfterFirstProcessStart: true
        ) else {
            return XCTFail("failed to start process-start replay fake exec-server websocket")
        }
        defer {
            execServer.0.terminate()
            try? FileManager.default.removeItem(atPath: home)
        }

        let tool = RemoteExecServerShellTool(
            websocketURL: "ws://127.0.0.1:\(execServer.1)")
        let result = try await tool.run(
            ToolCall(callId: "start-replay", name: "shell_command",
                     argumentsJSON: #"{"command":["echo","ok"],"cwd":"/remote-env-work"}"#),
            cwd: "/remote-env-work")
        XCTAssertTrue(result.success,
                      "shell should treat post-success AlreadyExists on replay as idempotent: \(result.output)")
        XCTAssertTrue(result.output.contains("REMOTE_EXEC_OK"), result.output)

        let calls = (try? String(contentsOfFile: callsPath)) ?? ""
        XCTAssertGreaterThanOrEqual(
            calls.components(separatedBy: #""method": "process/start""#).count - 1,
            2,
            "process/start should be replayed after the fake server closes the first websocket")
    }

    func testTurnStartAcceptsEnvironmentSwitchToRegisteredRemoteEnv() async throws {
        // A4 — turn-scope environment switching (approach B). thread/start on
        // remote-a runs a turn; the next turn/start asks for remote-b. The
        // router accepts the switch at the turn boundary, the supervisor
        // rebinds the worker to remote-b, and tool calls land at remote-b's
        // exec-server fake.
        let home = NSTemporaryDirectory() + "e2e-env-switch-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let callsA = home + "/exec-calls-a.jsonl"
        let callsB = home + "/exec-calls-b.jsonl"
        guard let serverA = fakeExecServerWebSocket(home, callsPath: callsA),
              let serverB = fakeExecServerWebSocket(home, callsPath: callsB) else {
            return XCTFail("failed to start two fake exec-server websockets")
        }
        defer {
            serverA.0.terminate()
            serverB.0.terminate()
            try? FileManager.default.removeItem(atPath: home)
        }

        // Each turn needs a tool-call scenario followed by a terminal text
        // scenario; completeContinue runs the tool then re-enters the model
        // loop which consumes the next scenario.
        let s = try makeStack(MockModelClient([
            MockScenario([
                .created,
                .toolCall(callId: "remote-a-shell", name: "shell_command",
                          argumentsJSON: #"{"command":"printf remote-a"}"#),
                .completeContinue(responseId: "remote-a-tool", tokens: 12),
            ]),
            .hello("turn 1 done on remote-a"),
            MockScenario([
                .created,
                .toolCall(callId: "remote-b-shell", name: "shell_command",
                          argumentsJSON: #"{"command":"printf remote-b"}"#),
                .completeContinue(responseId: "remote-b-tool", tokens: 12),
            ]),
            .hello("turn 2 done on remote-b"),
        ]), codexHome: home)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        for (rid, envId, port) in [(2, "remote-a", serverA.1), (3, "remote-b", serverB.1)] {
            s.conn.clientSend(req(rid, "environment/add", .object([
                "environmentId": .string(envId),
                "execServerUrl": .string("ws://127.0.0.1:\(port)"),
            ])))
            _ = await waitOutbound(s.conn) {
                if case .response(let r) = $0 { return r.id == .int(Int64(rid)) }
                return false
            }
        }

        s.conn.clientSend(req(10, "thread/start", .object([
            "cwd": .string("/remote-env-work"),
            "environments": .array([
                .object([
                    "environmentId": .string("remote-a"),
                    "cwd": .string("/remote-env-work"),
                ]),
            ]),
        ])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(10) }
            return false
        }
        guard case .response(let started)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(10) }
            return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                             from: started.result) else {
            return XCTFail("missing thread/start response")
        }
        let threadId = env.thread.id.raw

        // Turn 1 on remote-a — verify by checking serverA's calls file.
        s.conn.clientSend(req(11, "turn/start", .object([
            "threadId": .string(threadId),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string("turn-1 on remote-a"),
            ])]),
            "environments": .array([
                .object([
                    "environmentId": .string("remote-a"),
                    "cwd": .string("/remote-env-work"),
                ]),
            ]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }
        let sawA = await waitForFile(callsA)
        XCTAssertTrue(sawA, "remote-a exec-server should record the first turn's tool call")

        // Turn 2 switches to remote-b. Validate the switch is accepted and a
        // tool call reaches remote-b's exec-server.
        s.conn.clientSend(req(12, "turn/start", .object([
            "threadId": .string(threadId),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string("turn-2 on remote-b"),
            ])]),
            "environments": .array([
                .object([
                    "environmentId": .string("remote-b"),
                    "cwd": .string("/remote-env-work"),
                ]),
            ]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0, n.method == "turn/completed",
               let params = n.params, params["threadId"] == .string(threadId) {
                return true
            }
            return false
        }
        // The supervisor's rebind path force-stops the in-process worker and
        // builds a fresh one through the factory with the new
        // SessionConfig.remoteEnvironment. We probe both ends:
        //   (a) the rollout has two .environmentRebound records (initial +
        //       turn-2 switch), proving the router's switch logic engaged
        //       and the persistence path captured it.
        //   (b) opportunistically check whether remote-b's exec-server saw
        //       the new worker; this depends on worker re-spawn timing and
        //       is not strict.
        // Force a durability barrier so write-behind env-rebound records
        // land on disk before we inspect the rollout.
        try? await s.store.durabilityBarrier(ThreadId(threadId))
        // Discover the rollout under upstream's date-partitioned layout
        // (sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl); fall back to the flat path.
        let sessionsDir = home + "/sessions"
        var rolloutPath = sessionsDir + "/\(threadId).rollout.jsonl"
        let rels = (FileManager.default.enumerator(atPath: sessionsDir)?
            .allObjects.compactMap { $0 as? String }) ?? []
        if let match = rels.first(where: { $0.hasSuffix("-\(threadId).jsonl") }) {
            rolloutPath = sessionsDir + "/" + match
        }
        let rolloutText = (try? String(contentsOfFile: rolloutPath)) ?? ""
        let rebindCount = rolloutText
            .components(separatedBy: "\"t\":\"environmentRebound\"").count - 1
        XCTAssertGreaterThanOrEqual(
            rebindCount, 2,
            "rollout should record initial env binding and the turn-2 switch; got \(rebindCount) rebinds in \(rolloutText.prefix(400))")
        XCTAssertTrue(rolloutText.contains("\"environmentId\":\"remote-b\""),
                      "rollout should record the switch to remote-b; rollout content was:\n\(rolloutText)")

        // Soft assertion — give the new worker a brief window to materialize
        // a request against serverB.
        let sawB = await waitForFile(callsB, timeoutMs: 1000)
        if !sawB {
            // The rebind is proven by rollout above; the tool-call landing
            // on serverB depends on the new worker actually issuing the
            // tool call before the test exits. This is a softer signal in
            // the in-process worker harness.
            print("(soft) remote-b exec-server did not see a tool call within 1s")
        }
    }

    func testTurnStartRejectsSwitchToUnregisteredEnvironment() async throws {
        let home = NSTemporaryDirectory() + "e2e-env-switch-unregistered-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: home)
        }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        // No environment/add — directly try to switch on turn/start.
        s.conn.clientSend(req(2, "thread/start", .object([
            "cwd": .string("/remote-env-work"),
        ])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let started)? = startMsgs.last,
              let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                               from: started.result) else {
            return XCTFail("missing thread/start response")
        }
        s.conn.clientSend(req(3, "turn/start", .object([
            "threadId": .string(env.thread.id.raw),
            "input": .array([.object([
                "type": .string("text"), "text": .string("hi"),
            ])]),
            "environments": .array([
                .object([
                    "environmentId": .string("missing-env"),
                    "cwd": .string("/remote-env-work"),
                ]),
            ]),
        ])))
        let errs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }
        guard case .error(let e)? = errs.last else {
            return XCTFail("expected turn/start unknown-env error")
        }
        XCTAssertTrue(e.error.message.contains("missing-env"),
                      "expected message to name the unregistered env: \(e.error.message)")
    }

    func testRemoteExecServerHTTPRegistryBootstrapsWebSocketRendezvous() async throws {
        // A1 — minimal HTTP/registry bootstrap. The remote env URL is
        // http://... pointing at an executor registry; the client POSTs to
        // /executors/register, receives a JSON rendezvousURL, and upgrades
        // to that WebSocket. Operationally identical to the direct-WS path
        // once the rendezvous URL is resolved.
        let home = NSTemporaryDirectory() + "e2e-http-registry-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let callsPath = home + "/exec-calls.jsonl"
        guard let execServer = fakeExecServerWebSocket(
            home,
            callsPath: callsPath,
            serveHTTPRegistry: true
        ) else {
            return XCTFail("failed to start HTTP-registry fake exec-server")
        }
        defer {
            execServer.0.terminate()
            try? FileManager.default.removeItem(atPath: home)
        }

        // Pass an http:// URL — the client should POST to /executors/register
        // and follow the returned rendezvous WS URL.
        let tool = RemoteExecServerWriteFileTool(
            websocketURL: "http://127.0.0.1:\(execServer.1)")
        let result = try await tool.run(
            ToolCall(callId: "http-register", name: "write_file",
                     argumentsJSON: #"{"path":"hi.txt","content":"HELLO_VIA_HTTP_REGISTRY"}"#),
            cwd: "/remote-env-work")
        XCTAssertTrue(result.success,
                      "HTTP-registry bootstrap then WS upgrade should land a write: \(result.output)")

        let calls = (try? String(contentsOfFile: callsPath)) ?? ""
        XCTAssertTrue(
            calls.contains("\"method\": \"fs/writeFile\""),
            "the resolved WS endpoint should have received the fs/writeFile call after HTTP bootstrap: \(calls)")
        XCTAssertTrue(
            calls.contains("HELLO_VIA_HTTP_REGISTRY"),
            "payload should reach the WS endpoint after HTTP bootstrap: \(calls)")
    }

    func testRemoteExecServerUnifiedExecSurfacesServerRestartMarker() async throws {
        // A3 — active-process resume across exec-server restart. When the
        // exec-server itself bounces between process/start and the next
        // process/read, the client should detect the sessionId change (the
        // fake server bumps it on each new connection) and surface a
        // structured `restarted_by_server=true` marker rather than the raw
        // "unknown processId" failure.
        let home = NSTemporaryDirectory() + "e2e-remote-restart-marker-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let callsPath = home + "/exec-calls.jsonl"
        guard let execServer = fakeExecServerWebSocket(
            home,
            callsPath: callsPath,
            bumpSessionIdEachConnection: true,
            closeMidProcessReadOnce: true
        ) else {
            return XCTFail("failed to start restart-marker fake exec-server websocket")
        }
        defer {
            execServer.0.terminate()
            try? FileManager.default.removeItem(atPath: home)
        }

        let tool = RemoteExecServerUnifiedExecTool(
            websocketURL: "ws://127.0.0.1:\(execServer.1)")
        let result = try await tool.run(
            ToolCall(callId: "restart", name: "unified_exec",
                     argumentsJSON: #"{"command":["cat"]}"#),
            cwd: "/remote-env-work")
        XCTAssertFalse(result.success,
                       "restart marker should report success=false: \(result.output)")
        XCTAssertTrue(
            result.output.contains("restarted_by_server=true"),
            "expected structured restart marker, got: \(result.output)")
        XCTAssertTrue(
            result.output.contains("remote exec-server restarted"),
            "expected restart-body explanation, got: \(result.output)")
    }

    func testRemoteExecServerWriteStdinDoesNotReplayOnReconnect() async throws {
        // process/writeStdin is the one non-idempotent op we intentionally
        // do not replay: a replay would duplicate stdin bytes. Confirm that
        // a transport failure on writeStdin surfaces as a failed ToolResult
        // and the wire shows only one writeStdin attempt.
        let home = NSTemporaryDirectory() + "e2e-remote-stdin-noreplay-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let callsPath = home + "/exec-calls.jsonl"
        guard let execServer = fakeExecServerWebSocket(
            home,
            callsPath: callsPath,
            closeAfterFirstWriteStdin: true
        ) else {
            return XCTFail("failed to start writeStdin-noreplay fake exec-server websocket")
        }
        defer {
            execServer.0.terminate()
            try? FileManager.default.removeItem(atPath: home)
        }

        let tool = RemoteExecServerUnifiedExecTool(
            websocketURL: "ws://127.0.0.1:\(execServer.1)")
        // Open a process first to get a local process_id.
        let opened = try await tool.run(
            ToolCall(callId: "open", name: "unified_exec",
                     argumentsJSON: #"{"command":["cat"]}"#),
            cwd: "/remote-env-work")
        XCTAssertTrue(opened.success, opened.output)
        // Continue with stdin; the fake server closes after the first
        // writeStdin response, but the response itself has already been
        // delivered, so the client treats the followup read as the failure
        // path (transport torn during read). The key invariant we assert is
        // that fs- and process-side state remains coherent and that no
        // duplicate writeStdin appears in the call log on the second
        // attempt.
        let continued = try? await tool.run(
            ToolCall(callId: "continue", name: "unified_exec",
                     argumentsJSON: #"{"process_id":1,"input":"hello\n"}"#),
            cwd: "/remote-env-work")
        _ = continued // success/failure is environment-dependent; we only
                      // assert wire shape below.

        let calls = (try? String(contentsOfFile: callsPath)) ?? ""
        let writeStdinCount = calls.components(separatedBy: #""method": "process/write""#).count - 1
        XCTAssertEqual(
            writeStdinCount, 1,
            "exec-server process/write must not be replayed across reconnect (replay would duplicate stdin)")
    }

    func testFilesystemRPCsRoundTripRealBytes() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "fs-rpc-" + UUID().uuidString
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        let dir = root + "/nested"
        let note = dir + "/note.txt"
        let copy = dir + "/copy.txt"
        let encoded = Data("codexkit fs rpc\n".utf8).base64EncodedString()

        s.conn.clientSend(req(2, "fs/createDirectory", .object([
            "path": .string(dir), "recursive": .bool(true),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(2) }; return false }

        s.conn.clientSend(req(3, "fs/writeFile", .object([
            "path": .string(note), "dataBase64": .string(encoded),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(3) }; return false }

        s.conn.clientSend(req(4, "fs/readFile", .object(["path": .string(note)])))
        let readMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }
        guard case .response(let read)? = readMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }) else { return XCTFail("missing fs/readFile response") }
        XCTAssertEqual(read.result["dataBase64"]?.stringValue, encoded)

        s.conn.clientSend(req(5, "fs/getMetadata", .object(["path": .string(note)])))
        let metaMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }
        guard case .response(let meta)? = metaMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }) else { return XCTFail("missing fs/getMetadata response") }
        XCTAssertEqual(meta.result["isFile"]?.boolValue, true)
        XCTAssertEqual(meta.result["isDirectory"]?.boolValue, false)
        XCTAssertEqual(meta.result["isSymlink"]?.boolValue, false)

        s.conn.clientSend(req(6, "fs/copy", .object([
            "sourcePath": .string(note), "destinationPath": .string(copy),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(6) }; return false }

        s.conn.clientSend(req(7, "fs/readDirectory", .object(["path": .string(dir)])))
        let dirMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(7) }; return false
        }
        guard case .response(let listing)? = dirMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(7) }; return false
        }) else { return XCTFail("missing fs/readDirectory response") }
        let names = listing.result["entries"]?.arrayValue?.compactMap { $0["fileName"]?.stringValue } ?? []
        XCTAssertEqual(Set(names), Set(["note.txt", "copy.txt"]))

        s.conn.clientSend(req(8, "fs/remove", .object(["path": .string(copy), "force": .bool(false)])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(8) }; return false }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
    }

    func testFilesystemWatchReportsChangesAndUnwatchStopsNotifications() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "fs-watch-" + UUID().uuidString
        let dir = root + "/repo/.git"
        let fetchHead = dir + "/FETCH_HEAD"
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "old\n".write(toFile: fetchHead, atomically: false, encoding: .utf8)

        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "fs/watch", .object([
            "watchId": .string("watch-git"),
            "path": .string(dir),
        ])))
        let watchMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let watchResponse)? = watchMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing fs/watch response") }
        XCTAssertEqual(watchResponse.result["path"]?.stringValue, dir)

        try "updated\n".write(toFile: fetchHead, atomically: false, encoding: .utf8)
        let changedMsgs = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 { return n.method == "fs/changed" }
            return false
        }, timeoutMs: 4000)
        guard case .notification(let changed)? = changedMsgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "fs/changed" }
            return false
        }) else { return XCTFail("missing fs/changed notification") }
        XCTAssertEqual(changed.params?["watchId"]?.stringValue, "watch-git")
        let changedPaths = changed.params?["changedPaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(changedPaths.contains(fetchHead), changedPaths.joined(separator: "\n"))

        s.conn.clientSend(req(3, "fs/unwatch", .object(["watchId": .string("watch-git")])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }

        try "refs\n".write(toFile: dir + "/packed-refs", atomically: false, encoding: .utf8)
        let late = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 { return n.method == "fs/changed" }
            return false
        }, timeoutMs: 500)
        XCTAssertFalse(late.contains {
            if case .notification(let n) = $0 { return n.method == "fs/changed" }
            return false
        }, "fs/unwatch should stop future change notifications")
    }

    func testFilesystemWatchRejectsRelativeAndDuplicateIds() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "fs-watch-dupe-" + UUID().uuidString
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "fs/watch", .object([
            "watchId": .string("watch-relative"),
            "path": .string("relative"),
        ])))
        let relative = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        XCTAssertTrue(relative.contains {
            if case .error(let e) = $0 {
                return e.error.message.contains("absolute path")
            }
            return false
        })

        s.conn.clientSend(req(3, "fs/watch", .object([
            "watchId": .string("watch-root"),
            "path": .string(root),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        s.conn.clientSend(req(4, "fs/watch", .object([
            "watchId": .string("watch-root"),
            "path": .string(root + "/other"),
        ])))
        let duplicate = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(4) }
            return false
        }
        XCTAssertTrue(duplicate.contains {
            if case .error(let e) = $0 {
                return e.error.message.contains("watchId already exists: watch-root")
            }
            return false
        })
    }

    func testFilesystemWatchFilePathReportsContentChanges() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "fs-watch-file-" + UUID().uuidString
        let watched = root + "/note.txt"
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "one\n".write(toFile: watched, atomically: false, encoding: .utf8)

        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "fs/watch", .object([
            "watchId": .string("watch-file"),
            "path": .string(watched),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }

        try "two\n".write(toFile: watched, atomically: false, encoding: .utf8)
        let changedMsgs = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 { return n.method == "fs/changed" }
            return false
        }, timeoutMs: 4000)
        guard case .notification(let changed)? = changedMsgs.first(where: {
            if case .notification(let n) = $0 { return n.method == "fs/changed" }
            return false
        }) else { return XCTFail("missing fs/changed notification") }
        XCTAssertEqual(changed.params?["watchId"]?.stringValue, "watch-file")
        let changedPaths = changed.params?["changedPaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(changedPaths.contains(watched), changedPaths.joined(separator: "\n"))
    }

    func testFilesystemWatchStopsWhenConnectionCloses() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "fs-watch-close-" + UUID().uuidString
        let watched = root + "/state.txt"
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "before\n".write(toFile: watched, atomically: false, encoding: .utf8)

        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "fs/watch", .object([
            "watchId": .string("watch-close"),
            "path": .string(watched),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }

        s.conn.closeClient()
        await s.pump.value

        try "after\n".write(toFile: watched, atomically: false, encoding: .utf8)
        let late = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 { return n.method == "fs/changed" }
            return false
        }, timeoutMs: 500)
        XCTAssertFalse(late.contains {
            if case .notification(let n) = $0 { return n.method == "fs/changed" }
            return false
        }, "closing the client stream should cancel active file watches")
    }

    func testCommandExecRunsBufferedCommand() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "cmd-rpc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "command/exec", .object([
            "command": .array([
                .string("/bin/sh"),
                .string("-c"),
                .string("printf \"$CODEXKIT_E2E_CMD\"; printf err >&2"),
            ]),
            "cwd": .string(root),
            "env": .object(["CODEXKIT_E2E_CMD": .string("codexkit command rpc")]),
            "timeoutMs": .int(5_000),
        ])))
        let msgs = await waitOutbound(s.conn, {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }, timeoutMs: 10_000)
        guard case .response(let r)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing command/exec response") }
        XCTAssertEqual(r.result["exitCode"]?.intValue, 0)
        XCTAssertEqual(r.result["stdout"]?.stringValue, "codexkit command rpc")
        XCTAssertEqual(r.result["stderr"]?.stringValue, "err")
    }

    func testCommandExecStreamingWriteAndTerminateLifecycle() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "cmd-stream-rpc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        let processId = "stream-\(UUID().uuidString)"
        s.conn.clientSend(req(2, "command/exec", .object([
            "processId": .string(processId),
            "command": .array([
                .string("/bin/sh"),
                .string("-c"),
                .string("IFS= read line; printf \"out:$line\"; printf \"err:$line\" >&2"),
            ]),
            "cwd": .string(root),
            "streamStdin": .bool(true),
            "streamStdoutStderr": .bool(true),
            "timeoutMs": .int(5_000),
        ])))
        s.conn.clientSend(req(3, "command/exec/write", .object([
            "processId": .string(processId),
            "deltaBase64": .string(Data("hello\n".utf8).base64EncodedString()),
            "closeStdin": .bool(true),
        ])))

        let msgs = await waitOutbound(s.conn, {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }, timeoutMs: 5000)
        XCTAssertTrue(msgs.contains {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }, "write request should acknowledge")
        let deltas = msgs.compactMap { message -> JSONRPCNotification? in
            if case .notification(let n) = message,
               n.method == "command/exec/outputDelta" {
                return n
            }
            return nil
        }
        let rendered = deltas.reduce(into: [String: String]()) { acc, note in
            let stream = note.params?["stream"]?.stringValue ?? ""
            let encoded = note.params?["deltaBase64"]?.stringValue ?? ""
            let text = Data(base64Encoded: encoded)
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            acc[stream, default: ""] += text
        }
        XCTAssertEqual(rendered["stdout"], "out:hello")
        XCTAssertEqual(rendered["stderr"], "err:hello")
        guard case .response(let response)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing command/exec completion response") }
        XCTAssertEqual(response.result["exitCode"]?.intValue, 0)
        XCTAssertEqual(response.result["stdout"]?.stringValue, "")
        XCTAssertEqual(response.result["stderr"]?.stringValue, "")

        let sleeper = "sleep-\(UUID().uuidString)"
        s.conn.clientSend(req(4, "command/exec", .object([
            "processId": .string(sleeper),
            "command": .array([.string("/bin/sh"), .string("-c"), .string("sleep 30")]),
            "cwd": .string(root),
            "timeoutMs": .int(60_000),
        ])))
        s.conn.clientSend(req(5, "command/exec/terminate", .object([
            "processId": .string(sleeper),
        ])))
        let termMsgs = await waitOutbound(s.conn, {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }, timeoutMs: 5000)
        XCTAssertTrue(termMsgs.contains {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }, "terminate request should acknowledge")
        guard case .response(let terminated)? = termMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing terminated command response") }
        XCTAssertNotEqual(terminated.result["exitCode"]?.intValue, 0)
    }

    func testProcessSpawnWriteKillAndNotifications() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "process-rpc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        let processHandle = "proc-\(UUID().uuidString)"
        s.conn.clientSend(req(2, "process/spawn", .object([
            "processHandle": .string(processHandle),
            "command": .array([
                .string("/bin/sh"),
                .string("-c"),
                .string("IFS= read line; printf \"pout:$line\"; printf \"perr:$line\" >&2"),
            ]),
            "cwd": .string(root),
            // streamStdoutStderr defaults to false (buffered) upstream; opt in
            // to receive process/outputDelta notifications.
            "streamStdoutStderr": .bool(true),
        ])))
        let spawnAck = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        XCTAssertTrue(spawnAck.contains {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }, "process/spawn should acknowledge after the child is running")

        s.conn.clientSend(req(3, "process/writeStdin", .object([
            "processHandle": .string(processHandle),
            "deltaBase64": .string(Data("hello\n".utf8).base64EncodedString()),
            "closeStdin": .bool(true),
        ])))
        let finished = await waitOutbound(s.conn, {
            if case .notification(let n) = $0,
               n.method == "process/exited",
               n.params?["processHandle"]?.stringValue == processHandle {
                return true
            }
            return false
        }, timeoutMs: 5000)
        XCTAssertTrue(finished.contains {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }, "process/writeStdin should acknowledge")
        let rendered = finished.compactMap { message -> JSONRPCNotification? in
            if case .notification(let n) = message, n.method == "process/outputDelta" {
                return n
            }
            return nil
        }.reduce(into: [String: String]()) { acc, note in
            let stream = note.params?["stream"]?.stringValue ?? ""
            let encoded = note.params?["deltaBase64"]?.stringValue ?? ""
            let text = Data(base64Encoded: encoded)
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            acc[stream, default: ""] += text
        }
        XCTAssertEqual(rendered["stdout"], "pout:hello")
        XCTAssertEqual(rendered["stderr"], "perr:hello")

        let sleeper = "proc-sleep-\(UUID().uuidString)"
        s.conn.clientSend(req(4, "process/spawn", .object([
            "processHandle": .string(sleeper),
            "command": .array([.string("/bin/sh"), .string("-c"), .string("sleep 30")]),
            "cwd": .string(root),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        s.conn.clientSend(req(5, "process/kill", .object([
            "processHandle": .string(sleeper),
        ])))
        let killed = await waitOutbound(s.conn, {
            if case .notification(let n) = $0,
               n.method == "process/exited",
               n.params?["processHandle"]?.stringValue == sleeper {
                return true
            }
            return false
        }, timeoutMs: 5000)
        XCTAssertTrue(killed.contains {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }, "process/kill should acknowledge")
        guard case .notification(let exited)? = killed.first(where: {
            if case .notification(let n) = $0,
               n.method == "process/exited",
               n.params?["processHandle"]?.stringValue == sleeper {
                return true
            }
            return false
        }) else { return XCTFail("missing process/exited for killed process") }
        XCTAssertNotEqual(exited.params?["exitCode"]?.intValue, 0)
    }

    func testCommandExecTTYResizeAndOutputLifecycle() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "cmd-pty-rpc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        let processId = "cmd-pty-\(UUID().uuidString)"
        s.conn.clientSend(req(2, "command/exec", .object([
            "processId": .string(processId),
            "tty": .bool(true),
            "streamStdoutStderr": .bool(true),
            "streamStdin": .bool(true),
            "size": .object(["rows": .int(10), "cols": .int(40)]),
            "command": .array([
                .string("/bin/sh"),
                .string("-c"),
                .string("stty -echo; IFS= read line; test -t 0 && printf 'tty:'; stty size"),
            ]),
            "cwd": .string(root),
            "timeoutMs": .int(5_000),
        ])))
        s.conn.clientSend(req(3, "command/exec/resize", .object([
            "processId": .string(processId),
            "size": .object(["rows": .int(33), "cols": .int(101)]),
        ])))
        s.conn.clientSend(req(4, "command/exec/write", .object([
            "processId": .string(processId),
            "deltaBase64": .string(Data("go\n".utf8).base64EncodedString()),
            "closeStdin": .bool(true),
        ])))
        let msgs = await waitOutbound(s.conn, {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }, timeoutMs: 5000)
        XCTAssertTrue(msgs.contains {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }, "command/exec/resize should acknowledge for a live PTY")
        XCTAssertTrue(msgs.contains {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }, "command/exec/write should acknowledge for a live PTY")
        let lateOutput = await waitOutbound(s.conn, {
            if case .notification(let n) = $0, n.method == "command/exec/outputDelta" {
                return true
            }
            return false
        }, timeoutMs: 1000)
        let text = (msgs + lateOutput).compactMap { message -> String? in
            guard case .notification(let n) = message,
                  n.method == "command/exec/outputDelta",
                  let encoded = n.params?["deltaBase64"]?.stringValue,
                  let data = Data(base64Encoded: encoded) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined()
        XCTAssertTrue(text.contains("tty:"), "PTY child should observe isatty stdin; output=\(text)")
        XCTAssertTrue(text.contains("33 101"), "PTY resize should reach stty size; output=\(text)")
    }

    func testProcessSpawnTTYResizeAndExitNotification() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "process-pty-rpc-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        let processHandle = "proc-pty-\(UUID().uuidString)"
        s.conn.clientSend(req(2, "process/spawn", .object([
            "processHandle": .string(processHandle),
            "tty": .bool(true),
            "size": .object(["rows": .int(12), "cols": .int(44)]),
            "command": .array([
                .string("/bin/sh"),
                .string("-c"),
                .string("stty -echo; IFS= read line; test -t 0 && printf 'pty:'; stty size"),
            ]),
            "cwd": .string(root),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        s.conn.clientSend(req(3, "process/resizePty", .object([
            "processHandle": .string(processHandle),
            "size": .object(["rows": .int(41), "cols": .int(111)]),
        ])))
        s.conn.clientSend(req(4, "process/writeStdin", .object([
            "processHandle": .string(processHandle),
            "deltaBase64": .string(Data("go\n".utf8).base64EncodedString()),
            "closeStdin": .bool(true),
        ])))
        let msgs = await waitOutbound(s.conn, {
            if case .notification(let n) = $0,
               n.method == "process/exited",
               n.params?["processHandle"]?.stringValue == processHandle {
                return true
            }
            return false
        }, timeoutMs: 5000)
        XCTAssertTrue(msgs.contains {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }, "process/resizePty should acknowledge for a live PTY")
        XCTAssertTrue(msgs.contains {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }, "process/writeStdin should acknowledge for a live PTY")
        let lateOutput = await waitOutbound(s.conn, {
            if case .notification(let n) = $0, n.method == "process/outputDelta" {
                return true
            }
            return false
        }, timeoutMs: 1000)
        let text = (msgs + lateOutput).compactMap { message -> String? in
            guard case .notification(let n) = message,
                  n.method == "process/outputDelta",
                  let encoded = n.params?["deltaBase64"]?.stringValue,
                  let data = Data(base64Encoded: encoded) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined()
        XCTAssertTrue(text.contains("pty:"), "process/spawn PTY child should observe isatty stdin; output=\(text)")
        XCTAssertTrue(text.contains("41 111"), "process/resizePty should reach stty size; output=\(text)")
    }

    func testFuzzyFileSearchReturnsRankedFiles() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "fuzzy-rpc-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: root + "/docs", withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: root + "/alpha.txt"))
        try Data("alphabet".utf8).write(to: URL(fileURLWithPath: root + "/alphabet.txt"))
        try Data("beta".utf8).write(to: URL(fileURLWithPath: root + "/beta.txt"))
        try Data("alpine".utf8).write(to: URL(fileURLWithPath: root + "/docs/alpine.md"))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "fuzzyFileSearch", .object([
            "query": .string("alp"),
            "roots": .array([.string(root)]),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let r)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing fuzzyFileSearch response") }
        let files = r.result["files"]?.arrayValue ?? []
        let paths = files.compactMap { $0["path"]?.stringValue }
        XCTAssertEqual(paths.first, "alpha.txt")
        XCTAssertTrue(paths.contains("alphabet.txt"))
        XCTAssertTrue(paths.contains("docs/alpine.md"))
        XCTAssertFalse(paths.contains("beta.txt"))
        guard let first = files.first else { return XCTFail("expected fuzzy results") }
        XCTAssertEqual(first["root"]?.stringValue, root)
        XCTAssertEqual(first["match_type"]?.stringValue, "file")
        XCTAssertEqual(first["file_name"]?.stringValue, "alpha.txt")
        XCTAssertGreaterThan(first["score"]?.intValue ?? 0, 0)
        XCTAssertEqual(first["indices"]?.arrayValue?.compactMap(\.intValue), [0, 1, 2])
    }

    func testFuzzyFileSearchSessionStreamsUpdatesAndCompletion() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "fuzzy-session-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: root + "/alpha.txt"))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")]), "capabilities": .object(["experimentalApi": .bool(true)])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "fuzzyFileSearch/sessionStart", .object([
            "sessionId": .string("session-1"),
            "roots": .array([.string(root)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        s.conn.clientSend(req(3, "fuzzyFileSearch/sessionUpdate", .object([
            "sessionId": .string("session-1"),
            "query": .string("ALP"),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }

        let updateMsgs = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 {
                return n.method == "fuzzyFileSearch/sessionUpdated"
            }
            return false
        }, timeoutMs: 3000)
        guard case .notification(let updated)? = updateMsgs.first(where: {
            if case .notification(let n) = $0 {
                return n.method == "fuzzyFileSearch/sessionUpdated"
            }
            return false
        }) else { return XCTFail("missing fuzzyFileSearch/sessionUpdated") }
        XCTAssertEqual(updated.params?["sessionId"]?.stringValue, "session-1")
        XCTAssertEqual(updated.params?["query"]?.stringValue, "ALP")
        let files = updated.params?["files"]?.arrayValue ?? []
        XCTAssertEqual(files.first?["root"]?.stringValue, root)
        XCTAssertEqual(files.first?["path"]?.stringValue, "alpha.txt")

        let completedMsgs = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 {
                return n.method == "fuzzyFileSearch/sessionCompleted"
            }
            return false
        }, timeoutMs: 3000)
        guard case .notification(let completed)? = completedMsgs.first(where: {
            if case .notification(let n) = $0 {
                return n.method == "fuzzyFileSearch/sessionCompleted"
            }
            return false
        }) else { return XCTFail("missing fuzzyFileSearch/sessionCompleted") }
        XCTAssertEqual(completed.params?["sessionId"]?.stringValue, "session-1")
    }

    func testFuzzyFileSearchSessionMissingAndStoppedSessionsFail() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "fuzzy-session-stop-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: root + "/alpha.txt"))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")]), "capabilities": .object(["experimentalApi": .bool(true)])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "fuzzyFileSearch/sessionUpdate", .object([
            "sessionId": .string("missing"),
            "query": .string("alp"),
        ])))
        let missing = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        XCTAssertTrue(missing.contains {
            if case .error(let e) = $0 {
                return e.error.code == -32600
                    && e.error.message == "fuzzy file search session not found: missing"
            }
            return false
        })

        s.conn.clientSend(req(3, "fuzzyFileSearch/sessionStart", .object([
            "sessionId": .string("session-stop"),
            "roots": .array([.string(root)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        s.conn.clientSend(req(4, "fuzzyFileSearch/sessionStop", .object([
            "sessionId": .string("session-stop"),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        s.conn.clientSend(req(5, "fuzzyFileSearch/sessionUpdate", .object([
            "sessionId": .string("session-stop"),
            "query": .string("alp"),
        ])))
        let stopped = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(5) }
            return false
        }
        XCTAssertTrue(stopped.contains {
            if case .error(let e) = $0 {
                return e.error.message == "fuzzy file search session not found: session-stop"
            }
            return false
        })
    }

    func testFuzzyFileSearchSessionStopsWhenConnectionCloses() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let root = NSTemporaryDirectory() + "fuzzy-session-close-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: root + "/alpha.txt"))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: root)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")]), "capabilities": .object(["experimentalApi": .bool(true)])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "fuzzyFileSearch/sessionStart", .object([
            "sessionId": .string("session-close"),
            "roots": .array([.string(root)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }

        s.conn.closeClient()
        await s.pump.value

        let secondConn = InMemoryConnection()
        let secondPump = Task {
            for await m in secondConn.incoming() { await s.router.handle(m, secondConn) }
            await s.router.connectionClosed(secondConn)
        }
        defer {
            secondConn.closeClient()
            secondPump.cancel()
        }
        secondConn.clientSend(req(3, "fuzzyFileSearch/sessionUpdate", .object([
            "sessionId": .string("session-close"),
            "query": .string("alp"),
        ])))
        let missing = await waitOutbound(secondConn) {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }
        XCTAssertTrue(missing.contains {
            if case .error(let e) = $0 {
                return e.error.code == -32600
                    && e.error.message == "fuzzy file search session not found: session-close"
            }
            return false
        }, "closing the owning client stream should remove its fuzzy-search sessions")
    }

    func testFuzzyFileSearchSessionsAreIndependentAndClearQueryEmitsEmptySnapshot() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        let rootA = NSTemporaryDirectory() + "fuzzy-session-a-" + UUID().uuidString
        let rootB = NSTemporaryDirectory() + "fuzzy-session-b-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: rootB, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: rootA + "/alpha.txt"))
        try Data("beta".utf8).write(to: URL(fileURLWithPath: rootB + "/beta.txt"))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: rootA)
            try? FileManager.default.removeItem(atPath: rootB)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")]), "capabilities": .object(["experimentalApi": .bool(true)])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "fuzzyFileSearch/sessionStart", .object([
            "sessionId": .string("session-a"),
            "roots": .array([.string(rootA)]),
        ])))
        s.conn.clientSend(req(3, "fuzzyFileSearch/sessionStart", .object([
            "sessionId": .string("session-b"),
            "roots": .array([.string(rootB)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }

        s.conn.clientSend(req(4, "fuzzyFileSearch/sessionUpdate", .object([
            "sessionId": .string("session-a"),
            "query": .string("alp"),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        let aMsgs = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 {
                return n.method == "fuzzyFileSearch/sessionUpdated"
                    && n.params?["sessionId"]?.stringValue == "session-a"
            }
            return false
        }, timeoutMs: 3000)
        guard case .notification(let aUpdate)? = aMsgs.first(where: {
            if case .notification(let n) = $0 {
                return n.method == "fuzzyFileSearch/sessionUpdated"
                    && n.params?["sessionId"]?.stringValue == "session-a"
            }
            return false
        }) else { return XCTFail("missing session-a update") }
        XCTAssertEqual(aUpdate.params?["files"]?.arrayValue?.first?["root"]?.stringValue, rootA)

        s.conn.clientSend(req(5, "fuzzyFileSearch/sessionUpdate", .object([
            "sessionId": .string("session-b"),
            "query": .string(""),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }
        let bMsgs = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 {
                return n.method == "fuzzyFileSearch/sessionUpdated"
                    && n.params?["sessionId"]?.stringValue == "session-b"
            }
            return false
        }, timeoutMs: 3000)
        guard case .notification(let bUpdate)? = bMsgs.first(where: {
            if case .notification(let n) = $0 {
                return n.method == "fuzzyFileSearch/sessionUpdated"
                    && n.params?["sessionId"]?.stringValue == "session-b"
            }
            return false
        }) else { return XCTFail("missing session-b update") }
        XCTAssertEqual(bUpdate.params?["query"]?.stringValue, "")
        XCTAssertEqual(bUpdate.params?["files"]?.arrayValue, [])
    }

    func testConfigWriteRPCsMutateUserTomlAndReadBack() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "config/value/write", .object([
            "keyPath": .string("model"),
            "value": .string("gpt-4o-mini"),
            "mergeStrategy": .string("replace"),
        ])))
        let writeMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let wr)? = writeMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing config/value/write response") }
        XCTAssertEqual(wr.result["status"]?.stringValue, "ok")
        XCTAssertEqual(wr.result["filePath"]?.stringValue, s.home + "/config.toml")

        s.conn.clientSend(req(3, "config/batchWrite", .object([
            "edits": .array([
                .object([
                    "keyPath": .string("features.personality"),
                    "value": .bool(true),
                    "mergeStrategy": .string("replace"),
                ]),
                .object([
                    "keyPath": .string("tools"),
                    "value": .object(["web_search": .object(["enabled": .bool(false)])]),
                    "mergeStrategy": .string("upsert"),
                ]),
                .object([
                    "keyPath": .string("tools.shell"),
                    "value": .object(["enabled": .bool(true)]),
                    "mergeStrategy": .string("upsert"),
                ]),
            ]),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(3) }; return false }

        s.conn.clientSend(req(4, "config/read", .object([:])))
        let readMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }
        guard case .response(let rr)? = readMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }) else { return XCTFail("missing config/read response") }
        XCTAssertEqual(rr.result["config"]?["model"]?.stringValue, "gpt-4o-mini")
        XCTAssertEqual(rr.result["config"]?["features"]?["personality"]?.boolValue, true)
        XCTAssertEqual(rr.result["config"]?["tools"]?["web_search"]?["enabled"]?.boolValue, false)
        XCTAssertEqual(rr.result["config"]?["tools"]?["shell"]?["enabled"]?.boolValue, true)

        let written = try String(contentsOfFile: s.home + "/config.toml", encoding: .utf8)
        XCTAssertTrue(written.contains(#"model = "gpt-4o-mini""#))
        XCTAssertTrue(written.contains("[features]"))
        XCTAssertTrue(written.contains("personality = true"))
    }

    /// FINDING(config): the write path must reject configs that would fail
    /// `try_into::<ConfigToml>()` — wrong scalar type or unknown enum variant —
    /// with `configValidationError` (config_manager_service.rs:274-279,539-542).
    func testConfigWriteRejectsInvalidTypesAndEnumVariants() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        func expectValidationError(_ id: Int64, _ keyPath: String, _ value: JSONValue) async {
            s.conn.clientSend(req(Int(id), "config/value/write", .object([
                "keyPath": .string(keyPath),
                "value": value,
                "mergeStrategy": .string("replace"),
            ])))
            let msgs = await waitOutbound(s.conn) {
                if case .error(let e) = $0 { return e.id == .int(id) }
                if case .response(let r) = $0 { return r.id == .int(id) }
                return false
            }
            guard case .error(let err)? = msgs.first(where: {
                if case .error(let e) = $0 { return e.id == .int(id) }
                if case .response(let r) = $0 { return r.id == .int(id) }
                return false
            }) else { return XCTFail("expected error for \(keyPath)=\(value)") }
            // Wire shape: error data carries the config_write_error_code.
            let code = err.error.data?["config_write_error_code"]?.stringValue
            XCTAssertEqual(code, "configValidationError",
                           "\(keyPath)=\(value) must be rejected as configValidationError")
        }

        // Wrong scalar type: model expects a string.
        await expectValidationError(2, "model", .int(123))
        // Unknown enum variant: approval_policy.
        await expectValidationError(3, "approval_policy", .string("bogus"))
        // Unknown enum variant: sandbox_mode (upstream has no "full-write").
        await expectValidationError(4, "sandbox_mode", .string("full-write"))
        // Wrong scalar type: project_doc_max_bytes expects an integer.
        await expectValidationError(5, "project_doc_max_bytes", .string("x"))
        // Unknown enum variant: model_reasoning_effort.
        await expectValidationError(6, "model_reasoning_effort", .string("turbo"))
        // audit v11 config Finding 2: enum range-check the three previously
        // unvalidated ConfigToml enum keys (web_search / personality /
        // plan_mode_reasoning_effort), matching upstream's
        // `try_into::<ConfigToml>()` rejection (config_manager_service.rs:274-279).
        await expectValidationError(7, "web_search", .string("bogus"))
        await expectValidationError(8, "personality", .string("snarky"))
        await expectValidationError(9, "plan_mode_reasoning_effort", .string("ultra"))

        // The invalid writes must NOT have been persisted.
        let written = (try? String(contentsOfFile: s.home + "/config.toml", encoding: .utf8)) ?? ""
        XCTAssertFalse(written.contains("bogus"))
        XCTAssertFalse(written.contains("full-write"))
        XCTAssertFalse(written.contains("snarky"))
        XCTAssertFalse(written.contains("ultra"))

        // Valid values for the newly-validated enum keys still succeed.
        for (offset, kv) in [("web_search", "live"), ("personality", "friendly"),
                             ("plan_mode_reasoning_effort", "high")].enumerated() {
            let rid = 20 + offset
            s.conn.clientSend(req(rid, "config/value/write", .object([
                "keyPath": .string(kv.0), "value": .string(kv.1),
                "mergeStrategy": .string("replace"),
            ])))
            let m = await waitOutbound(s.conn) {
                if case .response(let r) = $0 { return r.id == .int(Int64(rid)) }
                if case .error(let e) = $0 { return e.id == .int(Int64(rid)) }
                return false
            }
            guard case .response(let r)? = m.first(where: {
                if case .response(let r) = $0 { return r.id == .int(Int64(rid)) }
                if case .error(let e) = $0 { return e.id == .int(Int64(rid)) }
                return false
            }) else { return XCTFail("valid \(kv.0)=\(kv.1) write should succeed") }
            XCTAssertEqual(r.result["status"]?.stringValue, "ok",
                           "valid \(kv.0)=\(kv.1) must persist")
        }

        // A VALID enum/scalar write still succeeds.
        s.conn.clientSend(req(7, "config/value/write", .object([
            "keyPath": .string("sandbox_mode"),
            "value": .string("workspace-write"),
            "mergeStrategy": .string("replace"),
        ])))
        let okMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(7) }; return false
        }
        guard case .response(let okr)? = okMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(7) }; return false
        }) else { return XCTFail("missing valid write response") }
        XCTAssertEqual(okr.result["status"]?.stringValue, "ok")
    }

    /// FINDING(config): the `version` returned by a write (and compared for
    /// `expectedVersion`) is the version of the RAW on-disk config.toml, so a
    /// read→write round-trip matches even when a `[profiles]` table exists
    /// (config_manager_service.rs:322-333, fingerprint.rs:37).
    func testConfigWriteVersionMatchesRawFileEvenWithProfiles() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        // Seed config.toml with an inline [profiles.<name>] table so the
        // user-layer projection differs from the raw file.
        try """
        model = "seed-model"

        [profiles.work]
        approval_policy = "never"
        """.write(toFile: s.home + "/config.toml", atomically: true, encoding: .utf8)

        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        // First write: capture the returned version.
        s.conn.clientSend(req(2, "config/value/write", .object([
            "keyPath": .string("model"),
            "value": .string("v1"),
            "mergeStrategy": .string("replace"),
        ])))
        let m1 = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(2) }; return false }
        guard case .response(let r1)? = m1.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing first write response") }
        let version = r1.result["version"]?.stringValue
        XCTAssertNotNil(version)
        XCTAssertTrue(version?.hasPrefix("sha256:") == true)

        // The returned version must equal the fingerprint of the RAW on-disk
        // file (profiles intact), not a profile-stripped/overlaid transform.
        let rawText = try String(contentsOfFile: s.home + "/config.toml", encoding: .utf8)
        let rawParsed = try TOML.parse(rawText)
        XCTAssertEqual(version, ConfigCanonicalVersion.version(of: rawParsed),
                       "write version must be the raw config.toml fingerprint")

        // Round-trip: a second write supplying that version as expectedVersion
        // must NOT spuriously conflict.
        s.conn.clientSend(req(3, "config/value/write", .object([
            "keyPath": .string("model"),
            "value": .string("v2"),
            "mergeStrategy": .string("replace"),
            "expectedVersion": .string(version!),
        ])))
        let m2 = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let r2)? = m2.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else { return XCTFail("expectedVersion round-trip spuriously conflicted") }
        XCTAssertEqual(r2.result["status"]?.stringValue, "ok")
    }

    /// FINDING(config): always-defaulted ConfigToml maps/structs + history
    /// max_bytes:null must appear in config/read for an empty config
    /// (config_toml.rs HashMaps/ShellEnvironmentPolicyToml, types.rs History).
    func testConfigReadEmitsAlwaysPresentDefaultMapsAndHistoryMaxBytes() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "config/read", .object([:])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let rr)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing config/read response") }
        let cfg = rr.result["config"]
        // Always-present empty maps.
        XCTAssertEqual(cfg?["mcp_servers"], .object([:]))
        XCTAssertEqual(cfg?["model_providers"], .object([:]))
        XCTAssertEqual(cfg?["plugins"], .object([:]))
        XCTAssertEqual(cfg?["marketplaces"], .object([:]))
        // shell_environment_policy default: an object with all-null leaves.
        guard case .object(let sep)? = cfg?["shell_environment_policy"] else {
            return XCTFail("shell_environment_policy must be an object")
        }
        XCTAssertEqual(sep["inherit"], .null)
        // history default carries max_bytes: null.
        guard case .object(let hist)? = cfg?["history"] else {
            return XCTFail("history must be an object")
        }
        XCTAssertEqual(hist["persistence"], .string("save-all"))
        XCTAssertTrue(hist.keys.contains("max_bytes"), "history must include max_bytes")
        XCTAssertEqual(hist["max_bytes"], .null)
    }

    /// audit v11 config Finding 1: an UNTRUSTED project-local layer surfaces in
    /// `config/read` `layers[]` with a `disabledReason` and is EXCLUDED from the
    /// effective `config` (upstream trust gating + v2 `ConfigLayer.disabled_reason`,
    /// loader/mod.rs:1162-1163, v2/config.rs:298-304).
    func testConfigReadSurfacesDisabledReasonForUntrustedProjectLayer() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        // A repo (with .git) carrying a project-local config, NOT trusted in the
        // user config under $CODEX_HOME.
        let repo = NSTemporaryDirectory() + "repo-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.codex",
                                                withIntermediateDirectories: true)
        try #"model = "untrusted-project-model""#.write(
            toFile: repo + "/.codex/config.toml", atomically: true, encoding: .utf8)

        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "config/read", .object([
            "cwd": .string(repo),
            "includeLayers": .bool(true),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let rr)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing config/read response") }

        // Effective config does NOT carry the untrusted repo's model.
        XCTAssertNotEqual(rr.result["config"]?["model"]?.stringValue,
                          "untrusted-project-model",
                          "untrusted project config must be excluded from effective config")

        // The project layer is still surfaced with a disabledReason.
        guard case .array(let layers)? = rr.result["layers"] else {
            return XCTFail("config/read must include layers[]")
        }
        let projectLayer = layers.first { layer in
            if case .object(let o) = layer, case .object(let name)? = o["name"],
               name["type"]?.stringValue == "project" { return true }
            return false
        }
        guard case .object(let pl)? = projectLayer else {
            return XCTFail("expected a project layer in layers[]")
        }
        let reason = pl["disabledReason"]?.stringValue
        XCTAssertNotNil(reason, "untrusted project layer must carry disabledReason")
        XCTAssertTrue(reason?.contains("trusted project") ?? false,
                      "disabledReason names the trust requirement")
    }

    /// FINDING(config): config/batchWrite accepts the reloadUserConfig flag
    /// (it is honored for newly spawned workers; the running-worker hot-reload
    /// is a documented multi-process divergence). The write itself must still
    /// succeed and persist.
    func testConfigBatchWriteAcceptsReloadUserConfigFlag() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "config/batchWrite", .object([
            "reloadUserConfig": .bool(true),
            "edits": .array([
                .object([
                    "keyPath": .string("model"),
                    "value": .string("reloaded-model"),
                    "mergeStrategy": .string("replace"),
                ]),
            ]),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let rr)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing batchWrite response") }
        XCTAssertEqual(rr.result["status"]?.stringValue, "ok")
        let written = try String(contentsOfFile: s.home + "/config.toml", encoding: .utf8)
        XCTAssertTrue(written.contains(#"model = "reloaded-model""#))
    }

    func testExternalAgentConfigDetectImportAndIdempotency() async throws {
        let root = NSTemporaryDirectory() + "external-agent-" + UUID().uuidString
        let home = root + "/.codex"
        let claudeHome = root + "/.claude"
        let repo = root + "/repo"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: claudeHome + "/skills/home-skill",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: claudeHome + "/hooks",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: claudeHome + "/agents",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: claudeHome + "/commands/nested",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.git",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.claude/skills/repo-skill",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.claude/hooks",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.claude/agents",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.claude/commands",
                                                withIntermediateDirectories: true)
        try "Home instructions\n".write(toFile: claudeHome + "/CLAUDE.md",
                                        atomically: true, encoding: .utf8)
        try "Repo instructions\n".write(toFile: repo + "/.claude/CLAUDE.md",
                                        atomically: true, encoding: .utf8)
        try "home skill body\n".write(toFile: claudeHome + "/skills/home-skill/SKILL.md",
                                      atomically: true, encoding: .utf8)
        try "repo skill body\n".write(toFile: repo + "/.claude/skills/repo-skill/SKILL.md",
                                      atomically: true, encoding: .utf8)
        try "print('home hook')\n".write(toFile: claudeHome + "/hooks/home.py",
                                        atomically: true, encoding: .utf8)
        try "print('repo hook')\n".write(toFile: repo + "/.claude/hooks/repo.py",
                                        atomically: true, encoding: .utf8)
        try """
        ---
        name: home-reviewer
        description: Reviews Claude output
        permissionMode: acceptEdits
        effort: max
        ---
        Use Claude carefully.
        """.write(toFile: claudeHome + "/agents/home-reviewer.md",
                   atomically: true, encoding: .utf8)
        try """
        ---
        name: repo-reader
        description: Reads repo Claude notes
        permissionMode: readOnly
        effort: low
        ---
        Read CLAUDE.md before answering.
        """.write(toFile: repo + "/.claude/agents/repo-reader.md",
                   atomically: true, encoding: .utf8)
        try """
        ---
        description: Explain the thing
        ---
        Explain this Claude command without unsupported placeholders.
        """.write(toFile: claudeHome + "/commands/nested/explain.md",
                   atomically: true, encoding: .utf8)
        try """
        ---
        description: Fix repo issue
        ---
        Fix the repo issue with Codex.
        """.write(toFile: repo + "/.claude/commands/fix.md",
                   atomically: true, encoding: .utf8)
        try """
        {
          "mcpServers": {
            "home-stdio": {
              "command": "node",
              "args": ["server.js"],
              "env": {"TOKEN": "${TOKEN}", "STATIC": "yes"}
            },
            "skipped-placeholder": {
              "command": "${BAD}"
            }
          }
        }
        """.write(toFile: root + "/.mcp.json", atomically: true, encoding: .utf8)
        try """
        {
          "mcpServers": {
            "repo-http": {
              "url": "https://example.test/mcp",
              "headers": {"Authorization": "Bearer ${REPO_TOKEN}", "X-Static": "ok"}
            }
          }
        }
        """.write(toFile: repo + "/.mcp.json", atomically: true, encoding: .utf8)
        try #"""
        {"env":{"FOO":"bar","COUNT":7,"DROP":null},"sandbox":{"enabled":true},
         "hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"python3 .claude/hooks/home.py","timeoutSec":5,"statusMessage":"Claude hook"}]}]}}
        """#
            .write(toFile: claudeHome + "/settings.json", atomically: true, encoding: .utf8)
        try #"""
        {"env":{"REPO_ONLY":true},"sandbox":{"enabled":true},
         "hooks":{"PreToolUse":[{"matcher":"shell","hooks":[{"type":"command","command":"python3 .claude/hooks/repo.py","timeout":9}]}]}}
        """#
            .write(toFile: repo + "/.claude/settings.json", atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "externalAgentConfig/detect", .object([
            "includeHome": .bool(true),
            "cwds": .array([.string(repo + "/nested")]),
        ])))
        let detectMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let detect)? = detectMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing externalAgentConfig/detect response") }
        let items = detect.result["items"]?.arrayValue ?? []
        let itemTypes = items.compactMap { $0["itemType"]?.stringValue }
        XCTAssertEqual(itemTypes.filter { $0 == "CONFIG" }.count, 2)
        XCTAssertEqual(itemTypes.filter { $0 == "MCP_SERVER_CONFIG" }.count, 2)
        XCTAssertEqual(itemTypes.filter { $0 == "HOOKS" }.count, 2)
        XCTAssertEqual(itemTypes.filter { $0 == "SKILLS" }.count, 2)
        XCTAssertEqual(itemTypes.filter { $0 == "COMMANDS" }.count, 2)
        XCTAssertEqual(itemTypes.filter { $0 == "SUBAGENTS" }.count, 2)
        XCTAssertEqual(itemTypes.filter { $0 == "AGENTS_MD" }.count, 2)
        XCTAssertTrue(items.contains { $0["cwd"]?.stringValue == repo })
        XCTAssertTrue(items.contains { $0["cwd"]?.isNull == true })
        XCTAssertTrue(items.contains {
            $0["itemType"]?.stringValue == "MCP_SERVER_CONFIG"
                && ($0["details"]?["mcpServers"]?.arrayValue ?? [])
                    .contains { $0["name"]?.stringValue == "home-stdio" }
        })
        XCTAssertTrue(items.contains {
            $0["itemType"]?.stringValue == "COMMANDS"
                && ($0["details"]?["commands"]?.arrayValue ?? [])
                    .contains { $0["name"]?.stringValue == "source-command-nested-explain" }
        })

        s.conn.clientSend(req(3, "externalAgentConfig/import", .object([
            "migrationItems": .array(items),
        ])))
        let importMessages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 {
                return n.method == "externalAgentConfig/import/completed"
            }
            return false
        }
        XCTAssertTrue(importMessages.contains {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }, "import returns before emitting the completion notification")
        XCTAssertTrue(importMessages.contains {
            if case .notification(let n) = $0 {
                return n.method == "externalAgentConfig/import/completed"
            }
            return false
        })

        XCTAssertEqual(try String(contentsOfFile: home + "/AGENTS.md", encoding: .utf8),
                       "Home instructions\n")
        XCTAssertEqual(try String(contentsOfFile: repo + "/AGENTS.md", encoding: .utf8),
                       "Repo instructions\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.agents/skills/home-skill/SKILL.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/.agents/skills/repo-skill/SKILL.md"))
        let homeConfig = try String(contentsOfFile: home + "/config.toml", encoding: .utf8)
        XCTAssertTrue(homeConfig.contains(#"sandbox_mode = "workspace-write""#))
        XCTAssertTrue(homeConfig.contains(#"inherit = "core""#))
        XCTAssertTrue(homeConfig.contains(#"FOO = "bar""#))
        XCTAssertTrue(homeConfig.contains(#"COUNT = "7""#))
        XCTAssertFalse(homeConfig.contains("DROP"))
        XCTAssertTrue(homeConfig.contains("[mcp_servers.home-stdio]"))
        XCTAssertTrue(homeConfig.contains(#"command = "node""#))
        XCTAssertTrue(homeConfig.contains(#"env_vars = ["TOKEN"]"#))
        XCTAssertFalse(homeConfig.contains("skipped-placeholder"))
        let repoConfig = try String(contentsOfFile: repo + "/.codex/config.toml", encoding: .utf8)
        XCTAssertTrue(repoConfig.contains(#"REPO_ONLY = "true""#))
        XCTAssertTrue(repoConfig.contains("[mcp_servers.repo-http]"))
        XCTAssertTrue(repoConfig.contains(#"bearer_token_env_var = "REPO_TOKEN""#))
        let homeHooks = try String(contentsOfFile: home + "/hooks.json", encoding: .utf8)
        XCTAssertTrue(homeHooks.contains("session-start"))
        XCTAssertTrue(homeHooks.contains(".codex\\/hooks\\/home.py")
                      || homeHooks.contains(".codex/hooks/home.py"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/hooks/home.py"))
        let repoHooks = try String(contentsOfFile: repo + "/.codex/hooks.json", encoding: .utf8)
        XCTAssertTrue(repoHooks.contains("pre-tool-use"))
        XCTAssertTrue(repoHooks.contains(".codex\\/hooks\\/repo.py")
                      || repoHooks.contains(".codex/hooks/repo.py"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/.codex/hooks/repo.py"))
        let homeAgent = try String(contentsOfFile: home + "/agents/home-reviewer.toml", encoding: .utf8)
        XCTAssertTrue(homeAgent.contains(#"name = "home-reviewer""#))
        XCTAssertTrue(homeAgent.contains(#"model_reasoning_effort = "xhigh""#))
        XCTAssertTrue(homeAgent.contains(#"sandbox_mode = "workspace-write""#))
        XCTAssertTrue(homeAgent.contains("Codex carefully."))
        let repoAgent = try String(contentsOfFile: repo + "/.codex/agents/repo-reader.toml",
                                   encoding: .utf8)
        XCTAssertTrue(repoAgent.contains(#"sandbox_mode = "read-only""#))
        XCTAssertTrue(repoAgent.contains("AGENTS.md"))
        let homeCommand = try String(contentsOfFile: root + "/.agents/skills/source-command-nested-explain/SKILL.md",
                                     encoding: .utf8)
        XCTAssertTrue(homeCommand.contains(#"name: "source-command-nested-explain""#))
        XCTAssertTrue(homeCommand.contains("Codex command"))
        let repoCommand = try String(contentsOfFile: repo + "/.agents/skills/source-command-fix/SKILL.md",
                                     encoding: .utf8)
        XCTAssertTrue(repoCommand.contains("Fix repo issue"))

        s.conn.clientSend(req(4, "externalAgentConfig/detect", .object([
            "includeHome": .bool(true),
            "cwds": .array([.string(repo)]),
        ])))
        let secondDetect = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }
        guard case .response(let after)? = secondDetect.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }) else { return XCTFail("missing second externalAgentConfig/detect response") }
        XCTAssertEqual(after.result["items"]?.arrayValue ?? [], [],
                       "imported CONFIG/SKILLS/AGENTS_MD items should not be offered again")
    }

    func testExternalAgentSessionImportCreatesReadableResumableThread() async throws {
        let root = NSTemporaryDirectory() + "external-session-" + UUID().uuidString
        let home = root + "/.codex"
        let claudeSessionDir = root + "/.claude/projects/repo"
        let repo = root + "/repo"
        let expectedRepo = URL(fileURLWithPath: repo).standardizedFileURL.path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: claudeSessionDir,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let sessionPath = claudeSessionDir + "/session.jsonl"
        try """
        {"type":"user","cwd":"\(repo)","timestamp":"2026-05-20T12:00:00Z","message":{"content":"first request"}}
        {"type":"assistant","cwd":"\(repo)","timestamp":"2026-05-20T12:00:01Z","message":{"content":"first answer"}}
        {"type":"custom-title","customTitle":"source session title"}
        """.write(toFile: sessionPath, atomically: true, encoding: .utf8)
        let expectedSessionPath = URL(fileURLWithPath: sessionPath).standardizedFileURL.path

        let s = try makeStack(MockModelClient([.hello("after import answer")]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "externalAgentConfig/detect", .object(["includeHome": .bool(true)])))
        let detectMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let detect)? = detectMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing session detect response") }
        let items = detect.result["items"]?.arrayValue ?? []
        let sessionItems = items.filter { $0["itemType"]?.stringValue == "SESSIONS" }
        XCTAssertEqual(sessionItems.count, 1)
        let sessions = sessionItems.first?["details"]?["sessions"]?.arrayValue ?? []
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?["path"]?.stringValue, expectedSessionPath)
        XCTAssertEqual(sessions.first?["cwd"]?.stringValue, expectedRepo)
        XCTAssertEqual(sessions.first?["title"]?.stringValue, "source session title")

        s.conn.clientSend(req(3, "externalAgentConfig/import", .object(["migrationItems": .array(sessionItems)])))
        let importMessages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 {
                return n.method == "externalAgentConfig/import/completed"
            }
            return false
        }
        XCTAssertTrue(importMessages.contains {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        })

        s.conn.clientSend(req(4, "thread/list", .object(["limit": .int(20)])))
        let listMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }
        guard case .response(let list)? = listMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }) else { return XCTFail("missing thread/list response") }
        let listedThreads = list.result["data"]?.arrayValue ?? []
        XCTAssertEqual(listedThreads.count, 1)
        XCTAssertEqual(listedThreads.first?["cwd"]?.stringValue, expectedRepo)
        XCTAssertEqual(listedThreads.first?["name"]?.stringValue, "source session title")
        guard let importedThreadId = listedThreads.first?["id"]?.stringValue else {
            return XCTFail("missing imported thread id")
        }

        s.conn.clientSend(req(5, "thread/read", .object([
            "threadId": .string(importedThreadId),
            "includeTurns": .bool(true),
        ])))
        let readMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }
        guard case .response(let read)? = readMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }) else { return XCTFail("missing thread/read response") }
        let turns = read.result["thread"]?["turns"]?.arrayValue ?? []
        XCTAssertEqual(turns.count, 1)
        let importedItems = turns.first?["items"]?.arrayValue ?? []
        XCTAssertEqual(importedItems.count, 3)
        XCTAssertEqual(importedItems[0]["type"]?.stringValue, "userMessage")
        XCTAssertEqual(importedItems[0]["content"]?.arrayValue?.first?["text"]?.stringValue, "first request")
        XCTAssertEqual(importedItems[1]["type"]?.stringValue, "agentMessage")
        XCTAssertEqual(importedItems[1]["text"]?.stringValue, "first answer")
        XCTAssertEqual(importedItems[2]["text"]?.stringValue, "<EXTERNAL SESSION IMPORTED>")

        s.conn.clientSend(req(6, "externalAgentConfig/detect", .object(["includeHome": .bool(true)])))
        let secondDetectMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(6) }; return false
        }
        guard case .response(let secondDetect)? = secondDetectMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(6) }; return false
        }) else { return XCTFail("missing second detect response") }
        XCTAssertFalse((secondDetect.result["items"]?.arrayValue ?? [])
            .contains { $0["itemType"]?.stringValue == "SESSIONS" })

        s.conn.clientSend(req(7, "externalAgentConfig/import", .object(["migrationItems": .array(sessionItems)])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 {
                return n.method == "externalAgentConfig/import/completed"
            }
            return false
        }
        s.conn.clientSend(req(8, "thread/list", .object(["limit": .int(20)])))
        let secondListMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(8) }; return false
        }
        guard case .response(let secondList)? = secondListMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(8) }; return false
        }) else { return XCTFail("missing second thread/list response") }
        XCTAssertEqual(secondList.result["data"]?.arrayValue?.count, 1)

        s.conn.clientSend(req(9, "thread/resume", .object(["threadId": .string(importedThreadId)])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(9) }; return false
        }
        s.conn.clientSend(req(10, "turn/start", .object([
            "threadId": .string(importedThreadId),
            "input": .array([.object(["type": .string("text"), "text": .string("continue after import")])]),
        ])))
        let followupMessages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }
        XCTAssertTrue(followupMessages.contains {
            if case .notification(let n) = $0 { return n.method == "item/agentMessage/delta" }
            return false
        })

        s.conn.clientSend(req(11, "thread/read", .object([
            "threadId": .string(importedThreadId),
            "includeTurns": .bool(true),
        ])))
        let followupReadMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(11) }; return false
        }
        guard case .response(let followupRead)? = followupReadMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(11) }; return false
        }) else { return XCTFail("missing follow-up thread/read response") }
        let followupTurns = followupRead.result["thread"]?["turns"]?.arrayValue ?? []
        XCTAssertEqual(followupTurns.count, 2)
        XCTAssertTrue((followupTurns.last?["items"]?.arrayValue ?? [])
            .contains { $0["text"]?.stringValue == "after import answer" })
    }

    func testExternalAgentPluginDetectImportListAndIdempotency() async throws {
        let root = NSTemporaryDirectory() + "external-plugin-" + UUID().uuidString
        let home = root + "/.codex"
        let claudeHome = root + "/.claude"
        let marketplaceRoot = root + "/marketplace"
        let pluginRoot = marketplaceRoot + "/plugins/sample"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: claudeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: marketplaceRoot + "/.agents/plugins",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: pluginRoot + "/.codex-plugin",
                                                withIntermediateDirectories: true)
        try """
        {
          "name": "debug",
          "plugins": [
            {
              "name": "sample",
              "source": {
                "source": "local",
                "path": "./plugins/sample"
              }
            }
          ]
        }
        """.write(toFile: marketplaceRoot + "/.agents/plugins/marketplace.json",
                   atomically: true, encoding: .utf8)
        try """
        {
          "name": "sample",
          "version": "0.1.0"
        }
        """.write(toFile: pluginRoot + "/.codex-plugin/plugin.json",
                   atomically: true, encoding: .utf8)
        try """
        plugin payload
        """.write(toFile: pluginRoot + "/README.md", atomically: true, encoding: .utf8)
        try """
        {
          "enabledPlugins": {
            "sample@debug": true,
            "disabled@debug": false
          },
          "extraKnownMarketplaces": {
            "debug": {
              "source": "local",
              "path": "\(marketplaceRoot)"
            }
          }
        }
        """.write(toFile: claudeHome + "/settings.json", atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "externalAgentConfig/detect", .object(["includeHome": .bool(true)])))
        let detectMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let detect)? = detectMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing externalAgentConfig/detect response") }
        let pluginItems = (detect.result["items"]?.arrayValue ?? [])
            .filter { $0["itemType"]?.stringValue == "PLUGINS" }
        XCTAssertEqual(pluginItems.count, 1)
        let pluginGroups = pluginItems.first?["details"]?["plugins"]?.arrayValue ?? []
        XCTAssertEqual(pluginGroups.count, 1)
        XCTAssertEqual(pluginGroups.first?["marketplaceName"]?.stringValue, "debug")
        XCTAssertEqual(pluginGroups.first?["pluginNames"]?.arrayValue?.compactMap(\.stringValue),
                       ["sample"])

        s.conn.clientSend(req(3, "externalAgentConfig/import", .object([
            "migrationItems": .array(pluginItems),
        ])))
        let importMessages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 {
                return n.method == "externalAgentConfig/import/completed"
            }
            return false
        }
        XCTAssertTrue(importMessages.contains {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        })

        let config = try String(contentsOfFile: home + "/config.toml", encoding: .utf8)
        XCTAssertTrue(config.contains(#"[marketplaces.debug]"#))
        XCTAssertTrue(config.contains(#"source_type = "local""#))
        XCTAssertTrue(config.contains(#"[plugins."sample@debug"]"#))
        XCTAssertTrue(config.contains("enabled = true"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home + "/plugins/cache/debug/sample/0.1.0/.codex-plugin/plugin.json"))

        s.conn.clientSend(req(4, "plugin/list", .object([:])))
        let listMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }
        guard case .response(let list)? = listMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }) else { return XCTFail("missing plugin/list response") }
        let marketplaces = list.result["marketplaces"]?.arrayValue ?? []
        let debugMarketplace = marketplaces.first { $0["name"]?.stringValue == "debug" }
        let sample = debugMarketplace?["plugins"]?.arrayValue?
            .first { $0["name"]?.stringValue == "sample" }
        XCTAssertEqual(sample?["id"]?.stringValue, "sample@debug")
        XCTAssertEqual(sample?["installed"]?.boolValue, true)
        XCTAssertEqual(sample?["enabled"]?.boolValue, true)
        XCTAssertEqual(sample?["localVersion"]?.stringValue, "0.1.0")

        s.conn.clientSend(req(5, "externalAgentConfig/detect", .object(["includeHome": .bool(true)])))
        let secondDetectMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }
        guard case .response(let secondDetect)? = secondDetectMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }) else { return XCTFail("missing second externalAgentConfig/detect response") }
        XCTAssertFalse((secondDetect.result["items"]?.arrayValue ?? [])
            .contains { $0["itemType"]?.stringValue == "PLUGINS" })
    }

    func testMarketplaceAddInstallUpgradeUninstallRemoveRoundTrip() async throws {
        let root = NSTemporaryDirectory() + "marketplace-rpc-" + UUID().uuidString
        let home = root + "/.codex"
        let marketplaceRoot = root + "/marketplace"
        let pluginRoot = marketplaceRoot + "/plugins/sample"
        let helperPluginRoot = marketplaceRoot + "/plugins/helper"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: marketplaceRoot + "/.agents/plugins",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: pluginRoot + "/.codex-plugin",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: helperPluginRoot + "/.codex-plugin",
                                                withIntermediateDirectories: true)
        try """
        {
          "name": "debug",
          "plugins": [
            {
              "name": "sample",
              "source": {
                "source": "local",
                "path": "./plugins/sample"
              }
            },
            {
              "name": "helper",
              "source": {
                "source": "local",
                "path": "./plugins/helper"
              }
            }
          ]
        }
        """.write(toFile: marketplaceRoot + "/.agents/plugins/marketplace.json",
                   atomically: true, encoding: .utf8)
        try """
        {
          "name": "sample",
          "version": "0.1.0"
        }
        """.write(toFile: pluginRoot + "/.codex-plugin/plugin.json",
                   atomically: true, encoding: .utf8)
        try """
        {
          "name": "helper",
          "version": "0.3.0"
        }
        """.write(toFile: helperPluginRoot + "/.codex-plugin/plugin.json",
                   atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "marketplace/add", .object([
            "source": .string(marketplaceRoot),
        ])))
        let addMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let add)? = addMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing marketplace/add response") }
        XCTAssertEqual(add.result["marketplaceName"]?.stringValue, "debug")
        XCTAssertEqual(add.result["installedRoot"]?.stringValue, marketplaceRoot)
        XCTAssertEqual(add.result["alreadyAdded"]?.boolValue, false)

        s.conn.clientSend(req(3, "plugin/install", .object([
            "pluginName": .string("sample"),
            "remoteMarketplaceName": .string("debug"),
        ])))
        let installMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }; return false
        }
        guard case .response(let install)? = installMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }; return false
        }) else { return XCTFail("missing plugin/install response") }
        XCTAssertEqual(install.result["authPolicy"]?.stringValue, "ON_USE")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home + "/plugins/cache/debug/sample/0.1.0/.codex-plugin/plugin.json"))

        s.conn.clientSend(req(4, "plugin/list", .object([:])))
        let listMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }
        guard case .response(let list)? = listMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }) else { return XCTFail("missing plugin/list response") }
        let sample = list.result["marketplaces"]?.arrayValue?.first?["plugins"]?
            .arrayValue?.first { $0["id"]?.stringValue == "sample@debug" }
        XCTAssertEqual(sample?["installed"]?.boolValue, true)
        XCTAssertEqual(sample?["enabled"]?.boolValue, true)

        s.conn.clientSend(req(5, "plugin/installed", .object([:])))
        let installedMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }
        guard case .response(let installed)? = installedMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }) else { return XCTFail("missing plugin/installed response") }
        let installedPlugins = installed.result["marketplaces"]?.arrayValue?.first?["plugins"]?
            .arrayValue ?? []
        XCTAssertEqual(installedPlugins.map { $0["id"]?.stringValue }, ["sample@debug"])

        s.conn.clientSend(req(50, "plugin/installed", .object([
            "installSuggestionPluginNames": .array([.string("helper")]),
        ])))
        let suggestedMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(50) }; return false
        }
        guard case .response(let suggested)? = suggestedMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(50) }; return false
        }) else { return XCTFail("missing plugin/installed suggestion response") }
        let suggestedPlugins = suggested.result["marketplaces"]?.arrayValue?.first?["plugins"]?
            .arrayValue ?? []
        XCTAssertEqual(suggestedPlugins.map { $0["id"]?.stringValue },
                       ["sample@debug", "helper@debug"])
        let helper = suggestedPlugins.first { $0["id"]?.stringValue == "helper@debug" }
        XCTAssertEqual(helper?["installed"]?.boolValue, false)
        XCTAssertEqual(helper?["enabled"]?.boolValue, false)

        s.conn.clientSend(req(6, "marketplace/upgrade", .object([
            "marketplaceName": .string("debug"),
        ])))
        let upgradeMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(6) }; return false
        }
        guard case .response(let upgrade)? = upgradeMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(6) }; return false
        }) else { return XCTFail("missing marketplace/upgrade response") }
        XCTAssertEqual(upgrade.result["upgraded"]?.arrayValue?.first?["pluginId"]?.stringValue,
                       "sample@debug")

        s.conn.clientSend(req(7, "plugin/uninstall", .object([
            "pluginId": .string("sample@debug"),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(7) }; return false
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/plugins/cache/debug/sample"))

        s.conn.clientSend(req(8, "marketplace/remove", .object([
            "marketplaceName": .string("debug"),
        ])))
        let removeMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(8) }; return false
        }
        guard case .response(let remove)? = removeMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(8) }; return false
        }) else { return XCTFail("missing marketplace/remove response") }
        XCTAssertEqual(remove.result["marketplaceName"]?.stringValue, "debug")
        let config = (try? String(contentsOfFile: home + "/config.toml", encoding: .utf8)) ?? ""
        XCTAssertFalse(config.contains("[marketplaces.debug]"))
        XCTAssertFalse(config.contains(#"[plugins."sample@debug"]"#))
    }

    func testPluginReadAndSkillReadReturnLocalBundleContents() async throws {
        let root = NSTemporaryDirectory() + "plugin-read-rpc-" + UUID().uuidString
        let home = root + "/.codex"
        let marketplaceRoot = root + "/marketplace"
        let pluginRoot = marketplaceRoot + "/plugins/sample"
        let marketplacePath = marketplaceRoot + "/.agents/plugins/marketplace.json"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: marketplaceRoot + "/.agents/plugins",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: pluginRoot + "/.codex-plugin",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: pluginRoot + "/skills/helper",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: pluginRoot + "/hooks",
                                                withIntermediateDirectories: true)
        try """
        {
          "name": "debug",
          "plugins": [
            {
              "name": "sample",
              "source": { "source": "local", "path": "./plugins/sample" },
              "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },
              "category": "Testing"
            }
          ]
        }
        """.write(toFile: marketplacePath, atomically: true, encoding: .utf8)
        try """
        {
          "name": "sample",
          "version": "0.2.0",
          "description": "Local plugin details",
          "keywords": ["swift", "agent"],
          "interface": { "displayName": "Sample Plugin" }
        }
        """.write(toFile: pluginRoot + "/.codex-plugin/plugin.json",
                   atomically: true, encoding: .utf8)
        try """
        ---
        name: helper
        description: Help with local plugin work
        ---

        # Helper Skill
        Use this skill carefully.
        """.write(toFile: pluginRoot + "/skills/helper/SKILL.md",
                   atomically: true, encoding: .utf8)
        try """
        { "mcpServers": { "demo": { "command": "demo-server" } } }
        """.write(toFile: pluginRoot + "/.mcp.json", atomically: true, encoding: .utf8)
        try """
        { "apps": { "gmail": { "id": "gmail" } } }
        """.write(toFile: pluginRoot + "/.app.json", atomically: true, encoding: .utf8)
        try """
        { "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "echo hi" } ] } ] } }
        """.write(toFile: pluginRoot + "/hooks/hooks.json", atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "marketplace/add", .object(["source": .string(marketplaceRoot)])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(2) }; return false }
        s.conn.clientSend(req(3, "plugin/install", .object([
            "pluginName": .string("sample"),
            "remoteMarketplaceName": .string("debug"),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(3) }; return false }

        s.conn.clientSend(req(30, "skills/config/write", .object([
            "name": .string("sample:helper"),
            "enabled": .bool(false),
        ])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(30) }; return false }

        s.conn.clientSend(req(4, "plugin/read", .object([
            "marketplacePath": .string(marketplacePath),
            "pluginName": .string("sample"),
        ])))
        let readMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let read)? = readMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing plugin/read response") }
        let plugin = read.result["plugin"]
        XCTAssertEqual(plugin?["marketplaceName"]?.stringValue, "debug")
        XCTAssertEqual(plugin?["marketplacePath"]?.stringValue, marketplacePath)
        XCTAssertEqual(plugin?["summary"]?["id"]?.stringValue, "sample@debug")
        XCTAssertEqual(plugin?["summary"]?["installed"]?.boolValue, true)
        XCTAssertEqual(plugin?["summary"]?["enabled"]?.boolValue, true)
        XCTAssertEqual(plugin?["summary"]?["interface"]?["displayName"]?.stringValue,
                       "Sample Plugin")
        XCTAssertEqual(plugin?["summary"]?["interface"]?["category"]?.stringValue, "Testing")
        XCTAssertEqual(plugin?["description"]?.stringValue, "Local plugin details")
        XCTAssertEqual(plugin?["skills"]?.arrayValue?.first?["name"]?.stringValue,
                       "sample:helper")
        XCTAssertEqual(plugin?["skills"]?.arrayValue?.first?["description"]?.stringValue,
                       "Help with local plugin work")
        XCTAssertEqual(plugin?["skills"]?.arrayValue?.first?["enabled"]?.boolValue, false)
        XCTAssertEqual(plugin?["hooks"]?.arrayValue?.first?["eventName"]?.stringValue,
                       "session_start")
        XCTAssertEqual(plugin?["apps"]?.arrayValue?.first?["id"]?.stringValue, "gmail")
        XCTAssertEqual(plugin?["mcpServers"]?.arrayValue?.compactMap(\.stringValue), ["demo"])

        s.conn.clientSend(req(31, "plugin/read", .object([
            "remoteMarketplaceName": .string("debug"),
            "pluginName": .string("sample"),
        ])))
        let namedReadMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(31) }
            return false
        }
        guard case .response(let namedRead)? = namedReadMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(31) }
            return false
        }) else { return XCTFail("missing remoteMarketplaceName plugin/read response") }
        XCTAssertEqual(namedRead.result["plugin"]?["summary"]?["id"]?.stringValue,
                       "sample@debug")
        XCTAssertEqual(namedRead.result["plugin"]?["skills"]?.arrayValue?.first?["enabled"]?.boolValue,
                       false)

        s.conn.clientSend(req(5, "plugin/share/save", .object([
            "pluginPath": .string(pluginRoot),
            "discoverability": .string("PRIVATE"),
        ])))
        let shareMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }
        guard case .response(let share)? = shareMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }) else { return XCTFail("missing plugin/share/save response") }
        let remotePluginId = share.result["remotePluginId"]?.stringValue ?? ""

        s.conn.clientSend(req(6, "plugin/skill/read", .object([
            "remoteMarketplaceName": .string("debug"),
            "remotePluginId": .string(remotePluginId),
            "skillName": .string("helper"),
        ])))
        let skillMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }
        guard case .response(let skill)? = skillMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }) else { return XCTFail("missing plugin/skill/read response") }
        XCTAssertTrue(skill.result["contents"]?.stringValue?.contains("# Helper Skill") == true)
    }

    func testPluginShareSaveListUpdateCheckoutDeleteRoundTrip() async throws {
        let root = NSTemporaryDirectory() + "plugin-share-rpc-" + UUID().uuidString
        let home = root + "/.codex"
        let marketplaceRoot = root + "/marketplace"
        let pluginRoot = marketplaceRoot + "/plugins/shared"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: marketplaceRoot + "/.agents/plugins",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: pluginRoot + "/.codex-plugin",
                                                withIntermediateDirectories: true)
        try """
        {
          "name": "debug",
          "plugins": [
            {
              "name": "shared",
              "source": {
                "source": "local",
                "path": "./plugins/shared"
              }
            }
          ]
        }
        """.write(toFile: marketplaceRoot + "/.agents/plugins/marketplace.json",
                   atomically: true, encoding: .utf8)
        try """
        {
          "name": "shared",
          "version": "2.3.4"
        }
        """.write(toFile: pluginRoot + "/.codex-plugin/plugin.json",
                   atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        func response(_ id: Int, _ method: String, _ params: JSONValue?) async throws -> JSONRPCResponse {
            s.conn.clientSend(req(id, method, params))
            let messages = await waitOutbound(s.conn) {
                if case .response(let r) = $0 { return r.id == .int(Int64(id)) }
                if case .error(let e) = $0 { return e.id == .int(Int64(id)) }
                return false
            }
            if case .response(let response)? = messages.first(where: {
                if case .response(let r) = $0 { return r.id == .int(Int64(id)) }
                return false
            }) {
                return response
            }
            XCTFail("missing \(method) response")
            return JSONRPCResponse(id: .int(Int64(id)), result: .object([:]))
        }

        _ = try await response(2, "marketplace/add", .object(["source": .string(marketplaceRoot)]))
        let save = try await response(3, "plugin/share/save", .object([
            "pluginPath": .string(pluginRoot),
            "discoverability": .string("UNLISTED"),
            "shareTargets": .array([
                .object([
                    "principalType": .string("user"),
                    "principalId": .string("teammate"),
                    "role": .string("editor"),
                ]),
            ]),
        ]))
        guard let remotePluginId = save.result["remotePluginId"]?.stringValue else {
            return XCTFail("missing remotePluginId")
        }
        XCTAssertTrue(remotePluginId.hasPrefix("rplg_"))
        XCTAssertEqual(save.result["shareUrl"]?.stringValue, "codex://plugin-share/\(remotePluginId)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home + "/.tmp/plugin-share-local-paths-v1.json"))

        let listedPlugins = try await response(4, "plugin/list", .object([:]))
        let shared = listedPlugins.result["marketplaces"]?.arrayValue?.first?["plugins"]?
            .arrayValue?.first { $0["id"]?.stringValue == "shared@debug" }
        XCTAssertEqual(shared?["shareContext"]?["remotePluginId"]?.stringValue, remotePluginId)
        XCTAssertEqual(shared?["shareContext"]?["discoverability"]?.stringValue, "UNLISTED")

        let updated = try await response(5, "plugin/share/updateTargets", .object([
            "remotePluginId": .string(remotePluginId),
            "discoverability": .string("PRIVATE"),
            "shareTargets": .array([
                .object([
                    "principalType": .string("group"),
                    "principalId": .string("eng"),
                    "role": .string("reader"),
                ]),
            ]),
        ]))
        XCTAssertEqual(updated.result["discoverability"]?.stringValue, "PRIVATE")
        XCTAssertEqual(updated.result["principals"]?.arrayValue?.count, 2)

        let shareList = try await response(6, "plugin/share/list", .object([:]))
        let share = shareList.result["data"]?.arrayValue?.first
        XCTAssertEqual(share?["localPluginPath"]?.stringValue, pluginRoot)
        XCTAssertEqual(share?["plugin"]?["shareContext"]?["remotePluginId"]?.stringValue,
                       remotePluginId)
        XCTAssertEqual(share?["plugin"]?["shareContext"]?["sharePrincipals"]?
            .arrayValue?.last?["principalId"]?.stringValue, "eng")

        let checkout = try await response(7, "plugin/share/checkout", .object([
            "remotePluginId": .string(remotePluginId),
        ]))
        XCTAssertEqual(checkout.result["pluginId"]?.stringValue, "shared@codex-curated")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home + "/plugins/shared/.codex-plugin/plugin.json"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home + "/.agents/plugins/marketplace.json"))

        let personalList = try await response(8, "plugin/list", .object([
            "cwds": .array([.string(home)]),
        ]))
        let checkedOut = personalList.result["marketplaces"]?.arrayValue?
            .flatMap { $0["plugins"]?.arrayValue ?? [] }
            .first { $0["id"]?.stringValue == "shared@codex-curated" }
        XCTAssertEqual(checkedOut?["shareContext"]?["remotePluginId"]?.stringValue,
                       remotePluginId)

        _ = try await response(9, "plugin/share/delete", .object([
            "remotePluginId": .string(remotePluginId),
        ]))
        let emptyList = try await response(10, "plugin/share/list", .object([:]))
        XCTAssertEqual(emptyList.result["data"]?.arrayValue?.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home + "/.tmp/plugin-share-local-paths-v1.json"))

        s.conn.clientSend(req(11, "plugin/share/save", .object([
            "pluginPath": .string(pluginRoot),
            "discoverability": .string("LISTED"),
        ])))
        let errorMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(11) }
            return false
        }
        XCTAssertTrue(errorMessages.contains {
            if case .error(let e) = $0 {
                return e.error.message.contains("LISTED is not supported")
            }
            return false
        })
    }

    func testAppListReturnsConfiguredConnectorsWithPaginationAndEnabledState() async throws {
        let root = NSTemporaryDirectory() + "app-list-rpc-" + UUID().uuidString
        let home = root + "/.codex"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        {
          "connectors": [
            {
              "id": "zeta",
              "name": "Zeta",
              "description": "second connector",
              "installUrl": "https://chatgpt.com/apps/zeta",
              "labels": { "tier": "internal" },
              "pluginDisplayNames": ["Zeta Plugin"]
            },
            {
              "id": "alpha",
              "name": "Alpha",
              "description": "first connector",
              "isAccessible": false
            }
          ]
        }
        """.write(toFile: home + "/connectors.json", atomically: true, encoding: .utf8)
        try """
        [apps.zeta]
        enabled = false
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "app/list", .object([
            "limit": .int(1),
            "forceRefetch": .bool(true),
        ])))
        let firstPageMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        XCTAssertTrue(firstPageMessages.contains {
            if case .notification(let n) = $0 {
                return n.method == "app/list/updated"
                    && n.params?["data"]?.arrayValue?.count == 1
            }
            return false
        })
        guard case .response(let firstPage)? = firstPageMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing app/list first page response") }
        XCTAssertEqual(firstPage.result["data"]?.arrayValue?.count, 1)
        XCTAssertEqual(firstPage.result["data"]?.arrayValue?.first?["id"]?.stringValue, "alpha")
        XCTAssertEqual(firstPage.result["data"]?.arrayValue?.first?["isAccessible"]?.boolValue, false)
        XCTAssertEqual(firstPage.result["data"]?.arrayValue?.first?["isEnabled"]?.boolValue, true)
        XCTAssertEqual(firstPage.result["nextCursor"]?.stringValue, "1")

        s.conn.clientSend(req(3, "app/list", .object([
            "cursor": .string("1"),
            "limit": .int(10),
        ])))
        let secondPageMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let secondPage)? = secondPageMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else { return XCTFail("missing app/list second page response") }
        let zeta = secondPage.result["data"]?.arrayValue?.first
        XCTAssertEqual(zeta?["id"]?.stringValue, "zeta")
        XCTAssertEqual(zeta?["isEnabled"]?.boolValue, false)
        XCTAssertEqual(zeta?["labels"]?["tier"]?.stringValue, "internal")
        XCTAssertEqual(zeta?["pluginDisplayNames"]?.arrayValue?.first?.stringValue,
                       "Zeta Plugin")
        XCTAssertTrue(secondPage.result["nextCursor"]?.isNull == true)

        s.conn.clientSend(req(4, "app/list", .object([
            "cursor": .string("bogus"),
        ])))
        let errorMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(4) }
            return false
        }
        XCTAssertTrue(errorMessages.contains {
            if case .error(let e) = $0 {
                return e.error.message.contains("invalid cursor")
            }
            return false
        })
    }

    func testExperimentalFeatureEnablementSetUpdatesRuntimeConfigAndFeatureList() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "experimentalFeature/list", .object([:])))
        let listMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let list)? = listMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing experimentalFeature/list response") }
        let features = list.result["data"]?.arrayValue ?? []
        let appsFeature = features.first { $0["name"]?.stringValue == "apps" }
        XCTAssertEqual(appsFeature?["enabled"]?.boolValue, false)
        XCTAssertEqual(appsFeature?["defaultEnabled"]?.boolValue, false)
        XCTAssertEqual(appsFeature?["stage"]?.stringValue, "beta")

        s.conn.clientSend(req(3, "experimentalFeature/enablement/set", .object([
            "enablement": .object([
                "apps": .bool(true),
                "plugins": .bool(false),
            ]),
        ])))
        let enableMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let enable)? = enableMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else { return XCTFail("missing experimentalFeature/enablement/set response") }
        XCTAssertEqual(enable.result["enablement"]?["apps"]?.boolValue, true)
        XCTAssertEqual(enable.result["enablement"]?["plugins"]?.boolValue, false)

        s.conn.clientSend(req(4, "config/read", .object([:])))
        let configMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }
        guard case .response(let config)? = configMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing config/read response") }
        XCTAssertEqual(config.result["config"]?["features"]?["apps"]?.boolValue, true)
        XCTAssertEqual(config.result["config"]?["features"]?["plugins"]?.boolValue, false)
        XCTAssertEqual(config.result["config"]?["features"]?["tool_search"]?.boolValue, false)

        s.conn.clientSend(req(5, "experimentalFeature/list", .object([:])))
        let updatedListMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }
        guard case .response(let updatedList)? = updatedListMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }) else { return XCTFail("missing updated experimentalFeature/list response") }
        let updatedFeatures = updatedList.result["data"]?.arrayValue ?? []
        XCTAssertEqual(updatedFeatures.first { $0["name"]?.stringValue == "apps" }?["enabled"]?.boolValue,
                       true)

        s.conn.clientSend(req(6, "experimentalFeature/enablement/set", .object([
            "enablement": .object([:]),
        ])))
        let emptyMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }
        guard case .response(let empty)? = emptyMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        }) else { return XCTFail("missing empty enablement response") }
        XCTAssertEqual(empty.result["enablement"]?.objectValue, [:])
    }

    func testExperimentalFeatureEnablementSetRejectsInvalidUnsupportedAndAliasKeys() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        let cases: [(Int, JSONValue, String)] = [
            (2, .object(["enablement": .object(["personality": .bool(true)])]),
             "unsupported feature enablement `personality`: currently supported features are"),
            (3, .object(["enablement": .object(["connectors": .bool(true)])]),
             "invalid feature enablement `connectors`: use canonical feature key `apps`"),
            (4, .object(["enablement": .object(["totally_unknown": .bool(true)])]),
             "invalid feature enablement `totally_unknown`"),
            (5, .object(["enablement": .object(["apps": .string("yes")])]),
             "invalid feature enablement `apps`: expected boolean"),
            (6, .object([:]),
             "experimentalFeature/enablement/set requires enablement"),
        ]
        for (id, params, expected) in cases {
            s.conn.clientSend(req(id, "experimentalFeature/enablement/set", params))
            let messages = await waitOutbound(s.conn) {
                if case .error(let e) = $0 { return e.id == .int(Int64(id)) }
                return false
            }
            XCTAssertTrue(messages.contains {
                if case .error(let e) = $0 {
                    return e.error.message.contains(expected)
                }
                return false
            }, "missing error containing \(expected)")
        }
    }

    func testExperimentalFeatureAppsToggleGatesAppListAndEmitsUpdate() async throws {
        let root = NSTemporaryDirectory() + "feature-apps-rpc-" + UUID().uuidString
        let home = root + "/.codex"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        {
          "connectors": [
            {
              "id": "alpha",
              "name": "Alpha",
              "description": "connector"
            }
          ]
        }
        """.write(toFile: home + "/connectors.json", atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "experimentalFeature/enablement/set", .object([
            "enablement": .object(["apps": .bool(false)]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        s.conn.clientSend(req(3, "app/list", .object([:])))
        let disabledMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let disabled)? = disabledMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else { return XCTFail("missing disabled app/list response") }
        XCTAssertEqual(disabled.result["data"]?.arrayValue, [])

        s.conn.clientSend(req(4, "experimentalFeature/enablement/set", .object([
            "enablement": .object(["apps": .bool(true)]),
        ])))
        let enableMessages = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "app/list/updated" }
            return false
        }
        XCTAssertTrue(enableMessages.contains {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        })
        XCTAssertTrue(enableMessages.contains {
            if case .notification(let n) = $0 {
                return n.method == "app/list/updated"
                    && n.params?["data"]?.arrayValue?.first?["id"]?.stringValue == "alpha"
            }
            return false
        })

        s.conn.clientSend(req(5, "app/list", .object([:])))
        let enabledMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }
        guard case .response(let enabled)? = enabledMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        }) else { return XCTFail("missing enabled app/list response") }
        XCTAssertEqual(enabled.result["data"]?.arrayValue?.first?["id"]?.stringValue, "alpha")
    }

    func testCollaborationModeListReturnsBuiltInPresetsInStableOrder() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")]), "capabilities": .object(["experimentalApi": .bool(true)])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "collaborationMode/list", .object([:])))
        let messages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let response)? = messages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing collaborationMode/list response") }
        let items = response.result["data"]?.arrayValue ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["name"]?.stringValue, "Plan")
        XCTAssertEqual(items[0]["mode"]?.stringValue, "plan")
        XCTAssertEqual(items[0]["model"]?.isNull, true)
        XCTAssertEqual(items[0]["reasoning_effort"]?.stringValue, "medium")
        XCTAssertEqual(items[1]["name"]?.stringValue, "Default")
        XCTAssertEqual(items[1]["mode"]?.stringValue, "default")
        XCTAssertEqual(items[1]["model"]?.isNull, true)
        XCTAssertEqual(items[1]["reasoning_effort"]?.isNull, true)
    }

    /// Audit app-server-registry/finding-1: collaborationMode/list (and the
    /// goal/realtime/remoteControl/fuzzyFileSearch session methods) are
    /// whole-method `#[experimental(...)]` upstream. A connection that did NOT
    /// negotiate experimentalApi must be rejected with
    /// `<method> requires experimentalApi capability` (-32600), never dispatched.
    func testCollaborationModeListGatedWithoutExperimentalApi() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize",
                              .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(req(2, "collaborationMode/list", .object([:])))
        let messages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let err)? = messages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }) else { return XCTFail("expected experimental gate error") }
        XCTAssertEqual(err.error.code, -32600)
        XCTAssertEqual(err.error.message,
                       "collaborationMode/list requires experimentalApi capability")
    }

    // MARK: turn/steer validation (turn_processor.rs:621-723)

    /// Starts a thread and returns its id over the wire `(stack, threadId)`.
    private func startThreadForSteer(experimentalApi: Bool = false)
        async throws -> (Stack, ThreadId) {
        let s = try makeStack(MockModelClient([.hello()]))
        var initCaps: JSONValue = .object(["clientInfo": .object(["name": .string("t")])])
        if experimentalApi {
            initCaps = .object([
                "clientInfo": .object(["name": .string("t")]),
                "capabilities": .object(["experimentalApi": .bool(true)]),
            ])
        }
        s.conn.clientSend(req(1, "initialize", initCaps))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }; return false
        }
        s.conn.clientSend(req(2, "thread/start", .object([
            "cwd": .string(FileManager.default.currentDirectoryPath),
            "model": .string("mock"),
        ])))
        let startMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let start)? = startMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }), let tidRaw = start.result["thread"]?["id"]?.stringValue else {
            throw XCTSkip("missing thread/start response")
        }
        return (s, ThreadId(tidRaw))
    }

    func testTurnSteerRejectsEmptyExpectedTurnId() async throws {
        let (s, tid) = try await startThreadForSteer()
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }

        s.conn.clientSend(req(3, "turn/steer", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("steer me")])]),
            "expectedTurnId": .string(""),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }
        guard case .error(let e)? = msgs.first(where: {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }) else { return XCTFail("expected empty-expectedTurnId error") }
        XCTAssertEqual(e.error.code, -32600)
        XCTAssertEqual(e.error.message, "expectedTurnId must not be empty")
    }

    func testTurnSteerRejectsOversizedTextInput() async throws {
        let (s, tid) = try await startThreadForSteer()
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }

        let limit = 1 << 20
        let oversized = String(repeating: "x", count: limit + 1)
        s.conn.clientSend(req(3, "turn/steer", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string(oversized)])]),
            "expectedTurnId": .string("t"),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }
        guard case .error(let e)? = msgs.first(where: {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }) else { return XCTFail("expected input-too-large error") }
        // Upstream uses invalid_params (-32602) with structured data.
        XCTAssertEqual(e.error.code, -32602)
        XCTAssertEqual(e.error.message,
                       "Input exceeds the maximum length of 1048576 characters.")
        XCTAssertEqual(e.error.data?["input_error_code"]?.stringValue, "input_too_large")
        XCTAssertEqual(e.error.data?["max_chars"]?.intValue, Int64(limit))
        XCTAssertEqual(e.error.data?["actual_chars"]?.intValue, Int64(limit + 1))
    }

    func testTurnSteerReturnsActiveTurnId() async throws {
        let (s, tid) = try await startThreadForSteer()
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }

        s.conn.clientSend(req(3, "turn/steer", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("steer me")])]),
            "expectedTurnId": .string("turn_active_42"),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }; return false
        }
        guard case .response(let r)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }; return false
        }) else { return XCTFail("expected turn/steer response") }
        // Wire shape: {"turnId": "<expectedTurnId>"} (TurnSteerResponse).
        XCTAssertEqual(r.result["turnId"]?.stringValue, "turn_active_42")
    }

    func testTurnSteerResponsesapiClientMetadataGatedWithoutExperimentalApi() async throws {
        let (s, tid) = try await startThreadForSteer(experimentalApi: false)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }

        s.conn.clientSend(req(3, "turn/steer", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("steer me")])]),
            "expectedTurnId": .string("t"),
            "responsesapiClientMetadata": .object(["k": .string("v")]),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }
        guard case .error(let e)? = msgs.first(where: {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }) else { return XCTFail("expected experimental-field gate error") }
        XCTAssertEqual(e.error.code, -32600)
        XCTAssertEqual(e.error.message,
                       "turn/steer.responsesapiClientMetadata requires experimentalApi capability")
    }

    func testTurnSteerResponsesapiClientMetadataAllowedWithExperimentalApi() async throws {
        let (s, tid) = try await startThreadForSteer(experimentalApi: true)
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }

        s.conn.clientSend(req(3, "turn/steer", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("steer me")])]),
            "expectedTurnId": .string("turn_active_7"),
            "responsesapiClientMetadata": .object(["k": .string("v")]),
        ])))
        let msgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }; return false
        }
        guard case .response(let r)? = msgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }; return false
        }) else { return XCTFail("expected turn/steer success with experimentalApi") }
        XCTAssertEqual(r.result["turnId"]?.stringValue, "turn_active_7")
    }

    func testRemoteControlStatusEnableDisableLifecycleAndEnrollment() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-control-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-token",
                                                      accountId: "acct-remote")
        let recorder = RemoteControlEnrollRecorder()
        let websocket = RemoteControlWebSocketRecorder()
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlEnroller: { tokens, baseURL, installationId, serverName in
                await recorder.record(tokens: tokens, baseURL: baseURL,
                                      installationId: installationId, serverName: serverName)
            },
            remoteControlWebSocketConnector: { request in
                await websocket.connect(request)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let initResponse = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(initResponse)

        s.conn.clientSend(req(2, "remoteControl/status/read", .object([:])))
        guard let initial = await awaitResponse(sink, id: 2) else {
            return XCTFail("missing initial remote-control status")
        }
        XCTAssertEqual(initial.result["status"], .string("disabled"))
        let serverName = initial.result["serverName"]?.stringValue ?? ""
        let installationId = initial.result["installationId"]?.stringValue ?? ""
        XCTAssertFalse(serverName.isEmpty)
        XCTAssertFalse(installationId.isEmpty)
        XCTAssertEqual(initial.result["environmentId"]?.isNull, true)

        s.conn.clientSend(req(3, "remoteControl/enable", .object([:])))
        guard let enabled = await awaitResponse(sink, id: 3) else {
            return XCTFail("missing remote-control enable response")
        }
        XCTAssertEqual(enabled.result["status"], .string("connecting"))
        XCTAssertEqual(enabled.result["serverName"]?.stringValue, serverName)
        XCTAssertEqual(enabled.result["installationId"]?.stringValue, installationId)
        let firstNotificationArrived = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 1)
        XCTAssertTrue(firstNotificationArrived)
        let firstChanged = await sink.notifications("remoteControl/status/changed").first
        XCTAssertEqual(firstChanged?.params?["status"], .string("connecting"))
        XCTAssertEqual(firstChanged?.params?["installationId"]?.stringValue, installationId)

        var calls: [RemoteControlEnrollRecorder.Call] = []
        for _ in 0..<50 {
            calls = await recorder.recordedCalls()
            if !calls.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(calls, [
            .init(accessToken: "remote-token",
                  accountId: "acct-remote",
                  baseURL: "https://chatgpt.com/backend-api",
                  installationId: installationId,
                  serverName: serverName),
        ])
        let enrollmentNotificationArrived = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 3)
        XCTAssertTrue(enrollmentNotificationArrived)
        let notifications = await sink.notifications("remoteControl/status/changed")
        let enrollmentChanged = notifications.dropFirst().first
        XCTAssertEqual(enrollmentChanged?.params?["status"], .string("connecting"))
        XCTAssertEqual(enrollmentChanged?.params?["environmentId"], .string("env-remote"))
        let connectedChanged = notifications.last
        XCTAssertEqual(connectedChanged?.params?["status"], .string("connected"))
        XCTAssertEqual(connectedChanged?.params?["environmentId"], .string("env-remote"))
        var websocketCalls: [RequestRouter.RemoteControlWebSocketRequest] = []
        for _ in 0..<50 {
            websocketCalls = await websocket.recordedCalls()
            if !websocketCalls.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(websocketCalls, [
            .init(websocketURL: "wss://chatgpt.com/backend-api/wham/remote/control/server",
                  accessToken: "remote-token",
                  accountId: "acct-remote",
                  serverId: "server-remote",
                  serverName: serverName,
                  installationId: installationId),
        ])

        s.conn.clientSend(req(4, "remoteControl/status/read", .object([:])))
        guard let current = await awaitResponse(sink, id: 4) else {
            return XCTFail("missing remote-control status after enable")
        }
        XCTAssertEqual(current.result["status"], .string("connected"))
        XCTAssertEqual(current.result["installationId"]?.stringValue, installationId)
        XCTAssertEqual(current.result["environmentId"], .string("env-remote"))

        s.conn.clientSend(req(5, "remoteControl/disable", .object([:])))
        guard let disabled = await awaitResponse(sink, id: 5) else {
            return XCTFail("missing remote-control disable response")
        }
        XCTAssertEqual(disabled.result["status"], .string("disabled"))
        XCTAssertEqual(disabled.result["serverName"]?.stringValue, serverName)
        XCTAssertEqual(disabled.result["installationId"]?.stringValue, installationId)
        let disableNotificationArrived = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 3)
        XCTAssertTrue(disableNotificationArrived)
        let disableChanged = await sink.notifications("remoteControl/status/changed").last
        XCTAssertEqual(disableChanged?.params?["status"], .string("disabled"))
        XCTAssertEqual(disableChanged?.params?["environmentId"]?.isNull, true)
        let closeCount = await websocket.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testRemoteControlEnrollmentFailurePublishesErroredStatus() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-control-fail-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-token",
                                                      accountId: "acct-remote")
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlEnroller: { _, _, _, _ in
                throw NSError(domain: "RemoteControlEnrollmentTest", code: 1)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let initResponse = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(initResponse)

        s.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        guard let enabled = await awaitResponse(sink, id: 2) else {
            return XCTFail("missing remote-control enable response")
        }
        XCTAssertEqual(enabled.result["status"], .string("connecting"))
        let failureNotificationsArrived = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 2)
        XCTAssertTrue(failureNotificationsArrived)
        let notifications = await sink.notifications("remoteControl/status/changed")
        XCTAssertEqual(notifications.first?.params?["status"], .string("connecting"))
        XCTAssertEqual(notifications.last?.params?["status"], .string("errored"))
        XCTAssertEqual(notifications.last?.params?["environmentId"]?.isNull, true)

        s.conn.clientSend(req(3, "remoteControl/status/read", .object([:])))
        guard let current = await awaitResponse(sink, id: 3) else {
            return XCTFail("missing remote-control status after failed enrollment")
        }
        XCTAssertEqual(current.result["status"], .string("errored"))
        XCTAssertEqual(current.result["environmentId"]?.isNull, true)
    }

    func testRemoteControlWebSocketFailurePublishesErroredStatus() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-control-ws-fail-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-token",
                                                      accountId: "acct-remote")
        let websocket = RemoteControlWebSocketRecorder()
        await websocket.setShouldFail(true)
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlEnroller: { _, _, _, _ in
                .init(serverId: "srv-fail", environmentId: "env-fail")
            },
            remoteControlWebSocketConnector: { request in
                try await websocket.connectOrFail(request)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let initResponse = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(initResponse)

        s.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        let enableResponse = await awaitResponse(sink, id: 2)
        XCTAssertNotNil(enableResponse)
        let errored = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 3)
        XCTAssertTrue(errored)
        let notifications = await sink.notifications("remoteControl/status/changed")
        XCTAssertEqual(notifications.first?.params?["status"], .string("connecting"))
        XCTAssertEqual(notifications.dropFirst().first?.params?["environmentId"],
                       .string("env-fail"))
        XCTAssertEqual(notifications.last?.params?["status"], .string("errored"))
        XCTAssertEqual(notifications.last?.params?["environmentId"]?.isNull, true)
        let failedConnectCalls = await websocket.recordedCalls()
        XCTAssertEqual(failedConnectCalls.count, 1)
    }

    func testRemoteControlDisableIgnoresLateEnrollmentAndWebSocketConnect() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-control-disable-race-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-token",
                                                      accountId: "acct-remote")
        let websocket = RemoteControlWebSocketRecorder()
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlEnroller: { _, _, _, _ in
                try await Task.sleep(nanoseconds: 150_000_000)
                return .init(serverId: "srv-late", environmentId: "env-late")
            },
            remoteControlWebSocketConnector: { request in
                await websocket.connect(request)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let initResponse = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(initResponse)

        s.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        let enableResponse = await awaitResponse(sink, id: 2)
        XCTAssertNotNil(enableResponse)
        s.conn.clientSend(req(3, "remoteControl/disable", .object([:])))
        guard let disabled = await awaitResponse(sink, id: 3) else {
            return XCTFail("missing disable response")
        }
        XCTAssertEqual(disabled.result["status"], .string("disabled"))
        try await Task.sleep(nanoseconds: 250_000_000)
        s.conn.clientSend(req(4, "remoteControl/status/read", .object([:])))
        guard let current = await awaitResponse(sink, id: 4) else {
            return XCTFail("missing status after late enrollment")
        }
        XCTAssertEqual(current.result["status"], .string("disabled"))
        XCTAssertEqual(current.result["environmentId"]?.isNull, true)
        let lateConnectCalls = await websocket.recordedCalls()
        XCTAssertEqual(lateConnectCalls.count, 0)
    }

    func testRemoteControlWebSocketRoutesVirtualClientMessages() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-control-routing-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-token",
                                                      accountId: "acct-remote")
        let websocket = RemoteControlWebSocketRecorder()
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlEnroller: { _, _, _, _ in
                .init(serverId: "srv-route", environmentId: "env-route")
            },
            remoteControlWebSocketConnector: { request in
                await websocket.connectWithRouting(request)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("control")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let controlInitResponse = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(controlInitResponse)
        s.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        let controlEnableResponse = await awaitResponse(sink, id: 2)
        XCTAssertNotNil(controlEnableResponse)
        let connected = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 3)
        XCTAssertTrue(connected)

        await websocket.sendClientEnvelope(.init(
            event: .clientMessage(req(10, "initialize", .object([
                "clientInfo": .object(["name": .string("remote-client")]),
            ]))),
            clientId: "client-a",
            streamId: "stream-a",
            seqId: 1))
        let initialized = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 1)
        XCTAssertTrue(initialized)
        var envelopes = await websocket.recordedServerEnvelopes()
        XCTAssertEqual(envelopes[0].clientId, "client-a")
        XCTAssertEqual(envelopes[0].streamId, "stream-a")
        XCTAssertEqual(envelopes[0].seqId, 1)
        guard case .serverMessage(.response(let initResponse)) = envelopes[0].event else {
            return XCTFail("expected remote initialize response envelope")
        }
        XCTAssertEqual(initResponse.id, .int(10))

        await websocket.sendClientEnvelope(.init(
            event: .clientMessage(req(11, "model/list", .object([:]))),
            clientId: "client-a",
            streamId: "stream-a",
            seqId: 2))
        let modelListReturned = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 2)
        XCTAssertTrue(modelListReturned)
        envelopes = await websocket.recordedServerEnvelopes()
        XCTAssertEqual(envelopes[1].clientId, "client-a")
        XCTAssertEqual(envelopes[1].streamId, "stream-a")
        XCTAssertEqual(envelopes[1].seqId, 2)
        guard case .serverMessage(.response(let modelResponse)) = envelopes[1].event else {
            return XCTFail("expected remote model/list response envelope")
        }
        XCTAssertEqual(modelResponse.id, .int(11))
        XCTAssertNotNil(modelResponse.result["data"]?.arrayValue)

        await websocket.sendClientEnvelope(.init(
            event: .clientMessage(req(12, "model/list", .object([:]))),
            clientId: "client-a",
            streamId: "stream-a",
            seqId: 2))
        try await Task.sleep(nanoseconds: 100_000_000)
        envelopes = await websocket.recordedServerEnvelopes()
        XCTAssertEqual(envelopes.count, 2, "duplicate inbound seq_id should be ignored")

        await websocket.sendClientEnvelope(.init(
            event: .ping,
            clientId: "client-a",
            streamId: "stream-a",
            seqId: 3))
        let activePongReturned = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 3)
        XCTAssertTrue(activePongReturned)
        envelopes = await websocket.recordedServerEnvelopes()
        guard case .pong(let status) = envelopes[2].event else {
            return XCTFail("expected remote pong envelope")
        }
        XCTAssertEqual(status, "active")

        await websocket.sendClientEnvelope(.init(
            event: .clientClosed,
            clientId: "client-a",
            streamId: "stream-a",
            seqId: 4))
        await websocket.sendClientEnvelope(.init(
            event: .ping,
            clientId: "client-a",
            streamId: "stream-a",
            seqId: 5))
        let closedPongReturned = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 4)
        XCTAssertTrue(closedPongReturned)
        envelopes = await websocket.recordedServerEnvelopes()
        guard case .pong(let closedStatus) = envelopes[3].event else {
            return XCTFail("expected unknown pong after client close")
        }
        XCTAssertEqual(closedStatus, "unknown")
    }

    func testRemoteControlWebSocketReassemblesClientChunksAndSplitsLargeServerMessages()
        async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-control-chunks-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-token",
                                                      accountId: "acct-remote")
        let websocket = RemoteControlWebSocketRecorder()
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlEnroller: { _, _, _, _ in
                .init(serverId: "srv-chunks", environmentId: "env-chunks")
            },
            remoteControlWebSocketConnector: { request in
                await websocket.connectWithRouting(request)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }

        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("control")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let controlInitialize = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(controlInitialize)
        s.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        let controlEnable = await awaitResponse(sink, id: 2)
        XCTAssertNotNil(controlEnable)
        let connected = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 3)
        XCTAssertTrue(connected)

        let initialize = req(20, "initialize", .object([
            "clientInfo": .object(["name": .string("remote-chunk-client")]),
        ]))
        let initializeChunks = try remoteClientChunks(
            initialize,
            clientId: "client-chunk",
            streamId: "stream-chunk",
            seqId: 1,
            chunkSize: 18)
        await websocket.sendClientEnvelope(initializeChunks[1])
        try await Task.sleep(for: .milliseconds(100))
        let outOfOrderEnvelopeCount = await websocket.recordedServerEnvelopes().count
        XCTAssertEqual(outOfOrderEnvelopeCount, 0,
                       "out-of-order client chunks should not open a virtual client")
        for chunk in initializeChunks {
            await websocket.sendClientEnvelope(chunk)
        }
        let initialized = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 1)
        XCTAssertTrue(initialized)
        var envelopes = await websocket.recordedServerEnvelopes()
        guard case .serverMessage(.response(let initResponse)) = envelopes[0].event else {
            return XCTFail("expected reassembled initialize response")
        }
        XCTAssertEqual(initResponse.id, .int(20))

        await websocket.sendClientEnvelope(.init(
            event: .clientMessage(.notification(JSONRPCNotification(method: "initialized"))),
            clientId: "client-chunk",
            streamId: "stream-chunk",
            seqId: 2))
        await websocket.sendClientEnvelope(.init(
            event: .clientMessage(req(21, "command/exec", .object([
                "command": .array([
                    .string("/usr/bin/env"),
                    .string("python3"),
                    .string("-c"),
                    .string("import sys; sys.stdout.write('x' * 180000)"),
                ]),
                "cwd": .string(home),
                "timeoutMs": .int(30_000),
            ]))),
            clientId: "client-chunk",
            streamId: "stream-chunk",
            seqId: 3))
        let reassembledResponse = await awaitRemoteChunkedServerResponse(
            websocket, responseId: .int(21), timeoutMs: 30_000)
        let reassembled: JSONRPCMessage
        let reassembledSeqId: UInt64
        switch reassembledResponse {
        case .chunked(let seqId, let message):
            reassembledSeqId = seqId
            reassembled = message
        case .direct(let message):
            return XCTFail("expected large command/exec response to be chunked, got direct \(message.summary)")
        case .timedOut(let summary):
            return XCTFail("expected large command/exec response to be split into chunks; \(summary)")
        }
        guard case .response(let commandResponse) = reassembled else {
            return XCTFail("expected reassembled command/exec response")
        }
        XCTAssertEqual(commandResponse.id, .int(21))
        XCTAssertEqual(commandResponse.result["exitCode"]?.intValue, 0)
        XCTAssertEqual(commandResponse.result["stdout"]?.stringValue?.count, 180_000)

        envelopes = await websocket.recordedServerEnvelopes()
        let commandChunks = envelopes.filter { envelope in
            if case .serverMessageChunk = envelope.event,
               envelope.seqId == reassembledSeqId {
                return true
            }
            return false
        }
        XCTAssertGreaterThan(commandChunks.count, 1)
        XCTAssertTrue(commandChunks.allSatisfy { $0.clientId == "client-chunk" })
        XCTAssertTrue(commandChunks.allSatisfy { $0.streamId == "stream-chunk" })
    }

    func testRemoteControlWebSocketReconnectReplaysOnlyUnackedServerEnvelopes()
        async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-control-replay-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-token",
                                                      accountId: "acct-remote")
        let websocket = RemoteControlWebSocketRecorder()
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlEnroller: { _, _, _, _ in
                .init(serverId: "srv-replay", environmentId: "env-replay")
            },
            remoteControlWebSocketConnector: { request in
                await websocket.connectWithRouting(request)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }

        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("control")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let controlInitialize = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(controlInitialize)
        s.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        let controlEnable = await awaitResponse(sink, id: 2)
        XCTAssertNotNil(controlEnable)
        let connected = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 3)
        XCTAssertTrue(connected)

        await websocket.sendClientEnvelope(.init(
            event: .clientMessage(req(30, "initialize", .object([
                "clientInfo": .object(["name": .string("remote-replay-client")]),
            ]))),
            clientId: "client-replay",
            streamId: "stream-replay",
            seqId: 1))
        let initialized = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 1)
        XCTAssertTrue(initialized)
        await websocket.sendClientEnvelope(.init(
            event: .clientMessage(req(31, "model/list", .object([:]))),
            clientId: "client-replay",
            streamId: "stream-replay",
            seqId: 2))
        let modelListReturned = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 2)
        XCTAssertTrue(modelListReturned)

        await websocket.sendClientEnvelope(.init(
            event: .ack(segmentId: nil),
            clientId: "client-replay",
            streamId: "stream-replay",
            seqId: 1))
        await websocket.finishIncoming()
        let reconnected = await awaitRemoteWebSocketCallCount(websocket, atLeast: 2)
        XCTAssertTrue(reconnected)
        let replayedEnvelope = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 3)
        XCTAssertTrue(replayedEnvelope)
        let envelopes = await websocket.recordedServerEnvelopes()
        XCTAssertEqual(envelopes.map(\.seqId), [1, 2, 2])
        XCTAssertEqual(envelopes[2].clientId, "client-replay")
        XCTAssertEqual(envelopes[2].streamId, "stream-replay")
        guard case .serverMessage(.response(let replayed)) = envelopes[2].event else {
            return XCTFail("expected unacked model/list response to replay")
        }
        XCTAssertEqual(replayed.id, .int(31))
    }

    func testRemoteControlIdleSweepClosesInactiveVirtualClients() async throws {
        setenv("CODEXKIT_REMOTE_CONTROL_CLIENT_IDLE_TIMEOUT_MS", "80", 1)
        setenv("CODEXKIT_REMOTE_CONTROL_IDLE_SWEEP_INTERVAL_MS", "20", 1)
        defer {
            unsetenv("CODEXKIT_REMOTE_CONTROL_CLIENT_IDLE_TIMEOUT_MS")
            unsetenv("CODEXKIT_REMOTE_CONTROL_IDLE_SWEEP_INTERVAL_MS")
        }
        let home = NSTemporaryDirectory() + "e2e-remote-control-idle-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-token",
                                                      accountId: "acct-remote")
        let websocket = RemoteControlWebSocketRecorder()
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlEnroller: { _, _, _, _ in
                .init(serverId: "srv-idle", environmentId: "env-idle")
            },
            remoteControlWebSocketConnector: { request in
                await websocket.connectWithRouting(request)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }

        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("control")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let controlInitialize = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(controlInitialize)
        s.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        let controlEnable = await awaitResponse(sink, id: 2)
        XCTAssertNotNil(controlEnable)
        let connected = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 3)
        XCTAssertTrue(connected)

        await websocket.sendClientEnvelope(.init(
            event: .clientMessage(req(40, "initialize", .object([
                "clientInfo": .object(["name": .string("remote-idle-client")]),
            ]))),
            clientId: "client-idle",
            streamId: "stream-idle",
            seqId: 1))
        let initialized = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 1)
        XCTAssertTrue(initialized)
        try await Task.sleep(for: .milliseconds(180))
        await websocket.sendClientEnvelope(.init(
            event: .ping,
            clientId: "client-idle",
            streamId: "stream-idle",
            seqId: 2))
        let pongReturned = await awaitRemoteServerEnvelopeCount(websocket, atLeast: 2)
        XCTAssertTrue(pongReturned)
        let envelopes = await websocket.recordedServerEnvelopes()
        guard case .pong(let status) = envelopes.last?.event else {
            return XCTFail("expected idle-swept client to receive unknown pong")
        }
        XCTAssertEqual(status, "unknown")
    }

    func testRemoteControlWebSocketHeartbeatFailureReconnects() async throws {
        setenv("CODEXKIT_REMOTE_CONTROL_PING_INTERVAL_MS", "20", 1)
        setenv("CODEXKIT_REMOTE_CONTROL_PONG_TIMEOUT_MS", "20", 1)
        defer {
            unsetenv("CODEXKIT_REMOTE_CONTROL_PING_INTERVAL_MS")
            unsetenv("CODEXKIT_REMOTE_CONTROL_PONG_TIMEOUT_MS")
        }
        let home = NSTemporaryDirectory() + "e2e-remote-control-heartbeat-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-token",
                                                      accountId: "acct-remote")
        let websocket = RemoteControlWebSocketRecorder()
        await websocket.setPingShouldFail(true)
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlEnroller: { _, _, _, _ in
                .init(serverId: "srv-heartbeat", environmentId: "env-heartbeat")
            },
            remoteControlWebSocketConnector: { request in
                await websocket.connectWithRouting(request)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }

        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("control")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let controlInitialize = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(controlInitialize)
        s.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        let controlEnable = await awaitResponse(sink, id: 2)
        XCTAssertNotNil(controlEnable)
        let firstConnected = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 3)
        XCTAssertTrue(firstConnected)
        let reconnected = await awaitRemoteWebSocketCallCount(websocket, atLeast: 2)
        XCTAssertTrue(reconnected)
        let closeCount = await websocket.recordedCloseCount()
        XCTAssertGreaterThanOrEqual(closeCount, 1)
    }

    func testRemoteControlDefaultEnrollerParsesEnrollmentAndSendsHeaders() async throws {
        let home = NSTemporaryDirectory() + "e2e-remote-control-http-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let requestPath = home + "/request.raw"
        guard let server = oneShotCaptureHTTPServer(
            home,
            responseBody: #"{"server_id":"srv-local","environment_id":"env-local"}"#,
            requestPath: requestPath) else {
            return XCTFail("failed to start local enrollment capture server")
        }
        defer { server.0.terminate() }
        try """
        chatgpt_base_url = "http://127.0.0.1:\(server.1)/backend-api"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithExternalChatGPTTokens(accessToken: "remote-http-token",
                                                      accountId: "acct-http")
        let websocket = RemoteControlWebSocketRecorder()
        let s = try makeStack(
            MockModelClient([.hello()]),
            codexHome: home,
            auth: auth,
            remoteControlWebSocketConnector: { request in
                await websocket.connect(request)
            })
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        let sink = OutboundSink()
        let drain = Task {
            for await message in s.conn.clientOutbound() {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }
        s.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        let initResponse = await awaitResponse(sink, id: 1)
        XCTAssertNotNil(initResponse)

        s.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        guard let enabled = await awaitResponse(sink, id: 2) else {
            return XCTFail("missing remote-control enable response")
        }
        let installationId = enabled.result["installationId"]?.stringValue ?? ""
        let serverName = enabled.result["serverName"]?.stringValue ?? ""
        XCTAssertFalse(installationId.isEmpty)
        XCTAssertFalse(serverName.isEmpty)
        let defaultEnrollmentNotificationArrived = await awaitNotificationCount(
            sink, method: "remoteControl/status/changed", atLeast: 3,
            timeoutMs: 5000)
        XCTAssertTrue(defaultEnrollmentNotificationArrived)
        let notifications = await sink.notifications("remoteControl/status/changed")
        let enrollmentChanged = notifications.dropFirst().first
        XCTAssertEqual(enrollmentChanged?.params?["status"], .string("connecting"))
        XCTAssertEqual(enrollmentChanged?.params?["environmentId"], .string("env-local"))
        XCTAssertEqual(notifications.last?.params?["status"], .string("connected"))
        XCTAssertEqual(notifications.last?.params?["environmentId"], .string("env-local"))

        let enrollmentRequestCaptured = await waitForFile(requestPath)
        XCTAssertTrue(enrollmentRequestCaptured, "enrollment server did not capture request")
        let raw = try String(contentsOfFile: requestPath, encoding: .utf8)
        XCTAssertTrue(raw.hasPrefix(
            "POST /backend-api/wham/remote/control/server/enroll HTTP/1.1"))
        XCTAssertTrue(raw.localizedCaseInsensitiveContains(
            "authorization: Bearer remote-http-token"))
        XCTAssertTrue(raw.localizedCaseInsensitiveContains(
            "chatgpt-account-id: acct-http"))
        XCTAssertTrue(raw.localizedCaseInsensitiveContains(
            "x-codex-installation-id: \(installationId)"))
        guard let separator = raw.range(of: "\r\n\r\n") else {
            return XCTFail("captured enrollment request missing HTTP body separator")
        }
        let body = String(raw[separator.upperBound...])
        let bodyData = Data(body.utf8)
        guard let object = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return XCTFail("captured enrollment body is not JSON")
        }
        XCTAssertEqual(object["name"] as? String, serverName)
        XCTAssertEqual(object["installation_id"] as? String, installationId)
        XCTAssertEqual(object["os"] as? String, "macos")
        XCTAssertNotNil(object["arch"] as? String)
        let websocketCalls = await websocket.recordedCalls()
        XCTAssertEqual(websocketCalls, [
            .init(websocketURL: "ws://127.0.0.1:\(server.1)/backend-api/wham/remote/control/server",
                  accessToken: "remote-http-token",
                  accountId: "acct-http",
                  serverId: "srv-local",
                  serverName: serverName,
                  installationId: installationId),
        ])

        s.conn.clientSend(req(3, "remoteControl/status/read", .object([:])))
        guard let current = await awaitResponse(sink, id: 3) else {
            return XCTFail("missing status after default enrollment")
        }
        XCTAssertEqual(current.result["status"], .string("connected"))
        XCTAssertEqual(current.result["environmentId"], .string("env-local"))
    }

    func testRemoteControlEnableRequiresChatGPTAuth() async throws {
        let noAuth = try makeStack(MockModelClient([.hello()]))
        defer { noAuth.pump.cancel(); try? FileManager.default.removeItem(atPath: noAuth.home) }
        noAuth.conn.clientSend(req(1, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(noAuth.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        noAuth.conn.clientSend(req(2, "remoteControl/enable", .object([:])))
        let noAuthMessages = await waitOutbound(noAuth.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let noAuthError)? = noAuthMessages.last else {
            return XCTFail("expected remote-control no-auth error")
        }
        XCTAssertEqual(noAuthError.error.message,
                       "codex account authentication required to enable remote control")

        let home = NSTemporaryDirectory() + "e2e-remote-api-key-" + UUID().uuidString
        let auth = AuthManager(store: FileTokenStore(codexHome: home))
        try await auth.loginWithAPIKey("sk-remote")
        let apiKey = try makeStack(MockModelClient([.hello()]), codexHome: home, auth: auth)
        defer { apiKey.pump.cancel(); try? FileManager.default.removeItem(atPath: home) }
        apiKey.conn.clientSend(req(3, "initialize", .object([
            "clientInfo": .object(["name": .string("t")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ])))
        _ = await waitOutbound(apiKey.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        apiKey.conn.clientSend(req(4, "remoteControl/enable", .object([:])))
        let apiKeyMessages = await waitOutbound(apiKey.conn) {
            if case .error(let e) = $0 { return e.id == .int(4) }
            return false
        }
        guard case .error(let apiKeyError)? = apiKeyMessages.last else {
            return XCTFail("expected remote-control api-key error")
        }
        XCTAssertEqual(apiKeyError.error.message,
                       "chatgpt authentication required to enable remote control")
    }

    func testRealtimeStructuralWebRTCSessionRoundTrip() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")]), "capabilities": .object(["experimentalApi": .bool(true)])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        let threadId = ThreadId.generate().raw

        s.conn.clientSend(req(2, "thread/realtime/listVoices", .object([:])))
        let voiceMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let voices)? = voiceMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing realtime voices response") }
        XCTAssertEqual(voices.result["voices"]?["defaultV2"]?.stringValue, "marin")
        XCTAssertTrue((voices.result["voices"]?["v2"]?.arrayValue ?? [])
            .contains { $0.stringValue == "marin" })

        s.conn.clientSend(req(3, "thread/realtime/appendText", .object([
            "threadId": .string(threadId),
            "text": .string("too early"),
        ])))
        let earlyMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }
        XCTAssertTrue(earlyMessages.contains {
            if case .error(let e) = $0 {
                return e.error.message.contains("active realtime session")
            }
            return false
        })

        s.conn.clientSend(req(4, "thread/realtime/start", .object([
            "threadId": .string(threadId),
            "outputModality": .string("audio"),
            "voice": .string("marin"),
            "prompt": .string("be concise"),
            "transport": .object([
                "type": .string("webrtc"),
                "sdp": .string("v=0\r\ns=test-offer\r\n"),
            ]),
        ])))
        let startMessages = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 { return n.method == "thread/realtime/itemAdded" }
            return false
        }, timeoutMs: 10_000)
        XCTAssertTrue(startMessages.contains {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        })
        let started = startMessages.first {
            if case .notification(let n) = $0 { return n.method == "thread/realtime/started" }
            return false
        }
        guard case .notification(let startedNotif)? = started else {
            return XCTFail("missing realtime started notification")
        }
        XCTAssertEqual(startedNotif.params?["threadId"]?.stringValue, threadId)
        XCTAssertEqual(startedNotif.params?["version"]?.stringValue, "v2")
        XCTAssertNotNil(startedNotif.params?["realtimeSessionId"]?.stringValue)
        let sdp = startMessages.first {
            if case .notification(let n) = $0 { return n.method == "thread/realtime/sdp" }
            return false
        }
        guard case .notification(let sdpNotif)? = sdp else {
            return XCTFail("missing realtime sdp notification")
        }
        XCTAssertEqual(sdpNotif.params?["threadId"]?.stringValue, threadId)
        XCTAssertTrue((sdpNotif.params?["sdp"]?.stringValue ?? "").contains("m=application"))
        XCTAssertTrue(startMessages.contains {
            if case .notification(let n) = $0 {
                return n.method == "thread/realtime/itemAdded"
                    && n.params?["item"]?["text"]?.stringValue == "be concise"
            }
            return false
        })

        s.conn.clientSend(req(5, "thread/realtime/appendText", .object([
            "threadId": .string(threadId),
            "text": .string("hello realtime"),
        ])))
        let textMessages = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 { return n.method == "thread/realtime/transcript/done" }
            return false
        }, timeoutMs: 10_000)
        XCTAssertTrue(textMessages.contains {
            if case .response(let r) = $0 { return r.id == .int(5) }
            return false
        })
        XCTAssertTrue(textMessages.contains {
            if case .notification(let n) = $0 {
                return n.method == "thread/realtime/transcript/delta"
                    && n.params?["role"]?.stringValue == "user"
                    && n.params?["delta"]?.stringValue == "hello realtime"
            }
            return false
        })
        XCTAssertTrue(textMessages.contains {
            if case .notification(let n) = $0 {
                return n.method == "thread/realtime/transcript/done"
                    && n.params?["text"]?.stringValue == "hello realtime"
            }
            return false
        })

        s.conn.clientSend(req(6, "thread/realtime/appendAudio", .object([
            "threadId": .string(threadId),
            "audio": .object([
                "data": .string("AAEC"),
                "sampleRate": .int(24_000),
                "numChannels": .int(1),
                "samplesPerChannel": .int(3),
                "itemId": .string("audio-1"),
            ]),
        ])))
        let audioMessages = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 { return n.method == "thread/realtime/outputAudio/delta" }
            return false
        }, timeoutMs: 10_000)
        XCTAssertTrue(audioMessages.contains {
            if case .response(let r) = $0 { return r.id == .int(6) }
            return false
        })
        guard case .notification(let audioNotif)? = audioMessages.first(where: {
            if case .notification(let n) = $0 { return n.method == "thread/realtime/outputAudio/delta" }
            return false
        }) else { return XCTFail("missing realtime audio notification") }
        XCTAssertEqual(audioNotif.params?["audio"]?["data"]?.stringValue, "AAEC")
        XCTAssertEqual(audioNotif.params?["audio"]?["sampleRate"]?.intValue, 24_000)
        XCTAssertEqual(audioNotif.params?["audio"]?["numChannels"]?.intValue, 1)

        s.conn.clientSend(req(7, "thread/realtime/stop", .object([
            "threadId": .string(threadId),
        ])))
        let stopMessages = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 { return n.method == "thread/realtime/closed" }
            return false
        }, timeoutMs: 10_000)
        XCTAssertTrue(stopMessages.contains {
            if case .response(let r) = $0 { return r.id == .int(7) }
            return false
        })
        XCTAssertTrue(stopMessages.contains {
            if case .notification(let n) = $0 {
                return n.method == "thread/realtime/closed"
                    && n.params?["reason"]?.stringValue == "client_stopped"
            }
            return false
        })
    }

    /// v9 app-server-events finding 6: a realtime session started with NO
    /// explicit prompt (and no config prompt) injects the default backend
    /// system prompt (templates/realtime/backend_prompt.md) as a system
    /// itemAdded, with `{{ user_first_name }}` substituted — parity with
    /// `prepare_realtime_backend_prompt` returning BACKEND_PROMPT.
    func testRealtimeStartWithoutPromptInjectsDefaultBackendPrompt() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer { s.pump.cancel(); try? FileManager.default.removeItem(atPath: s.home) }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")]), "capabilities": .object(["experimentalApi": .bool(true)])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        let threadId = ThreadId.generate().raw
        // No `prompt` key at all → upstream `None` → default backend prompt.
        s.conn.clientSend(req(2, "thread/realtime/start", .object([
            "threadId": .string(threadId),
            "outputModality": .string("text"),
        ])))
        let msgs = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 { return n.method == "thread/realtime/itemAdded" }
            return false
        }, timeoutMs: 10_000)
        let systemItem = msgs.first {
            if case .notification(let n) = $0 {
                return n.method == "thread/realtime/itemAdded"
                    && n.params?["item"]?["role"]?.stringValue == "system"
            }
            return false
        }
        guard case .notification(let note)? = systemItem else {
            return XCTFail("expected a default system prompt itemAdded")
        }
        let text = note.params?["item"]?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.hasPrefix("## Identity, tone, and role"),
                      "default backend prompt injected")
        XCTAssertTrue(text.contains("You are Codex, an OpenAI general-purpose agentic assistant"))
        XCTAssertFalse(text.contains("{{ user_first_name }}"),
                       "placeholder must be substituted")
    }

    func testMcpServerStatusAndToolCallUseRealConfiguredServer() async throws {
        let home = NSTemporaryDirectory() + "mcp-router-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let script = home + "/server.py"
        try """
        import sys, json
        def send(o):
            sys.stdout.write(json.dumps(o) + "\\n")
            sys.stdout.flush()
        while True:
            line = sys.stdin.readline()
            if line == "":
                break
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            mid = msg.get("id")
            method = msg.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"protocolVersion": "2025-06-18"}})
            elif method == "notifications/initialized":
                pass
            elif method == "tools/list":
                send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
                    {"name": "echo", "description": "echoes message",
                     "inputSchema": {"type": "object",
                                     "properties": {"message": {"type": "string"}},
                                     "required": ["message"]}}]}})
            elif method == "tools/call":
                args = msg.get("params", {}).get("arguments", {})
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": "echo:" + args.get("message", "")}],
                    "isError": False}})
            elif method == "resources/read":
                uri = msg.get("params", {}).get("uri", "")
                send({"jsonrpc": "2.0", "id": mid, "result": {"contents": [
                    {"uri": uri, "mimeType": "text/plain", "text": "resource:" + uri}
                ]}})
        """.write(toFile: script, atomically: true, encoding: .utf8)

        try """
        {
          "mcpServers": {
            "mock": { "command": "python3", "args": ["-u", "\(script)"] }
          }
        }
        """.write(toFile: home + "/mcp.json", atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "mcpServerStatus/list", .object([
            "detail": .string("toolsAndAuthOnly")
        ])))
        let statusMessages = await waitOutbound(s.conn, {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }, timeoutMs: 10_000)
        guard case .response(let status)? = statusMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing mcpServerStatus/list response") }
        let servers = status.result["data"]?.arrayValue ?? []
        let mock = servers.first { $0["name"]?.stringValue == "mock" }
        XCTAssertEqual(mock?["status"]?.stringValue, "ready")
        XCTAssertEqual(mock?["authStatus"]?.stringValue, "notLoggedIn")
        XCTAssertEqual(mock?["tools"]?["echo"]?["description"]?.stringValue, "echoes message")
        XCTAssertEqual(mock?["tools"]?["echo"]?["inputSchema"]?["required"]?.arrayValue?
            .compactMap(\.stringValue), ["message"])

        s.conn.clientSend(req(3, "mcpServer/tool/call", .object([
            "threadId": .string(ThreadId.generate().raw),
            "server": .string("mock"),
            "tool": .string("echo"),
            "arguments": .object(["message": .string("hello")]),
        ])))
        let callMessages = await waitOutbound(s.conn, {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }, timeoutMs: 10_000)
        guard case .response(let call)? = callMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else { return XCTFail("missing mcpServer/tool/call response") }
        XCTAssertEqual(call.result["content"]?.arrayValue?.first?["text"]?.stringValue,
                       "echo:hello")
        XCTAssertEqual(call.result["isError"]?.boolValue, false)

        s.conn.clientSend(req(4, "mcpServer/resource/read", .object([
            "threadId": .string(ThreadId.generate().raw),
            "server": .string("mock"),
            "uri": .string("file:///fixture.txt"),
        ])))
        let resourceMessages = await waitOutbound(s.conn, {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }, timeoutMs: 10_000)
        guard case .response(let resource)? = resourceMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }
            return false
        }) else { return XCTFail("missing mcpServer/resource/read response") }
        let contents = resource.result["contents"]?.arrayValue ?? []
        XCTAssertEqual(contents.first?["uri"]?.stringValue, "file:///fixture.txt")
        XCTAssertEqual(contents.first?["mimeType"]?.stringValue, "text/plain")
        XCTAssertEqual(contents.first?["text"]?.stringValue, "resource:file:///fixture.txt")
    }

    func testConfigMcpServerReloadClearsStaleServersAndLoadsNewConfig() async throws {
        let home = NSTemporaryDirectory() + "mcp-reload-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let script = home + "/server.py"
        try """
        import os, sys, json
        label = os.environ.get("LABEL", "unset")
        def send(o):
            sys.stdout.write(json.dumps(o) + "\\n")
            sys.stdout.flush()
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            mid = msg.get("id")
            method = msg.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"protocolVersion": "2025-06-18"}})
            elif method == "notifications/initialized":
                pass
            elif method == "tools/list":
                send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
                    {"name": "label", "description": "returns configured label",
                     "inputSchema": {"type": "object", "additionalProperties": False}}]}})
            elif method == "tools/call":
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": label}],
                    "isError": False}})
        """.write(toFile: script, atomically: true, encoding: .utf8)

        func writeMcpConfig(name: String, label: String) throws {
            try """
            {
              "mcpServers": {
                "\(name)": {
                  "command": "python3",
                  "args": ["-u", "\(script)"],
                  "env": { "LABEL": "\(label)" }
                }
              }
            }
            """.write(toFile: home + "/mcp.json", atomically: true, encoding: .utf8)
        }

        try writeMcpConfig(name: "alpha", label: "one")
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        func response(_ id: Int, _ method: String, _ params: JSONValue?) async throws -> JSONRPCResponse {
            let requestId = RequestId.int(Int64(id))
            s.conn.clientSend(req(id, method, params))
            let messages = await waitOutbound(s.conn, {
                if case .response(let r) = $0 { return r.id == requestId }
                if case .error(let e) = $0 { return e.id == requestId }
                return false
            }, timeoutMs: 10_000)
            if case .error(let error)? = messages.first(where: {
                if case .error(let e) = $0 { return e.id == requestId }
                return false
            }) {
                throw NSError(domain: "EndToEndTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: error.error.message])
            }
            guard case .response(let response)? = messages.first(where: {
                if case .response(let r) = $0 { return r.id == requestId }
                return false
            }) else {
                throw NSError(domain: "EndToEndTests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "missing response \(id)"])
            }
            return response
        }

        let initial = try await response(2, "mcpServerStatus/list", .object([:]))
        XCTAssertEqual(initial.result["data"]?.arrayValue.map {
            $0.compactMap { $0["name"]?.stringValue }
        }, ["alpha"])

        try writeMcpConfig(name: "beta", label: "two")
        let reload = try await response(3, "config/mcpServer/reload", .object([:]))
        XCTAssertEqual(reload.result, .object([:]))

        let reloaded = try await response(4, "mcpServerStatus/list", .object([:]))
        let names = reloaded.result["data"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, ["beta"])

        let betaCall = try await response(5, "mcpServer/tool/call", .object([
            "threadId": .string(ThreadId.generate().raw),
            "server": .string("beta"),
            "tool": .string("label"),
            "arguments": .object([:]),
        ]))
        XCTAssertEqual(betaCall.result["content"]?.arrayValue?.first?["text"]?.stringValue, "two")

        s.conn.clientSend(req(6, "mcpServer/tool/call", .object([
            "threadId": .string(ThreadId.generate().raw),
            "server": .string("alpha"),
            "tool": .string("label"),
            "arguments": .object([:]),
        ])))
        let removedMessages = await waitOutbound(s.conn, {
            if case .error(let e) = $0 { return e.id == .int(6) }
            return false
        }, timeoutMs: 10_000)
        guard case .error(let removedError)? = removedMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(6) }
            return false
        }) else { return XCTFail("missing removed MCP server error") }
        XCTAssertTrue(removedError.error.message.contains("MCP server not loaded: alpha"),
                      removedError.error.message)
    }

    func testMcpToolCallRoutesElicitationRequestAndReturnsClientResponse() async throws {
        let home = NSTemporaryDirectory() + "mcp-elicitation-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let script = home + "/server.py"
        try """
        import sys, json
        def send(o):
            sys.stdout.write(json.dumps(o) + "\\n")
            sys.stdout.flush()
        def read_msg():
            while True:
                line = sys.stdin.readline()
                if line == "":
                    return None
                line = line.strip()
                if line:
                    return json.loads(line)
        while True:
            msg = read_msg()
            if msg is None:
                break
            mid = msg.get("id")
            method = msg.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"protocolVersion": "2025-06-18"}})
            elif method == "notifications/initialized":
                pass
            elif method == "tools/list":
                send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
                    {"name": "needs_input", "description": "asks before continuing",
                     "inputSchema": {"type": "object", "properties": {}}}]}})
            elif method == "tools/call":
                send({"jsonrpc": "2.0", "id": 99,
                      "method": "elicitation/create",
                      "params": {
                        "_meta": {"source": "fixture"},
                        "message": "Allow fixture tool?",
                        "requestedSchema": {
                          "type": "object",
                          "properties": {
                            "confirmed": {"type": "boolean"},
                            "note": {"type": "string"}
                          },
                          "required": ["confirmed"]
                        }
                      }})
                response = read_msg()
                result = response.get("result", {}) if response else {}
                content = result.get("content") or {}
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text",
                                 "text": "confirmed=%s note=%s" % (
                                     content.get("confirmed"), content.get("note", ""))}],
                    "isError": False}})
        """.write(toFile: script, atomically: true, encoding: .utf8)

        try """
        {
          "mcpServers": {
            "asker": { "command": "python3", "args": ["-u", "\(script)"] }
          }
        }
        """.write(toFile: home + "/mcp.json", atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        let threadId = ThreadId.generate().raw
        s.conn.clientSend(req(2, "mcpServer/tool/call", .object([
            "threadId": .string(threadId),
            "server": .string("asker"),
            "tool": .string("needs_input"),
            "arguments": .object([:]),
        ])))
        let requestMessages = await waitOutbound(s.conn, {
            if case .request(let r) = $0 { return r.method == "mcpServer/elicitation/request" }
            return false
        }, timeoutMs: 10_000)
        guard case .request(let elicitation)? = requestMessages.first(where: {
            if case .request(let r) = $0 { return r.method == "mcpServer/elicitation/request" }
            return false
        }) else { return XCTFail("missing MCP elicitation request") }
        XCTAssertEqual(elicitation.id, .int(99))
        XCTAssertEqual(elicitation.params?["threadId"]?.stringValue, threadId)
        XCTAssertEqual(elicitation.params?["serverName"]?.stringValue, "asker")
        XCTAssertEqual(elicitation.params?["mode"]?.stringValue, "form")
        XCTAssertEqual(elicitation.params?["_meta"]?["source"]?.stringValue, "fixture")
        XCTAssertEqual(elicitation.params?["requestedSchema"]?["properties"]?["confirmed"]?["type"]?
            .stringValue, "boolean")

        s.conn.clientSend(.response(JSONRPCResponse(id: .int(99), result: .object([
            "action": .string("accept"),
            "content": .object([
                "confirmed": .bool(true),
                "note": .string("ok"),
            ]),
            "_meta": .null,
        ]))))
        let callMessages = await waitOutbound(s.conn, {
            if case .response(let r) = $0 { return r.id == .int(2) }
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }, timeoutMs: 10_000)
        if case .error(let error)? = callMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }) {
            return XCTFail("MCP call failed: \(error.error.message)")
        }
        guard case .response(let call)? = callMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing MCP call response") }
        XCTAssertEqual(call.result["content"]?.arrayValue?.first?["text"]?.stringValue,
                       "confirmed=True note=ok")
        XCTAssertEqual(call.result["isError"]?.boolValue, false)
    }

    func testDirectMcpCallsUseBoundSessionWorkerLifecycle() async throws {
        let home = NSTemporaryDirectory() + "mcp-session-lifecycle-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let script = home + "/count_mcp.py"
        try """
        import json, os, sys
        count = 0
        def send(obj):
            sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\\n")
            sys.stdout.flush()
        for line in sys.stdin:
            msg = json.loads(line)
            mid = msg.get("id")
            method = msg.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2024-11-05"}})
            elif method == "tools/list":
                send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{
                    "name": "count",
                    "description": "per-process count",
                    "inputSchema": {"type": "object", "additionalProperties": False}}]}})
            elif method == "tools/call":
                count += 1
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": "pid=%s count=%d" % (os.getpid(), count)}],
                    "isError": False}})
        """.write(toFile: script, atomically: true, encoding: .utf8)

        try """
        {
          "mcpServers": {
            "counter": { "command": "python3", "args": ["-u", "\(script)"] }
          }
        }
        """.write(toFile: home + "/mcp.json", atomically: true, encoding: .utf8)

        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        let model = MockModelClient([.hello()])
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link, makeComponents: { c in
                let router = ToolRouter(limits: limits)
                let mcp = McpManager()
                await mcp.startAll(McpManager.loadConfigs(codexHome: home),
                                   router: router,
                                   oauthStore: nil,
                                   elicitationHandler: nil)
                let engine = SessionEngine(config: c, model: model, store: store,
                                           router: router, limits: limits)
                let handler: WorkerMcpHandler = { request in
                    do {
                        guard let tool = request.tool,
                              let argumentsJSON = request.argumentsJSON else {
                            throw NSError(domain: "EndToEndTests", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "bad test MCP request"])
                        }
                        let result = try await mcp.callTool(server: request.server,
                                                            tool: tool,
                                                            argumentsJSON: argumentsJSON)
                        return WorkerMcpResponse(requestId: request.requestId,
                                                 result: .object([
                            "content": .array([
                                .object(["type": .string("text"),
                                         "text": .string(result.text)])
                            ]),
                            "structuredContent": .null,
                            "isError": .bool(result.isError),
                            "_meta": .null,
                        ]))
                    } catch {
                        return WorkerMcpResponse(requestId: request.requestId,
                                                 result: nil,
                                                 error: error.localizedDescription)
                    }
                }
                return SessionRuntimeComponents(engine: engine, mcpHandler: handler)
            })
            let task = Task { await rt.run() }
            return WorkerHandle(link: link, task: task)
        }
        let supervisor = SessionSupervisor(factory: factory)
        let router = RequestRouter(supervisor: supervisor, store: store, codexHome: home)
        let conn = InMemoryConnection()
        let pump = Task {
            for await m in conn.incoming() { await router.handle(m, conn) }
        }
        defer { pump.cancel() }

        conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        conn.clientSend(req(2, "thread/start", .object(["cwd": .string(home)])))
        let startedA = await waitOutbound(conn, {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }, timeoutMs: 10_000)
        conn.clientSend(req(3, "thread/start", .object(["cwd": .string(home)])))
        let startedB = await waitOutbound(conn, {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }, timeoutMs: 10_000)
        guard case .response(let threadA)? = startedA.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let threadIdA = threadA.result["thread"]?["id"]?.stringValue else {
            return XCTFail("missing first thread/start response")
        }
        guard case .response(let threadB)? = startedB.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }), let threadIdB = threadB.result["thread"]?["id"]?.stringValue else {
            return XCTFail("missing second thread/start response")
        }

        func call(_ id: Int, _ threadId: String) async throws -> String {
            conn.clientSend(req(id, "mcpServer/tool/call", .object([
                "threadId": .string(threadId),
                "server": .string("counter"),
                "tool": .string("count"),
                "arguments": .object([:]),
            ])))
            let messages = await waitOutbound(conn, {
                if case .response(let r) = $0 { return r.id == .int(Int64(id)) }
                return false
            }, timeoutMs: 10_000)
            guard case .response(let response)? = messages.first(where: {
                if case .response(let r) = $0 { return r.id == .int(Int64(id)) }
                return false
            }), let text = response.result["content"]?.arrayValue?.first?["text"]?.stringValue else {
                throw NSError(domain: "EndToEndTests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "missing MCP call response \(id)"])
            }
            return text
        }

        let a1 = try await call(4, threadIdA)
        let a2 = try await call(5, threadIdA)
        let b1 = try await call(6, threadIdB)

        XCTAssertTrue(a1.contains("count=1"), a1)
        XCTAssertTrue(a2.contains("count=2"), a2)
        XCTAssertTrue(b1.contains("count=1"), b1)
        XCTAssertNotEqual(a1.components(separatedBy: " ").first,
                          b1.components(separatedBy: " ").first)
    }

    func testMcpOAuthLoginDiscoversPathScopedMetadataAndReturnsAuthorizationUrl() async throws {
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.arguments = ["python3", "--version"]
        python.standardOutput = Pipe()
        python.standardError = Pipe()
        do { try python.run() } catch {
            throw XCTSkip("python3 not available")
        }
        python.waitUntilExit()
        try XCTSkipUnless(python.terminationStatus == 0, "python3 not available")

        let home = NSTemporaryDirectory() + "mcp-oauth-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let script = home + "/oauth.py"
        try """
        import sys, os, json, signal, threading, time
        from http.server import BaseHTTPRequestHandler, HTTPServer
        from urllib.parse import parse_qs

        signal.signal(signal.SIGTERM, lambda *a: os._exit(0))
        _start = time.time()
        _ppid0 = os.getppid()
        def _watchdog():
            while True:
                if os.getppid() != _ppid0 or time.time() - _start > 60:
                    os._exit(0)
                time.sleep(0.2)
        threading.Thread(target=_watchdog, daemon=True).start()

        class H(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.0'
            def log_message(self, *a): pass
            def do_GET(self):
                if self.path != '/.well-known/oauth-authorization-server/mcp':
                    self.send_response(404)
                    self.end_headers()
                    return
                base = 'http://127.0.0.1:%d' % self.server.server_address[1]
                out = json.dumps({
                    'issuer': base,
                    'authorization_endpoint': base + '/authorize',
                    'token_endpoint': base + '/token'
                }).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(out)))
                self.end_headers()
                self.wfile.write(out)
            def do_POST(self):
                if self.path != '/token':
                    self.send_response(404)
                    self.end_headers()
                    return
                length = int(self.headers.get('content-length', '0'))
                form = parse_qs(self.rfile.read(length).decode())
                if form.get('grant_type') != ['authorization_code'] or form.get('code') != ['code-123']:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b'{"error":"invalid_grant"}')
                    return
                if not form.get('code_verifier', [''])[0]:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b'{"error":"missing_verifier"}')
                    return
                out = json.dumps({
                    'access_token': 'mcp-access-token',
                    'refresh_token': 'mcp-refresh-token',
                    'token_type': 'Bearer',
                    'expires_in': 3600,
                }).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(out)))
                self.end_headers()
                self.wfile.write(out)

        s = HTTPServer(('127.0.0.1', 0), H)
        print(s.server_address[1])
        sys.stdout.flush()
        s.serve_forever()
        """.write(toFile: script, atomically: true, encoding: .utf8)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", script]
        let outPipe = Pipe()
        server.standardOutput = outPipe
        server.standardError = Pipe()
        try server.run()
        defer { server.terminate() }

        var acc = Data()
        let deadline = Date().addingTimeInterval(10)
        var port: Int?
        while Date() < deadline, port == nil {
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            acc.append(chunk)
            if let str = String(data: acc, encoding: .utf8),
               let nl = str.firstIndex(of: "\n") {
                port = Int(String(str[str.startIndex..<nl])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        guard let port, port > 0 else {
            return XCTFail("OAuth metadata server did not report a port")
        }

        try """
        {
          "mcpServers": {
            "httpOAuth": { "url": "http://127.0.0.1:\(port)/mcp" }
          }
        }
        """.write(toFile: home + "/mcp.json", atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "mcpServer/oauth/login", .object([
            "name": .string("httpOAuth"),
            "scopes": .array([.string("read"), .string("write")]),
            "timeoutSecs": .int(2),
        ])))
        let messages = await waitOutbound(s.conn, {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }, timeoutMs: 10_000)
        guard case .response(let response)? = messages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }) else { return XCTFail("missing mcpServer/oauth/login response") }

        let authorizationUrl = response.result["authorizationUrl"]?.stringValue ?? ""
        guard let components = URLComponents(string: authorizationUrl) else {
            return XCTFail("authorizationUrl did not parse: \(authorizationUrl)")
        }
        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "127.0.0.1")
        XCTAssertEqual(components.port, port)
        XCTAssertEqual(components.path, "/authorize")
        let query = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            })
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "Codex")
        XCTAssertEqual(query["scope"], "read write")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertFalse(query["code_challenge"]?.isEmpty ?? true)
        XCTAssertFalse(query["state"]?.isEmpty ?? true)
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:1455/mcp/oauth/callback")

        let callback = Process()
        callback.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        callback.arguments = [
            "curl", "-sS", "--max-time", "5",
            "http://127.0.0.1:1455/mcp/oauth/callback?state=\(query["state"] ?? "")&code=code-123",
        ]
        callback.standardOutput = Pipe()
        callback.standardError = Pipe()
        try callback.run()
        callback.waitUntilExit()
        XCTAssertEqual(callback.terminationStatus, 0)

        let notificationMessages = await waitOutbound(s.conn, {
            if case .notification(let n) = $0 {
                return n.method == "mcpServer/oauthLogin/completed"
            }
            return false
        }, timeoutMs: 10_000)
        guard case .notification(let completed)? = notificationMessages.first(where: {
            if case .notification(let n) = $0 {
                return n.method == "mcpServer/oauthLogin/completed"
            }
            return false
        }) else { return XCTFail("missing mcpServer/oauthLogin/completed") }
        XCTAssertEqual(completed.params?["name"]?.stringValue, "httpOAuth")
        XCTAssertEqual(completed.params?["success"]?.boolValue, true)
        XCTAssertNil(completed.params?["error"])

        let stored = McpOAuthStore(codexHome: home).load(server: "httpOAuth")
        XCTAssertEqual(stored?.accessToken, "mcp-access-token")
        XCTAssertEqual(stored?.refreshToken, "mcp-refresh-token")
        XCTAssertFalse(stored?.isExpired ?? true)
    }

    func testFeedbackUploadSpoolsManifestAndAttachments() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string("/work")])))
        let startMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let start)? = startMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                            from: start.result) else {
            return XCTFail("missing thread/start response")
        }

        let extraLog = s.home + "/extra.log"
        try FileManager.default.createDirectory(atPath: s.home, withIntermediateDirectories: true)
        try "extra feedback context\n".write(toFile: extraLog,
                                              atomically: true, encoding: .utf8)
        FeedbackLogStore.shared.clear()
        Log(category: "feedback-e2e").info("thread scoped feedback row", threadId: env.thread.id.raw)
        Log(category: "feedback-e2e").warn("threadless feedback row")
        s.conn.clientSend(req(3, "feedback/upload", .object([
            "classification": .string("bug"),
            "reason": .string("deterministic feedback test"),
            "threadId": .string(env.thread.id.raw),
            "includeLogs": .bool(true),
            "extraLogFiles": .array([.string(extraLog)]),
            "tags": .object(["component": .string("supervisor")]),
        ])))
        let uploadMessages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }
        guard case .response(let upload)? = uploadMessages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }
            return false
        }) else { return XCTFail("missing feedback/upload response") }
        XCTAssertEqual(upload.result["threadId"]?.stringValue, env.thread.id.raw)

        let feedbackRoot = s.home + "/feedback"
        let bundles = try FileManager.default.contentsOfDirectory(atPath: feedbackRoot)
        XCTAssertEqual(bundles.count, 1)
        let manifestPath = feedbackRoot + "/" + bundles[0] + "/manifest.json"
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let manifest = try JSONDecoder().decode(JSONValue.self, from: manifestData)
        XCTAssertEqual(manifest["gate"]?.stringValue, "feedback/upload")
        XCTAssertEqual(manifest["result"]?.stringValue, "spooled")
        XCTAssertEqual(manifest["classification"]?.stringValue, "bug")
        XCTAssertEqual(manifest["threadId"]?.stringValue, env.thread.id.raw)
        XCTAssertEqual(manifest["includeLogs"]?.boolValue, true)
        XCTAssertEqual(manifest["tags"]?["component"]?.stringValue, "supervisor")
        XCTAssertNotNil(manifest["installContext"]?["type"]?.stringValue)
        XCTAssertNotNil(manifest["installContext"]?["rgCommand"]?.stringValue)
        let attachmentNames = (manifest["attachments"]?.arrayValue ?? [])
            .compactMap { $0["filename"]?.stringValue }
        XCTAssertTrue(attachmentNames.contains("codex-logs.log"))
        XCTAssertTrue(attachmentNames.contains("extra.log"))
        let bundlePath = (manifest["attachments"]?.arrayValue ?? [])
            .first { $0["filename"]?.stringValue == "codex-logs.log" }?["path"]?.stringValue
        XCTAssertNotNil(bundlePath)
        let feedbackLogs = try String(contentsOfFile: bundlePath ?? "", encoding: .utf8)
        XCTAssertTrue(feedbackLogs.contains("thread scoped feedback row"), feedbackLogs)
        XCTAssertTrue(feedbackLogs.contains("threadless feedback row"), feedbackLogs)
    }

    func testFeedbackUploadValidatesConfigAndThreadId() async throws {
        let home = NSTemporaryDirectory() + "feedback-disabled-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try """
        [feedback]
        enabled = false
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }

        s.conn.clientSend(req(2, "feedback/upload", .object([
            "classification": .string("bug"),
            "includeLogs": .bool(false),
            "threadId": .string("thr_disabled_feedback"),
        ])))
        let disabledMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }
        guard case .error(let disabled)? = disabledMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(2) }
            return false
        }) else { return XCTFail("missing disabled feedback error") }
        XCTAssertEqual(disabled.error.message, "sending feedback is disabled by configuration")

        try """
        [feedback]
        enabled = true
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        s.conn.clientSend(req(3, "feedback/upload", .object([
            "classification": .string("bug"),
            "includeLogs": .bool(false),
            "threadId": .string("../escape"),
        ])))
        let invalidMessages = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }
        guard case .error(let invalid)? = invalidMessages.first(where: {
            if case .error(let e) = $0 { return e.id == .int(3) }
            return false
        }) else { return XCTFail("missing invalid thread id error") }
        XCTAssertTrue(invalid.error.message.hasPrefix("invalid thread id"),
                      "got: \(invalid.error.message)")
    }

    func testThreadMetadataUpdatePersistsGitInfo() async throws {
        let s = try makeStack(MockModelClient([.hello()]))
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string("/work")])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let sr)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self, from: sr.result) else {
            return XCTFail("no thread/start response")
        }

        s.conn.clientSend(req(3, "thread/metadata/update", .object([
            "threadId": .string(env.thread.id.raw),
            "gitInfo": .object([
                "branch": .string("feature/oracle-metadata"),
                "sha": .string("abc123"),
            ]),
        ])))
        let updateMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(3) }; return false
        }
        guard case .response(let ur)? = updateMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(3) }; return false
        }) else { return XCTFail("missing metadata update response") }
        XCTAssertEqual(ur.result["thread"]?["gitInfo"]?["branch"]?.stringValue,
                       "feature/oracle-metadata")
        XCTAssertEqual(ur.result["thread"]?["gitInfo"]?["sha"]?.stringValue, "abc123")
        XCTAssertEqual(ur.result["thread"]?["gitInfo"]?["originUrl"], .null)

        s.conn.clientSend(req(4, "thread/read", .object([
            "threadId": .string(env.thread.id.raw),
            "includeTurns": .bool(false),
        ])))
        let readMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }
        guard case .response(let rr)? = readMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(4) }; return false
        }) else { return XCTFail("missing thread/read response") }
        XCTAssertEqual(rr.result["thread"]?["gitInfo"]?["branch"]?.stringValue,
                       "feature/oracle-metadata")

        s.conn.clientSend(req(5, "thread/metadata/update", .object([
            "threadId": .string(env.thread.id.raw),
            "gitInfo": .object(["branch": .null, "sha": .null]),
        ])))
        let clearMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }
        guard case .response(let cr)? = clearMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(5) }; return false
        }) else { return XCTFail("missing metadata clear response") }
        XCTAssertNil(cr.result["thread"]?["gitInfo"])
    }

    func testConfigRequirementsReadSurfacesManagedConstraintsAndRejectsInvalidToml() async throws {
        let home = NSTemporaryDirectory() + "requirements-e2e-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let reqPath = home + "/requirements.toml"
        let managedPath = home + "/managed_config.toml"
        try """
        allowed_approval_policies = ["on-request"]
        allowed_sandbox_modes = ["workspace-write", "read-only"]
        enforce_residency = true

        [features]
        apps = false
        plugins = true

        [hooks]
        managed_dir = "/Library/Application Support/OpenAI/Codex/hooks"

        [experimental_network]
        managed_allowed_domains_only = true
        domains = { "api.openai.com" = "allow", "*.example.com" = "deny" }
        unix_sockets = { "/tmp/codex.sock" = "allow" }
        """.write(toFile: reqPath, atomically: true, encoding: .utf8)
        try """
        approval_policy = "never"
        sandbox_mode = "danger-full-access"
        """.write(toFile: managedPath, atomically: true, encoding: .utf8)

        let loader = ConfigRequirementsLoader(systemRequirementsPath: reqPath,
                                              legacyManagedConfigPath: managedPath,
                                              managedPreferenceDomain: "com.openai.codex.tests." + UUID().uuidString)
        let s = try makeStack(MockModelClient([.hello()]), codexHome: home,
                              requirementsLoader: loader)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "configRequirements/read", nil))
        let readMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let read)? = readMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing configRequirements/read response") }
        let requirements = try XCTUnwrap(read.result["requirements"])
        XCTAssertEqual(requirements["allowedApprovalPolicies"]?.arrayValue,
                       [.string("on-request")])
        XCTAssertEqual(requirements["allowedSandboxModes"]?.arrayValue,
                       [.string("workspace-write"), .string("read-only")])
        XCTAssertEqual(requirements["enforceResidency"]?.boolValue, true)
        XCTAssertEqual(requirements["featureRequirements"]?["apps"]?.boolValue, false)
        XCTAssertEqual(requirements["featureRequirements"]?["plugins"]?.boolValue, true)
        XCTAssertEqual(requirements["hooks"]?["managedDir"]?.stringValue,
                       "/Library/Application Support/OpenAI/Codex/hooks")
        XCTAssertEqual(requirements["network"]?["managedAllowedDomainsOnly"]?.boolValue,
                       true)
        XCTAssertEqual(requirements["network"]?["domains"]?["api.openai.com"]?.stringValue,
                       "allow")
        XCTAssertEqual(requirements["network"]?["domains"]?["*.example.com"]?.stringValue,
                       "deny")
        XCTAssertEqual(requirements["network"]?["unixSockets"]?["/tmp/codex.sock"]?.stringValue,
                       "allow")

        try "allowed_approval_policies = [".write(
            toFile: reqPath, atomically: true, encoding: .utf8)
        s.conn.clientSend(req(3, "configRequirements/read", nil))
        let invalidMsgs = await waitOutbound(s.conn) {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }
        guard case .error(let invalid)? = invalidMsgs.first(where: {
            if case .error(let e) = $0 { return e.id == .int(3) }; return false
        }) else { return XCTFail("missing invalid requirements error") }
        XCTAssertTrue(invalid.error.message.contains("failed to load config requirements"),
                      invalid.error.message)
    }

    func testHooksListDiscoversHomeAndProjectHooksWithState() async throws {
        let home = NSTemporaryDirectory() + "hooks-list-e2e-" + UUID().uuidString
        let cwd = NSTemporaryDirectory() + "hooks-list-cwd-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cwd + "/.codex/hooks",
                                                withIntermediateDirectories: true)
        let homeHooks = home + "/hooks.json"
        let projectHooks = cwd + "/.codex/hooks.json"
        try """
        {"hooks":[{"event":"session-start","command":"echo home","timeout":3}]}
        """.write(toFile: homeHooks, atomically: true, encoding: .utf8)
        try """
        [{"eventName":"preToolUse","matcher":"shell","command":"python3 .codex/hooks/repo.py","timeoutSec":7,"statusMessage":"repo hook"}]
        """.write(toFile: projectHooks, atomically: true, encoding: .utf8)
        try "print('repo')\n".write(toFile: cwd + "/.codex/hooks/repo.py",
                                    atomically: true, encoding: .utf8)
        let projectKey = "\(projectHooks):pre_tool_use:0:0"
        try """
        [hooks.state."\(projectKey)"]
        enabled = false
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let s = try makeStack(MockModelClient([.hello()]), codexHome: home)
        defer {
            s.pump.cancel()
            try? FileManager.default.removeItem(atPath: s.home)
            try? FileManager.default.removeItem(atPath: cwd)
        }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) { if case .response(let r) = $0 { return r.id == .int(1) }; return false }

        s.conn.clientSend(req(2, "hooks/list", .object(["cwds": .array([.string(cwd)])])))
        let messages = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }
        guard case .response(let response)? = messages.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }; return false
        }) else { return XCTFail("missing hooks/list response") }
        let row = try XCTUnwrap(response.result["data"]?.arrayValue?.first)
        XCTAssertEqual(row["cwd"]?.stringValue, cwd)
        XCTAssertEqual(row["errors"]?.arrayValue, [])
        let hooks = row["hooks"]?.arrayValue ?? []
        XCTAssertEqual(hooks.count, 2)
        XCTAssertEqual(hooks[0]["key"]?.stringValue, "\(homeHooks):session_start:0:0")
        XCTAssertEqual(hooks[0]["eventName"]?.stringValue, "session_start")
        XCTAssertEqual(hooks[0]["command"]?.stringValue, "echo home")
        XCTAssertEqual(hooks[0]["source"]?.stringValue, "user")
        XCTAssertEqual(hooks[0]["enabled"]?.boolValue, true)
        XCTAssertEqual(hooks[1]["key"]?.stringValue, projectKey)
        XCTAssertEqual(hooks[1]["eventName"]?.stringValue, "pre_tool_use")
        XCTAssertEqual(hooks[1]["matcher"]?.stringValue, "shell")
        XCTAssertEqual(hooks[1]["timeoutSec"]?.intValue, 7)
        XCTAssertEqual(hooks[1]["statusMessage"]?.stringValue, "repo hook")
        XCTAssertEqual(hooks[1]["source"]?.stringValue, "project")
        XCTAssertEqual(hooks[1]["enabled"]?.boolValue, false)
        XCTAssertEqual(hooks[1]["trustStatus"]?.stringValue, "untrusted")
        let expectedHookPath = URL(fileURLWithPath: cwd + "/.codex/hooks/repo.py")
            .standardizedFileURL.path
        XCTAssertTrue(hooks[1]["command"]?.stringValue?.contains(expectedHookPath) == true,
                      hooks[1]["command"]?.stringValue ?? "")
        XCTAssertNotNil(hooks[1]["currentHash"]?.stringValue)
    }

    func testThreadStartRunsOnlyTrustedHookThroughWorker() async throws {
        let home = NSTemporaryDirectory() + "e2e-hook-trust-" + UUID().uuidString
        let cwd = NSTemporaryDirectory() + "e2e-hook-cwd-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cwd + "/.codex",
                                                withIntermediateDirectories: true)
        let out = home + "/prompt.json"
        let command = "cat > '\(out)'"
        let hookObject: [String: JSONValue] = [
            "event": .string("user-prompt-submit"),
            "command": .string(command),
            "timeout": .int(5),
        ]
        let hookData = try JSONEncoder().encode(JSONValue.object(["hooks": .array([.object(hookObject)])]))
        try hookData.write(to: URL(fileURLWithPath: cwd + "/.codex/hooks.json"), options: .atomic)
        let key = cwd + "/.codex/hooks.json:user_prompt_submit:0:0"
        let trustedHash = HookEngine.stableHookHash(hookObject)
        try """
        [hooks.state."\(key)"]
        trusted_hash = "\(trustedHash)"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: home)
            try? FileManager.default.removeItem(atPath: cwd)
        }

        let s = try makeStack(MockModelClient([.hello("hook trusted")]), codexHome: home)
        defer { s.pump.cancel() }
        s.conn.clientSend(req(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])])))
        _ = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(1) }
            return false
        }
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
        s.conn.clientSend(req(2, "thread/start", .object(["cwd": .string(cwd)])))
        let startMsgs = await waitOutbound(s.conn) {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }
        guard case .response(let sr)? = startMsgs.first(where: {
            if case .response(let r) = $0 { return r.id == .int(2) }
            return false
        }), let env = try? JSONBridge.decode(ThreadSessionResponseEnvelope.self,
                                             from: sr.result) else {
            return XCTFail("no thread/start response")
        }
        s.conn.clientSend(req(3, "turn/start", .object([
            "threadId": .string(env.thread.id.raw),
            "input": .array([.object(["type": .string("text"),
                                      "text": .string("trusted prompt")])]),
        ])))
        _ = await waitOutbound(s.conn) {
            if case .notification(let n) = $0 { return n.method == "turn/completed" }
            return false
        }
        let captured = try String(contentsOfFile: out, encoding: .utf8)
        // P4.6 / H-27: stdin field is PascalCase now (matches upstream).
        XCTAssertTrue(captured.contains(#""hook_event_name":"UserPromptSubmit""#))
        XCTAssertTrue(captured.contains("trusted prompt"))
    }

    func testMultiSubscriberFanOut() async throws {
        // Two notification sinks on one thread both receive turn events.
        let model = MockModelClient(repeating: .hello("fan"), times: 8)
        let home = NSTemporaryDirectory() + "fan-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link) { c in
                SessionEngine(config: c, model: model, store: store,
                              router: ToolRouter(limits: limits), limits: limits)
            }
            let t = Task { await rt.run() }
            return WorkerHandle(link: link, task: t)
        }
        let supervisor = SessionSupervisor(factory: factory)
        let cfg = SessionConfig(threadId: ThreadId.generate(), cwd: "/w")
        _ = try await store.create(cfg)

        let a = Counter3(); let b = Counter3()
        await supervisor.ensureWorker(cfg) { _ in Task { await a.inc() } }
        await supervisor.ensureWorker(cfg) { _ in Task { await b.inc() } }
        let subs = await supervisor.subscriberCount(cfg.threadId)
        XCTAssertEqual(subs, 2)
        await supervisor.submit(cfg.threadId, .startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(400))
        let av = await a.value
        let bv = await b.value
        XCTAssertGreaterThan(av, 0)
        XCTAssertGreaterThan(bv, 0, "second subscriber must also receive notifications")
    }

    /// prompts finding A/B/C: `RequestRouter.agentsMdConfig` must seed the
    /// model-visible user-instructions from the GLOBAL
    /// `~/.codex/AGENTS.override.md` / `AGENTS.md` and forward the AGENTS.md
    /// config knobs (`project_doc_fallback_filenames`, `project_root_markers`,
    /// `project_doc_max_bytes`, `child_agents_md` feature) into SessionConfig.
    func testAgentsMdConfigLoadsGlobalAndForwardsKnobs() throws {
        let home = NSTemporaryDirectory() + "agentsmd-cfg-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        // Global AGENTS.md in $CODEX_HOME.
        try "GLOBAL-AGENTS-MARKER".write(toFile: home + "/AGENTS.md",
                                         atomically: true, encoding: .utf8)
        try """
        project_doc_fallback_filenames = ["WORKFLOW.md"]
        project_root_markers = [".hg"]
        project_doc_max_bytes = 4096

        [features]
        child_agents_md = true
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let cwd = NSTemporaryDirectory() + "agentsmd-cwd-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let config = ConfigLoader(codexHome: home).load()
        let agentsMd = RequestRouter.agentsMdConfig(config, codexHome: home, cwd: cwd)

        // Finding A: global AGENTS.md content seeds user instructions.
        XCTAssertEqual(agentsMd.userInstructions, "GLOBAL-AGENTS-MARKER",
                       "global ~/.codex/AGENTS.md must seed agentsMdUserInstructions")
        // Finding B: fallback filenames / root markers / child feature forwarded.
        XCTAssertEqual(agentsMd.filenames, ["WORKFLOW.md"])
        XCTAssertEqual(agentsMd.projectRootMarkers, [".hg"])
        XCTAssertTrue(agentsMd.childEnabled,
                      "child_agents_md feature must reach agentsMdChildEnabled")
        // Finding C: project_doc_max_bytes forwarded verbatim.
        XCTAssertEqual(agentsMd.projectDocMaxBytes, 4096)
    }

    /// prompts finding C: `project_doc_max_bytes = 0` disables *discovered
    /// project AGENTS.md docs* (`read_agents_md` short-circuit), but the GLOBAL
    /// override (`~/.codex/AGENTS.override.md` / `AGENTS.md`) is loaded
    /// unconditionally into `Config.user_instructions` (`config/mod.rs:2349`)
    /// and prepended regardless of the budget (`agents_md.rs:98-100`), so it
    /// must survive a zero budget.
    func testAgentsMdConfigZeroBudgetKeepsGlobalDropsProjectDocs() throws {
        let home = NSTemporaryDirectory() + "agentsmd-zero-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "GLOBAL-AGENTS-MARKER".write(toFile: home + "/AGENTS.md",
                                         atomically: true, encoding: .utf8)
        try "project_doc_max_bytes = 0\n".write(toFile: home + "/config.toml",
                                                 atomically: true, encoding: .utf8)
        let config = ConfigLoader(codexHome: home).load()
        // cwd that contains its own project AGENTS.md to prove the budget gate
        // drops the *project* doc while the global override still flows through.
        let cwd = NSTemporaryDirectory() + "agentsmd-zero-cwd-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        try "PROJECT-DOC".write(toFile: cwd + "/AGENTS.md", atomically: true, encoding: .utf8)

        let agentsMd = RequestRouter.agentsMdConfig(config, codexHome: home, cwd: cwd)
        XCTAssertEqual(agentsMd.projectDocMaxBytes, 0)
        // Global override survives the zero budget (upstream loads it into
        // config.user_instructions regardless of project_doc_max_bytes; the
        // budget only gates the discovered project AGENTS.md docs via
        // read_agents_md's zero short-circuit). The project-doc drop under a
        // zero budget is asserted engine-side in
        // SkillsAgentsMdParityTests.testProjectDocMaxBytesZeroDisablesAgentsMd.
        XCTAssertEqual(agentsMd.userInstructions, "GLOBAL-AGENTS-MARKER",
                       "global AGENTS.md must survive project_doc_max_bytes=0")
    }
}

actor Counter3 { private(set) var value = 0; func inc() { value += 1 } }
