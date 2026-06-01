import XCTest
import Foundation
@testable import ModelClient

/// Wire-shape coverage for the Freeform custom-grammar tool serialization
/// (upstream `tools/src/tool_spec.rs` `#[serde(tag="type")]` → `"custom"` for
/// `Freeform`, `tools/src/responses_api.rs` `FreeformTool`/`FreeformToolFormat`).
final class ApplyPatchFreeformWireTests: XCTestCase {

    private func freeformPrompt() -> Prompt {
        let spec = ToolSpec(
            name: "apply_patch",
            description: "Use the `apply_patch` tool to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.",
            parametersJSON: #"{"type":"object","properties":{"patch":{"type":"string"}},"required":["patch"]}"#,
            freeformFormat: FreeformToolFormat(
                type: "grammar", syntax: "lark",
                definition: "start: begin_patch hunk+ end_patch\n%import common.LF\n"))
        return Prompt(instructions: "i", input: [.userText("hi")], tools: [spec])
    }

    func testFreeformToolSerializesAsTypeCustom() {
        let body = OpenAIResponsesClient.buildRequestBody(
            freeformPrompt(),
            ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        guard let tools = body["tools"] as? [[String: Any]],
              let tool = tools.first else {
            return XCTFail("tools array missing")
        }
        XCTAssertEqual(tool["type"] as? String, "custom",
                       "freeform tool must serialize as type:custom, not function")
        XCTAssertEqual(tool["name"] as? String, "apply_patch")
        XCTAssertEqual(tool["description"] as? String,
            "Use the `apply_patch` tool to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.")
        // No JSON-function `parameters` key for the freeform shape.
        XCTAssertNil(tool["parameters"], "freeform tools must NOT emit parameters")
        guard let format = tool["format"] as? [String: Any] else {
            return XCTFail("format block missing")
        }
        XCTAssertEqual(format["type"] as? String, "grammar")
        XCTAssertEqual(format["syntax"] as? String, "lark")
        XCTAssertEqual(format["definition"] as? String,
                       "start: begin_patch hunk+ end_patch\n%import common.LF\n")
    }

    func testNonFreeformToolStillSerializesAsTypeFunction() {
        let spec = ToolSpec(name: "edit", description: "edits",
                            parametersJSON: #"{"type":"object","properties":{}}"#)
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")], tools: [spec]),
            ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        let tools = body["tools"] as? [[String: Any]]
        let tool = tools?.first
        XCTAssertEqual(tool?["type"] as? String, "function")
        XCTAssertNotNil(tool?["parameters"])
        XCTAssertNil(tool?["format"], "JSON function tools must not gain a format block")
    }

    /// Upstream `tools/src/responses_api.rs:32`: `ResponsesApiTool.strict` is a
    /// non-skippable bool, so EVERY function tool serializes `"strict": <bool>`
    /// (confirmed on the wire in `core/tests/suite/search_tool.rs:666`). And
    /// `output_schema` is `#[serde(skip)]` (`responses_api.rs:36-37`) — never on
    /// the wire even when the tool declares one.
    func testFunctionToolEmitsStrictAndOmitsOutputSchema() {
        let spec = ToolSpec(
            name: "exec_command", description: "runs a command",
            parametersJSON: #"{"type":"object","properties":{}}"#,
            outputSchemaJSON: #"{"type":"object","properties":{"output":{"type":"string"}}}"#,
            strict: false)
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")], tools: [spec]),
            ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        let tool = (body["tools"] as? [[String: Any]])?.first
        XCTAssertEqual(tool?["type"] as? String, "function")
        XCTAssertEqual(tool?["strict"] as? Bool, false,
                       "strict must always be emitted (non-skippable upstream bool)")
        XCTAssertNil(tool?["output_schema"],
                     "output_schema is #[serde(skip)] upstream — never on the wire")
    }

    func testStrictTrueIsPreservedOnTheWire() {
        let spec = ToolSpec(name: "strict_tool", description: "d",
                            parametersJSON: #"{"type":"object"}"#, strict: true)
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")], tools: [spec]),
            ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        let tool = (body["tools"] as? [[String: Any]])?.first
        XCTAssertEqual(tool?["strict"] as? Bool, true)
    }

    /// The remote-compaction builder mirrors the same tool serializer, so it
    /// must also emit `strict` and omit `output_schema`.
    func testRemoteCompactionToolWireShapeMatches() {
        let spec = ToolSpec(
            name: "write_stdin", description: "d",
            parametersJSON: #"{"type":"object","properties":{}}"#,
            outputSchemaJSON: #"{"type":"object"}"#,
            strict: false)
        let body = RemoteCompaction.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")], tools: [spec]),
            ModelSettings(model: "gpt", threadId: "t"))
        let tool = (body["tools"] as? [[String: Any]])?.first
        XCTAssertEqual(tool?["type"] as? String, "function")
        XCTAssertEqual(tool?["strict"] as? Bool, false)
        XCTAssertNil(tool?["output_schema"],
                     "compaction builder must not emit output_schema either")
    }

    func testMixedToolsKeepRespectiveWireShapes() {
        let freeform = ToolSpec(
            name: "apply_patch", description: "d",
            parametersJSON: "{}",
            freeformFormat: FreeformToolFormat(type: "grammar", syntax: "lark", definition: "x"))
        let fn = ToolSpec(name: "shell", description: "d", parametersJSON: #"{"type":"object"}"#)
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")], tools: [freeform, fn]),
            ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        let tools = body["tools"] as? [[String: Any]] ?? []
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { t -> (String, String)? in
            guard let n = t["name"] as? String, let ty = t["type"] as? String else { return nil }
            return (n, ty)
        })
        XCTAssertEqual(byName["apply_patch"], "custom")
        XCTAssertEqual(byName["shell"], "function")
    }
}
