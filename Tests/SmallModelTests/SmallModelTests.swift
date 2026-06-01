import XCTest
import Foundation
@testable import SmallModel
@testable import ModelClient

/// Deterministic tests for the SmallModel utility (Phase 3). MockModelClient
/// only — no network. They prove the JSON-task framing, fence stripping, and
/// decode-or-retry contract (`T: Decodable` is the schema).
final class SmallModelTests: XCTestCase {

    private struct Label: Decodable, Equatable, Sendable {
        let label: String
        let score: Int
    }

    private func service(_ scenarios: [MockScenario]) -> LocalSmallModel {
        LocalSmallModel(model: MockModelClient(scenarios), modelId: "local-small")
    }

    func testJsonDecodesStructuredReply() async throws {
        let svc = service([.hello(#"{"label":"spam","score":3}"#)])
        let r = try await svc.json(SmallTask(prompt: "classify", input: "buy now!!!"), as: Label.self)
        XCTAssertEqual(r, Label(label: "spam", score: 3))
    }

    func testJsonStripsCodeFences() async throws {
        let svc = service([.hello("```json\n{\"label\":\"ok\",\"score\":1}\n```")])
        let r = try await svc.json(SmallTask(prompt: "classify", input: "hi"), as: Label.self)
        XCTAssertEqual(r, Label(label: "ok", score: 1))
    }

    func testJsonRetriesOnceOnUndecodable() async throws {
        // First reply is prose (undecodable) → retry → valid JSON.
        let svc = service([.hello("Sure! Here is the classification."),
                           .hello(#"{"label":"ham","score":0}"#)])
        let r = try await svc.json(SmallTask(prompt: "classify", input: "meeting notes"), as: Label.self)
        XCTAssertEqual(r, Label(label: "ham", score: 0))
    }

    func testJsonThrowsAfterTwoUndecodableReplies() async {
        let svc = service([.hello("nope"), .hello("still not json")])
        do {
            _ = try await svc.json(SmallTask(prompt: "classify"), as: Label.self)
            XCTFail("expected SmallModelError.undecodable")
        } catch let e as SmallModelError {
            guard case .undecodable = e else { return XCTFail("wrong error: \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func testTextPassthrough() async throws {
        let svc = service([.hello("the answer is 42")])
        let r = try await svc.text(SmallTask(prompt: "what is the answer?"))
        XCTAssertEqual(r, "the answer is 42")
    }

    func testStripFencesHelper() {
        XCTAssertEqual(LocalSmallModel.stripFences("```json\n{\"a\":1}\n```"), "{\"a\":1}")
        XCTAssertEqual(LocalSmallModel.stripFences("```\n[1,2]\n```"), "[1,2]")
        XCTAssertEqual(LocalSmallModel.stripFences("  {\"x\":true}  "), "{\"x\":true}")
    }

    // --- review-driven robustness (D1/D2/D4/D5) ---

    func testJsonDecodesValueContainingBackticksUncorrupted() async throws {
        // D1: valid JSON whose string value contains ``` must decode AS-IS
        // (the raw candidate is tried first; never fence-stripped into garbage).
        let svc = service([.hello(#"{"code":"```"}"#)])
        let r = try await svc.json(SmallTask(prompt: "echo"), as: [String: String].self)
        XCTAssertEqual(r, ["code": "```"])
    }

    func testJsonStripsProseWrappedFence() async throws {
        // D2: leading prose + a fenced block must still decode (fenced candidate).
        let svc = service([.hello("Here is the JSON:\n```json\n{\"label\":\"ok\",\"score\":1}\n```")])
        let r = try await svc.json(SmallTask(prompt: "classify"), as: Label.self)
        XCTAssertEqual(r, Label(label: "ok", score: 1))
    }

    func testJsonRescuesBracedSpanFromProse() async throws {
        // No fence, JSON embedded in prose → braced-span candidate rescues it.
        let svc = service([.hello("Sure, the result is {\"label\":\"x\",\"score\":2} — hope that helps!")])
        let r = try await svc.json(SmallTask(prompt: "classify"), as: Label.self)
        XCTAssertEqual(r, Label(label: "x", score: 2))
    }

    func testJsonThrowsEmptyOnEmptyReply() async {
        // D4: an empty reply maps to `.empty` (not `.undecodable("")`).
        let empty = MockScenario([.created, .completeEndTurn(responseId: "r", tokens: 1)])
        let svc = LocalSmallModel(model: MockModelClient([empty, empty]), modelId: "local-small")
        do {
            _ = try await svc.json(SmallTask(prompt: "classify"), as: Label.self)
            XCTFail("expected .empty")
        } catch let e as SmallModelError {
            XCTAssertEqual(e, .empty)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testCollectReturnsDeltasWhenNoAgentDone() async throws {
        // D5: a stream of deltas with NO agentDone still yields the text.
        let svc = service([MockScenario([
            .created,
            .delta(itemId: "m", "the "),
            .delta(itemId: "m", "answer"),
            .completeEndTurn(responseId: "r", tokens: 1)])])
        let r = try await svc.text(SmallTask(prompt: "q"))
        XCTAssertEqual(r, "the answer")
    }

    func testBracedSpanHelper() {
        XCTAssertEqual(LocalSmallModel.bracedSpan("prefix {\"a\":1} suffix"), "{\"a\":1}")
        XCTAssertEqual(LocalSmallModel.bracedSpan("noise [1,2,3] noise"), "[1,2,3]")
        XCTAssertNil(LocalSmallModel.bracedSpan("no json here"))
    }
}
