import XCTest
import Foundation
@testable import SmallModel
@testable import ModelClient

/// Live-LLM E2E for the Phase 3 SmallModel utility (docs/extensions/ARCHITECTURE
/// .md §7.4). Drives `LocalSmallModel.json` against a real model and asserts it
/// decodes a structured classification — proving the schema (Decodable) →
/// decode-or-retry path end-to-end. Backed here by the live client for
/// verification; in production the same service is pointed at a local endpoint.
/// Skips without OPENAI_API_KEY.
final class LiveSmallModelTests: XCTestCase {

    private struct Sentiment: Decodable, Sendable { let sentiment: String }

    func testSmallModelJsonClassificationWithLiveModel() async throws {
        try lxSkipUnlessLiveKey()
        let svc = LocalSmallModel(model: lxClient(120), modelId: lxModel())
        let r = try await svc.json(SmallTask(
            prompt: "Classify the sentiment of INPUT as exactly one of: positive, negative, neutral. "
                + "Respond as a JSON object {\"sentiment\": \"...\"}.",
            input: "I absolutely love this — best day ever!"), as: Sentiment.self)
        XCTAssertEqual(r.sentiment.lowercased(), "positive",
                       "the small model must return a decodable, correct classification")
    }
}
