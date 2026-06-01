import XCTest
@testable import ModelClient
@testable import InfraPrimitives

/// Wire-shape + behavior tests for the remote `/responses/compact` path
/// (faithful to `codex-rs/codex-api/src/{endpoint/compact.rs,common.rs}` and
/// `core/src/{client.rs,compact_remote.rs}`).
final class RemoteCompactionTests: XCTestCase {

    private func body(_ prompt: Prompt, _ settings: ModelSettings) -> [String: Any] {
        RemoteCompaction.buildRequestBody(prompt, settings)
    }

    private func settings(reasoningEffort: String? = nil,
                          serviceTier: String? = nil,
                          textVerbosity: String? = nil,
                          parallelToolCalls: Bool = false,
                          threadId: String = "thr_1") -> ModelSettings {
        ModelSettings(model: "gpt-5.5",
                      threadId: threadId,
                      parallelToolCalls: parallelToolCalls,
                      reasoningEffort: reasoningEffort,
                      serviceTier: serviceTier,
                      textVerbosity: textVerbosity)
    }

    // MARK: wire shape

    func testRequestBodyUsesSnakeCaseAndRequiredFields() throws {
        let prompt = Prompt(instructions: "be terse",
                            input: [.userText("hello")])
        let b = body(prompt, settings(parallelToolCalls: true))
        // CompactionInput carries NO serde(rename_all) → snake_case names.
        XCTAssertNotNil(b["parallel_tool_calls"], "must be snake_case, not parallelToolCalls")
        XCTAssertNil(b["parallelToolCalls"])
        XCTAssertEqual(b["parallel_tool_calls"] as? Bool, true)
        XCTAssertEqual(b["model"] as? String, "gpt-5.5")
        XCTAssertEqual(b["instructions"] as? String, "be terse")
        XCTAssertEqual(b["prompt_cache_key"] as? String, "thr_1")
        // tools always present (Vec<Value>), here empty.
        XCTAssertNotNil(b["tools"])
        XCTAssertEqual((b["tools"] as? [Any])?.count, 0)
        // input is the mapped transcript.
        let input = b["input"] as? [[String: Any]]
        XCTAssertEqual(input?.count, 1)
        XCTAssertEqual(input?.first?["role"] as? String, "user")
    }

    func testInstructionsOmittedWhenEmpty() throws {
        let prompt = Prompt(instructions: "", input: [.userText("hi")])
        let b = body(prompt, settings())
        XCTAssertNil(b["instructions"], "empty instructions must be omitted (str::is_empty)")
    }

    func testReasoningOmittedWhenAbsentUnlikeStreamingBody() throws {
        // CompactionInput.reasoning is skip_serializing_if Option::is_none, so
        // when no effort/summary is present the key must be ABSENT — NOT null
        // (which is what the streaming body emits).
        let prompt = Prompt(instructions: "x", input: [.userText("hi")])
        let b = body(prompt, settings(reasoningEffort: nil))
        XCTAssertNil(b["reasoning"], "reasoning must be omitted, not null, for compact")
    }

    func testReasoningPresentWhenEffortSet() throws {
        let prompt = Prompt(instructions: "x", input: [.userText("hi")])
        let b = body(prompt, settings(reasoningEffort: "high"))
        let reasoning = b["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "high")
    }

    func testServiceTierAndTextOmittedWhenNil() throws {
        let prompt = Prompt(instructions: "x", input: [.userText("hi")])
        let b = body(prompt, settings(serviceTier: nil, textVerbosity: nil))
        XCTAssertNil(b["service_tier"])
        XCTAssertNil(b["text"])
    }

    func testServiceTierAndTextPresentWhenSet() throws {
        let prompt = Prompt(instructions: "x", input: [.userText("hi")])
        let b = body(prompt, settings(serviceTier: "flex", textVerbosity: "low"))
        XCTAssertEqual(b["service_tier"] as? String, "flex")
        XCTAssertEqual((b["text"] as? [String: Any])?["verbosity"] as? String, "low")
    }

    func testToolsEncodeAsFunctionObjects() throws {
        let tool = ToolSpec(name: "shell", description: "run",
                            parametersJSON: "{\"type\":\"object\"}")
        let prompt = Prompt(instructions: "x", input: [.userText("hi")], tools: [tool])
        let b = body(prompt, settings())
        let tools = b["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["type"] as? String, "function")
        XCTAssertEqual(tools?.first?["name"] as? String, "shell")
        XCTAssertEqual(tools?.first?["strict"] as? Bool, false,
                       "compact function tools always serialize strict")
    }

    func testCompactToolsEmitStrictAndNeverOutputSchema() throws {
        let tool = ToolSpec(name: "shell", description: "run",
                            parametersJSON: "{\"type\":\"object\"}",
                            outputSchemaJSON: "{\"type\":\"object\"}",
                            strict: true)
        let prompt = Prompt(instructions: "x", input: [.userText("hi")], tools: [tool])
        let b = body(prompt, settings())
        let t = (b["tools"] as? [[String: Any]])?.first
        XCTAssertEqual(t?["strict"] as? Bool, true)
        XCTAssertNil(t?["output_schema"],
                     "output_schema is #[serde(skip)] upstream — never sent")
    }

    // MARK: response parsing

    func testParseOutputExtractsMessageItems() throws {
        let json = """
        {"output":[
          {"type":"message","role":"developer","content":[{"type":"input_text","text":"sys"}]},
          {"type":"message","role":"user","content":[{"type":"input_text","text":"keep me"}]},
          {"type":"message","role":"assistant","content":[{"type":"output_text","text":"summary"}]}
        ]}
        """
        let messages = try RemoteCompaction.parseOutput(Data(json.utf8))
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, "developer")
        XCTAssertEqual(messages[1].text, "keep me")
        XCTAssertEqual(messages[2].role, "assistant")
        XCTAssertEqual(messages[2].text, "summary")
    }

    func testParseOutputDropsNonMessageItems() throws {
        let json = """
        {"output":[
          {"type":"reasoning","summary":["x"]},
          {"type":"function_call","call_id":"c","name":"t","arguments":"{}"},
          {"type":"message","role":"user","content":[{"type":"input_text","text":"u"}]}
        ]}
        """
        let messages = try RemoteCompaction.parseOutput(Data(json.utf8))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, "user")
    }

    // Finding 2: `should_keep_compacted_history_item` RETAINS encrypted
    // `Compaction` (`type: "compaction"`, serde alias `"compaction_summary"`)
    // and `ContextCompaction` (`type: "context_compaction"`) output items;
    // `parseOutput` must surface them rather than dropping them.
    func testParseOutputSurfacesCompactionItems() throws {
        let json = """
        {"output":[
          {"type":"compaction","encrypted_content":"ENC-A"},
          {"type":"context_compaction","encrypted_content":"ENC-B"},
          {"type":"context_compaction"},
          {"type":"message","role":"assistant","content":[{"type":"output_text","text":"s"}]}
        ]}
        """
        let messages = try RemoteCompaction.parseOutput(Data(json.utf8))
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0].kind, .compaction)
        XCTAssertEqual(messages[0].encryptedContent, "ENC-A")
        XCTAssertEqual(messages[1].kind, .contextCompaction)
        XCTAssertEqual(messages[1].encryptedContent, "ENC-B")
        XCTAssertEqual(messages[2].kind, .contextCompaction)
        XCTAssertNil(messages[2].encryptedContent, "context_compaction encrypted_content is optional")
        XCTAssertEqual(messages[3].kind, .message)
    }

    func testParseOutputAcceptsCompactionSummaryAlias() throws {
        // ResponseItem::Compaction has serde alias "compaction_summary".
        let json = #"{"output":[{"type":"compaction_summary","encrypted_content":"E"}]}"#
        let messages = try RemoteCompaction.parseOutput(Data(json.utf8))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].kind, .compaction)
        XCTAssertEqual(messages[0].encryptedContent, "E")
    }

    // Finding 2: user-message contextual filter mirroring
    // `should_keep_compacted_history_item` → `parse_turn_item`.
    func testShouldKeepUserMessageDropsContextualWrappers() {
        // Real user message → kept.
        XCTAssertTrue(RemoteCompaction.shouldKeepUserMessage("just a question"))
        // Standard contextual user fragments → dropped.
        XCTAssertFalse(RemoteCompaction.shouldKeepUserMessage(
            "<environment_context>cwd=/w</environment_context>"))
        XCTAssertFalse(RemoteCompaction.shouldKeepUserMessage(
            "  <environment_context>x</environment_context>  "))
        XCTAssertFalse(RemoteCompaction.shouldKeepUserMessage(
            "# AGENTS.md instructions for /repo\nbe nice</INSTRUCTIONS>"))
        XCTAssertFalse(RemoteCompaction.shouldKeepUserMessage(
            "<user_shell_command>ls</user_shell_command>"))
        XCTAssertFalse(RemoteCompaction.shouldKeepUserMessage(
            "<turn_aborted>x</turn_aborted>"))
        XCTAssertFalse(RemoteCompaction.shouldKeepUserMessage(
            "<subagent_notification>x</subagent_notification>"))
        XCTAssertFalse(RemoteCompaction.shouldKeepUserMessage(
            "<goal_context>g</goal_context>"))
        // SkillInstructions (ROLE=user, registered in CONTEXTUAL_USER_FRAGMENTS)
        // → dropped. `is_standard_contextual_user_text` matches by text against
        // the registered list regardless of role.
        XCTAssertFalse(RemoteCompaction.shouldKeepUserMessage(
            "<skill>\n<name>foo</name>\n<path>/p</path>\nbody\n</skill>"))
    }

    func testShouldKeepUserMessageKeepsHookPrompt() {
        // Hook-prompt messages parse as TurnItem::HookPrompt → kept.
        XCTAssertTrue(RemoteCompaction.shouldKeepUserMessage(
            #"<hook_prompt hook_run_id="hook-run-1">Retry with tests.</hook_prompt>"#))
        // A hook_prompt with an empty hook_run_id is NOT a valid hook prompt;
        // it carries no contextual marker either, so it is kept as a plain msg.
        XCTAssertTrue(RemoteCompaction.shouldKeepUserMessage(
            #"<hook_prompt hook_run_id="">x</hook_prompt>"#))
    }

    func testParseOutputThrowsOnMissingOutput() {
        XCTAssertThrowsError(try RemoteCompaction.parseOutput(Data("{}".utf8)))
    }

    func testParseOutputThrowsOnErrorBody() {
        let json = "{\"error\":{\"message\":\"boom\"}}"
        XCTAssertThrowsError(try RemoteCompaction.parseOutput(Data(json.utf8))) { err in
            XCTAssertTrue("\(err)".contains("boom"))
        }
    }

    // MARK: URL derivation

    func testCompactURLFromResponsesURL() {
        XCTAssertEqual(
            RemoteCompaction.compactURL(fromResponsesURL: "https://api.openai.com/v1/responses"),
            "https://api.openai.com/v1/responses/compact")
    }

    func testCompactURLPreservesQueryParams() {
        XCTAssertEqual(
            RemoteCompaction.compactURL(
                fromResponsesURL: "https://h/v1/responses?api-version=2025"),
            "https://h/v1/responses/compact?api-version=2025")
    }

    // MARK: provider gating

    func testOpenAIProviderSupportsRemoteCompaction() {
        XCTAssertTrue(ModelProvider.openAI.supportsRemoteCompaction)
        XCTAssertTrue(ModelProvider.openAI.isOpenAI)
    }

    func testAzureProviderSupportsRemoteCompaction() {
        let azure = ModelProvider(id: "azure", name: "azure",
                                  baseURL: "https://x.openai.azure.com")
        XCTAssertTrue(azure.supportsRemoteCompaction)
        let byUrl = ModelProvider(id: "p", name: "Custom",
                                  baseURL: "https://x.cognitiveservices.azure.com/openai")
        XCTAssertTrue(byUrl.supportsRemoteCompaction)
    }

    func testThirdPartyProviderDoesNotSupportRemoteCompaction() {
        let p = ModelProvider(id: "groq", name: "Groq",
                              baseURL: "https://api.groq.com/openai/v1")
        XCTAssertFalse(p.supportsRemoteCompaction)
    }

    // MARK: default protocol behavior + provider gate

    func testUnsupportedProviderReturnsNilWithoutNetwork() async throws {
        // A non-OpenAI provider must short-circuit to nil (local fallback)
        // without issuing a network request.
        let provider = ModelProvider(id: "groq", name: "Groq",
                                     baseURL: "https://api.groq.com/openai/v1",
                                     experimentalBearerToken: "k")
        let client = OpenAIResponsesClient(provider: provider)
        let result = try await client.compactConversationHistory(
            Prompt(instructions: "x", input: [.userText("hi")]),
            settings())
        XCTAssertNil(result, "unsupported provider must return nil for local fallback")
    }

    func testEmptyInputReturnsEmptyWithoutNetwork() async throws {
        // Upstream returns Ok(Vec::new()) for empty input without a round-trip.
        let client = OpenAIResponsesClient(provider: ModelProvider.openAI)
        let result = try await client.compactConversationHistory(
            Prompt(instructions: "x", input: []), settings())
        XCTAssertEqual(result, [])
    }

    func testMockClientDefaultReturnsNil() async throws {
        // Clients that do not override the protocol method get the default
        // (nil = unsupported) so existing local-compaction tests are unchanged.
        let mock = MockModelClient([.hello("Hi")])
        let result = try await mock.compactConversationHistory(
            Prompt(instructions: "x", input: [.userText("hi")]), settings())
        XCTAssertNil(result)
    }
}
