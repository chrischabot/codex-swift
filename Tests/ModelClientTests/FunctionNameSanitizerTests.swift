import XCTest
import Foundation
@testable import ModelClient

/// #11 — wire-boundary backstop: a replayed function_call name must be coerced to
/// a valid OpenAI identifier (^[A-Za-z0-9_-]+$) so a stray name cannot 400 the
/// whole Responses request (which drops the entire turn).
final class FunctionNameSanitizerTests: XCTestCase {

    func testValidNamesPassThrough() {
        XCTAssertEqual(sanitizedResponsesFunctionName("shell_command"), "shell_command")
        XCTAssertEqual(sanitizedResponsesFunctionName("apply_patch"), "apply_patch")
        XCTAssertEqual(sanitizedResponsesFunctionName("web-search_2"), "web-search_2")
    }

    func testInvalidNamesCoerced() {
        XCTAssertEqual(sanitizedResponsesFunctionName("git status"), "git_status")
        XCTAssertEqual(sanitizedResponsesFunctionName("ls -la"), "ls_-la")
        XCTAssertEqual(sanitizedResponsesFunctionName("echo hi | cat"), "echo_hi___cat")
        XCTAssertEqual(sanitizedResponsesFunctionName("café"), "caf_")   // non-ASCII → _
    }

    func testEmptyBecomesTool() {
        XCTAssertEqual(sanitizedResponsesFunctionName(""), "tool")
    }

    // End-to-end through the request builder: a spaced name in a replayed tool
    // output must serialize to a valid function_call name on the wire.
    func testBuildRequestBodyEmitsValidName() throws {
        let prompt = Prompt(
            instructions: "x",
            input: [.toolOutput(callId: "c1", name: "git status",
                                argumentsJSON: "{}", output: "ok")])
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t1")
        let body = OpenAIResponsesClient.buildRequestBody(prompt, settings, maxOutputTokens: nil)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let fnCall = try XCTUnwrap(input.first { ($0["type"] as? String) == "function_call" })
        let name = try XCTUnwrap(fnCall["name"] as? String)
        XCTAssertFalse(name.contains(" "), "serialized function_call name must have no spaces; got \(name)")
        XCTAssertEqual(name, "git_status")
    }
}
