import XCTest
import Foundation
@testable import ModelClient

/// Coverage for the Responses-stream signals ported from upstream
/// `codex-api/src/sse/responses.rs`: reasoning-item replay wire shape, the
/// header-dump / per-event server-model resolution, models-etag /
/// reasoning-included header constants, and model-verification parsing.
final class ResponsesStreamSignalsTests: XCTestCase {

    // MARK: Finding 1 — reasoning item round-trips into the input array.

    func testReasoningPromptInputSerializesUpstreamShape() {
        let prompt = Prompt(
            instructions: "i",
            input: [.reasoning(summary: ["thought A", "thought B"],
                               content: ["chain step 1"],
                               encryptedContent: "ENC123")])
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        guard let input = body["input"] as? [[String: Any]],
              let item = input.first(where: { ($0["type"] as? String) == "reasoning" })
        else { return XCTFail("reasoning input item missing") }

        XCTAssertEqual(item["encrypted_content"] as? String, "ENC123")
        // `id` is never serialized (upstream #[serde(skip_serializing)]).
        XCTAssertNil(item["id"])
        let summary = item["summary"] as? [[String: Any]] ?? []
        XCTAssertEqual(summary.map { $0["type"] as? String }, ["summary_text", "summary_text"])
        XCTAssertEqual(summary.map { $0["text"] as? String }, ["thought A", "thought B"])
        let content = item["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content.first?["type"] as? String, "reasoning_text")
        XCTAssertEqual(content.first?["text"] as? String, "chain step 1")
    }

    func testReasoningPromptInputOmitsContentWhenEmptyAndNullsEncrypted() {
        let prompt = Prompt(
            instructions: "i",
            input: [.reasoning(summary: ["s"], content: [], encryptedContent: nil)])
        let body = OpenAIResponsesClient.buildRequestBody(
            prompt, ModelSettings(model: "gpt", threadId: "t"),
            maxOutputTokens: nil)
        let input = body["input"] as? [[String: Any]] ?? []
        let item = input.first { ($0["type"] as? String) == "reasoning" }
        XCTAssertNotNil(item)
        // No reasoning-text parts → `content` is omitted entirely.
        XCTAssertNil(item?["content"], "empty content must be omitted")
        // `encrypted_content` is always emitted, as null when absent.
        XCTAssertTrue(item?["encrypted_content"] is NSNull)
    }

    func testParseReasoningItemFlattensSummaryContentAndEncrypted() {
        let item: [String: Any] = [
            "type": "reasoning",
            "id": "r1",
            "summary": [["type": "summary_text", "text": "sum"]],
            "content": [["type": "reasoning_text", "text": "cot"]],
            "encrypted_content": "E",
        ]
        let r = ResponsesStreamParsing.parseReasoningItem(item)
        XCTAssertEqual(r.id, "r1")
        XCTAssertEqual(r.summary, ["sum"])
        XCTAssertEqual(r.content, ["cot"])
        XCTAssertEqual(r.encryptedContent, "E")
    }

    // MARK: Finding 2 — server-model resolution (header dump + per-event).

    func testHeaderDumpParsesCaseAndWhitespace() {
        let dump = "HTTP/2 200\r\nopenai-model: gpt-5-safe\r\nX-Models-Etag:  abc123 \r\n" +
            "x-reasoning-included: 1\r\nx-codex-turn-state: TS-9\r\n\r\n"
        let h = ResponsesStreamParsing.parseHeaderDump(dump)
        XCTAssertEqual(h["openai-model"], "gpt-5-safe")
        XCTAssertEqual(h["x-models-etag"], "abc123")
        XCTAssertEqual(h["x-reasoning-included"], "1")
        XCTAssertEqual(h["x-codex-turn-state"], "TS-9")
        // The status line must not pollute the map.
        XCTAssertNil(h["http/2 200"])
    }

    func testServerModelFromResponseHeadersFrame() {
        let frame: [String: Any] = [
            "type": "response.in_progress",
            "response": ["headers": ["openai-model": "gpt-routed"]],
        ]
        XCTAssertEqual(ResponsesStreamParsing.serverModelFromFrame(frame), "gpt-routed")
    }

    func testServerModelFallsBackToTopLevelHeadersAndIsCaseInsensitive() {
        let frame: [String: Any] = ["headers": ["X-OpenAI-Model": "ws-model"]]
        XCTAssertEqual(ResponsesStreamParsing.serverModelFromFrame(frame), "ws-model")
    }

    func testServerModelNilWhenNoHeaderPresent() {
        XCTAssertNil(ResponsesStreamParsing.serverModelFromFrame(
            ["type": "response.output_text.delta", "delta": "x"]))
    }

    // MARK: Finding 4 — model verifications from response.metadata.

    func testModelVerificationsParsedFromMetadataFrameAndDeduped() {
        let frame: [String: Any] = [
            "type": "response.metadata",
            "metadata": [
                "openai_verification_recommendation": [
                    "trusted_access_for_cyber",
                    "trusted_access_for_cyber",
                    "some_unknown_recommendation",
                ],
            ],
        ]
        let verifs = ResponsesStreamParsing.modelVerificationsFromFrame(frame)
        XCTAssertEqual(verifs, ["trusted_access_for_cyber"],
                       "known recommendation kept once; unknown dropped")
    }

    func testModelVerificationsNilOutsideMetadataKindContent() {
        // Helper returns nil when the recommendation array is absent.
        XCTAssertNil(ResponsesStreamParsing.modelVerificationsFromFrame(
            ["type": "response.metadata", "metadata": [:]]))
    }
}
