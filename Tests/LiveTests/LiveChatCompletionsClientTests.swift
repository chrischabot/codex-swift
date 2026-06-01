import XCTest
import Foundation
@testable import SmallModel
@testable import ModelClient

/// Live-LLM E2E for `ChatCompletionsClient` (DEFERRED ITEM 3): the
/// chat-completions `ModelClient` that backs `SmallModel` against an
/// OpenAI-compatible endpoint. Points `baseURL` at `https://api.openai.com`
/// (the canonical OpenAI `/v1/chat/completions` surface) with a real model and
/// asserts `SmallModelService.json` decodes a structured value end-to-end —
/// proving the chat wire shape + SSE→ResponseEvent mapping against a live
/// server, not just canned bytes.
///
/// In production this same client is pointed at a LOCAL endpoint (ollama /
/// lmstudio / llama.cpp); OpenAI's chat-completions endpoint is shape-identical
/// (`messages[]` request, `choices[].delta.content` SSE chunks, `[DONE]`
/// sentinel) so it is the right live proxy for the local target.
///
/// Gated on OPENAI_API_KEY via `lxSkipUnlessLiveKey()`. NOTE: if OpenAI ever
/// retires or changes the `/v1/chat/completions` shape for the configured
/// model, this test (and only this test) must be updated — the deterministic
/// `ChatCompletionsClientTests` (in `Tests/SmallModelTests`) pin the mapping
/// and need no network.
final class LiveChatCompletionsClientTests: XCTestCase {

    private struct Sentiment: Decodable, Sendable { let sentiment: String }

    func testChatCompletionsSmallModelJsonDecodesWithLiveOpenAI() async throws {
        try lxSkipUnlessLiveKey()
        let client = ChatCompletionsClient(
            baseURL: "https://api.openai.com",
            model: lxModel(),
            apiKey: lxAPIKey())
        let svc = LocalSmallModel(model: client, modelId: lxModel())
        let r = try await svc.json(SmallTask(
            prompt: "Classify the sentiment of INPUT as exactly one of: positive, negative, neutral. "
                + "Respond as a JSON object {\"sentiment\": \"...\"}.",
            input: "I absolutely love this — best day ever!"), as: Sentiment.self)
        XCTAssertEqual(r.sentiment.lowercased(), "positive",
                       "the chat-completions client must stream a decodable, correct classification")
    }
}
