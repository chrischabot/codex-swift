import Foundation
import InfraPrimitives
import Sandbox

private struct RemoteJSON: @unchecked Sendable {
    var object: [String: Any]
    init(_ object: [String: Any] = [:]) {
        self.object = object
    }
}

/// Defines what the client should do when a remote exec-server request fails.
///
/// Upstream exec-server has no idempotency-key protocol, so replay safety is
/// reasoned at the client layer:
///
/// - `.never`        — throw on any transport failure. Use for genuinely
///                     non-idempotent ops like `process/writeStdin` where a
///                     replay would write stdin twice.
/// - `.safe`         — naturally idempotent reads (`fs/readFile`, `fs/getMetadata`,
///                     `fs/readDirectory`, `process/read`) and content-overwrite
///                     writes (`fs/writeFile`, recursive `fs/createDirectory`)
///                     where replay reproduces the same outcome.
/// - `.tolerateExistsOnRetry` — `process/start` with a stable client-supplied
///                     `processId`. On retry the upstream server rejects the
///                     duplicate id; we interpret that rejection as proof the
///                     prior attempt succeeded.
/// - `.tolerateNotFoundOnRetry` — `fs/remove`. On retry the upstream server
///                     reports the path is gone; we interpret that as proof
///                     the prior remove succeeded.
private enum RemoteReplayPolicy: Sendable {
    case never
    case safe
    case tolerateExistsOnRetry
    case tolerateNotFoundOnRetry
}

private actor RemoteExecServerJSONClient {
    private let websocketURL: String
    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var initialized = false
    private var requestBusy = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var sessionId: String?

    init(websocketURL: String) {
        self.websocketURL = websocketURL
    }

    /// Returns the `sessionId` from the most recent successful
    /// `initialize` handshake, or `nil` if the client has not yet
    /// completed an initial handshake.
    ///
    /// Tools that own state tied to a remote process (e.g.
    /// `unified_exec`) capture this at process-start time and compare
    /// against the current value after each subsequent request. A
    /// changed `sessionId` means the exec-server itself restarted in
    /// the interim, in which case the previous process handle is gone
    /// and the tool surfaces a structured restart marker to the model.
    func currentSessionId() -> String? {
        sessionId
    }

    func request(method: String,
                 params: RemoteJSON,
                 replay: RemoteReplayPolicy = .never) async throws -> RemoteJSON {
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        var didRetry = false
        while true {
            do {
                try await ensureInitialized()
                return try await sendRequest(method: method, params: params)
            } catch let error as ToolError {
                if didRetry {
                    switch replay {
                    case .tolerateExistsOnRetry
                        where RemoteErrorClassifier.isAlreadyExists(error.message):
                        return RemoteJSON()
                    case .tolerateNotFoundOnRetry
                        where RemoteErrorClassifier.isNotFound(error.message):
                        return RemoteJSON()
                    default:
                        throw error
                    }
                }
                throw error
            } catch {
                resetConnection()
                switch replay {
                case .never:
                    throw error
                case .safe, .tolerateExistsOnRetry, .tolerateNotFoundOnRetry:
                    if !didRetry {
                        didRetry = true
                        continue
                    }
                    throw error
                }
            }
        }
    }

    private func acquireRequestSlot() async {
        if !requestBusy {
            requestBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        if requestWaiters.isEmpty {
            requestBusy = false
        } else {
            requestWaiters.removeFirst().resume()
        }
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        let rendezvousURL = try await resolveRendezvousURL(websocketURL)
        guard let url = URL(string: rendezvousURL) else {
            throw ToolError(message: "invalid remote exec-server rendezvous url: \(rendezvousURL)")
        }
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        let result = try await sendRequest(
            method: "initialize",
            params: RemoteJSON(["clientName": "codex-swift"]))
        sessionId = result.object["sessionId"] as? String
        try await sendNotification(method: "initialized", params: RemoteJSON())
        initialized = true
    }

    /// Resolves the WebSocket rendezvous endpoint for a configured
    /// `execServerUrl`. WebSocket URLs are returned unchanged. HTTP(S) URLs
    /// are treated as an executor-registry root: we POST to
    /// `<url>/executors/register` with a JSON body, expect a JSON response
    /// carrying the rendezvous `wss://` URL, and return that.
    ///
    /// This is the "minimal HTTP→WS upgrade" path called out in
    /// evaluation/codex-macos-swift-remote-execution-completion.md (A1). The
    /// full upstream protobuf-relay framing is intentionally out of scope:
    /// once the registry returns a rendezvous WS URL, the client uses the
    /// same JSON-RPC framing it uses for direct WebSocket exec-servers.
    private func resolveRendezvousURL(_ raw: String) async throws -> String {
        let scheme = URL(string: raw)?.scheme?.lowercased() ?? ""
        switch scheme {
        case "ws", "wss":
            return raw
        case "http", "https":
            return try await registerWithExecutorRegistry(raw)
        default:
            throw ToolError(message: "unsupported remote exec-server scheme: \(scheme)")
        }
    }

    private func registerWithExecutorRegistry(_ registryURL: String) async throws -> String {
        let endpoint = registryURL.hasSuffix("/")
            ? registryURL + "executors/register"
            : registryURL + "/executors/register"
        guard let url = URL(string: endpoint) else {
            throw ToolError(message: "invalid executor-registry endpoint: \(endpoint)")
        }
        let body: [String: Any] = [
            "clientName": "codex-swift",
            "executorId": UUID().uuidString,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ToolError(message: "executor-registry POST failed: \(error)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ToolError(message:
                "executor-registry POST status \(http.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ToolError(message: "executor-registry response is not JSON")
        }
        if let rendezvous = obj["rendezvousURL"] as? String, !rendezvous.isEmpty {
            return rendezvous
        }
        // Some registries name the field differently; tolerate the
        // `rendezvous` alias.
        if let rendezvous = obj["rendezvous"] as? String, !rendezvous.isEmpty {
            return rendezvous
        }
        throw ToolError(message:
            "executor-registry response missing `rendezvousURL` field: \(obj.keys.sorted())")
    }

    private func resetConnection() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        initialized = false
    }

    private func sendNotification(method: String, params: RemoteJSON) async throws {
        let object: [String: Any] = ["method": method, "params": params.object]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError(message: "failed to encode remote exec-server notification")
        }
        try await currentTask().send(.string(text))
    }

    private func sendRequest(method: String, params: RemoteJSON) async throws -> RemoteJSON {
        let id = nextId
        nextId += 1
        let object: [String: Any] = ["id": id, "method": method, "params": params.object]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError(message: "failed to encode remote exec-server request")
        }
        try await currentTask().send(.string(text))
        while true {
            let response = try await currentTask().receive()
            let responseText: String
            switch response {
            case .string(let text):
                responseText = text
            case .data(let data):
                responseText = String(decoding: data, as: UTF8.self)
            @unknown default:
                continue
            }
            guard let responseData = responseText.data(using: .utf8),
                  let decoded = try JSONSerialization.jsonObject(with: responseData)
                    as? [String: Any] else {
                continue
            }
            guard (decoded["id"] as? Int) == id else { continue }
            if let error = decoded["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "remote exec-server request failed"
                throw ToolError(message: message)
            }
            return RemoteJSON(decoded["result"] as? [String: Any] ?? [:])
        }
    }

    private func currentTask() throws -> URLSessionWebSocketTask {
        guard let task else {
            throw ToolError(message: "remote exec-server websocket is not connected")
        }
        return task
    }
}

private enum RemoteErrorClassifier {
    static func isNotFound(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not found")
            || lower.contains("no such file")
            || lower.contains("enoent")
            || lower.contains("does not exist")
    }

    static func isAlreadyExists(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("already exists")
            || lower.contains("already running")
            || lower.contains("already started")
            || lower.contains("duplicate")
            || lower.contains("eexist")
    }
}

private struct RemotePath {
    static func resolve(_ path: String, cwd: String) throws -> String {
        if path.hasPrefix("/") {
            throw ToolError(message: "absolute path not allowed: \(path)")
        }
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("..") {
            throw ToolError(message: "path traversal not allowed: \(path)")
        }
        let root = (cwd as NSString).standardizingPath
        guard root.hasPrefix("/") else {
            throw ToolError(message: "remote cwd must be absolute")
        }
        guard !trimmed.isEmpty else { return root }
        return ((root as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
    }
}

public struct RemoteExecServerShellTool: Tool {
    public let name = "shell_command"
    public let parallelSafe = false
    public var toolDescription: String {
        "Run a shell command in the selected remote environment."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"command":{"description":"shell string or argv array"},"cwd":{"type":"string"},"timeoutMs":{"type":"integer"}},"required":["command"],"additionalProperties":true}"#
    }

    private let client: RemoteExecServerJSONClient
    private let maxOutputBytes: Int

    public init(websocketURL: String, limits: Limits = Limits()) {
        self.client = RemoteExecServerJSONClient(websocketURL: websocketURL)
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
    }

    private struct Args: Decodable {
        var command: CommandSpec
        var cwd: String?
        var timeoutMs: Int?
        enum CodingKeys: String, CodingKey { case command, cwd, timeoutMs, timeout_ms }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(CommandSpec.self, forKey: .command)
            cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
            timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
                ?? container.decodeIfPresent(Int.self, forKey: .timeout_ms)
        }
    }

    private enum CommandSpec: Decodable {
        case argv([String])
        case line(String)
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let array = try? container.decode([String].self) {
                self = .argv(array)
            } else {
                self = .line(try container.decode(String.self))
            }
        }
        var argv: [String] {
            switch self {
            case .argv(let argv): return argv
            case .line(let line): return ["/bin/sh", "-c", line]
            }
        }
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid shell arguments",
                              success: false, truncated: false)
        }
        let processId = "proc_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let workDir = args.cwd ?? cwd
        do {
            _ = try await client.request(method: "process/start", params: RemoteJSON([
                "processId": processId,
                "argv": args.command.argv,
                "cwd": workDir,
                "env": [:],
                "tty": false,
                "pipeStdin": false,
                "arg0": NSNull(),
            ]), replay: .tolerateExistsOnRetry)
            let deadline = Date().addingTimeInterval(Double(args.timeoutMs ?? 120_000) / 1000.0)
            var afterSeq: UInt64?
            var output = HeadTailBuffer(maxBytes: maxOutputBytes)
            var exitCode: Int?
            while Date() < deadline {
                var params: [String: Any] = [
                    "processId": processId,
                    "maxBytes": maxOutputBytes,
                    "waitMs": 100,
                ]
                params["afterSeq"] = afterSeq.map { NSNumber(value: $0) } ?? NSNull()
                let read = try await client.request(method: "process/read",
                                                    params: RemoteJSON(params),
                                                    replay: .safe).object
                afterSeq = Self.uint64(read["nextSeq"]) ?? afterSeq
                if let chunks = read["chunks"] as? [[String: Any]] {
                    for chunk in chunks {
                        if let base64 = chunk["chunk"] as? String,
                           let bytes = Data(base64Encoded: base64) {
                            output.append(String(decoding: bytes, as: UTF8.self))
                        }
                    }
                }
                exitCode = Self.int(read["exitCode"]) ?? exitCode
                let exited = read["exited"] as? Bool ?? false
                let closed = read["closed"] as? Bool ?? false
                if let failure = read["failure"] as? String, !failure.isEmpty {
                    return ToolResult(callId: call.callId, output: failure,
                                      success: false, truncated: false)
                }
                if exited && closed {
                    return ToolResult(callId: call.callId,
                                      output: output.rendered(),
                                      success: (exitCode ?? 0) == 0,
                                      truncated: output.didTruncate)
                }
            }
            _ = try? await client.request(method: "process/terminate",
                                          params: RemoteJSON(["processId": processId]))
            return ToolResult(callId: call.callId, output: "command timed out",
                              success: false, truncated: false)
        } catch let error as ToolError {
            return ToolResult(callId: call.callId, output: error.message,
                              success: false, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "remote shell failed: \(error)",
                              success: false, truncated: false)
        }
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        if let i = value as? Int { return UInt64(i) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return nil
    }
}

public struct RemoteExecServerReadFileTool: Tool {
    public let name = "read_file"
    public let parallelSafe = true
    public var toolDescription: String { "Read a workspace-relative text file in the selected remote environment." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"],"additionalProperties":false}"#
    }
    private let client: RemoteExecServerJSONClient
    private let maxBytes: Int
    public init(websocketURL: String, limits: Limits = Limits()) {
        self.client = RemoteExecServerJSONClient(websocketURL: websocketURL)
        self.maxBytes = limits.clamped().maxToolOutputBytes
    }
    private struct Args: Decodable { var path: String; var offset: Int?; var limit: Int? }
    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid read_file arguments",
                              success: false, truncated: false)
        }
        do {
            let path = try RemotePath.resolve(args.path, cwd: cwd)
            let response = try await client.request(method: "fs/readFile", params: RemoteJSON([
                "path": path,
                "sandbox": NSNull(),
            ]), replay: .safe).object
            guard let base64 = response["dataBase64"] as? String,
                  let bytes = Data(base64Encoded: base64) else {
                return ToolResult(callId: call.callId,
                                  output: "remote read_file returned malformed data",
                                  success: false, truncated: false)
            }
            var text = String(decoding: bytes, as: UTF8.self)
            if args.offset != nil || args.limit != nil {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                let start = max(0, (args.offset ?? 1) - 1)
                guard start <= lines.count else {
                    return ToolResult(callId: call.callId, output: "",
                                      success: true, truncated: false)
                }
                let end = args.limit.map { min(lines.count, start + max(0, $0)) } ?? lines.count
                text = lines[start..<min(end, lines.count)].joined(separator: "\n")
            }
            var ring = HeadTailBuffer(maxBytes: maxBytes)
            ring.append(text)
            return ToolResult(callId: call.callId, output: ring.rendered(),
                              success: true, truncated: ring.didTruncate)
        } catch let error as ToolError {
            return ToolResult(callId: call.callId, output: error.message,
                              success: false, truncated: false)
        }
    }
}

public struct RemoteExecServerWriteFileTool: Tool {
    public let name = "write_file"
    public let parallelSafe = false
    public var toolDescription: String { "Create or overwrite a workspace-relative text file in the selected remote environment." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#
    }
    private let client: RemoteExecServerJSONClient
    public init(websocketURL: String) {
        self.client = RemoteExecServerJSONClient(websocketURL: websocketURL)
    }
    private struct Args: Decodable { var path: String; var content: String }
    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid write_file arguments",
                              success: false, truncated: false)
        }
        do {
            let path = try RemotePath.resolve(args.path, cwd: cwd)
            _ = try await client.request(method: "fs/writeFile", params: RemoteJSON([
                "path": path,
                "dataBase64": Data(args.content.utf8).base64EncodedString(),
                "sandbox": NSNull(),
            ]), replay: .safe)
            return ToolResult(callId: call.callId,
                              output: "wrote \(args.content.utf8.count) bytes to \(args.path)",
                              success: true, truncated: false)
        } catch let error as ToolError {
            return ToolResult(callId: call.callId, output: error.message,
                              success: false, truncated: false)
        }
    }
}

public struct RemoteExecServerListDirTool: Tool {
    public let name = "list_dir"
    public let parallelSafe = true
    public var toolDescription: String { "List a workspace-relative directory in the selected remote environment." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"}},"additionalProperties":false}"#
    }
    private let client: RemoteExecServerJSONClient
    public init(websocketURL: String) {
        self.client = RemoteExecServerJSONClient(websocketURL: websocketURL)
    }
    private struct Args: Decodable { var path: String? }
    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let args = (call.argumentsJSON.data(using: .utf8)).flatMap {
            try? JSONDecoder().decode(Args.self, from: $0)
        } ?? Args(path: nil)
        do {
            let path = try RemotePath.resolve(args.path ?? "", cwd: cwd)
            let response = try await client.request(method: "fs/readDirectory", params: RemoteJSON([
                "path": path,
                "sandbox": NSNull(),
            ]), replay: .safe).object
            let entries = (response["entries"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
                guard let name = entry["fileName"] as? String else { return nil }
                return (entry["isDirectory"] as? Bool ?? false) ? "\(name)/" : name
            }.sorted()
            return ToolResult(callId: call.callId,
                              output: entries.isEmpty ? "(empty)" : entries.joined(separator: "\n"),
                              success: true, truncated: false)
        } catch let error as ToolError {
            return ToolResult(callId: call.callId, output: error.message,
                              success: false, truncated: false)
        }
    }
}

private actor RemoteUnifiedExecState {
    struct Entry {
        var remoteProcessId: String
        var afterSeq: UInt64?
        /// The exec-server `sessionId` captured at `process/start` time.
        /// A subsequent `process/read` whose post-call `currentSessionId()`
        /// differs from this value means the exec-server restarted between
        /// the two operations and the remote process handle is gone.
        var serverSessionId: String?
    }

    private var nextId: Int = 1
    private var entries: [Int: Entry] = [:]

    func create(remoteProcessId: String, serverSessionId: String?) -> Int {
        let id = nextId
        nextId += 1
        entries[id] = Entry(remoteProcessId: remoteProcessId,
                            afterSeq: nil,
                            serverSessionId: serverSessionId)
        return id
    }

    func entry(for id: Int) -> Entry? {
        entries[id]
    }

    func updateAfterSeq(_ afterSeq: UInt64?, for id: Int) {
        guard var entry = entries[id] else { return }
        entry.afterSeq = afterSeq
        entries[id] = entry
    }

    func remove(_ id: Int) {
        entries[id] = nil
    }
}

public struct RemoteExecServerUnifiedExecTool: Tool {
    public let name = "unified_exec"
    public let parallelSafe = false
    public var toolDescription: String {
        "Run or continue an interactive process in the selected remote environment."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"command":{"description":"shell string or argv array to open a new process"},"process_id":{"type":"integer","description":"existing process id to continue"},"input":{"type":"string","description":"stdin to write before reading (may be empty to just poll)"},"yield_time_ms":{"type":"integer"},"max_output_tokens":{"type":"integer"}},"additionalProperties":true}"#
    }

    private enum Constants {
        static let outputMaxBytes = 1 << 20
        static let defaultMaxOutputTokens = 10_000
        static let minEmptyYieldMs = 5_000
        static let yieldMinMs = 250
        static let yieldMaxMs = 30_000
    }

    private let client: RemoteExecServerJSONClient
    private let state = RemoteUnifiedExecState()
    private let maxOutputBytes: Int

    public init(websocketURL: String, limits: Limits = Limits()) {
        self.client = RemoteExecServerJSONClient(websocketURL: websocketURL)
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
    }

    private enum CommandSpec: Decodable {
        case argv([String])
        case line(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let argv = try? container.decode([String].self) {
                self = .argv(argv)
                return
            }
            self = .line(try container.decode(String.self))
        }

        var argv: [String] {
            switch self {
            case .argv(let argv): return argv
            case .line(let line): return ["/bin/sh", "-lc", line]
            }
        }
    }

    private struct Args: Decodable {
        var command: CommandSpec?
        var processId: Int?
        var input: String?
        var yieldMs: Int?
        var maxOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case command, input
            case process_id, processId
            case yield_time_ms, yieldTimeMs
            case max_output_tokens, maxOutputTokens
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decodeIfPresent(CommandSpec.self, forKey: .command)
            input = try container.decodeIfPresent(String.self, forKey: .input)
            processId = try container.decodeIfPresent(Int.self, forKey: .process_id)
                ?? container.decodeIfPresent(Int.self, forKey: .processId)
            yieldMs = try container.decodeIfPresent(Int.self, forKey: .yield_time_ms)
                ?? container.decodeIfPresent(Int.self, forKey: .yieldTimeMs)
            maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .max_output_tokens)
                ?? container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        }
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId,
                              output: "unified_exec: invalid arguments",
                              success: false, truncated: false)
        }

        let reqYield = args.yieldMs ?? Constants.yieldMinMs
        let tokenBytes = args.maxOutputTokens.map { Swift.max(16, $0 * 4) }
            ?? (Constants.defaultMaxOutputTokens * 4)
        let maxBytes = Swift.min(maxOutputBytes,
                                 Swift.min(tokenBytes, Constants.outputMaxBytes))

        if let processId = args.processId {
            guard let entry = await state.entry(for: processId) else {
                return ToolResult(callId: call.callId,
                                  output: "unified_exec: no such process \(processId)",
                                  success: false, truncated: false)
            }
            let input = args.input ?? ""
            let yieldMs = input.isEmpty
                ? Swift.max(Constants.minEmptyYieldMs,
                            Self.clamp(reqYield, Constants.yieldMinMs,
                                       Constants.yieldMaxMs))
                : Self.clamp(reqYield, Constants.yieldMinMs,
                             Constants.yieldMaxMs)
            do {
                if !input.isEmpty {
                    try await writeStdin(input, remoteProcessId: entry.remoteProcessId)
                }
                let read = try await readWindow(remoteProcessId: entry.remoteProcessId,
                                                afterSeq: entry.afterSeq,
                                                yieldMs: yieldMs,
                                                maxBytes: maxBytes)
                if let restart = await detectSessionRestart(
                    callId: call.callId,
                    localProcessId: processId,
                    entrySessionId: entry.serverSessionId) {
                    return restart
                }
                await state.updateAfterSeq(read.afterSeq, for: processId)
                if read.exited { await state.remove(processId) }
                return makeResult(callId: call.callId,
                                  processId: processId,
                                  output: read.output,
                                  exited: read.exited,
                                  exitCode: read.exitCode,
                                  truncated: read.truncated)
            } catch let error as ToolError {
                if let restart = await detectSessionRestart(
                    callId: call.callId,
                    localProcessId: processId,
                    entrySessionId: entry.serverSessionId) {
                    return restart
                }
                return ToolResult(callId: call.callId, output: error.message,
                                  success: false, truncated: false)
            } catch {
                if let restart = await detectSessionRestart(
                    callId: call.callId,
                    localProcessId: processId,
                    entrySessionId: entry.serverSessionId) {
                    return restart
                }
                return ToolResult(callId: call.callId,
                                  output: "remote unified_exec failed: \(error)",
                                  success: false, truncated: false)
            }
        }

        guard let spec = args.command else {
            return ToolResult(
                callId: call.callId,
                output: "unified_exec: provide `command` to open or "
                    + "`process_id`+`input` to continue",
                success: false, truncated: false)
        }

        let remoteProcessId = "ux_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            _ = try await client.request(method: "process/start", params: RemoteJSON([
                "processId": remoteProcessId,
                "argv": spec.argv,
                "cwd": cwd,
                "env": [:],
                "tty": true,
                "pipeStdin": true,
                "arg0": NSNull(),
            ]), replay: .tolerateExistsOnRetry)
            // Record the session that owns this remote process. A subsequent
            // exec-server restart will mint a fresh sessionId on
            // re-initialize; we detect that on the next read.
            let startSessionId = await client.currentSessionId()
            let localProcessId = await state.create(remoteProcessId: remoteProcessId,
                                                    serverSessionId: startSessionId)
            let yieldMs = Self.clamp(reqYield, Constants.yieldMinMs,
                                     Constants.yieldMaxMs)
            do {
                let read = try await readWindow(remoteProcessId: remoteProcessId,
                                                afterSeq: nil,
                                                yieldMs: yieldMs,
                                                maxBytes: maxBytes)
                if let restart = await detectSessionRestart(
                    callId: call.callId,
                    localProcessId: localProcessId,
                    entrySessionId: startSessionId) {
                    return restart
                }
                await state.updateAfterSeq(read.afterSeq, for: localProcessId)
                if read.exited { await state.remove(localProcessId) }
                return makeResult(callId: call.callId,
                                  processId: localProcessId,
                                  output: read.output,
                                  exited: read.exited,
                                  exitCode: read.exitCode,
                                  truncated: read.truncated)
            } catch let error as ToolError {
                if let restart = await detectSessionRestart(
                    callId: call.callId,
                    localProcessId: localProcessId,
                    entrySessionId: startSessionId) {
                    return restart
                }
                return ToolResult(callId: call.callId, output: error.message,
                                  success: false, truncated: false)
            }
        } catch let error as ToolError {
            return ToolResult(callId: call.callId, output: error.message,
                              success: false, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "remote unified_exec failed: \(error)",
                              success: false, truncated: false)
        }
    }

    /// Returns a structured restart marker if the exec-server sessionId has
    /// changed since `entrySessionId` was captured, and tears down the local
    /// process registry entry. Returns nil when the session is unchanged.
    private func detectSessionRestart(callId: String,
                                      localProcessId: Int,
                                      entrySessionId: String?) async -> ToolResult? {
        guard let entryId = entrySessionId,
              let currentId = await client.currentSessionId(),
              currentId != entryId else {
            return nil
        }
        await state.remove(localProcessId)
        return makeRestartResult(callId: callId, processId: localProcessId)
    }

    private func makeRestartResult(callId: String, processId: Int) -> ToolResult {
        let header = "[unified_exec process_id=\(processId) exited=true"
            + " restarted_by_server=true]"
        let body = "(remote exec-server restarted; the previous process handle "
            + "is gone — issue a fresh `command` to continue)"
        return ToolResult(callId: callId,
                          output: header + "\n" + body,
                          success: false, truncated: false)
    }

    private func writeStdin(_ input: String, remoteProcessId: String) async throws {
        // `.never`: writeStdin is the one client-irreparable non-idempotent op.
        // Upstream exec-server has no stdin-write deduplication, so a transport
        // failure mid-write would result in duplicate stdin on retry.
        _ = try await client.request(method: "process/writeStdin", params: RemoteJSON([
            "processId": remoteProcessId,
            "processHandle": remoteProcessId,
            "deltaBase64": Data(input.utf8).base64EncodedString(),
            "closeStdin": false,
        ]), replay: .never)
    }

    private func readWindow(remoteProcessId: String,
                            afterSeq: UInt64?,
                            yieldMs: Int,
                            maxBytes: Int) async throws
        -> (output: String, exited: Bool, exitCode: Int?, truncated: Bool,
            afterSeq: UInt64?) {
        let deadline = Date().addingTimeInterval(Double(yieldMs) / 1000.0)
        var nextSeq = afterSeq
        var output = HeadTailBuffer(maxBytes: maxBytes)
        var exited = false
        var exitCode: Int?

        repeat {
            var params: [String: Any] = [
                "processId": remoteProcessId,
                "maxBytes": maxBytes,
                "waitMs": 100,
            ]
            params["afterSeq"] = nextSeq.map { NSNumber(value: $0) } ?? NSNull()
            let read = try await client.request(method: "process/read",
                                                params: RemoteJSON(params),
                                                replay: .safe).object
            nextSeq = Self.uint64(read["nextSeq"]) ?? nextSeq
            if let chunks = read["chunks"] as? [[String: Any]] {
                for chunk in chunks {
                    if let base64 = chunk["chunk"] as? String
                        ?? chunk["deltaBase64"] as? String,
                       let bytes = Data(base64Encoded: base64) {
                        output.append(String(decoding: bytes, as: UTF8.self))
                    }
                }
            }
            exitCode = Self.int(read["exitCode"]) ?? exitCode
            exited = read["exited"] as? Bool ?? exited
            if let failure = read["failure"] as? String, !failure.isEmpty {
                throw ToolError(message: failure)
            }
            if exited || Date() >= deadline { break }
        } while true

        return (output.rendered(), exited, exitCode, output.didTruncate, nextSeq)
    }

    private func makeResult(callId: String, processId: Int,
                            output: String, exited: Bool,
                            exitCode: Int?, truncated: Bool) -> ToolResult {
        let exitPart = exitCode.map { " exit_code=\($0)" } ?? ""
        let header = "[unified_exec process_id=\(processId) exited=\(exited)\(exitPart)]"
        let body = output.isEmpty ? "(no output)" : output
        let success = !exited || exitCode == 0
        return ToolResult(callId: callId,
                          output: header + "\n" + body,
                          success: success,
                          truncated: truncated)
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        Swift.min(high, Swift.max(low, value))
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        if let i = value as? Int { return UInt64(i) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return nil
    }
}

public struct RemoteExecServerApplyPatchTool: Tool {
    public let name = "apply_patch"
    public let parallelSafe = false
    public var toolDescription: String {
        "Apply a Codex apply_patch envelope in the selected remote environment."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"patch":{"type":"string","description":"The *** Begin Patch / *** End Patch envelope"}},"required":["patch"],"additionalProperties":false}"#
    }

    private let client: RemoteExecServerJSONClient

    public init(websocketURL: String) {
        self.client = RemoteExecServerJSONClient(websocketURL: websocketURL)
    }

    private struct Args: Decodable { var patch: String }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid apply_patch arguments",
                              success: false, truncated: false)
        }
        let ap = ApplyPatch()
        do {
            let planned = try ap.parse(args.patch)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("remote-apply-patch-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: scratch,
                                                    withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            for file in planned {
                switch file.kind {
                case .add:
                    if try await remoteExists(file.path, cwd: cwd) {
                        throw ApplyPatchError.targetExists(file.path)
                    }
                case .update:
                    let original = try await readRemoteText(file.path, cwd: cwd)
                    try writeScratch(path: file.path, contents: original, root: scratch)
                    if let movePath = file.movePath, movePath != file.path,
                       try await remoteExists(movePath, cwd: cwd) {
                        throw ApplyPatchError.targetExists(movePath)
                    }
                case .delete:
                    let original = try await readRemoteText(file.path, cwd: cwd)
                    try writeScratch(path: file.path, contents: original, root: scratch)
                }
            }

            let applied = try ap.apply(args.patch, root: scratch.path)
            for file in applied {
                switch file.kind {
                case .add:
                    try await writeRemoteText(file.newContents ?? "", path: file.path, cwd: cwd)
                case .update:
                    let target = file.movePath ?? file.path
                    try await writeRemoteText(file.newContents ?? "", path: target, cwd: cwd)
                    if let movePath = file.movePath, movePath != file.path {
                        try await removeRemote(path: file.path, cwd: cwd)
                    }
                case .delete:
                    try await removeRemote(path: file.path, cwd: cwd)
                }
            }
            let summary = applied.map { file in
                if let movePath = file.movePath {
                    return "\(file.kind.rawValue) \(file.path) -> \(movePath)"
                }
                return "\(file.kind.rawValue) \(file.path)"
            }.joined(separator: "\n")
            return ToolResult(callId: call.callId, output: "applied:\n\(summary)",
                              success: true, truncated: false)
        } catch let error as ApplyPatchError {
            return ToolResult(callId: call.callId, output: "apply_patch failed: \(error)",
                              success: false, truncated: false)
        } catch let error as ToolError {
            return ToolResult(callId: call.callId, output: error.message,
                              success: false, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "apply_patch failed: \(error)",
                              success: false, truncated: false)
        }
    }

    private func remoteExists(_ path: String, cwd: String) async throws -> Bool {
        let remotePath = try RemotePath.resolve(path, cwd: cwd)
        do {
            _ = try await client.request(method: "fs/getMetadata", params: RemoteJSON([
                "path": remotePath,
                "sandbox": NSNull(),
            ]), replay: .safe)
            return true
        } catch let error as ToolError where RemoteErrorClassifier.isNotFound(error.message) {
            return false
        } catch {
            throw error
        }
    }

    private func readRemoteText(_ path: String, cwd: String) async throws -> String {
        let remotePath = try RemotePath.resolve(path, cwd: cwd)
        let response = try await client.request(method: "fs/readFile", params: RemoteJSON([
            "path": remotePath,
            "sandbox": NSNull(),
        ]), replay: .safe).object
        guard let base64 = response["dataBase64"] as? String,
              let bytes = Data(base64Encoded: base64) else {
            throw ToolError(message: "remote apply_patch read returned malformed data for \(path)")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeRemoteText(_ contents: String, path: String, cwd: String) async throws {
        let remotePath = try RemotePath.resolve(path, cwd: cwd)
        try await createRemoteParentDirectoryIfNeeded(for: path, cwd: cwd)
        _ = try await client.request(method: "fs/writeFile", params: RemoteJSON([
            "path": remotePath,
            "dataBase64": Data(contents.utf8).base64EncodedString(),
            "sandbox": NSNull(),
        ]), replay: .safe)
    }

    private func removeRemote(path: String, cwd: String) async throws {
        let remotePath = try RemotePath.resolve(path, cwd: cwd)
        _ = try await client.request(method: "fs/remove", params: RemoteJSON([
            "path": remotePath,
            "sandbox": NSNull(),
        ]), replay: .tolerateNotFoundOnRetry)
    }

    private func createRemoteParentDirectoryIfNeeded(for path: String, cwd: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != ".", parent != path else { return }
        let remoteParent = try RemotePath.resolve(parent, cwd: cwd)
        _ = try await client.request(method: "fs/createDirectory", params: RemoteJSON([
            "path": remoteParent,
            "recursive": true,
            "sandbox": NSNull(),
        ]), replay: .safe)
    }

    private func writeScratch(path: String, contents: String, root: URL) throws {
        let fileURL = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

public struct RemoteExecServerGitDiffTool: Tool {
    public let name = "git_diff"
    public let parallelSafe = true
    public var toolDescription: String {
        "Show the git diff in the selected remote environment: mode \"working\", \"staged\", or \"remote\"."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"mode":{"type":"string","enum":["working","staged","remote"]},"cwd":{"type":"string"}},"additionalProperties":false}"#
    }

    private struct Args: Decodable {
        var mode: String?
        var cwd: String?
    }

    private struct ProcessResult {
        var stdout: String
        var stderr: String
        var exitCode: Int
        var timedOut: Bool
    }

    private let client: RemoteExecServerJSONClient
    private let maxOutputBytes: Int

    public init(websocketURL: String, limits: Limits = Limits()) {
        self.client = RemoteExecServerJSONClient(websocketURL: websocketURL)
        self.maxOutputBytes = limits.clamped().maxToolOutputBytes
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let args = (call.argumentsJSON.data(using: .utf8)).flatMap {
            try? JSONDecoder().decode(Args.self, from: $0)
        } ?? Args(mode: nil, cwd: nil)
        do {
            let workDir = try args.cwd.map { try RemotePath.resolve($0, cwd: cwd) } ?? cwd
            let isRepo = try await runGit(["rev-parse", "--is-inside-work-tree"],
                                          cwd: workDir)
            guard isRepo.exitCode == 0,
                  Self.trim(isRepo.stdout) == "true" else {
                return ToolResult(callId: call.callId,
                                  output: "(not a git repository)",
                                  success: false,
                                  truncated: false)
            }

            let diff: String
            switch args.mode ?? "working" {
            case "staged":
                let staged = try await runGit(["diff", "--cached"], cwd: workDir)
                diff = staged.exitCode == 0 ? staged.stdout : ""
            case "remote":
                diff = try await remoteDiff(cwd: workDir)
            default:
                diff = try await workingDiff(cwd: workDir)
            }

            guard !diff.isEmpty else {
                return ToolResult(callId: call.callId,
                                  output: "(no changes)",
                                  success: true,
                                  truncated: false)
            }
            var ring = HeadTailBuffer(maxBytes: maxOutputBytes)
            ring.append(diff)
            return ToolResult(callId: call.callId,
                              output: ring.rendered(),
                              success: true,
                              truncated: ring.didTruncate)
        } catch let error as ToolError {
            return ToolResult(callId: call.callId, output: error.message,
                              success: false, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "remote git_diff failed: \(error)",
                              success: false, truncated: false)
        }
    }

    private func workingDiff(cwd: String) async throws -> String {
        let diff = try await runGit(["diff", "HEAD"], cwd: cwd)
        let base = diff.exitCode == 0 ? diff.stdout : ""
        return base + (try await untrackedDiffs(cwd: cwd))
    }

    private func remoteDiff(cwd: String) async throws -> String {
        guard let ref = try await defaultRemoteRef(cwd: cwd),
              let mergeBase = try await mergeBaseWithHead(ref, cwd: cwd) else {
            return try await workingDiff(cwd: cwd)
        }
        let diff = try await runGit(["diff", mergeBase], cwd: cwd)
        let base = diff.exitCode == 0 ? diff.stdout : ""
        return base + (try await untrackedDiffs(cwd: cwd))
    }

    private func untrackedDiffs(cwd: String) async throws -> String {
        let listed = try await runGit(["ls-files", "--others", "--exclude-standard"],
                                      cwd: cwd)
        guard listed.exitCode == 0 else { return "" }
        var out = ""
        for line in listed.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let file = String(line)
            let diff = try await runGit(["diff", "--no-index", "/dev/null", file],
                                        cwd: cwd)
            if diff.exitCode == 0 || diff.exitCode == 1 {
                out += diff.stdout
            }
        }
        return out
    }

    private func defaultRemoteRef(cwd: String) async throws -> String? {
        let upstream = try await runGit(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            cwd: cwd)
        if upstream.exitCode == 0 {
            let ref = Self.trim(upstream.stdout)
            if !ref.isEmpty { return ref }
        }
        let symbolic = try await runGit(
            ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
            cwd: cwd)
        if symbolic.exitCode == 0 {
            var ref = Self.trim(symbolic.stdout)
            if ref.hasPrefix("refs/remotes/") {
                ref = String(ref.dropFirst("refs/remotes/".count))
            }
            if !ref.isEmpty { return ref }
        }
        for candidate in ["origin/main", "origin/master"] {
            let verified = try await runGit(
                ["rev-parse", "--verify", "--quiet", candidate],
                cwd: cwd)
            if verified.exitCode == 0 { return candidate }
        }
        return nil
    }

    private func mergeBaseWithHead(_ ref: String, cwd: String) async throws -> String? {
        let result = try await runGit(["merge-base", "HEAD", ref], cwd: cwd)
        guard result.exitCode == 0 else { return nil }
        let sha = Self.trim(result.stdout)
        return Self.isHex40(sha) ? sha : nil
    }

    private func runGit(_ args: [String], cwd: String) async throws -> ProcessResult {
        let processId = "git_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        _ = try await client.request(method: "process/start", params: RemoteJSON([
            "processId": processId,
            "argv": ["git"] + args,
            "cwd": cwd,
            "env": [:],
            "tty": false,
            "pipeStdin": false,
            "arg0": NSNull(),
        ]), replay: .tolerateExistsOnRetry)

        let deadline = Date().addingTimeInterval(30)
        var afterSeq: UInt64?
        var stdout = HeadTailBuffer(maxBytes: 1024 * 1024)
        var stderr = HeadTailBuffer(maxBytes: 1024 * 1024)
        var exitCode: Int?
        while Date() < deadline {
            var params: [String: Any] = [
                "processId": processId,
                "maxBytes": 1024 * 1024,
                "waitMs": 100,
            ]
            params["afterSeq"] = afterSeq.map { NSNumber(value: $0) } ?? NSNull()
            let read = try await client.request(method: "process/read",
                                                params: RemoteJSON(params),
                                                replay: .safe).object
            afterSeq = Self.uint64(read["nextSeq"]) ?? afterSeq
            if let chunks = read["chunks"] as? [[String: Any]] {
                for chunk in chunks {
                    let stream = chunk["stream"] as? String ?? "stdout"
                    if let base64 = chunk["chunk"] as? String
                        ?? chunk["deltaBase64"] as? String,
                       let bytes = Data(base64Encoded: base64) {
                        if stream == "stderr" {
                            stderr.append(String(decoding: bytes, as: UTF8.self))
                        } else {
                            stdout.append(String(decoding: bytes, as: UTF8.self))
                        }
                    }
                }
            }
            exitCode = Self.int(read["exitCode"]) ?? exitCode
            if let failure = read["failure"] as? String, !failure.isEmpty {
                return ProcessResult(stdout: stdout.rendered(), stderr: failure,
                                     exitCode: -1, timedOut: false)
            }
            let exited = read["exited"] as? Bool ?? false
            let closed = read["closed"] as? Bool ?? false
            if exited && closed {
                return ProcessResult(stdout: stdout.rendered(), stderr: stderr.rendered(),
                                     exitCode: exitCode ?? 0, timedOut: false)
            }
        }
        _ = try? await client.request(method: "process/terminate",
                                      params: RemoteJSON(["processId": processId]))
        return ProcessResult(stdout: "", stderr: "git timed out",
                             exitCode: -1, timedOut: true)
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHex40(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        if let i = value as? Int { return UInt64(i) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return nil
    }
}

public struct RemoteExecServerFileSearchTool: Tool {
    public let name = "file_search"
    public let parallelSafe = true
    public var toolDescription: String {
        "Fuzzy-search filenames in the selected remote environment."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"],"additionalProperties":false}"#
    }

    private let client: RemoteExecServerJSONClient
    private let maxEntries: Int
    private let defaultLimit: Int

    public init(websocketURL: String, maxEntries: Int = 20_000,
                defaultLimit: Int = 50) {
        self.client = RemoteExecServerJSONClient(websocketURL: websocketURL)
        self.maxEntries = maxEntries
        self.defaultLimit = defaultLimit
    }

    private struct Args: Decodable { var query: String; var limit: Int? }
    private static let skipDirs: Set<String> = [
        ".git", ".build", "node_modules", ".swiftpm", "DerivedData",
        ".venv", "venv", "__pycache__", ".mypy_cache", "target", "dist",
    ]

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return ToolResult(callId: call.callId, output: "invalid file_search arguments",
                              success: false, truncated: false)
        }
        let limit = max(1, min(args.limit ?? defaultLimit, 500))
        do {
            let root = try RemotePath.resolve("", cwd: cwd)
            var stack: [(remotePath: String, relativePath: String)] = [(root, "")]
            var visited = 0
            var seenDirs = Set<String>()
            var results: [(path: String, score: Int)] = []

            while let current = stack.popLast() {
                guard seenDirs.insert(current.remotePath).inserted else { continue }
                let response = try await client.request(
                    method: "fs/readDirectory",
                    params: RemoteJSON(["path": current.remotePath, "sandbox": NSNull()])
                , replay: .safe).object
                let entries = response["entries"] as? [[String: Any]] ?? []
                for entry in entries.sorted(by: { Self.fileName($0) < Self.fileName($1) }) {
                    if visited >= maxEntries { break }
                    guard let name = entry["fileName"] as? String,
                          !name.isEmpty,
                          name != ".",
                          name != "..",
                          !name.contains("/") else { continue }
                    visited += 1
                    let relative = current.relativePath.isEmpty
                        ? name
                        : current.relativePath + "/" + name
                    let full = (current.remotePath as NSString).appendingPathComponent(name)
                    let isDirectory = entry["isDirectory"] as? Bool ?? false
                    let isFile = entry["isFile"] as? Bool ?? !isDirectory
                    if isDirectory {
                        if !Self.skipDirs.contains(name) {
                            stack.append((full, relative))
                        }
                    } else if isFile, let score = FileSearchTool.score(args.query, relative) {
                        results.append((relative, score))
                    }
                }
                if visited >= maxEntries { break }
            }

            results.sort {
                $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path
            }
            let top = results.prefix(limit).map(\.path)
            return ToolResult(callId: call.callId,
                              output: top.isEmpty ? "(no matches)" : top.joined(separator: "\n"),
                              success: true, truncated: false)
        } catch let error as ToolError {
            return ToolResult(callId: call.callId, output: error.message,
                              success: false, truncated: false)
        }
    }

    private static func fileName(_ entry: [String: Any]) -> String {
        entry["fileName"] as? String ?? ""
    }
}

public enum RemoteExecServerTools {
    public static func register(on router: ToolRouter,
                                websocketURL: String,
                                limits: Limits = Limits()) async {
        await router.register(RemoteExecServerApplyPatchTool(websocketURL: websocketURL))
        await router.register(RemoteExecServerUnifiedExecTool(websocketURL: websocketURL,
                                                              limits: limits))
        await router.register(RemoteExecServerGitDiffTool(websocketURL: websocketURL,
                                                          limits: limits))
        await router.register(RemoteExecServerFileSearchTool(websocketURL: websocketURL))
        await router.register(RemoteExecServerShellTool(websocketURL: websocketURL,
                                                        limits: limits))
        await router.register(RemoteExecServerReadFileTool(websocketURL: websocketURL,
                                                           limits: limits))
        await router.register(RemoteExecServerWriteFileTool(websocketURL: websocketURL))
        await router.register(RemoteExecServerListDirTool(websocketURL: websocketURL))
    }
}
