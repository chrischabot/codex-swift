import XCTest
import Foundation
@testable import ModelClient
@testable import InfraPrimitives
import WireProtocol

/// Coverage for the v9 model-client audit findings:
///  - store default false / Azure coupling (finding 2)
///  - structured-output `text.format` (finding 3)
///  - header rate-limit parse drops plan_type (finding 5)
///  - RateLimitSnapshot → notification JSON wire shape (finding 1)
final class ModelClientAuditV9Tests: XCTestCase {

    // MARK: store default (finding 2)

    /// Upstream `build_responses_request` (`core/src/client.rs:754`):
    /// `store: provider.is_azure_responses_endpoint()` — for the standard
    /// OpenAI provider that is `false`. The ModelSettings default is now
    /// `false`, and an un-chained request keeps it false on the wire.
    func testStoreDefaultsToFalseForStandardProvider() {
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]),
            ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        XCTAssertEqual(body["store"] as? Bool, false,
                       "standard OpenAI request must send store:false")
    }

    /// Azure Responses endpoints send `store:true` even when settings default
    /// to false (provider coupling, `client.rs:754`).
    func testStoreIsTrueForAzureProvider() {
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]),
            ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil,
            isAzureResponsesProvider: true)
        XCTAssertEqual(body["store"] as? Bool, true,
                       "Azure Responses endpoint must send store:true")
    }

    /// previousResponseId forces store:true (sticky-routing exception is kept).
    func testPreviousResponseIdForcesStoreTrue() {
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]),
            ModelSettings(model: "gpt", threadId: "t",
                          previousResponseId: "resp_prev"),
            maxOutputTokens: nil)
        XCTAssertEqual(body["store"] as? Bool, true,
                       "previous_response_id chaining requires store:true")
    }

    /// An explicit store:true caller override is honored.
    func testExplicitStoreTrueHonored() {
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]),
            ModelSettings(model: "gpt", threadId: "t", store: true),
            maxOutputTokens: nil)
        XCTAssertEqual(body["store"] as? Bool, true)
    }

    // MARK: structured-output text.format (finding 3)

    /// Upstream `create_text_param_for_request` (`common.rs:279-297`): an
    /// `output_schema` produces `text.format = {type:"json_schema",
    /// name:"codex_output_schema", strict, schema}`.
    func testOutputSchemaEmitsTextFormat() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["answer": .object(["type": .string("string")])]),
            "required": .array([.string("answer")]),
        ])
        var prompt = Prompt(instructions: "i", input: [.userText("hi")])
        prompt.outputSchema = schema
        prompt.outputSchemaStrict = true
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        guard let text = body["text"] as? [String: Any],
              let format = text["format"] as? [String: Any] else {
            return XCTFail("text.format missing")
        }
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["name"] as? String, "codex_output_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        guard let emitted = format["schema"] as? [String: Any] else {
            return XCTFail("schema missing")
        }
        XCTAssertEqual(emitted["type"] as? String, "object")
        XCTAssertNotNil(emitted["properties"])
        // verbosity not set → only format key present.
        XCTAssertNil(text["verbosity"])
    }

    /// strict:false is preserved (default).
    func testOutputSchemaStrictFalseEmitted() {
        var prompt = Prompt(instructions: "i", input: [.userText("hi")])
        prompt.outputSchema = .object(["type": .string("object")])
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["strict"] as? Bool, false)
    }

    /// verbosity + output schema both present → text carries both keys
    /// (`create_text_param_for_request` merges them).
    func testVerbosityAndSchemaMerge() {
        var prompt = Prompt(instructions: "i", input: [.userText("hi")])
        prompt.outputSchema = .object(["type": .string("object")])
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt,
            ModelSettings(model: "gpt", threadId: "t",
                          textVerbosity: "low", supportVerbosity: true),
            maxOutputTokens: nil)
        let text = body["text"] as? [String: Any]
        XCTAssertEqual(text?["verbosity"] as? String, "low")
        XCTAssertNotNil(text?["format"])
    }

    /// No schema and no verbosity → no `text` key at all (matches the
    /// non-structured wire shape).
    func testNoSchemaNoVerbosityOmitsText() {
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]),
            ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        XCTAssertNil(body["text"], "text must be omitted when neither verbosity nor schema set")
    }

    /// verbosity only (no schema) keeps the legacy `{verbosity}` shape.
    func testVerbosityOnlyKeepsLegacyShape() {
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]),
            ModelSettings(model: "gpt", threadId: "t",
                          textVerbosity: "high", supportVerbosity: true),
            maxOutputTokens: nil)
        let text = body["text"] as? [String: Any]
        XCTAssertEqual(text?["verbosity"] as? String, "high")
        XCTAssertNil(text?["format"])
    }

    // MARK: header rate-limit parse drops plan_type (finding 5)

    /// Upstream `parse_rate_limit_for_limit` (`rate_limits.rs:88-97`) always
    /// sets plan_type:None on a header-derived snapshot — even when an
    /// `x-codex-plan-type` header is present.
    func testHeaderSnapshotNeverCarriesPlanType() {
        let dump = """
        x-codex-primary-used-percent: 42
        x-codex-primary-window-minutes: 60
        x-codex-plan-type: pro
        """
        let snap = RateLimitSnapshot.parseRateLimits(headerDump: dump)
        XCTAssertNotNil(snap)
        XCTAssertNil(snap?.planType,
                     "header-derived snapshot must never carry plan_type")
        XCTAssertEqual(snap?.primary?.usedPercent, 42)
    }

    /// A lone plan_type header (no primary/secondary/credits/limit-name) must
    /// NOT keep a snapshot alive — plan_type is removed from the has_data gate.
    func testLonePlanTypeHeaderDoesNotCreateSnapshot() {
        let dump = "x-codex-plan-type: pro\n"
        let snap = RateLimitSnapshot.parseRateLimits(headerDump: dump)
        XCTAssertNil(snap,
                     "a bare plan_type header must not yield a snapshot")
    }

    // MARK: RateLimitSnapshot → notification JSON (finding 1)

    /// The `account/rateLimits/updated` payload mirrors the v2
    /// `RateLimitSnapshot` (camelCase, every field present, used_percent
    /// rounded to an int, `rateLimitReachedType` null for header snapshots).
    func testSnapshotNotificationJSONShape() {
        let snap = RateLimitSnapshot(
            limitId: "codex",
            limitName: "Codex",
            primary: RateLimitWindow(usedPercent: 42.6, windowMinutes: 60,
                                     resetAt: 1_700_000_000),
            secondary: nil,
            credits: CreditsSnapshot(hasCredits: true, unlimited: false,
                                     balance: "5"),
            planType: nil)
        guard case .object(let obj) = snap.asNotificationJSON() else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj["limitId"], .string("codex"))
        XCTAssertEqual(obj["limitName"], .string("Codex"))
        XCTAssertEqual(obj["secondary"], .null)
        XCTAssertEqual(obj["planType"], .null)
        XCTAssertEqual(obj["rateLimitReachedType"], .null)
        guard case .object(let primary)? = obj["primary"] else {
            return XCTFail("primary window missing")
        }
        XCTAssertEqual(primary["usedPercent"], .int(43),
                       "used_percent rounds to an integer (account.rs:347)")
        XCTAssertEqual(primary["windowDurationMins"], .int(60))
        XCTAssertEqual(primary["resetsAt"], .int(1_700_000_000))
        guard case .object(let credits)? = obj["credits"] else {
            return XCTFail("credits missing")
        }
        XCTAssertEqual(credits["hasCredits"], .bool(true))
        XCTAssertEqual(credits["unlimited"], .bool(false))
        XCTAssertEqual(credits["balance"], .string("5"))
    }
}

extension ModelClientAuditV9Tests {
    func testParseAllRateLimitsFromCRLFDump() {
        // CRLF dump — exactly the line ending real HTTP header dumps use. A
        // `\r\n` is a single Swift grapheme, so the parser must split on scalars
        // (regression guard for the headerMap CRLF fix).
        let dump = "x-codex-primary-used-percent: 37\r\nx-codex-primary-window-minutes: 60\r\nContent-Type: text/event-stream\r\n"
        let snaps = RateLimitSnapshot.parseAllRateLimits(headerDump: dump)
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps.first?.limitId, "codex")
        XCTAssertEqual(snaps.first?.primary?.usedPercent, 37)
    }
}
