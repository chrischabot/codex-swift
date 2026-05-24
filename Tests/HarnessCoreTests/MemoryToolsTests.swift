import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Tools
@testable import InfraPrimitives

/// P4.8 / H-32 — namespaced memory tools (`memories/list`, `memories/read`,
/// `memories/search`) plus the model-driven Stage-1 consolidation pipeline.
///
/// Upstream source of truth:
///   * `codex-rs/ext/memories/src/tools/{list,read,search}.rs`
///   * `codex-rs/memories/write/src/phase1.rs` (Stage-1 output schema)
final class MemoryToolsTests: XCTestCase {

    // MARK: - Tool registration + schema

    private func makeMemoryStore() throws -> (MemoryStore, String) {
        let home = NSTemporaryDirectory() + "mem-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home,
                                                withIntermediateDirectories: true)
        return (MemoryStore(codexHome: home), home)
    }

    func testMemoriesListToolRegistered() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let router = ToolRouter(limits: Limits())
        await router.register(MemoriesListTool(store: mem))
        let specs = await router.specs()
        guard let spec = specs.first(where: { $0.name == "memories_list" }) else {
            return XCTFail("memories/list tool must be registered")
        }
        // Schema should be an object with optional path/cursor/max_results.
        guard let d = spec.parametersJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let props = obj["properties"] as? [String: Any] else {
            return XCTFail("schema must be a valid JSON object")
        }
        XCTAssertNotNil(props["cursor"], "schema must declare cursor")
        XCTAssertNotNil(props["max_results"], "schema must declare max_results")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false,
                       "upstream uses additionalProperties:false")
    }

    func testMemoriesReadToolRegistered() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let router = ToolRouter(limits: Limits())
        await router.register(MemoriesReadTool(store: mem))
        let specs = await router.specs()
        guard let spec = specs.first(where: { $0.name == "memories_read" }) else {
            return XCTFail("memories/read tool must be registered")
        }
        guard let d = spec.parametersJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return XCTFail("schema must be a valid JSON object")
        }
        let required = obj["required"] as? [String] ?? []
        XCTAssertTrue(required.contains("path"),
                      "memories/read schema must require `path` (upstream parity)")
        let props = obj["properties"] as? [String: Any] ?? [:]
        XCTAssertNotNil(props["line_offset"], "must declare line_offset")
        XCTAssertNotNil(props["max_lines"], "must declare max_lines")
    }

    func testMemoriesSearchToolRegistered() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let router = ToolRouter(limits: Limits())
        await router.register(MemoriesSearchTool(store: mem))
        let specs = await router.specs()
        guard let spec = specs.first(where: { $0.name == "memories_search" }) else {
            return XCTFail("memories/search tool must be registered")
        }
        guard let d = spec.parametersJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let props = obj["properties"] as? [String: Any] else {
            return XCTFail("schema must be a valid JSON object")
        }
        // Upstream: `queries` is an array of strings (we also accept singular
        // `query` for simpler callers).
        XCTAssertNotNil(props["queries"], "must declare queries array")
    }

    func testLegacyMemoryToolStillRegisteredForBackCompat() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let router = ToolRouter(limits: Limits())
        await router.register(MemoryTool(store: mem))
        let specs = await router.specs()
        XCTAssertTrue(specs.contains { $0.name == "memory" },
                      "legacy `memory` tool must remain registered for back-compat")
    }

    // MARK: - Tool behavior

    func testMemoriesListPaginates() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for i in 0..<5 {
            try "body".write(toFile: home + "/memories/file\(i).md",
                             atomically: true, encoding: .utf8)
        }
        let tool = MemoriesListTool(store: mem)
        let r1 = try await tool.run(ToolCall(callId: "c1", name: "memories_list",
                                             argumentsJSON: #"{"max_results":2}"#),
                                    cwd: "/")
        guard let d = r1.output.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let items = obj["items"] as? [String] else {
            return XCTFail("expected items[]: got \(r1.output)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertNotNil(obj["next_cursor"] as? String, "must return next_cursor for next page")
        let cursor = obj["next_cursor"] as! String
        let r2 = try await tool.run(
            ToolCall(callId: "c2", name: "memories_list",
                     argumentsJSON: "{\"max_results\":2,\"cursor\":\"\(cursor)\"}"),
            cwd: "/")
        guard let d2 = r2.output.data(using: .utf8),
              let obj2 = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any],
              let items2 = obj2["items"] as? [String] else {
            return XCTFail("expected items[]: got \(r2.output)")
        }
        XCTAssertEqual(items2.count, 2)
        XCTAssertNotEqual(items, items2, "second page must differ from first")
    }

    func testMemoriesReadLineOffsetAndMaxLines() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let body = "line1\nline2\nline3\nline4\nline5"
        try body.write(toFile: home + "/memories/test.md",
                       atomically: true, encoding: .utf8)
        let tool = MemoriesReadTool(store: mem)
        let r = try await tool.run(
            ToolCall(callId: "c1", name: "memories_read",
                     argumentsJSON: #"{"path":"test.md","line_offset":2,"max_lines":2}"#),
            cwd: "/")
        guard let d = r.output.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return XCTFail("invalid JSON output: \(r.output)")
        }
        XCTAssertEqual(obj["content"] as? String, "line2\nline3")
        XCTAssertEqual(obj["total_lines"] as? Int, 5)
    }

    // MARK: - P4.8 — extended memories_search schema fields

    func testMemoriesSearchSchemaAdvertisesUpstreamFields() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let router = ToolRouter(limits: Limits())
        await router.register(MemoriesSearchTool(store: mem))
        let specs = await router.specs()
        guard let spec = specs.first(where: { $0.name == "memories_search" }),
              let d = spec.parametersJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let props = obj["properties"] as? [String: Any] else {
            return XCTFail("expected memories_search schema to be a JSON object")
        }
        // Upstream `SearchArgs` (memories/mcp/src/server.rs) declares these
        // exact fields. P4.8 brought them into codex-swift's schema.
        XCTAssertNotNil(props["match_mode"], "schema must declare match_mode")
        XCTAssertNotNil(props["path"], "schema must declare path")
        XCTAssertNotNil(props["context_lines"], "schema must declare context_lines")
        XCTAssertNotNil(props["case_sensitive"], "schema must declare case_sensitive")
        XCTAssertNotNil(props["normalized"], "schema must declare normalized")

        // match_mode must enumerate the three upstream variants.
        if let mm = props["match_mode"] as? [String: Any],
           let mmProps = mm["properties"] as? [String: Any],
           let t = mmProps["type"] as? [String: Any],
           let enumValues = t["enum"] as? [String] {
            XCTAssertEqual(Set(enumValues),
                           ["any", "all_on_same_line", "all_within_lines"])
        } else {
            XCTFail("match_mode.type.enum must match upstream SearchMatchMode variants")
        }
    }

    func testMemoriesSearchToolDeclaresOutputSchema() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let router = ToolRouter(limits: Limits())
        await router.register(MemoriesSearchTool(store: mem))
        await router.register(MemoriesListTool(store: mem))
        await router.register(MemoriesReadTool(store: mem))
        let specs = await router.specs()
        for name in ["memories_search", "memories_list", "memories_read"] {
            guard let spec = specs.first(where: { $0.name == name }) else {
                return XCTFail("\(name) not registered")
            }
            guard let json = spec.outputSchemaJSON,
                  let d = json.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d))
                    as? [String: Any] else {
                return XCTFail("\(name) must declare an outputSchemaJSON")
            }
            XCTAssertEqual(obj["type"] as? String, "object",
                           "\(name) output schema must describe an object")
            XCTAssertEqual(obj["additionalProperties"] as? Bool, false,
                           "\(name) output must reject additional properties")
        }
    }

    func testMemoriesSearchCaseInsensitiveMatches() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "Hello WORLD".write(toFile: home + "/memories/a.md",
                                atomically: true, encoding: .utf8)
        let tool = MemoriesSearchTool(store: mem)
        // Case-sensitive default: "hello" does NOT match "Hello".
        let strict = try await tool.run(
            ToolCall(callId: "c", name: "memories_search",
                     argumentsJSON: #"{"queries":["hello"]}"#), cwd: "/")
        guard let d1 = strict.output.data(using: .utf8),
              let obj1 = (try? JSONSerialization.jsonObject(with: d1)) as? [String: Any],
              let items1 = obj1["items"] as? [String] else {
            return XCTFail("expected items[] in strict result")
        }
        XCTAssertTrue(items1.isEmpty,
                      "case-sensitive search must not match \"Hello\"")
        // Case-insensitive: matches.
        let loose = try await tool.run(
            ToolCall(callId: "c", name: "memories_search",
                     argumentsJSON: #"{"queries":["hello"],"case_sensitive":false}"#),
            cwd: "/")
        guard let d2 = loose.output.data(using: .utf8),
              let obj2 = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any],
              let items2 = obj2["items"] as? [String] else {
            return XCTFail("expected items[] in loose result")
        }
        XCTAssertEqual(items2, ["a.md"],
                       "case-insensitive search must match \"Hello\"")
    }

    func testMemoriesSearchAllOnSameLineMode() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "alpha and beta together\njust alpha\njust beta".write(
            toFile: home + "/memories/x.md", atomically: true, encoding: .utf8)
        let tool = MemoriesSearchTool(store: mem)
        let r = try await tool.run(
            ToolCall(callId: "c", name: "memories_search",
                     argumentsJSON: #"{"queries":["alpha","beta"],"match_mode":{"type":"all_on_same_line"}}"#),
            cwd: "/")
        guard let d = r.output.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let matches = obj["matches"] as? [[String: Any]] else {
            return XCTFail("expected matches[]: \(r.output)")
        }
        XCTAssertEqual(matches.count, 1,
                       "all_on_same_line must only match the joint line")
        XCTAssertEqual(matches[0]["match_line_number"] as? Int, 1)
    }

    func testMemoriesSearchAllWithinLinesMode() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "alpha here\nthen beta nearby\nfar later\nbeta again".write(
            toFile: home + "/memories/y.md", atomically: true, encoding: .utf8)
        let tool = MemoriesSearchTool(store: mem)
        let r = try await tool.run(
            ToolCall(callId: "c", name: "memories_search",
                     argumentsJSON: #"{"queries":["alpha","beta"],"match_mode":{"type":"all_within_lines","line_count":2}}"#),
            cwd: "/")
        guard let d = r.output.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let matches = obj["matches"] as? [[String: Any]] else {
            return XCTFail("expected matches[]: \(r.output)")
        }
        XCTAssertGreaterThanOrEqual(matches.count, 1,
                                    "alpha+beta should match within a 2-line window")
        // Verify the matched_queries are reported.
        let mq = matches[0]["matched_queries"] as? [String] ?? []
        XCTAssertEqual(Set(mq), ["alpha", "beta"])
    }

    func testMemoriesSearchContextLinesAndNormalized() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "line0\nline1\nmagic-foo bar\nline3\nline4".write(
            toFile: home + "/memories/z.md", atomically: true, encoding: .utf8)
        let tool = MemoriesSearchTool(store: mem)
        // `magicfoo` matches `magic-foo` only when normalized strips the dash.
        let r = try await tool.run(
            ToolCall(callId: "c", name: "memories_search",
                     argumentsJSON: #"{"queries":["magicfoo"],"normalized":true,"context_lines":1}"#),
            cwd: "/")
        guard let d = r.output.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let matches = obj["matches"] as? [[String: Any]],
              let first = matches.first else {
            return XCTFail("expected at least one match: \(r.output)")
        }
        // context_lines=1 expands the content to include line1, line2 (match),
        // and line3.
        let content = first["content"] as? String ?? ""
        XCTAssertTrue(content.contains("line1"))
        XCTAssertTrue(content.contains("line3"))
        XCTAssertEqual(first["match_line_number"] as? Int, 3)
        XCTAssertEqual(first["content_start_line_number"] as? Int, 2)
    }

    func testMemoriesSearchPathScopesResults() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(
            atPath: home + "/memories/sub", withIntermediateDirectories: true)
        try "alpha here".write(toFile: home + "/memories/sub/a.md",
                               atomically: true, encoding: .utf8)
        try "alpha at root".write(toFile: home + "/memories/b.md",
                                  atomically: true, encoding: .utf8)
        // NOTE: the local MemoryStore.list() only enumerates *.md immediately
        // under the memories root by design; we still want path scoping to be
        // accepted, so passing the empty scope must succeed and an explicit
        // non-existent scope must yield no matches.
        let tool = MemoriesSearchTool(store: mem)
        let scoped = try await tool.run(
            ToolCall(callId: "c", name: "memories_search",
                     argumentsJSON: #"{"queries":["alpha"],"path":"no-such-dir"}"#),
            cwd: "/")
        guard let d = scoped.output.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let matches = obj["matches"] as? [[String: Any]] else {
            return XCTFail("expected matches[]: \(scoped.output)")
        }
        XCTAssertTrue(matches.isEmpty,
                      "scoped search on a non-existent path returns no matches")
        XCTAssertEqual(obj["path"] as? String, "no-such-dir",
                       "response echoes the scope path back")
    }

    func testMemoriesSearchRejectsBadMatchMode() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "alpha".write(toFile: home + "/memories/a.md",
                          atomically: true, encoding: .utf8)
        let tool = MemoriesSearchTool(store: mem)
        // all_within_lines requires line_count.
        let r1 = try await tool.run(
            ToolCall(callId: "c", name: "memories_search",
                     argumentsJSON: #"{"queries":["alpha"],"match_mode":{"type":"all_within_lines"}}"#),
            cwd: "/")
        XCTAssertFalse(r1.success,
                       "missing line_count must be rejected, not silently ignored")
        // Unknown match_mode.type is also rejected.
        let r2 = try await tool.run(
            ToolCall(callId: "c", name: "memories_search",
                     argumentsJSON: #"{"queries":["alpha"],"match_mode":{"type":"fuzzy"}}"#),
            cwd: "/")
        XCTAssertFalse(r2.success,
                       "unknown match_mode.type must be rejected")
    }

    func testToolOutputSchemaIsEmittedInOpenAIRequestBody() throws {
        // P4.8 — when a ToolSpec carries an outputSchemaJSON, the OpenAI
        // Responses request body must emit `output_schema` next to
        // `parameters` for that tool (mirrors `ResponsesApiTool.output_schema`
        // from `codex-tools/src/responses_api.rs`).
        let outSchema =
            #"{"type":"object","properties":{"items":{"type":"array","items":{"type":"string"}}},"required":["items"],"additionalProperties":false}"#
        let spec = ToolSpec(name: "memories_list",
                            description: "list",
                            parametersJSON: #"{"type":"object"}"#,
                            outputSchemaJSON: outSchema)
        let prompt = Prompt(instructions: "i",
                            input: [.userText("hi")],
                            tools: [spec])
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt,
            ModelSettings(model: "m", threadId: "t"),
            maxOutputTokens: nil)
        guard let tools = body["tools"] as? [[String: Any]],
              let first = tools.first,
              let emitted = first["output_schema"] as? [String: Any] else {
            return XCTFail("output_schema must appear on the tool entry: \(body)")
        }
        XCTAssertEqual(emitted["type"] as? String, "object",
                       "emitted output_schema must preserve schema body")
        XCTAssertEqual(emitted["additionalProperties"] as? Bool, false)
        // When a tool has no outputSchemaJSON, the key must be omitted so the
        // wire shape stays unchanged for the majority of tools.
        let noOut = ToolSpec(name: "x",
                             description: "x",
                             parametersJSON: #"{"type":"object"}"#)
        let prompt2 = Prompt(instructions: "i", input: [.userText("hi")],
                             tools: [noOut])
        let body2 = OpenAIResponsesClient.buildRequestBody(
            prompt2, ModelSettings(model: "m", threadId: "t"),
            maxOutputTokens: nil)
        let tools2 = body2["tools"] as? [[String: Any]] ?? []
        XCTAssertNil(tools2.first?["output_schema"],
                     "output_schema must be omitted when not declared")
    }

    func testMemoriesSearchUsesQueriesArray() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "hello world".write(toFile: home + "/memories/a.md",
                                atomically: true, encoding: .utf8)
        try "the quick fox".write(toFile: home + "/memories/b.md",
                                  atomically: true, encoding: .utf8)
        let tool = MemoriesSearchTool(store: mem)
        let r = try await tool.run(
            ToolCall(callId: "c1", name: "memories_search",
                     argumentsJSON: #"{"queries":["hello","fox"]}"#),
            cwd: "/")
        guard let d = r.output.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let items = obj["items"] as? [String] else {
            return XCTFail("invalid output: \(r.output)")
        }
        XCTAssertEqual(items.sorted(), ["a.md", "b.md"],
                       "queries array unions matches (upstream Any mode)")
    }

    // MARK: - Stage-1 consolidation pipeline

    func testConsolidationCallsModelWithStructuredOutput() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // The mock model emits a single Stage-1 JSON object as the agent's
        // completion text, mirroring what a structured-output-enabled model
        // returns when given the consolidator instructions.
        let payload = """
            {"raw_memory":"Durable memory body: ship feature X.","rollout_summary":"Implemented feature X.","rollout_slug":"feature-x"}
            """
        let model = MockModelClient([
            MockScenario([
                .created,
                .agentDone(itemId: "stage1", payload),
                .completeEndTurn(responseId: "resp_stage1", tokens: 7),
            ])
        ])
        await mem.setModelClient(model)
        await mem.consolidate(threadId: "tid-1",
                              transcript: "user: do thing\nassistant: ok\n")
        let body = await mem.read("tid-1.md") ?? ""
        XCTAssertTrue(body.contains("Durable memory body: ship feature X."),
                      "stage-1 raw_memory must be written to disk")
        XCTAssertTrue(body.contains("Implemented feature X."),
                      "stage-1 rollout_summary must appear in header")
        XCTAssertTrue(body.contains("feature-x"),
                      "stage-1 rollout_slug must drive the header id")

        // Assert the model was actually called with a Stage-1 thread id —
        // distinct from the regular session prompt-cache key.
        let caps = await model.capturedRequests()
        XCTAssertEqual(caps.count, 1, "stage-1 makes exactly one model call")
        XCTAssertTrue(caps[0].promptCacheKey.contains("mem-stage1"),
                      "stage-1 uses a dedicated prompt-cache key")
    }

    func testConsolidationRedactsSecretsBeforeWriting() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let payload = """
            {"raw_memory":"key=sk-abcdefghijklmnopqrstuvwxyz0123 and Bearer abcdefghijklmnopqrst","rollout_summary":"ok","rollout_slug":null}
            """
        let model = MockModelClient([
            MockScenario([
                .created,
                .agentDone(itemId: "s1", payload),
                .completeEndTurn(responseId: "r1", tokens: 7),
            ])
        ])
        await mem.setModelClient(model)
        await mem.consolidate(threadId: "tid-redact", transcript: "x")
        let body = await mem.read("tid-redact.md") ?? ""
        XCTAssertFalse(body.contains("sk-abcdefghijklmnopqrstuvwxyz0123"),
                       "OpenAI keys must be redacted")
        XCTAssertFalse(body.contains("Bearer abcdefghijklmnopqrst"),
                       "Bearer tokens must be redacted")
        XCTAssertTrue(body.contains("[REDACTED_SECRET]"),
                      "redaction marker must appear in stored body")
    }

    func testConsolidationFallbackOnModelError() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // Model client throws — store must fall back to local summary so the
        // engine never blocks turn completion.
        let model = MockModelClient([
            MockScenario([.failTerminal("simulated model failure")])
        ])
        await mem.setModelClient(model)
        await mem.consolidate(threadId: "tid-fallback",
                              transcript: "transcript text from a turn")
        let body = await mem.read("tid-fallback.md") ?? ""
        XCTAssertTrue(body.contains("transcript text from a turn"),
                      "on model error we fall back to the deterministic local summary")
        XCTAssertTrue(body.contains("# Memory for tid-fallback"),
                      "fallback header is the legacy format")
    }

    func testConsolidationFallbackOnUnparseableModelOutput() async throws {
        let (mem, home) = try makeMemoryStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let model = MockModelClient([
            MockScenario([
                .created,
                .agentDone(itemId: "s1",
                           "I refuse to answer — no JSON here."),
                .completeEndTurn(responseId: "r1", tokens: 4),
            ])
        ])
        await mem.setModelClient(model)
        await mem.consolidate(threadId: "tid-noparse",
                              transcript: "transcript content")
        let body = await mem.read("tid-noparse.md") ?? ""
        XCTAssertTrue(body.contains("transcript content"),
                      "unparseable model output falls back to local summary")
    }

    func testStage1OutputSchemaMatchesUpstreamKeys() {
        // Upstream `phase1::output_schema()` declares exactly these required
        // keys with additionalProperties:false.
        guard let d = Stage1Prompt.outputSchemaJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return XCTFail("output schema must be valid JSON")
        }
        let required = obj["required"] as? [String] ?? []
        XCTAssertEqual(Set(required), Set(["raw_memory", "rollout_summary", "rollout_slug"]))
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        let props = obj["properties"] as? [String: Any] ?? [:]
        XCTAssertNotNil(props["raw_memory"])
        XCTAssertNotNil(props["rollout_summary"])
        XCTAssertNotNil(props["rollout_slug"])
    }

    func testStage1OutputParserToleratesPreambleAndFences() {
        let withPreamble = """
            Here is the consolidation:
            ```json
            {"raw_memory":"body","rollout_summary":"sum","rollout_slug":"slug"}
            ```
            That's all.
            """
        guard let parsed = Stage1Output.parse(withPreamble) else {
            return XCTFail("parser must tolerate fenced/preambled JSON")
        }
        XCTAssertEqual(parsed.rawMemory, "body")
        XCTAssertEqual(parsed.rolloutSummary, "sum")
        XCTAssertEqual(parsed.rolloutSlug, "slug")
    }
}
