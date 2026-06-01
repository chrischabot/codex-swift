import XCTest
@testable import Tools
@testable import InfraPrimitives

private struct StubTool: Tool {
    let name: String
    let desc: String
    let parallelSafe = true
    var toolDescription: String { desc }
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        ToolResult(callId: call.callId, output: name, success: true, truncated: false)
    }
}

/// A tool that throws a TURN-FATAL error (upstream `FunctionCallError::Fatal`).
private struct FatalStubTool: Tool {
    let name = "fatal_tool"
    let parallelSafe = true
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        throw FatalToolError(message: "tool produced no output")
    }
}

/// A tool that throws an ORDINARY (model-recoverable) error.
private struct RecoverableStubTool: Tool {
    let name = "recoverable_tool"
    let parallelSafe = true
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        throw ToolError(message: "please retry")
    }
}

final class ToolSearchTests: XCTestCase {

    private func makeRouter() -> ToolRouter {
        ToolRouter(limits: Limits())
    }

    private func farDeadline() -> Deadline {
        Deadline.fromNow(.seconds(30))
    }

    func testDeferredToolsAreHiddenUntilSearched() async {
        let router = makeRouter()
        await router.registerDeferred(StubTool(name: "db_query", desc: "Query a database"))
        await router.registerDeferred(StubTool(name: "web_fetch", desc: "Fetch a web page"))
        await router.installToolSearch()

        let specs = await router.specs()
        let names = specs.map { $0.name }
        XCTAssertTrue(names.contains("tool_search"))
        XCTAssertFalse(names.contains("db_query"))
        XCTAssertFalse(names.contains("web_fetch"))

        let deferredNames = await router.deferredToolNames()
        XCTAssertEqual(deferredNames, ["db_query", "web_fetch"])
    }

    func testToolSearchActivatesRankedMatches() async {
        let router = makeRouter()
        await router.registerDeferred(StubTool(name: "db_query", desc: "Query a database"))
        await router.registerDeferred(StubTool(name: "web_fetch", desc: "Fetch a web page"))
        await router.installToolSearch()

        let call = ToolCall(callId: "c1", name: "tool_search",
                            argumentsJSON: #"{"query":"database query","limit":1}"#)
        let result = await router.dispatch(call, cwd: ".", deadline: farDeadline())
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("db_query"))

        let activated = await router.activatedToolNames()
        XCTAssertEqual(activated, ["db_query"])

        let specs = await router.specs()
        let names = specs.map { $0.name }
        XCTAssertTrue(names.contains("db_query"))
        XCTAssertFalse(names.contains("web_fetch"))
    }

    func testActivatedDeferredToolIsDispatchable() async {
        let router = makeRouter()
        await router.registerDeferred(StubTool(name: "db_query", desc: "Query a database"))
        await router.installToolSearch()

        let search = ToolCall(callId: "s", name: "tool_search",
                              argumentsJSON: #"{"query":"database query"}"#)
        _ = await router.dispatch(search, cwd: ".", deadline: farDeadline())

        let call = ToolCall(callId: "c2", name: "db_query", argumentsJSON: "{}")
        let result = await router.dispatch(call, cwd: ".", deadline: farDeadline())
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "db_query")
    }

    func testDeferredToolCallableByNameEvenBeforeActivation() async {
        let router = makeRouter()
        await router.registerDeferred(StubTool(name: "web_fetch", desc: "Fetch a web page"))
        await router.installToolSearch()

        let specs = await router.specs()
        let names = specs.map { $0.name }
        XCTAssertFalse(names.contains("web_fetch"))

        let call = ToolCall(callId: "c3", name: "web_fetch", argumentsJSON: "{}")
        let result = await router.dispatch(call, cwd: ".", deadline: farDeadline())
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "web_fetch")
    }

    func testNoMatchActivatesNothing() async {
        let router = makeRouter()
        await router.registerDeferred(StubTool(name: "db_query", desc: "Query a database"))
        await router.registerDeferred(StubTool(name: "web_fetch", desc: "Fetch a web page"))
        await router.installToolSearch()

        let specsBefore = await router.specs().map { $0.name }

        let call = ToolCall(callId: "c4", name: "tool_search",
                            argumentsJSON: #"{"query":"zzzzz nonexistent"}"#)
        let result = await router.dispatch(call, cwd: ".", deadline: farDeadline())
        XCTAssertTrue(result.output.contains("(no matching tools)"))

        let activated = await router.activatedToolNames()
        XCTAssertTrue(activated.isEmpty)

        let specsAfter = await router.specs().map { $0.name }
        XCTAssertEqual(specsBefore, specsAfter)
    }

    func testToolSearchDeterministic() async {
        let router = makeRouter()
        await router.registerDeferred(StubTool(name: "db_query", desc: "Query a database"))
        await router.registerDeferred(StubTool(name: "web_fetch", desc: "Fetch a web page"))
        await router.installToolSearch()

        let call = ToolCall(callId: "c5", name: "tool_search",
                            argumentsJSON: #"{"query":"web database query"}"#)
        let r1 = await router.dispatch(call, cwd: ".", deadline: farDeadline())
        let r2 = await router.dispatch(call, cwd: ".", deadline: farDeadline())
        XCTAssertEqual(r1.output, r2.output)
    }

    /// Finding 4: the advertised `tool_search` spec must mirror upstream
    /// `tool_search_spec.rs::create_tool_search_tool` — the `# Tool discovery`
    /// description, `query`/`limit` parameter descriptions, and `limit` typed
    /// as `number` (NOT integer) with the "defaults to 8" wording.
    func testToolSearchSpecMatchesUpstream() async throws {
        let router = makeRouter()
        await router.registerDeferred(StubTool(name: "db_query", desc: "Query a database"))
        await router.installToolSearch()

        let spec = await router.specs().first { $0.name == "tool_search" }
        let tool = try XCTUnwrap(spec)
        XCTAssertTrue(tool.description.hasPrefix("# Tool discovery"),
                      "description must use upstream `# Tool discovery` framing")
        XCTAssertTrue(tool.description.contains("BM25"))
        XCTAssertTrue(tool.description.contains("list_mcp_resources"),
                      "description must carry upstream MCP-discovery guidance")

        let obj = try JSONSerialization.jsonObject(
            with: Data(tool.parametersJSON.utf8)) as? [String: Any]
        let props = (obj?["properties"] as? [String: Any]) ?? [:]
        XCTAssertEqual((props["query"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props["query"] as? [String: Any])?["description"] as? String,
                       "Search query for deferred tools.")
        XCTAssertEqual((props["limit"] as? [String: Any])?["type"] as? String, "number",
                       "upstream types `limit` as number, not integer")
        XCTAssertEqual((props["limit"] as? [String: Any])?["description"] as? String,
                       "Maximum number of tools to return (defaults to 8).")
        XCTAssertEqual(obj?["required"] as? [String], ["query"])
        XCTAssertEqual(obj?["additionalProperties"] as? Bool, false)
    }

    func testRegisteredToolsAndSpecsUnchanged() async {
        let router = makeRouter()
        await router.register(StubTool(name: "alpha_tool", desc: "Alpha"))
        await router.register(StubTool(name: "beta_tool", desc: "Beta"))

        let specs = await router.specs()
        let names = specs.map { $0.name }
        XCTAssertEqual(names, ["alpha_tool", "beta_tool"])

        let call = ToolCall(callId: "c6", name: "alpha_tool", argumentsJSON: "{}")
        let result = await router.dispatch(call, cwd: ".", deadline: farDeadline())
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "alpha_tool")
    }

    /// Audit tools-router finding 3: a tool that throws `FatalToolError`
    /// (upstream `FunctionCallError::Fatal`) must surface a ToolResult flagged
    /// `isFatal` so the SessionEngine turn loop can abort the turn — distinct
    /// from an ordinary recoverable failure.
    func testFatalToolErrorSurfacesAsFatalResult() async {
        let router = makeRouter()
        await router.register(FatalStubTool())
        let call = ToolCall(callId: "f1", name: "fatal_tool", argumentsJSON: "{}")
        let r = await router.dispatch(call, cwd: ".", deadline: farDeadline())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.isFatal,
                      "FatalToolError must surface isFatal==true to abort the turn")
        XCTAssertEqual(r.output, "tool produced no output")
    }

    /// An ordinary `ToolError` stays model-recoverable: `isFatal` is false so the
    /// turn loop feeds the failure back to the model (parity with
    /// `parallel.rs:71` RespondToModel → failed function_call_output).
    func testRecoverableToolErrorIsNotFatal() async {
        let router = makeRouter()
        await router.register(RecoverableStubTool())
        let call = ToolCall(callId: "r1", name: "recoverable_tool", argumentsJSON: "{}")
        let r = await router.dispatch(call, cwd: ".", deadline: farDeadline())
        XCTAssertFalse(r.success)
        XCTAssertFalse(r.isFatal,
                       "an ordinary ToolError must NOT be fatal (model-recoverable)")
        XCTAssertEqual(r.output, "please retry")
    }
}