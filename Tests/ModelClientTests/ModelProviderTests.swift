import XCTest
import Foundation
@testable import ModelClient
@testable import InfraPrimitives

final class ModelProviderTests: XCTestCase {

    func testBuiltinOpenAIProviderDefaults() {
        let p = ModelProvider.openAI
        XCTAssertEqual(p.id, "openai")
        XCTAssertEqual(p.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(p.envKey, "OPENAI_API_KEY")
        XCTAssertEqual(p.wireApi, .responses)
        XCTAssertTrue(p.requiresOpenAIAuth)
        XCTAssertEqual(p.responsesURL(),
                       "https://api.openai.com/v1/responses")
    }

    func testAuthHeaderPrecedenceAndEnvResolution() {
        let bearer = ModelProvider(
            id: "x", name: "X", baseURL: "https://e",
            envKey: "MY_KEY", experimentalBearerToken: "tok")
        XCTAssertEqual(
            bearer.effectiveAuthHeader(env: ["MY_KEY": "envval"]),
            "Bearer tok")

        let envOnly = ModelProvider(
            id: "x", name: "X", baseURL: "https://e", envKey: "MY_KEY")
        XCTAssertEqual(
            envOnly.effectiveAuthHeader(env: ["MY_KEY": "envval"]),
            "Bearer envval")
        XCTAssertNil(envOnly.effectiveAuthHeader(env: [:]))
        XCTAssertNil(envOnly.effectiveAuthHeader(env: ["MY_KEY": ""]))

        let none = ModelProvider(id: "x", name: "X", baseURL: "https://e")
        XCTAssertNil(none.effectiveAuthHeader(env: [:]))
    }

    func testResolvedHeadersIncludeEnvHttpOnlyWhenSet() {
        let p = ModelProvider(
            id: "x", name: "X", baseURL: "https://e",
            httpHeaders: ["X-Static": "s"],
            envHttpHeaders: ["X-Env": "ENV_VAR"])
        XCTAssertEqual(p.resolvedHeaders(env: [:]), ["X-Static": "s"])
        XCTAssertEqual(p.resolvedHeaders(env: ["ENV_VAR": "v"]),
                       ["X-Static": "s", "X-Env": "v"])
        XCTAssertEqual(p.resolvedHeaders(env: ["ENV_VAR": ""]),
                       ["X-Static": "s"])
    }

    func testResponsesURLAppendsSortedQueryParams() {
        let p = ModelProvider(
            id: "x", name: "X", baseURL: "https://api.example.com/v1/",
            queryParams: ["b": "2 2", "a": "1"])
        XCTAssertEqual(p.responsesURL(),
                       "https://api.example.com/v1/responses?a=1&b=2%202")
    }

    func testRegistryLoadFromConfigObject() throws {
        let custom: [String: ConfigValueLite] = [
            "name": .string("Custom"),
            "base_url": .string("https://custom.example/v2"),
            "env_key": .string("CUSTOM_KEY"),
            "wire_api": .string("responses"),
            "http_headers": .object(["X-H": .string("hv")]),
            "env_http_headers": .object(["X-E": .string("CUSTOM_ENV")]),
            "query_params": .object(["q": .string("1")]),
            "request_max_retries": .int(7),
        ]
        let cfg: [String: ConfigValueLite] = [
            "model_providers": .object(["custom": .object(custom)]),
        ]
        let reg = try ModelProviderRegistry.load(from: cfg)
        XCTAssertNotNil(reg.providers["openai"])
        let c = reg.resolve("custom")
        XCTAssertEqual(c.baseURL, "https://custom.example/v2")
        XCTAssertEqual(c.envKey, "CUSTOM_KEY")
        XCTAssertEqual(c.wireApi, .responses)
        XCTAssertEqual(c.httpHeaders, ["X-H": "hv"])
        XCTAssertEqual(c.envHttpHeaders, ["X-E": "CUSTOM_ENV"])
        XCTAssertEqual(c.queryParams, ["q": "1"])
        XCTAssertEqual(c.requestMaxRetries, 7)
        XCTAssertEqual(reg.resolve(nil).id, "openai")
        XCTAssertEqual(reg.resolve("unknown").id, "openai")
    }

    func testRegistryLoadFromJSON() throws {
        let json = """
        {"model_providers":{"custom":{"name":"Custom",\
        "base_url":"https://c/v2","env_key":"CK","wire_api":"responses",\
        "http_headers":{"X-H":"hv"},"env_http_headers":{"X-E":"CE"},\
        "query_params":{"q":"1"},"request_max_retries":3}}}
        """
        let reg = try ModelProviderRegistry.load(fromJSON: Data(json.utf8))
        let c = reg.resolve("custom")
        XCTAssertEqual(c.baseURL, "https://c/v2")
        XCTAssertEqual(c.wireApi, .responses)
        XCTAssertEqual(c.requestMaxRetries, 3)
        XCTAssertNotNil(reg.providers["openai"])
    }

    /// P1.7: upstream removed `wire_api = "chat"` and hard-errors on it
    /// (`CHAT_WIRE_API_REMOVED_ERROR`). The Swift registry loader must
    /// reject the same string instead of silently accepting it.
    func testWireApiChatRejected() {
        let custom: [String: ConfigValueLite] = [
            "name": .string("LegacyChat"),
            "base_url": .string("https://legacy.example/v1"),
            "env_key": .string("LEGACY_KEY"),
            "wire_api": .string("chat"),
        ]
        let cfg: [String: ConfigValueLite] = [
            "model_providers": .object(["legacy": .object(custom)]),
        ]
        XCTAssertThrowsError(try ModelProviderRegistry.load(from: cfg)) {
            error in
            guard let err = error as? ModelProviderConfigError else {
                return XCTFail("expected ModelProviderConfigError, got \(error)")
            }
            XCTAssertEqual(err, .chatWireApiRemoved(providerId: "legacy"))
            let msg = String(describing: err)
            XCTAssertTrue(msg.contains("`wire_api = \"chat\"`"),
                          "error must mention the removed setting; got: \(msg)")
            XCTAssertTrue(msg.contains("responses"),
                          "error must point users at the `responses` value; got: \(msg)")
        }

        // JSON variant mirrors `load(fromJSON:)` flow.
        let json = """
        {"model_providers":{"legacy":{"name":"L","base_url":"https://x",\
        "env_key":"K","wire_api":"chat"}}}
        """
        XCTAssertThrowsError(
            try ModelProviderRegistry.load(fromJSON: Data(json.utf8))
        ) { error in
            XCTAssertEqual(
                error as? ModelProviderConfigError,
                .chatWireApiRemoved(providerId: "legacy"))
        }

        // `loadOrDefault` falls back to the built-in registry instead of
        // throwing — used by non-throwing internal call sites.
        let fallback = ModelProviderRegistry.loadOrDefault(from: cfg)
        XCTAssertNotNil(fallback.providers["openai"])
        XCTAssertNil(fallback.providers["legacy"])
    }

    func testUnknownWireApiRejected() {
        let custom: [String: ConfigValueLite] = [
            "name": .string("Bogus"),
            "base_url": .string("https://x"),
            "wire_api": .string("grpc"),
        ]
        let cfg: [String: ConfigValueLite] = [
            "model_providers": .object(["bogus": .object(custom)]),
        ]
        XCTAssertThrowsError(try ModelProviderRegistry.load(from: cfg)) {
            error in
            XCTAssertEqual(
                error as? ModelProviderConfigError,
                .unknownWireApi(providerId: "bogus", value: "grpc"))
        }
    }

    func testParseRateLimitsHeaderFamily() {
        let dump = """
        HTTP/2 200
        content-type: text/event-stream
        x-codex-primary-used-percent: 42.5
        x-codex-primary-window-minutes: 60
        x-codex-primary-reset-at: 2026-01-01T00:00:00Z
        x-codex-secondary-used-percent: 10
        x-codex-limit-name: codex
        """
        let snap = RateLimitSnapshot.parseRateLimits(headerDump: dump)
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.primary?.usedPercent, 42.5)
        XCTAssertEqual(snap?.primary?.windowMinutes, 60)
        XCTAssertEqual(snap?.primary?.resetAt, "2026-01-01T00:00:00Z")
        XCTAssertEqual(snap?.secondary?.usedPercent, 10)
        XCTAssertNil(snap?.secondary?.windowMinutes)
        XCTAssertNil(snap?.secondary?.resetAt)
        XCTAssertEqual(snap?.limitName, "codex")

        let none = RateLimitSnapshot.parseRateLimits(
            headerDump: "HTTP/2 200\ncontent-type: text/plain")
        XCTAssertNil(none)
    }

    func testUsageTrackerLastWriteWins() async {
        let t = UsageTracker()
        await t.recordUsage(UsageSnapshot(
            inputTokens: 1, cachedInputTokens: 0,
            outputTokens: 1, totalTokens: 2))
        await t.recordUsage(UsageSnapshot(
            inputTokens: 5, cachedInputTokens: 2,
            outputTokens: 3, totalTokens: 8))
        let u = await t.lastUsage()
        XCTAssertEqual(u, UsageSnapshot(
            inputTokens: 5, cachedInputTokens: 2,
            outputTokens: 3, totalTokens: 8))

        await t.recordRateLimits(RateLimitSnapshot(limitName: "a"))
        await t.recordRateLimits(RateLimitSnapshot(limitName: "b"))
        let r = await t.lastRateLimits()
        let name = r?.limitName
        XCTAssertEqual(name, "b")
    }

    func testLegacyInitStillProducesByteIdenticalRequestBody() {
        let client = OpenAIResponsesClient(
            apiKey: "k", endpoint: "http://127.0.0.1:9/v1/responses")
        _ = client
        let prompt = Prompt(instructions: "inst",
                            input: [.userText("hello")])
        let settings = ModelSettings(model: "gpt", threadId: "th",
                                     turnState: "ts", previousResponseId: "resp_prev")
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        XCTAssertEqual(body["model"] as? String, "gpt")
        XCTAssertEqual(body["instructions"] as? String, "inst")
        XCTAssertEqual(body["prompt_cache_key"] as? String, "th")
        XCTAssertNil(body["x_codex_turn_state"])
        XCTAssertEqual(body["previous_response_id"] as? String, "resp_prev")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["input"])
    }

#if canImport(Network)
    func testWebSocketRequestPlanIncludesV2BetaNoZstdTurnStateAndAttestationHeaders() throws {
        let prompt = Prompt(
            instructions: "system",
            input: [.developerText("dev"), .userText("hello")],
            tools: [ToolSpec(name: "edit",
                             description: "edits files",
                             parametersJSON: #"{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}"#)])
        let settings = ModelSettings(model: "gpt-5.1-codex",
                                     threadId: "thread-123",
                                     turnState: "turn-state-abc",
                                     previousResponseId: "resp_previous")

        let plan = try WebSocketResponsesClient.buildRequestPlan(
            prompt: prompt,
            settings: settings,
            apiKey: "sk-test",
            maxOutputTokens: 128,
            options: .init(prewarm: true, explicitNoZstd: true),
            attestationHeader: "attestation.jwt")

        XCTAssertEqual(plan.headers["Authorization"], "Bearer sk-test")
        XCTAssertEqual(plan.headers["OpenAI-Beta"],
                       WebSocketResponsesClient.betaHeaderValue)
        XCTAssertEqual(plan.headers["Accept-Encoding"], "identity",
                       "macOS WS path explicitly opts out of zstd until zstd frames are implemented")
        XCTAssertEqual(plan.headers["x-codex-turn-state"], "turn-state-abc")
        XCTAssertEqual(plan.headers["x-oai-attestation"], "attestation.jwt")

        let request = try decodeJSONDictionary(plan.requestJSON)
        XCTAssertEqual(request["type"] as? String,
                       WebSocketResponsesClient.createEventType)
        XCTAssertEqual(request["model"] as? String, "gpt-5.1-codex")
        XCTAssertEqual(request["prompt_cache_key"] as? String, "thread-123")
        XCTAssertEqual(request["previous_response_id"] as? String, "resp_previous")
        XCTAssertEqual(request["max_output_tokens"] as? Int, 128)
        XCTAssertNil(request["stream"],
                     "WebSocket response.create frames omit HTTP/SSE stream")
        XCTAssertNil(request["generate"],
                     "only the prewarm frame may set generate=false")
        XCTAssertNil(request["x_codex_turn_state"],
                     "turn-state is a transport header, not a body field")

        let prewarmJSON = try XCTUnwrap(plan.prewarmJSON)
        let prewarm = try decodeJSONDictionary(prewarmJSON)
        XCTAssertEqual(prewarm["type"] as? String,
                       WebSocketResponsesClient.createEventType)
        XCTAssertEqual(prewarm["model"] as? String, "gpt-5.1-codex")
        XCTAssertEqual(prewarm["prompt_cache_key"] as? String, "thread-123")
        XCTAssertEqual(prewarm["previous_response_id"] as? String, "resp_previous")
        XCTAssertEqual(prewarm["generate"] as? Bool, false,
                       "WS prewarm must use response.create generate=false")
        XCTAssertNil(prewarm["stream"],
                     "WebSocket prewarm frames omit HTTP/SSE stream")
    }

    func testWebSocketRequestPlanOmitsOptionalHeadersAndPrewarmWhenDisabled() throws {
        let prompt = Prompt(instructions: "system",
                            input: [.userText("hello")])
        let settings = ModelSettings(model: "gpt", threadId: "thread")

        let plan = try WebSocketResponsesClient.buildRequestPlan(
            prompt: prompt,
            settings: settings,
            apiKey: "sk-test",
            maxOutputTokens: nil,
            options: .init(prewarm: false, explicitNoZstd: false),
            attestationHeader: "")

        XCTAssertEqual(plan.headers["Authorization"], "Bearer sk-test")
        XCTAssertEqual(plan.headers["OpenAI-Beta"],
                       WebSocketResponsesClient.betaHeaderValue)
        XCTAssertNil(plan.headers["Accept-Encoding"])
        XCTAssertNil(plan.headers["x-codex-turn-state"])
        XCTAssertNil(plan.headers["x-oai-attestation"])
        XCTAssertNil(plan.prewarmJSON)

        let request = try decodeJSONDictionary(plan.requestJSON)
        XCTAssertEqual(request["type"] as? String,
                       WebSocketResponsesClient.createEventType)
        XCTAssertEqual(request["prompt_cache_key"] as? String, "thread")
        XCTAssertNil(request["previous_response_id"])
        XCTAssertNil(request["max_output_tokens"])
        XCTAssertNil(request["generate"])
        XCTAssertNil(request["stream"])
    }
#endif

    // MARK: - P6.1: Responses API request-body parity fields

    private func defaultBody() -> [String: Any] {
        let prompt = Prompt(instructions: "system", input: [.userText("hi")])
        let settings = ModelSettings(model: "gpt-5.1-codex", threadId: "thread-1")
        return OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
    }

    func testRequestBodyIncludesToolChoiceAuto() {
        let body = defaultBody()
        XCTAssertEqual(body["tool_choice"] as? String, "auto",
                       "Default `tool_choice` must be `auto` so the server is allowed to call tools (upstream client.rs line 751).")
    }

    func testRequestBodyIncludesParallelToolCalls() {
        let body = defaultBody()
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false,
                       "Default `parallel_tool_calls` mirrors upstream `Prompt::default()` (client_common.rs:56 — `false`) and the model-catalog default for `supports_parallel_tool_calls`. Until codex-swift maintains a model-info catalog, `false` is the safe upstream-faithful default.")
    }

    func testRequestBodyParallelToolCallsHonorsCallerOverride() {
        let prompt = Prompt(instructions: "s", input: [.userText("hi")])
        let settings = ModelSettings(
            model: "gpt-5.1-codex", threadId: "t", parallelToolCalls: true)
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, true,
                       "Caller-supplied `parallelToolCalls: true` must override the default for models the caller knows support it.")
    }

    func testRequestBodyIncludesEncryptedReasoningInInclude() {
        // When reasoningEffort is supplied, the builder must auto-derive
        // include = ["reasoning.encrypted_content"] to match upstream
        // client.rs lines 722-726.
        let prompt = Prompt(instructions: "s", input: [.userText("hi")])
        let settings = ModelSettings(
            model: "gpt-5.1-codex", threadId: "t",
            reasoningEffort: "high",
            reasoningSummary: "auto")
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        let include = body["include"] as? [String] ?? []
        XCTAssertTrue(include.contains("reasoning.encrypted_content"),
                      "When reasoning is active, include MUST contain `reasoning.encrypted_content` so encrypted reasoning is preserved across turns.")
        let reasoning = body["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "high")
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")
    }

    func testRequestBodyEmitsEmptyIncludeWhenReasoningInactive() {
        let body = defaultBody()
        let include = body["include"] as? [String] ?? ["sentinel"]
        XCTAssertEqual(include, [],
                       "Without reasoning, `include` is an empty array (matches upstream `Vec::new()` in client.rs line 725).")
    }

    func testReasoningEmittedAsNullWhenInactive() {
        // Upstream `ResponsesApiRequest.reasoning: Option<Reasoning>` has NO
        // `skip_serializing_if` (`codex-api/src/common.rs:178`), so serde
        // emits `"reasoning": null` when the field is `None`. The Swift
        // builder must emit `NSNull()` to produce the same wire shape.
        let body = defaultBody()
        XCTAssertTrue(body["reasoning"] is NSNull,
                      "When reasoning is inactive the key MUST be present as JSON null to match upstream's serde output (no `skip_serializing_if`).")

        // Round-trip through JSON to confirm the wire shape is literal `null`.
        let data = try? JSONSerialization.data(withJSONObject: body)
        XCTAssertNotNil(data)
        let decoded = (try? JSONSerialization.jsonObject(with: data ?? Data(),
                                                         options: [.fragmentsAllowed]))
            as? [String: Any]
        XCTAssertNotNil(decoded?["reasoning"],
                        "After JSON round-trip the `reasoning` key must still be present (carrying NSNull).")
        XCTAssertTrue(decoded?["reasoning"] is NSNull,
                      "After JSON round-trip the `reasoning` value must be JSON null.")
    }

    func testRequestBodyOverridesIncludeWhenCallerProvides() {
        let prompt = Prompt(instructions: "s", input: [.userText("hi")])
        let settings = ModelSettings(
            model: "gpt-5.1-codex", threadId: "t",
            include: ["reasoning.encrypted_content",
                      "code_interpreter_call.outputs"])
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        XCTAssertEqual(body["include"] as? [String],
                       ["reasoning.encrypted_content",
                        "code_interpreter_call.outputs"],
                       "Caller-provided include MUST be sent verbatim.")
    }

    func testClientMetadataOmittedWhenEmpty() {
        // Upstream `ResponsesApiRequest.client_metadata` is
        // `Option<HashMap<String, String>>` with
        // `skip_serializing_if = Option::is_none`
        // (`codex-api/src/common.rs:188`). When no caller-supplied installation
        // id is available we omit the key entirely rather than emitting fake
        // defaults — upstream's REST path always has an installation_id (resolved
        // from `$CODEX_HOME/installation_id`) but the Swift session glue does
        // not yet thread it through, so absence is the upstream-faithful
        // fallback (no `cli_version`/`originator` are emitted either —
        // those live in `session_meta`, not in REST `client_metadata`).
        let body = defaultBody()
        XCTAssertNil(body["client_metadata"],
                     "`client_metadata` must be omitted when no caller-supplied entries are present (upstream `skip_serializing_if = Option::is_none`).")
    }

    func testClientMetadataOnlyHasInstallationIdByDefault() {
        // The ONLY key upstream's REST `build_responses_request` puts into
        // `client_metadata` is `x-codex-installation-id` (`client.rs:760-763`).
        // `cli_version` and `originator` are NOT in the REST body — they live
        // in `session_meta` / `build_ws_client_metadata`. When a caller has
        // an installation id and passes it through `ModelSettings.clientMetadata`,
        // the wire-emitted map must contain ONLY that key.
        let prompt = Prompt(instructions: "s", input: [.userText("hi")])
        let settings = ModelSettings(
            model: "gpt-5.1-codex", threadId: "t",
            clientMetadata: [CodexClientIdentity.installationIdKey: "install-7"])
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        let metadata = body["client_metadata"] as? [String: String] ?? [:]
        XCTAssertEqual(metadata, [CodexClientIdentity.installationIdKey: "install-7"],
                       "REST `client_metadata` must contain ONLY `x-codex-installation-id` by default — matches upstream `client.rs:760-763`.")
        XCTAssertNil(metadata["cli_version"],
                     "`cli_version` is NOT in upstream REST `client_metadata` — it belongs in `session_meta`.")
        XCTAssertNil(metadata["originator"],
                     "`originator` is NOT in upstream REST `client_metadata` — it belongs in `session_meta`/`originator` headers.")
    }

    func testClientMetadataMergesCallerProvided() {
        let prompt = Prompt(instructions: "s", input: [.userText("hi")])
        let settings = ModelSettings(
            model: "gpt-5.1-codex", threadId: "t",
            clientMetadata: [
                CodexClientIdentity.installationIdKey: "install-99",
                "x-codex-window-id": "win-1",
            ])
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        let metadata = body["client_metadata"] as? [String: String] ?? [:]
        XCTAssertEqual(metadata[CodexClientIdentity.installationIdKey], "install-99")
        XCTAssertEqual(metadata["x-codex-window-id"], "win-1",
                       "Additional caller-supplied keys must be forwarded verbatim (matches upstream `build_ws_client_metadata`).")
        XCTAssertEqual(metadata.count, 2,
                       "Only caller-supplied keys appear — no default keys are injected.")
    }

    func testResolveInstallationIdReadsAndPersistsUUID() throws {
        // Mirrors upstream `core/src/installation_id.rs::resolve_installation_id`:
        // when the file is absent a fresh UUID is created; when present (and
        // valid) the existing value is reused.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-swift-installation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let first = try XCTUnwrap(
            CodexClientIdentity.resolveInstallationId(codexHome: tmpDir.path),
            "First call must mint a UUID and persist it.")
        XCTAssertNotNil(UUID(uuidString: first),
                        "Returned id must be a valid UUID.")

        let second = try XCTUnwrap(
            CodexClientIdentity.resolveInstallationId(codexHome: tmpDir.path),
            "Second call must reuse the persisted UUID.")
        XCTAssertEqual(first, second,
                       "Repeated calls must return the same id — upstream `resolve_installation_id` is idempotent.")
    }

    func testRequestBodyIncludesStoreDefaultTrue() {
        let body = defaultBody()
        XCTAssertEqual(body["store"] as? Bool, true,
                       "Default `store` is true: OpenAI Responses API requires stored responses for `previous_response_id` chaining. Cat-scan verification surfaced HTTP 400 `previous_response_not_found` when this defaulted false.")
    }

    func testRequestBodyHonorsStoreOverride() {
        let prompt = Prompt(instructions: "s", input: [.userText("hi")])
        let settings = ModelSettings(
            model: "gpt-5.1-codex", threadId: "t", store: true)
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        XCTAssertEqual(body["store"] as? Bool, true)
    }

    func testRequestBodyServiceTierOmittedByDefault() {
        let body = defaultBody()
        XCTAssertNil(body["service_tier"],
                     "service_tier is `skip_serializing_if = Option::is_none` upstream; omit when nil.")
    }

    func testRequestBodyServiceTierEmittedWhenSet() {
        let prompt = Prompt(instructions: "s", input: [.userText("hi")])
        let settings = ModelSettings(
            model: "gpt-5.1-codex", threadId: "t", serviceTier: "flex")
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        XCTAssertEqual(body["service_tier"] as? String, "flex")
    }

    func testRequestBodyTextVerbosityEmittedWhenSet() {
        let prompt = Prompt(instructions: "s", input: [.userText("hi")])
        let settings = ModelSettings(
            model: "gpt-5.1-codex", threadId: "t", textVerbosity: "medium")
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        let text = body["text"] as? [String: Any]
        XCTAssertEqual(text?["verbosity"] as? String, "medium")
    }

    func testRequestBodyToolsAlwaysSerialized() {
        let body = defaultBody()
        let tools = body["tools"]
        XCTAssertNotNil(tools,
                        "Upstream `ResponsesApiRequest::tools` is a non-skippable `Vec<Value>`. Empty array must be serialized, not omitted.")
        XCTAssertEqual((tools as? [Any])?.count, 0)
    }

    func testRequestBodyToolChoiceOverrideRequired() {
        let prompt = Prompt(instructions: "s", input: [.userText("hi")])
        let settings = ModelSettings(
            model: "gpt-5.1-codex", threadId: "t", toolChoice: "required")
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, settings, maxOutputTokens: nil)
        XCTAssertEqual(body["tool_choice"] as? String, "required",
                       "Caller-supplied tool_choice (`required`, `none`, etc.) must override the default.")
    }

    private func decodeJSONDictionary(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }
}
