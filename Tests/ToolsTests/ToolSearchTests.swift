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
}