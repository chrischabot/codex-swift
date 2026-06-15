import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives

/// Live-LLM proof for P2 (tool input-schema compaction). Registers a tool whose
/// input schema is far over the ~1k-token budget, runs a REAL turn against the
/// OpenAI Responses API, and asserts two things that can only both hold if
/// compaction works end-to-end:
///   1. the spec that went ON THE WIRE was compacted (descriptions stripped,
///      under budget) — captured from the real request, not a mock; and
///   2. the live API ACCEPTED the compacted tool schema (the turn completed
///      instead of failing with a 400 invalid-schema error), and the model was
///      able to call the tool.
/// Skips cleanly without OPENAI_API_KEY (same policy as the rest of LiveTests).
final class LiveToolSchemaCompactionTests: XCTestCase {

    /// A tool with a deliberately huge input schema (long descriptions on many
    /// dummy properties) so the normalized form blows past the 4000-byte budget.
    /// The only meaningful argument is `text`, which the model fills.
    private struct BigEchoTool: Tool {
        let name = "bigecho"
        let parallelSafe = true
        var toolDescription: String { "Echo back the provided text verbatim." }
        var jsonSchema: String {
            let longDesc = String(repeating: "lorem ipsum dolor sit amet ", count: 6)
            var props = ["\"text\":{\"type\":\"string\",\"description\":\"the text to echo back exactly\"}"]
            for i in 0..<60 {
                props.append("\"pad\(i)\":{\"type\":\"string\",\"description\":\"\(longDesc)\"}")
            }
            return "{\"type\":\"object\",\"properties\":{\(props.joined(separator: ","))},\"required\":[\"text\"],\"additionalProperties\":false}"
        }
        func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
            ToolResult(callId: call.callId, output: "ECHO:" + call.argumentsJSON,
                       success: true, truncated: false)
        }
    }

    func testLargeToolSchemaIsCompactedOnTheWireAndAcceptedByLiveAPI() async throws {
        guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil else {
            throw XCTSkip("OPENAI_API_KEY not set (live test skipped)")
        }
        let home = lxTmp("p2-compact-home")
        let work = lxTmp("p2-compact-work")
        defer { try? FileManager.default.removeItem(atPath: home) }
        defer { try? FileManager.default.removeItem(atPath: work) }

        let store = try lxStore(home)
        let tid = ThreadId("thr_p2_" + UUID().uuidString.prefix(8))
        let (engine, rec, router, _) = await lxFullToolEngine(
            home: home, work: work, tid: tid, store: store, maxIters: 6, deadline: .seconds(120))

        // Sanity: the raw schema is genuinely over the normalized budget.
        let big = BigEchoTool()
        XCTAssertGreaterThan(ToolSchemaCompaction.normalizedLen(
            try! JSONSerialization.jsonObject(with: big.jsonSchema.data(using: .utf8)!,
                options: [.fragmentsAllowed])), ToolSchemaCompaction.maxBytes,
            "fixture schema must exceed the compaction budget")

        await router.register(big)

        await engine.submit(.startTurn(input: [TurnInput(text:
            "Call the bigecho tool with text exactly 'P2_LIVE_OK'. Use the tool; do not answer directly.")],
            model: nil, turnId: nil))
        let evs = await lxCollect(engine, untilCompletions: 1, timeout: .seconds(120))

        // (1) The turn TERMINATED and the live API did not reject the request.
        let status = lxLastTurnStatus(evs)
        XCTAssertNotNil(status, "the live turn must terminate")
        XCTAssertNotEqual(status, .failed,
            "a failed turn here means the live API rejected the (compacted) tool schema")

        // (2) The spec sent ON THE WIRE was compacted: descriptions stripped and
        // the normalized form under budget — captured from the REAL request.
        let caps = await rec.capturedRequests()
        XCTAssertFalse(caps.isEmpty, "at least one live request was captured")
        let wireSpec = caps.compactMap { $0.prompt.tools.first { $0.name == "bigecho" } }.first
        let spec = try XCTUnwrap(wireSpec, "bigecho tool must be advertised on the wire")
        XCTAssertFalse(spec.parametersJSON.contains("\"description\""),
            "compaction stripped descriptions before the schema reached the API")
        let wireLen = ToolSchemaCompaction.normalizedLen(
            try! JSONSerialization.jsonObject(with: spec.parametersJSON.data(using: .utf8)!,
                options: [.fragmentsAllowed]))
        XCTAssertLessThanOrEqual(wireLen, ToolSchemaCompaction.maxBytes,
            "the compacted on-wire schema is under budget")
        // The text argument survives compaction so the tool stays callable.
        XCTAssertTrue(spec.parametersJSON.contains("\"text\""),
            "the meaningful `text` property survived compaction")
    }
}
