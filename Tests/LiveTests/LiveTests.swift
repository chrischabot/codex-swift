import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import Prompts
@testable import MCP

// MARK: - Live test scaffolding

private func liveAPIKey() -> String? {
    let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    return (k?.isEmpty == false) ? k : nil
}
private func liveModel() -> String {
    ProcessInfo.processInfo.environment["CODEXKIT_LIVE_MODEL"] ?? "gpt-4o-mini"
}
private func tmpHome() -> String {
    let p = NSTemporaryDirectory() + "live-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

/// Collect notifications until `n` turn completions or `timeout`. Free
/// function so the collector Task does not capture the non-Sendable test case.
private func liveCollect(_ engine: SessionEngine,
                         untilCompletions n: Int = 1,
                         timeout: Duration = .seconds(120)) async -> [ServerNotification] {
    let stream = await engine.events()
    let collector = Task { () -> [ServerNotification] in
        var out: [ServerNotification] = []
        var c = 0
        for await ev in stream {
            out.append(ev)
            if case .turnCompleted = ev { c += 1; if c == n { break } }
        }
        return out
    }
    let timer = Task { try? await Task.sleep(for: timeout); collector.cancel() }
    let r = await collector.value
    timer.cancel()
    return r
}

private func lastTurnStatus(_ evs: [ServerNotification]) -> TurnStatus? {
    for n in evs.reversed() {
        if case .turnCompleted(_, let t) = n { return t.status }
    }
    return nil
}

private func liveClient(maxOutputTokens: Int = 400) -> OpenAIResponsesClient {
    OpenAIResponsesClient(apiKey: liveAPIKey() ?? "missing",
                          maxOutputTokens: maxOutputTokens,
                          limits: Limits())
}

#if os(macOS)
private func liveURLSessionClient(maxOutputTokens: Int = 80) -> URLSessionResponsesClient {
    URLSessionResponsesClient(apiKey: liveAPIKey() ?? "missing",
                              maxOutputTokens: maxOutputTokens,
                              limits: Limits())
}

private func liveWebSocketClient(maxOutputTokens: Int = 80,
                                 limits: Limits = Limits()) -> WebSocketResponsesClient {
    WebSocketResponsesClient(apiKey: liveAPIKey() ?? "missing",
                             maxOutputTokens: maxOutputTokens,
                             limits: limits,
                             options: .init(prewarm: false, explicitNoZstd: true))
}
#endif

private func liveDrainModel(_ client: any ModelClient,
                            expectedText: String = "URLSESSION_LIVE_OK",
                            timeout: Duration = .seconds(120)) async throws -> [ResponseEvent] {
    let stream = try await client.stream(
        Prompt(instructions: "You are a concise test responder.",
               input: [.userText("Reply exactly: \(expectedText)")]),
        ModelSettings(model: liveModel(), threadId: "thr_urlsession_live"))
    let collector = Task { () throws -> [ResponseEvent] in
        var events: [ResponseEvent] = []
        for try await ev in stream.events {
            events.append(ev)
            if case .completed = ev { break }
        }
        return events
    }
    let timer = Task { try? await Task.sleep(for: timeout); collector.cancel() }
    do {
        let r = try await collector.value
        timer.cancel()
        return r
    } catch {
        timer.cancel()
        throw error
    }
}

private struct LiveEchoTool: Tool {
    let name = "echo"
    let parallelSafe = true
    var toolDescription: String { "Echo back the provided text verbatim." }
    var jsonSchema: String {
        #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#
    }
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct A: Decodable { let text: String }
        let t = (try? JSONDecoder().decode(A.self, from: Data(call.argumentsJSON.utf8)))?.text ?? ""
        return ToolResult(callId: call.callId, output: t, success: true, truncated: false)
    }
}

final class LiveTests: XCTestCase {

    private func makeStore(_ home: String) throws -> ThreadStore {
        try ThreadStore(codexHome: home, limits: Limits())
    }

    // MARK: 1. Offline: byte-faithful request body + prompt-cache-key (always runs)

    func testRequestBodyCacheKeyAndToolMapping() throws {
        let prompt = Prompt(
            instructions: "SYSTEM",
            input: [.developerText("DEV"), .userText("hello"),
                    .assistantText("prior reply"),
                    .toolOutput(callId: "c1", output: "OUT")],
            tools: [ToolSpec(name: "echo",
                             description: "echoes",
                             parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"}}}"#)])
        let settings = ModelSettings(model: "gpt-4o-mini",
                                     threadId: "thr_cache_42",
                                     turnState: "turn-state-42",
                                     previousResponseId: "resp_prev_42")
        let body = OpenAIResponsesClient.buildRequestBody(prompt, settings,
                                                          maxOutputTokens: 64)

        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(body["instructions"] as? String, "SYSTEM")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["prompt_cache_key"] as? String, "thr_cache_42",
                       "prompt_cache_key MUST equal the thread id (Codex contract)")
        XCTAssertNil(body["x_codex_turn_state"],
                     "turn-state is a transport header, not a Responses API body field")
        XCTAssertEqual(body["previous_response_id"] as? String, "resp_prev_42",
                       "within-turn response continuity must be transport-neutral")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 64)

        let input = body["input"] as? [[String: Any]] ?? []
        // dev, user, assistant, function_call, function_call_output
        XCTAssertEqual(input.count, 5)
        XCTAssertEqual(input[0]["role"] as? String, "developer")
        XCTAssertEqual(input[1]["role"] as? String, "user")
        XCTAssertEqual(input[2]["role"] as? String, "assistant")
        XCTAssertEqual(input[3]["type"] as? String, "function_call")
        XCTAssertEqual(input[3]["call_id"] as? String, "c1")
        XCTAssertEqual(input[4]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[4]["output"] as? String, "OUT")

        let tools = body["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(tools[0]["name"] as? String, "echo")
        XCTAssertNotNil(tools[0]["parameters"] as? [String: Any],
                        "schema string must be parsed into a JSON object")

        // Body must serialize cleanly to JSON for curl --data-binary.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    // MARK: 2. Live basic turn

    func testLiveBasicTurn() async throws {
        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: home, model: liveModel()))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: liveModel()),
                                   model: liveClient(), store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()
        let collector = Task { await liveCollect(engine) }
        await engine.submit(.startTurn(
            input: [TurnInput(text: "Reply with exactly the word: pong")], model: nil, turnId: nil))
        let evs = await collector.value

        XCTAssertEqual(lastTurnStatus(evs), .completed, "live turn must complete")
        let gotText = evs.contains {
            if case .agentMessageDelta(_, _, _, let d) = $0 { return !d.isEmpty }
            if case .itemCompleted(_, _, let it, _) = $0,
               case .agentMessage(_, let t) = it { return !t.isEmpty }
            return false
        }
        XCTAssertTrue(gotText, "model produced assistant text")
        XCTAssertTrue(evs.contains { if case .tokenUsageUpdated = $0 { return true }; return false },
                      "token usage emitted from real usage.total_tokens")
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .agentMessage = $0 { return true }; return false
        }, "assistant message persisted to the rollout")
    }

    #if os(macOS)
    func testLiveURLSessionResponsesClientBasicStream() async throws {
        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        let events = try await liveDrainModel(liveURLSessionClient(maxOutputTokens: 32))
        let text = events.compactMap { ev -> String? in
            if case .agentDelta(_, let delta) = ev { return delta }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("URLSESSION_LIVE_OK"),
                      "native URLSession client streamed live model text: \(text)")
        XCTAssertTrue(events.contains {
            if case .completed(_, let total, true, _) = $0 { return total > 0 }
            return false
        }, "native URLSession client completed with token usage")
    }

    func testLiveWebSocketResponsesClientDirectStream() async throws {
        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        var limits = Limits()
        limits.turnDeadline = .seconds(45)
        limits.streamMaxRetries = 0
        limits.retryTokensCapacity = 0
        limits.retryTokensPerSecond = 0
        limits.retryBaseDelay = .milliseconds(1)
        limits.retryMaxDelay = .milliseconds(1)
        let ws = liveWebSocketClient(maxOutputTokens: 32, limits: limits)
        let https = URLSessionResponsesClient(apiKey: liveAPIKey() ?? "missing",
                                              maxOutputTokens: 32,
                                              limits: limits)
        let client = TransportFallbackModelClient(primary: ws,
                                                  fallback: https,
                                                  limits: limits)

        let expected = "WS_OR_FALLBACK_LIVE_OK"
        let events = try await liveDrainModel(client,
                                             expectedText: expected)
        let text = events.compactMap { ev -> String? in
            if case .agentDelta(_, let delta) = ev { return delta }
            return nil
        }.joined()
        XCTAssertTrue(text.contains(expected),
                      "direct WS production path streamed live model text: \(text)")
        XCTAssertTrue(events.contains {
            if case .completed(_, let total, true, _) = $0 { return total > 0 }
            return false
        }, "WS/fallback live client completed with token usage")

        let fallbackEngaged = await client.isFallbackEngaged()
        XCTAssertFalse(fallbackEngaged,
                       "direct WS endpoint should complete without sticky HTTPS fallback")
    }
    #endif

    // MARK: 3. prompt_cache_key stable across turns (cache management)

    func testLivePromptCacheKeyStableAcrossTurns() async throws {
        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: home, model: liveModel()))
        let rec = RecordingModelClient(liveClient(maxOutputTokens: 64))
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: liveModel()),
                                   model: rec, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits())
        await engine.start()

        let c1 = Task { await liveCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text: "Say A")], model: nil, turnId: nil))
        _ = await c1.value
        let c2 = Task { await liveCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text: "Say B")], model: nil, turnId: nil))
        _ = await c2.value

        let caps = await rec.capturedRequests()
        XCTAssertGreaterThanOrEqual(caps.count, 2)
        for cap in caps {
            XCTAssertEqual(cap.settings.threadId, tid.raw,
                           "prompt_cache_key (threadId) is the stable cache key every request")
        }
        XCTAssertEqual(caps[0].prompt.instructions, caps[1].prompt.instructions,
                       "system instructions are byte-stable across turns (prompt-cache stable)")
        // Sticky routing token stays within the same window generation.
        XCTAssertEqual(caps[0].settings.turnState, caps[1].settings.turnState)
    }

    // MARK: 4. Tool-calling round-trip (deterministic + bounded best-effort live)

    func testLiveToolCallRoundTrip() async throws {
        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: home, model: liveModel()))
        let router = ToolRouter(limits: Limits())
        await router.register(LiveEchoTool())

        // (a) Deterministic: the registered tool round-trips through the
        //     router and is advertised to the model with its spec.
        let direct = await router.dispatch(
            ToolCall(callId: "e1", name: "echo", argumentsJSON: #"{"text":"CODEXKIT_LIVE"}"#),
            cwd: home, deadline: .fromNow(.seconds(10)))
        XCTAssertTrue(direct.success && direct.output == "CODEXKIT_LIVE",
                      "echo tool round-trips through the router: \(direct.output)")
        let echoSpecs = await router.specs()
        XCTAssertTrue(echoSpecs.contains {
            $0.name == "echo" && $0.description == "Echo back the provided text verbatim."
        }, "echo advertised to the model with its model-visible spec")

        // (b) Best-effort live: a bounded sampling-iteration cap so a chatty
        //     model cannot wedge the turn. Require the turn to terminate; if
        //     the live model elected to call echo, its output round-tripped.
        var lim = Limits()
        lim.maxSamplingIterationsPerTurn = 6
        lim.turnDeadline = .seconds(90)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: liveModel()),
                                   model: liveClient(), store: store,
                                   router: router, limits: lim)
        await engine.start()
        let collector = Task { await liveCollect(engine, timeout: .seconds(140)) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Use the echo tool to echo the text CODEXKIT_LIVE, then stop "
                + "and give a one-word final answer.")],
            model: nil, turnId: nil))
        let evs = await collector.value

        XCTAssertNotNil(lastTurnStatus(evs),
                        "the live turn terminated within the bounded iteration cap")
        let echoOutputs = evs.compactMap { n -> String? in
            if case .itemCompleted(_, _, let it, _) = n,
               case .commandExecution(_, let cmd, _, _, _, let out, _, _, _, _) = it,
               cmd.first == "echo" { return out ?? "" }
            return nil
        }
        if !echoOutputs.isEmpty {
            XCTAssertTrue(echoOutputs.contains { $0.contains("CODEXKIT_LIVE") },
                          "when the live model called echo, the tool output round-tripped")
        }
    }

    // MARK: 5. Byte-faithful personality (system prompt) + live acceptance

    func testLivePersonalityByteFaithfulAndAccepted() async throws {
        // The byte-faithful assertion always runs; the live turn is gated.
        //
        // `modelInstructions()` is MODEL-AWARE (faithful to upstream
        // `get_model_instructions(personality)`): for a model whose catalog
        // entry (`models.json`) ships an `instructions_template`, the
        // `{{ personality }}` placeholder is replaced by the
        // `instructions_variables["personality_<id>"]` fragment; a model
        // without a template (or the empty default slug) returns
        // `BASE_INSTRUCTIONS_DEFAULT` verbatim with no personality.
        //
        // We assert the SUBSTITUTION MECHANISM against the catalog as the
        // source of truth (rather than a hard-coded wording snapshot, which
        // drifts whenever the upstream catalog is refreshed — e.g. gpt-5.5's
        // friendly fragment was reworded away from the legacy "team morale"
        // phrasing): the correct fragment is selected per personality, the
        // placeholder is consumed, and personality actually varies the prompt.
        let probeModel = "gpt-5.5"
        let entry = try XCTUnwrap(ModelsCatalog.entry(for: probeModel),
                                  "the bundled models.json catalog must resolve \(probeModel)")
        let friendlyFrag = try XCTUnwrap(entry.instructionsVariables["personality_friendly"])
        let pragmaticFrag = try XCTUnwrap(entry.instructionsVariables["personality_pragmatic"])
        XCTAssertNotEqual(friendlyFrag, pragmaticFrag, "the catalog ships distinct personality fragments")

        let friendly = PromptComposer(personality: .friendly, model: probeModel).modelInstructions()
        let pragmatic = PromptComposer(personality: .pragmatic, model: probeModel).modelInstructions()

        XCTAssertTrue(friendly.contains(friendlyFrag),
                      "the friendly fragment is substituted verbatim into model instructions")
        XCTAssertFalse(friendly.contains(pragmaticFrag),
                       "the friendly instructions carry ONLY the friendly fragment")
        XCTAssertTrue(pragmatic.contains(pragmaticFrag),
                      "the pragmatic fragment is substituted verbatim")
        XCTAssertFalse(friendly.contains("{{ personality }}"),
                       "the {{ personality }} placeholder is fully consumed")
        XCTAssertNotEqual(friendly, pragmatic,
                          "selecting a personality actually varies the system prompt")
        // A model WITHOUT a personality template falls back to the default base
        // instructions with no substitution and no leftover placeholder
        // (upstream-faithful: BASE_INSTRUCTIONS_DEFAULT carries no personality).
        let bare = PromptComposer(personality: .friendly).modelInstructions()
        XCTAssertFalse(bare.contains("{{ personality }}"),
                       "the default base instructions leave no unsubstituted placeholder")

        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try makeStore(home)
        let tid = ThreadId.generate()
        let cfg = SessionConfig(threadId: tid, cwd: home, model: liveModel())
        var withPersona = cfg
        withPersona.personality = "friendly"
        _ = try await store.create(withPersona)
        let engine = SessionEngine(config: withPersona, model: liveClient(maxOutputTokens: 64),
                                   store: store, router: ToolRouter(limits: Limits()),
                                   limits: Limits())
        await engine.start()
        let collector = Task { await liveCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text: "Say ok")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertEqual(lastTurnStatus(evs), .completed,
                       "the real API accepts the byte-faithful personality system prompt")
    }

    // MARK: 6. Skills + AGENTS.md initial-context injection (verified in the wire prompt)

    func testLiveSkillsAndAgentsMdInitialContext() async throws {
        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = tmpHome(); defer { try? FileManager.default.removeItem(atPath: work) }
        try? FileManager.default.createDirectory(atPath: work + "/.git",
                                                 withIntermediateDirectories: true)
        try "PROJECT RULE: always greet with HELLO_CODEXKIT."
            .write(toFile: work + "/AGENTS.md", atomically: true, encoding: .utf8)
        let store = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work, model: liveModel()))
        let rec = RecordingModelClient(liveClient(maxOutputTokens: 64))
        let skills = [PromptComposer.SkillInjection(
            name: "greeter", description: "Greets the user", path: work + "/skills/greeter")]
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: work,
                                                         model: liveModel()),
                                   model: rec, store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits(),
                                   skills: skills)
        await engine.start()
        let collector = Task { await liveCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(text: "Greet me.")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertEqual(lastTurnStatus(evs), .completed)

        // The initial-context fragments must be present in the wire prompt.
        let caps = await rec.capturedRequests()
        let firstInput = caps.first?.prompt.input ?? []
        func projected(_ items: [PromptInput]) -> String {
            items.map { i in
                switch i {
                case .userText(let t), .developerText(let t), .assistantText(let t): return t
                case .toolOutput(_, let o): return o
                case .reasoning(let summary, let content, _): return (summary + content).joined(separator: "\n")
                }
            }.joined(separator: "\n")
        }
        let blob = projected(firstInput)
        XCTAssertTrue(blob.contains("<permissions instructions>"),
                      "permissions developer fragment injected")
        XCTAssertTrue(blob.contains("HELLO_CODEXKIT"),
                      "AGENTS.md project doc injected via UserInstructions fragment")
        XCTAssertTrue(blob.contains("## Skills") && blob.contains("greeter"),
                      "available-skills fragment injected")
    }

    // MARK: 7. Memories consolidation after a real turn

    func testLiveMemoriesConsolidation() async throws {
        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: home, model: liveModel()))
        let mem = MemoryStore(codexHome: home)
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: liveModel()),
                                   model: liveClient(maxOutputTokens: 64), store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits(),
                                   memoryStore: mem)
        await engine.start()
        let collector = Task { await liveCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Remember the secret token LIVE_MEM_TOKEN_42.")], model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertEqual(lastTurnStatus(evs), .completed)
        let names = await mem.list()
        XCTAssertTrue(names.contains("\(tid.raw).md"),
                      "consolidation wrote a per-thread memory note")
        let body = await mem.read("\(tid.raw).md") ?? ""
        XCTAssertTrue(body.contains("LIVE_MEM_TOKEN_42"),
                      "the turn transcript was folded into memory")
    }

    // MARK: 8. Model-driven context compaction against the real model

    func testLiveContextCompaction() async throws {
        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: home, model: liveModel()))
        // First turn normal; second turn forces pre-sampling compaction
        // (autoCompactTokens=1 with non-zero server token usage from turn 1).
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: liveModel()),
                                   model: liveClient(maxOutputTokens: 80), store: store,
                                   router: ToolRouter(limits: Limits()), limits: Limits(),
                                   autoCompactTokens: 1)
        await engine.start()
        let c1 = Task { await liveCollect(engine) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Briefly note: project codename is FALCON.")], model: nil, turnId: nil))
        _ = await c1.value
        let c2 = Task { await liveCollect(engine, timeout: .seconds(150)) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "What is the project codename?")], model: nil, turnId: nil))
        let evs = await c2.value

        XCTAssertTrue(evs.contains {
            if case .itemCompleted(_, _, let item, _) = $0,
               case .contextCompaction = item { return true }
            return false
        }, "model-driven compaction ran (contextCompaction item emitted)")
        let rebuilt = try await store.reconstruct(tid)
        // Live OpenAI uses the remote `/responses/compact` path
        // (compact_remote.rs::run_remote_compact_task_inner_impl), NOT the
        // local prompt-driven path. Upstream's remote path installs the
        // endpoint's returned messages verbatim (whatever roles it assigns)
        // and persists CompactedItem { message: "" } — it does NOT prepend
        // SUMMARY_PREFIX (that prefix is only added by the LOCAL
        // build_compacted_history). Empirically the live endpoint, for a small
        // transcript, returns the existing developer/user context with no
        // synthesized assistant summary at all. So the meaningful, path-stable
        // assertions are: compaction ran (thread/compacted), it installed a
        // replacement history (reflected in the reconstructed transcript), and
        // the post-compaction turn still answered correctly from the compacted
        // context. If the local path is exercised (e.g. a non-OpenAI provider),
        // the summary appears as a SUMMARY_PREFIX-prefixed user message
        // (build_compacted_history pushes role:"user"); accept either form.
        let summaryAsUser = rebuilt.items.contains {
            if case .userMessage(_, let c) = $0 {
                return c.compactMap { $0.text }.joined(separator: "\n")
                    .hasPrefix(Compaction.summaryPrefix)
            }
            return false
        }
        // Remote-path proof: the compacted history was installed and the model
        // answered the post-compaction question from that history.
        let answeredFromCompacted = rebuilt.items.contains {
            if case .agentMessage(_, let t) = $0 {
                return t.uppercased().contains("FALCON")
            }
            return false
        }
        XCTAssertTrue(summaryAsUser || answeredFromCompacted,
                      "compaction installed a replacement history and the model "
                      + "answered from it (remote path) or wrote a SUMMARY_PREFIX "
                      + "user summary (local path)")
        XCTAssertEqual(lastTurnStatus(evs), .completed,
                       "the post-compaction turn completed against the real model")
    }

    // MARK: 9. MCP proxy tool calling (deterministic stdio round-trip + live)

    func testLiveMcpProxyToolCall() async throws {
        try XCTSkipUnless(liveAPIKey() != nil, "OPENAI_API_KEY not set")
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        // A minimal MCP stdio server exposing one `ping` tool. Uses an
        // explicit unbuffered readline loop (run via `python3 -u`) so it
        // works with a long-lived stdin pipe (CPython's `for line in
        // sys.stdin` read-ahead stalls when stdin stays open).
        let script = home + "/mcpserver.py"
        let py = """
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
            m = json.loads(line)
            mid = m.get("id")
            meth = m.get("method")
            if meth == "initialize":
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"protocolVersion": "2025-06-18"}})
            elif meth == "notifications/initialized":
                pass
            elif meth == "tools/list":
                send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
                    {"name": "ping", "description": "returns pong",
                     "inputSchema": {"type": "object", "properties": {},
                                     "additionalProperties": False}}]}})
            elif meth == "tools/call":
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "content": [{"type": "text", "text": "pong"}],
                    "isError": False}})
        """
        try py.write(toFile: script, atomically: true, encoding: .utf8)

        let store = try makeStore(home)
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: home, model: liveModel()))
        let router = ToolRouter(limits: Limits())
        let mcp = McpManager()
        await mcp.startAll([McpServerConfig(name: "mock", command: "python3",
                                            args: ["-u", script])],
                           router: router)

        // (a) Deterministic: the MCP server was discovered and its tool
        //     advertised to the model with the discovered spec.
        let specs = await router.specs()
        XCTAssertTrue(specs.contains { $0.name == "mcp__mock__ping" },
                      "MCP proxy tool advertised to the model with its discovered spec")
        XCTAssertTrue(specs.contains { $0.name == "mcp__mock__ping"
                                       && $0.description == "returns pong" },
                      "discovered MCP description carried into the model-visible spec")

        // (b) Deterministic: a direct dispatch proves the full stdio JSON-RPC
        //     round-trip (model-independent).
        let direct = await router.dispatch(
            ToolCall(callId: "d1", name: "mcp__mock__ping", argumentsJSON: "{}"),
            cwd: home, deadline: .fromNow(.seconds(20)))
        XCTAssertTrue(direct.success && direct.output.contains("pong"),
                      "MCP proxy round-trips real server output over stdio: \(direct.output)")

        // (c) Best-effort live: the real model is offered the MCP tool; we
        //     require the turn to complete (the model may or may not elect to
        //     call it — that nondeterminism must not fail the suite).
        let engine = SessionEngine(config: SessionConfig(threadId: tid, cwd: home,
                                                         model: liveModel()),
                                   model: liveClient(), store: store,
                                   router: router, limits: Limits())
        await engine.start()
        let collector = Task { await liveCollect(engine, timeout: .seconds(150)) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Call the mcp__mock__ping tool now. You must call the tool.")],
            model: nil, turnId: nil))
        let evs = await collector.value
        await mcp.stopAll()
        XCTAssertEqual(lastTurnStatus(evs), .completed,
                       "the live turn offering the MCP tool completed against the real model")
    }
}
