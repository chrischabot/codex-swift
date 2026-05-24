import Foundation
import InfraPrimitives

private final class CurlStreamState: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var outHandle: FileHandle?
    private var errHandle: FileHandle?
    private var cancelled = false

    func setReadHandles(out: FileHandle, err: FileHandle) {
        lock.lock()
        if cancelled {
            try? out.close()
            try? err.close()
        } else {
            outHandle = out
            errHandle = err
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let out = outHandle
        let err = errHandle
        outHandle = nil
        errHandle = nil
        if process.isRunning {
            process.terminate()
        }
        lock.unlock()

        // `FileHandle.availableData` can remain blocked after SIGTERM until the
        // pipe endpoint changes state. Closing the read handles gives cancelled
        // streams a deterministic wake-up path so XCTest does not wait forever
        // on a stray reader thread.
        try? out?.close()
        try? err?.close()
    }
}

/// Portable OpenAI Responses API client (`POST /v1/responses`, `stream:true`).
///
/// SSE is streamed by spawning `curl -sS -N` (ubiquitous on Linux + macOS,
/// `-N` disables buffering — ideal for SSE) and reading its stdout on a
/// dedicated OS thread that feeds an `AsyncThrowingStream`, mapped through
/// `StreamMapper` (bounded, consumer-dropped cancellation kills curl). This is
/// the portable live-test client. Curl receives sensitive headers through a
/// temporary 0600 config file rather than argv. On macOS,
/// `URLSessionResponsesClient` is the production SSE path; WebSocket
/// prewarm/attestation/zstd/401→broker refresh remain the P2-M1 completion
/// layer.
public actor OpenAIResponsesClient: ModelClient {
    private let provider: ModelProvider
    private let env: [String: String]
    private let usageTracker: UsageTracker?
    /// Set only by the legacy `init(apiKey:endpoint:)` to guarantee
    /// byte-identical URL + Authorization for existing callers.
    private let explicitEndpoint: String?
    private let explicitBearer: String?
    private let maxOutputTokens: Int?
    private let streamCapacity: Int
    private let requestTimeoutSeconds: Int

    /// Designated provider-based initializer.
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
        self.requestTimeoutSeconds = Self.transportTimeoutSeconds(clamped)
    }

    /// Legacy initializer — preserved byte-for-byte. Synthesizes an `openai`
    /// provider but uses `explicitEndpoint`/`explicitBearer` verbatim so the
    /// POST URL and `Authorization` header are exactly as before.
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
        self.requestTimeoutSeconds = Self.transportTimeoutSeconds(clamped)
    }

    private static func transportTimeoutSeconds(_ limits: Limits) -> Int {
        Swift.max(1, Swift.min(Int(ceil(limits.turnDeadline.seconds)), 180))
    }

    private static func curlConfigValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Deterministic, offline-testable request body. `prompt_cache_key` is the
    /// thread id (Codex contract); developer/assistant roles and
    /// function-call-output replay are mapped faithfully.
    public static func buildRequestBody(_ prompt: Prompt, _ settings: ModelSettings,
                                        maxOutputTokens: Int?) -> [String: Any] {
        var input: [[String: Any]] = []
        for item in prompt.input {
            switch item {
            case .userText(let t):
                input.append(["role": "user",
                              "content": [["type": "input_text", "text": t]]])
            case .developerText(let t):
                input.append(["role": "developer",
                              "content": [["type": "input_text", "text": t]]])
            case .assistantText(let t):
                input.append(["role": "assistant",
                              "content": [["type": "output_text", "text": t]]])
            case .toolOutput(let callId, let output):
                // Replay a minimal preceding function_call so the API accepts
                // the function_call_output (it requires a matching call).
                input.append(["type": "function_call", "call_id": callId,
                              "name": "tool", "arguments": "{}"])
                input.append(["type": "function_call_output",
                              "call_id": callId, "output": output])
            }
        }
        if input.isEmpty {
            input.append(["role": "user",
                          "content": [["type": "input_text", "text": " "]]])
        }
        // P6.1: Request body fields now mirror upstream Codex's
        // `ResponsesApiRequest` (`codex-rs/codex-api/src/common.rs` line 170)
        // populated by `build_responses_request`
        // (`codex-rs/core/src/client.rs` lines 709-766). Eight fields that
        // were previously missing — `tool_choice`, `parallel_tool_calls`,
        // `reasoning`, `store`, `include`, `service_tier`, `text`,
        // `client_metadata` — are now sent so reasoning-capable models surface
        // thought summaries, encrypted reasoning is preserved across turns,
        // and the server can call tools (default `tool_choice: "auto"`).
        // `previous_response_id` + `store: false` is incompatible — OpenAI
        // requires the prior response to have been stored (`store: true`)
        // before it can be referenced. Upstream's default of `store: false`
        // only works because its REST path doesn't chain via
        // `previous_response_id` (it relies on `prompt_cache_key` + full
        // transcript replay). Our turn loop DOES set `previousResponseId`
        // for sticky routing within a turn, so we must force `store: true`
        // whenever it's set. Callers that explicitly want `store: false`
        // for an un-chained call simply leave `previousResponseId` nil.
        let effectiveStore = settings.previousResponseId != nil ? true : settings.store
        var body: [String: Any] = [
            "model": settings.model,
            "instructions": prompt.instructions,
            "input": input,
            "stream": true,
            "prompt_cache_key": settings.threadId,
            "tool_choice": settings.toolChoice,
            "parallel_tool_calls": settings.parallelToolCalls,
            "store": effectiveStore,
        ]
        if let previousResponseId = settings.previousResponseId {
            body["previous_response_id"] = previousResponseId
        }
        if !prompt.tools.isEmpty {
            body["tools"] = prompt.tools.map { spec -> [String: Any] in
                let params = ((try? JSONSerialization.jsonObject(
                    with: Data(spec.parametersJSON.utf8))) as? [String: Any])
                    ?? ["type": "object", "additionalProperties": true]
                var entry: [String: Any] = ["type": "function", "name": spec.name,
                                            "description": spec.description,
                                            "parameters": params]
                // P4.8 / H-32 — optional `output_schema` declared alongside
                // `parameters` (mirrors `codex_tools::ResponsesApiTool.output_schema`).
                // Only emitted when the tool declared one; otherwise we keep
                // the wire shape unchanged so existing fixtures stay byte-stable.
                if let outSchema = spec.outputSchemaJSON,
                   let parsed = (try? JSONSerialization.jsonObject(
                    with: Data(outSchema.utf8))) as? [String: Any] {
                    entry["output_schema"] = parsed
                }
                return entry
            }
        } else {
            // Upstream always serializes `tools: []` (non-skippable field).
            // Send an empty array rather than omitting so the wire shape
            // matches `ResponsesApiRequest::tools: Vec<Value>`.
            body["tools"] = [] as [Any]
        }
        if let m = maxOutputTokens { body["max_output_tokens"] = m }

        // Reasoning + `include`. Upstream's `build_reasoning` only emits the
        // object when the model "supports reasoning summaries". codex-swift
        // does not yet maintain a model-info table, so we treat the caller-
        // provided `reasoningEffort` as the authoritative signal: present
        // means the model is reasoning-capable, absent means it is not.
        // `include` defaults to `["reasoning.encrypted_content"]` when
        // reasoning is active (matches upstream `client.rs` lines 722-726).
        //
        // Wire shape for `reasoning`: upstream's `ResponsesApiRequest.reasoning`
        // is `Option<Reasoning>` with NO `skip_serializing_if`
        // (`codex-api/src/common.rs:178`), so serde emits `"reasoning": null`
        // when the field is `None`. We mirror that by emitting `NSNull()` when
        // reasoning is inactive rather than omitting the key — keeps wire
        // shape byte-equivalent to upstream Rust output.
        var reasoning: [String: Any] = [:]
        if let effort = settings.reasoningEffort, !effort.isEmpty {
            reasoning["effort"] = effort
        }
        if let summary = settings.reasoningSummary, !summary.isEmpty {
            reasoning["summary"] = summary
        }
        if !reasoning.isEmpty {
            body["reasoning"] = reasoning
        } else {
            body["reasoning"] = NSNull()
        }
        let include: [String] = settings.include
            ?? (reasoning.isEmpty ? [] : ["reasoning.encrypted_content"])
        body["include"] = include

        if let tier = settings.serviceTier, !tier.isEmpty {
            body["service_tier"] = tier
        }

        // Optional `text` controls — verbosity only for now; JSON-schema
        // output is intentionally deferred (no callers route through it yet).
        if let verbosity = settings.textVerbosity, !verbosity.isEmpty {
            body["text"] = ["verbosity": verbosity]
        }

        // `client_metadata` mirrors upstream's REST shape
        // (`client.rs:760-763`): the REST `build_responses_request` only puts
        // `x-codex-installation-id` into the map. `cli_version` /
        // `originator` are NOT in the REST body — they live in
        // `build_ws_client_metadata` (WebSocket path) and `session_meta`
        // (rollout telemetry).
        //
        // We therefore emit whatever caller-supplied keys are in
        // `settings.clientMetadata` verbatim. The field is
        // `skip_serializing_if = Option::is_none` upstream
        // (`common.rs:188`), so when no entries are supplied we omit the
        // field entirely instead of emitting fake defaults the server may
        // reject or count as drift.
        if !settings.clientMetadata.isEmpty {
            body["client_metadata"] = settings.clientMetadata
        }

        return body
    }

    public func stream(_ prompt: Prompt,
                       _ settings: ModelSettings) async throws -> ResponseStream {
        let body = Self.buildRequestBody(prompt, settings,
                                         maxOutputTokens: maxOutputTokens)
        let data = try JSONSerialization.data(withJSONObject: body)
        let cap = streamCapacity
        let url = explicitEndpoint ?? provider.responsesURL()
        let authHeader: String? = {
            if let b = explicitBearer { return "Bearer \(b)" }
            return provider.effectiveAuthHeader(env: env)
        }()
        let extraHeaders = provider.resolvedHeaders(env: env)
        let headerDumpPath = NSTemporaryDirectory()
            + "codexkit-hdr-" + UUID().uuidString
        let curlConfigPath = NSTemporaryDirectory()
            + "codexkit-curl-" + UUID().uuidString
        let tracker = usageTracker
        let timeoutSecs = requestTimeoutSeconds

        @Sendable func intOf(_ v: Any?) -> Int {
            if let i = v as? Int { return i }
            if let d = v as? Double { return Int(d) }
            if let n = v as? NSNumber { return n.intValue }
            return 0
        }

        return StreamMapper.map(capacity: cap) {
            AsyncThrowingStream<ResponseEvent, any Error> { cont in
                let recordTelemetry: @Sendable () -> Void = {
                    let dump = (try? String(
                        contentsOfFile: headerDumpPath,
                        encoding: .utf8)) ?? ""
                    if let tracker = tracker,
                       let snap = RateLimitSnapshot.parseRateLimits(
                        headerDump: dump) {
                        Task.detached { await tracker.recordRateLimits(snap) }
                    }
                    try? FileManager.default.removeItem(
                        atPath: headerDumpPath)
                    try? FileManager.default.removeItem(
                        atPath: curlConfigPath)
                }

                let state = CurlStreamState()
                let proc = state.process
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                let connectTimeout = Swift.max(1, Swift.min(20, timeoutSecs))
                var configLines = [
                    "header = \"Content-Type: application/json\"",
                    "header = \"Accept: text/event-stream\"",
                ]
                if let a = authHeader {
                    configLines.append(
                        "header = \"Authorization: \(Self.curlConfigValue(a))\"")
                }
                if let turnState = settings.turnState {
                    configLines.append(
                        "header = \"x-codex-turn-state: \(Self.curlConfigValue(turnState))\"")
                }
                for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) {
                    configLines.append(
                        "header = \"\(Self.curlConfigValue(k)): \(Self.curlConfigValue(v))\"")
                }
                let curlConfig = configLines.joined(separator: "\n") + "\n"
                do {
                    try curlConfig.write(toFile: curlConfigPath,
                                         atomically: true,
                                         encoding: .utf8)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: curlConfigPath)
                } catch {
                    recordTelemetry()
                    cont.finish(throwing: ModelError(
                        "failed to create curl config: \(error)",
                        retryable: false))
                    return
                }
                var args = ["curl", "-sS", "-N", "--no-buffer",
                            "--connect-timeout", "\(connectTimeout)",
                            "--max-time", "\(timeoutSecs)",
                            "-D", headerDumpPath,
                            "-K", curlConfigPath,
                            "-X", "POST", url]
                args += ["--data-binary", "@-"]
                proc.arguments = args
                let inPipe = Pipe()
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardInput = inPipe
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                cont.onTermination = { _ in
                    state.cancel()
                }
                do {
                    try proc.run()
                } catch {
                    recordTelemetry()
                    cont.finish(throwing: ModelError(
                        "failed to spawn curl: \(error)", retryable: false))
                    return
                }
                inPipe.fileHandleForWriting.write(data)
                try? inPipe.fileHandleForWriting.close()
                let outH = outPipe.fileHandleForReading
                let errH = errPipe.fileHandleForReading
                state.setReadHandles(out: outH, err: errH)
                let reader = Thread {
                    var buf = Data()
                    var sawAny = false
                    while true {
                        let chunk = outH.availableData
                        if chunk.isEmpty { break }
                        buf.append(chunk)
                        while let nl = buf.firstIndex(of: 0x0A) {
                            let lineData = buf.subdata(in: buf.startIndex..<nl)
                            buf.removeSubrange(buf.startIndex...nl)
                            guard let raw = String(data: lineData, encoding: .utf8)
                            else { continue }
                            let line = raw.hasSuffix("\r")
                                ? String(raw.dropLast()) : raw
                            guard line.hasPrefix("data:") else { continue }
                            var payload = String(line.dropFirst(5))
                            if payload.hasPrefix(" ") { payload.removeFirst() }
                            if payload.isEmpty || payload == "[DONE]" { continue }
                            guard let pd = payload.data(using: .utf8),
                                  let obj = (try? JSONSerialization.jsonObject(
                                    with: pd)) as? [String: Any] else { continue }
                            sawAny = true
                            if let err = obj["error"] as? [String: Any] {
                                let msg = (err["message"] as? String) ?? "OpenAI error"
                                recordTelemetry()
                                cont.finish(throwing: ModelError(msg, retryable: false))
                                return
                            }
                            let type = obj["type"] as? String ?? ""
                            switch type {
                            case "response.created":
                                cont.yield(.created)
                            case "response.output_text.delta":
                                let id = obj["item_id"] as? String ?? "msg"
                                let d = obj["delta"] as? String ?? ""
                                if !d.isEmpty {
                                    cont.yield(.agentDelta(itemId: id, delta: d))
                                }
                            case "response.output_item.done":
                                if let it = obj["item"] as? [String: Any] {
                                    let itype = it["type"] as? String ?? ""
                                    if itype == "message" {
                                        let id = it["id"] as? String ?? "msg"
                                        var text = ""
                                        if let content = it["content"]
                                            as? [[String: Any]] {
                                            for c in content {
                                                if let s = c["text"] as? String {
                                                    text += s
                                                }
                                            }
                                        }
                                        cont.yield(.agentDone(itemId: id, text: text))
                                    } else if itype == "function_call" {
                                        let callId = it["call_id"]
                                            as? String ?? "call"
                                        let name = it["name"] as? String ?? ""
                                        let args = it["arguments"]
                                            as? String ?? "{}"
                                        cont.yield(.toolCall(callId: callId,
                                                             name: name,
                                                             argumentsJSON: args))
                                    }
                                }
                            case "response.failed":
                                // P6.2 / H-44: classify `error.code` so the
                                // retry / turn loop can branch on
                                // context_window_exceeded, quota_exceeded,
                                // cyber_policy, server_is_overloaded, etc.
                                let resp = obj["response"] as? [String: Any]
                                let err = resp?["error"] as? [String: Any]
                                recordTelemetry()
                                cont.finish(throwing: ModelClientErrorClassifier
                                    .classifyResponseFailed(err))
                                return
                            case "response.incomplete":
                                // P6.2 / H-43 + STATUS.md:624-629: when reason
                                // is `max_output_tokens`, treat as
                                // terminal-completed so the turn keeps its
                                // partial output + accurate usage accounting.
                                // Other reasons (content_filter, etc.) fall
                                // through to the retryable stream-error path.
                                let respIncomplete =
                                    obj["response"] as? [String: Any]
                                if !ModelClientErrorClassifier
                                    .incompleteIsTerminalSuccess(respIncomplete) {
                                    recordTelemetry()
                                    cont.finish(throwing: ModelClientErrorClassifier
                                        .classifyIncomplete(respIncomplete))
                                    return
                                }
                                fallthrough
                            case "response.completed":
                                let resp = obj["response"] as? [String: Any]
                                let id = resp?["id"] as? String ?? "resp"
                                let usage = resp?["usage"] as? [String: Any]
                                let total = intOf(usage?["total_tokens"])
                                let details = usage?["input_tokens_details"]
                                    as? [String: Any]
                                // P2.2 / H-05: extract reasoning token count
                                // from `output_tokens_details.reasoning_tokens`
                                // (OpenAI Responses shape) so the per-call
                                // delta carries the full upstream breakdown.
                                let outputDetails = usage?["output_tokens_details"]
                                    as? [String: Any]
                                let snap = UsageSnapshot(
                                    inputTokens: intOf(usage?["input_tokens"]),
                                    cachedInputTokens: intOf(
                                        details?["cached_tokens"]),
                                    outputTokens: intOf(usage?["output_tokens"]),
                                    reasoningOutputTokens: intOf(
                                        outputDetails?["reasoning_tokens"]),
                                    totalTokens: total)
                                if let tracker = tracker {
                                    Task.detached {
                                        await tracker.recordUsage(snap)
                                    }
                                }
                                cont.yield(.completed(responseId: id,
                                                      totalTokens: total,
                                                      endTurn: true,
                                                      usage: snap))
                                recordTelemetry()
                                cont.finish()
                                return
                            default:
                                continue
                            }
                        }
                    }
                    state.process.waitUntilExit()
                    if !sawAny {
                        let e = errH.readDataToEndOfFile()
                        let emsg = String(data: e, encoding: .utf8) ?? ""
                        recordTelemetry()
                        cont.finish(throwing: ModelError(
                            "no SSE from OpenAI (exit \(state.process.terminationStatus)): "
                            + "\(emsg.prefix(400))", retryable: false))
                        return
                    }
                    recordTelemetry()
                    cont.finish()
                }
                reader.stackSize = 1 << 20
                reader.name = "openai-sse-reader"
                reader.start()
            }
        }
    }
}
