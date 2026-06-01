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

/// Live-LLM end-to-end coverage for three harness features that are each
/// proven by an observable, model-independent side-effect:
///
///  - harness-mcp: a real `python3 -u` stdio MCP server is spawned, its
///    `ping` tool is discovered and advertised on the router as
///    `mcp__mock__ping`, and a real stdio JSON-RPC round-trip returns "pong".
///  - harness-toolsearch: a deferred tool D is invisible in `router.specs()`
///    until `tool_search` activates it, at which point the wire tool list
///    visibly changes — driven by the deterministic BM25 search, not the model.
///  - harness-codemode: the `exec` JS tool evaluates arithmetic and, through
///    the nested-dispatch `callTool` bridge, writes a real file on disk
///    (macOS / JavaScriptCore). On non-darwin it returns the honest gated
///    string so the JSC gate never silently no-ops.
///
/// Each gated test opens with the shared live-key skip and pairs a hard
/// deterministic assertion with a bounded best-effort live turn whose only
/// guarantee is that it TERMINATES.
final class LiveHarnessMcpCodeModeToolSearchTests: XCTestCase {

    // MARK: - happy: MCP proxy advertised + real stdio JSON-RPC round-trip

    func testMcpProxyAdvertisedAndRoundTrips() async throws {
        // Deterministic half (MCP round-trip) runs only when python3 exists;
        // the live turn additionally needs the API key.
        guard let python = Self.findPython3() else {
            throw XCTSkip("python3 not available for stdio MCP server")
        }

        let home = lxTmp("mcp-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = lxTmp("mcp-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let serverPath = work + "/mock_mcp_server.py"
        try Self.mockMcpServerSource.write(toFile: serverPath, atomically: true, encoding: .utf8)

        let tid = ThreadId.generate()
        let store = try lxStore(home)
        _ = try await store.create(SessionConfig(threadId: tid, cwd: work, model: lxModel()))

        // Build the full-tool engine; we register the MCP proxy on its router.
        let (engine, rec, router, _) = await lxFullToolEngine(
            home: home, work: work, tid: tid, store: store,
            maxOut: 256, maxIters: 4, deadline: .seconds(120))

        // Spawn the real python3 -u stdio MCP server and register its proxies.
        let manager = McpManager()
        let cfg = McpServerConfig(name: "mock", command: python,
                                  args: ["-u", serverPath])
        await manager.startAll([cfg], router: router)
        defer { Task { await manager.stopAll() } }

        // The server must reach "ready" with the ping tool discovered.
        let statuses = await manager.statusList()
        XCTAssertEqual(statuses.first?.state, "ready",
                       "stdio MCP server initialized: \(statuses.first?.error ?? "nil")")

        // --- DETERMINISTIC: advertised proxy spec ---
        let specs = await router.specs()
        guard let pingSpec = specs.first(where: { $0.name == "mcp__mock__ping" }) else {
            return XCTFail("router.specs() must advertise mcp__mock__ping; got: \(specs.map { $0.name })")
        }
        XCTAssertEqual(pingSpec.description, "returns pong",
                       "the proxy carries the server-declared description byte-for-byte")

        // --- DETERMINISTIC: real stdio JSON-RPC round-trip ---
        let result = await router.dispatch(
            ToolCall(callId: "c-ping", name: "mcp__mock__ping", argumentsJSON: "{}"),
            cwd: work, deadline: .fromNow(.seconds(30)))
        XCTAssertTrue(result.success, "mcp__mock__ping dispatch succeeded over stdio")
        XCTAssertTrue(result.output.contains("pong"),
                      "the MCP server's tool result round-tripped: \(result.output)")

        // --- BOUNDED LIVE TURN: offering the tool must merely terminate ---
        try lxSkipUnlessLiveKey()
        await engine.start()
        let collector = Task { await lxCollect(engine, untilCompletions: 1, timeout: .seconds(120)) }
        await engine.submit(.startTurn(input: [TurnInput(
            text: "Call the mcp__mock__ping tool now. You must call the tool.")],
            model: nil, turnId: nil))
        let evs = await collector.value
        XCTAssertEqual(lxLastTurnStatus(evs), .completed,
                       "a turn offering an MCP tool completes (no wedge), regardless of model choice")
        _ = rec
    }

    // MARK: - adversarial: tool_search changes the wire tool list

    func testToolSearchActivatesDeferredToolChangingWireToolList() async throws {
        // Deterministic + model-independent: no live key required to PROVE the
        // feature. We still gate the (intentionally absent) live half cleanly.
        let router = ToolRouter(limits: Limits())

        // Register a deferred tool D whose description is the only thing the
        // search can latch onto, plus the always-active tool_search.
        let deferredTool = LXDeferredProbeTool()
        let D = deferredTool.name
        await router.registerDeferred(deferredTool)
        await router.installToolSearch()

        // --- BEFORE: D is discoverable but NOT advertised on the wire ---
        let before = await router.specs().map { $0.name }
        XCTAssertFalse(before.contains(D),
                       "deferred tool must be hidden from the wire tool list before activation")
        XCTAssertTrue(before.contains("tool_search"),
                      "tool_search is always-active")
        let deferredNames = await router.deferredToolNames()
        XCTAssertTrue(deferredNames.contains(D), "D is registered as deferred")
        let activatedBefore = await router.activatedToolNames()
        XCTAssertFalse(activatedBefore.contains(D), "D is not yet activated")

        // --- DISPATCH tool_search with a query that matches D's description ---
        let q = #"{"query":"crystalline lattice diffraction spectroscopy"}"#
        let searchResult = await router.dispatch(
            ToolCall(callId: "c-search", name: "tool_search", argumentsJSON: q),
            cwd: ".", deadline: .fromNow(.seconds(10)))
        XCTAssertTrue(searchResult.success, "tool_search dispatch succeeded")

        // The output ends with a JSON line containing "activated" naming D.
        let lines = searchResult.output.split(separator: "\n", omittingEmptySubsequences: true)
        guard let jsonLine = lines.last.map(String.init) else {
            return XCTFail("tool_search produced no output lines")
        }
        XCTAssertTrue(jsonLine.contains("\"activated\""),
                      "final line is the machine-readable activation JSON: \(jsonLine)")
        XCTAssertTrue(jsonLine.contains(D),
                      "the activation JSON names the matched deferred tool D: \(jsonLine)")
        // Prove it parses and D is in the activated array.
        if let data = jsonLine.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["activated"] as? [[String: Any]] {
            XCTAssertTrue(arr.contains { ($0["name"] as? String) == D },
                          "activated array contains a record for D")
        } else {
            XCTFail("activation JSON line did not parse: \(jsonLine)")
        }

        // --- AFTER: the wire tool list visibly changed BECAUSE of tool_search ---
        let activatedAfter = await router.activatedToolNames()
        XCTAssertTrue(activatedAfter.contains(D),
                      "tool_search activated D (activatedToolNames now contains it)")
        let after = await router.specs().map { $0.name }
        XCTAssertTrue(after.contains(D),
                      "the wire tool list now advertises D — it changed only via tool_search")

        // Adversarial containment: a query matching NOTHING must not activate.
        let router2 = ToolRouter(limits: Limits())
        await router2.registerDeferred(LXDeferredProbeTool())
        await router2.installToolSearch()
        let miss = await router2.dispatch(
            ToolCall(callId: "c-miss", name: "tool_search",
                     argumentsJSON: #"{"query":"zzzzz_no_token_matches_anything_qqqq"}"#),
            cwd: ".", deadline: .fromNow(.seconds(10)))
        XCTAssertTrue(miss.output.contains("\"activated\":[]"),
                      "a non-matching query activates nothing (empty activation set)")
        let stillHidden = await router2.specs().map { $0.name }
        XCTAssertFalse(stillHidden.contains(LXDeferredProbeTool().name),
                       "a missed search leaves the deferred tool hidden — no silent activation")
    }

    // MARK: - severe: code-mode exec evaluates + writes a file via callTool

    func testCodeModeExecEvaluatesAndWritesFileViaCallTool() async throws {
        let work = lxTmp("cm-work"); defer { try? FileManager.default.removeItem(atPath: work) }

        // Build a minimal router: write_file (the nested tool the JS will call)
        // plus the code-mode pair wired through the nested-dispatch bridge,
        // exactly as DefaultTools does (but isolated for a tight assertion).
        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite, writableRoots: [work]))
        let router = ToolRouter(limits: Limits())
        await router.register(WriteFileTool(sandbox: sandbox))
        let nestedNames = await router.specs().map { $0.name }
        await installCodeMode(on: router, toolNames: nestedNames) { name, argsJSON, cwd, timeoutMs in
            await router.dispatchNestedFromCode(name: name, argumentsJSON: argsJSON,
                                                cwd: cwd, timeoutMs: timeoutMs)
        }

        #if os(macOS)
        // --- exec evaluates pure JS arithmetic ---
        let calc = await router.dispatch(
            ToolCall(callId: "c-calc", name: CodeMode.publicToolName,
                     argumentsJSON: #"{"source":"return 6*7"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertTrue(calc.success, "exec evaluated arithmetic: \(calc.output)")
        XCTAssertEqual(calc.output, "42",
                       "exec returns the evaluated value (model-independent JSC)")

        // --- exec calls write_file through the nested callTool bridge ---
        let cmPath = work + "/cm.txt"
        XCTAssertFalse(FileManager.default.fileExists(atPath: cmPath),
                       "precondition: cm.txt does not exist before exec runs")
        // The code-mode runtime wraps `source` in a synchronous IIFE and binds
        // `callTool` as a synchronous function, so the bridge is called WITHOUT
        // `await` (using `await` here is a JS SyntaxError under the real runtime).
        let src = #"callTool('write_file', {path:'cm.txt', content:'CM_OK'}); return 'done';"#
        let writeViaCode = await router.dispatch(
            ToolCall(callId: "c-cm", name: CodeMode.publicToolName,
                     argumentsJSON: Self.jsonObject(["source": src])),
            cwd: work, deadline: .fromNow(.seconds(30)))
        XCTAssertTrue(writeViaCode.success,
                      "exec running a nested callTool succeeded: \(writeViaCode.output)")

        // The PROVABLE side-effect: a real file on disk written THROUGH the
        // JS -> callTool -> dispatchNestedFromCode -> WriteFileTool bridge.
        XCTAssertTrue(FileManager.default.fileExists(atPath: cmPath),
                      "exec wrote cm.txt through the nested dispatch bridge")
        let contents = (try? String(contentsOfFile: cmPath, encoding: .utf8)) ?? ""
        XCTAssertEqual(contents, "CM_OK",
                       "the nested write_file persisted the exact JS-supplied content")
        #else
        // --- non-darwin: the JSC gate must fail honestly, never silently ---
        let gated = await router.dispatch(
            ToolCall(callId: "c-gate", name: CodeMode.publicToolName,
                     argumentsJSON: #"{"source":"return 6*7"}"#),
            cwd: work, deadline: .fromNow(.seconds(20)))
        XCTAssertFalse(gated.success,
                       "exec must report failure where JavaScriptCore is unavailable")
        XCTAssertTrue(gated.output.contains("JavaScriptCore"),
                      "the gated message names the missing runtime honestly: \(gated.output)")
        let cmPath = work + "/cm.txt"
        XCTAssertFalse(FileManager.default.fileExists(atPath: cmPath),
                       "no file is written when the JSC gate is closed (no silent no-op)")
        #endif
    }

    // MARK: - helpers

    /// Locate a usable python3 interpreter for the stdio MCP server.
    private static func findPython3() -> String? {
        let candidates = ["/usr/bin/python3", "/usr/local/bin/python3",
                          "/opt/homebrew/bin/python3"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fall back to PATH resolution via /usr/bin/env.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", "import sys; print(sys.executable)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    private static func jsonObject(_ dict: [String: String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
    }

    /// A minimal, dependency-free stdio MCP server exposing a single `ping`
    /// tool. Implements the JSON-RPC 2.0 lifecycle the Swift `McpClient`
    /// expects: `initialize` (protocolVersion 2025-06-18), the
    /// `notifications/initialized` notification (ignored), `tools/list`, and
    /// `tools/call`. Frames are newline-delimited JSON read from stdin and
    /// written to stdout.
    private static let mockMcpServerSource = """
    import sys, json

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

    TOOLS = [
        {
            "name": "ping",
            "description": "returns pong",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        }
    ]

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "mock", "version": "0.1"},
                },
            })
        elif method == "notifications/initialized":
            # Notification: no response.
            continue
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            params = msg.get("params") or {}
            name = params.get("name")
            if name == "ping":
                send({
                    "jsonrpc": "2.0",
                    "id": mid,
                    "result": {
                        "content": [{"type": "text", "text": "pong"}],
                        "isError": False,
                    },
                })
            else:
                send({
                    "jsonrpc": "2.0",
                    "id": mid,
                    "error": {"code": -32601, "message": "unknown tool: " + str(name)},
                })
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}})
    """
}

// MARK: - probe deferred tool used by the tool_search test

/// A deferred tool whose description carries distinctive tokens so the
/// BM25-lite `tool_search` can match it deterministically. It is never
/// auto-advertised; only `tool_search` activation can surface it on the wire.
struct LXDeferredProbeTool: Tool {
    let name = "crystallography_analyzer"
    let parallelSafe = true
    var toolDescription: String {
        "Performs crystalline lattice diffraction spectroscopy analysis on samples."
    }
    var jsonSchema: String {
        #"{"type":"object","properties":{"sample":{"type":"string"}},"required":["sample"],"additionalProperties":false}"#
    }
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        ToolResult(callId: call.callId, output: "analyzed", success: true, truncated: false)
    }
}
