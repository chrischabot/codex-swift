import XCTest
@testable import Prompts

/// Port of `core/src/realtime_prompt.rs` tests (finding 6, app-server-events):
/// realtime backend system-prompt selection precedence.
final class RealtimeBackendPromptTests: XCTestCase {

    func testPrefersConfigOverride() {
        let out = Templates.prepareRealtimeBackendPrompt(
            requestPrompt: .some(.some("prompt from request")),
            configPrompt: "prompt from config",
            userFirstName: "Ada")
        XCTAssertEqual(out, "prompt from config")
    }

    func testUsesRequestPromptWhenNoConfig() {
        let out = Templates.prepareRealtimeBackendPrompt(
            requestPrompt: .some(.some("prompt from request")),
            configPrompt: nil,
            userFirstName: "Ada")
        XCTAssertEqual(out, "prompt from request")
    }

    func testPreservesEmptyRequestPrompt() {
        XCTAssertEqual(
            Templates.prepareRealtimeBackendPrompt(
                requestPrompt: .some(.some("")), configPrompt: nil, userFirstName: "Ada"),
            "")
        // Explicit null request prompt (upstream `Some(None)`) → empty string.
        XCTAssertEqual(
            Templates.prepareRealtimeBackendPrompt(
                requestPrompt: .some(.none), configPrompt: nil, userFirstName: "Ada"),
            "")
    }

    func testBlankConfigFallsThroughToRequest() {
        // A whitespace-only config prompt is treated as absent (upstream trims).
        let out = Templates.prepareRealtimeBackendPrompt(
            requestPrompt: .some(.some("request")),
            configPrompt: "   \n  ",
            userFirstName: "Ada")
        XCTAssertEqual(out, "request")
    }

    func testRendersDefaultBackendPromptWithName() {
        // Neither config nor request prompt present (upstream `None`) → default
        // backend prompt with `{{ user_first_name }}` substituted.
        let out = Templates.prepareRealtimeBackendPrompt(
            requestPrompt: nil, configPrompt: nil, userFirstName: "Ada")
        XCTAssertTrue(out.hasPrefix("## Identity, tone, and role"))
        XCTAssertTrue(out.contains("You are Codex, an OpenAI general-purpose agentic assistant"))
        XCTAssertTrue(out.contains("The user's name is Ada."))
        XCTAssertFalse(out.contains("{{ user_first_name }}"),
                       "placeholder must be substituted")
        // trim_end() — no trailing whitespace/newline.
        XCTAssertEqual(out, String(out.reversed().drop(while: { $0 == "\n" || $0 == " " }).reversed()))
    }

    func testDefaultUserFirstNameFallback() {
        let out = Templates.prepareRealtimeBackendPrompt(
            requestPrompt: nil, configPrompt: nil, userFirstName: "")
        XCTAssertTrue(out.contains("The user's name is there."),
                      "empty name falls back to \"there\"")
    }
}
