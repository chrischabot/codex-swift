import XCTest
import Foundation
import Prompts
@testable import ModelClient

/// Coverage for the v12 model-client audit findings:
///  1. `x-openai-subagent` request header for sub-agent source routing.
///  2. `service_tier` gated on model-catalog support.
///  3. `response.failed` with no error object → verbatim upstream message
///     (covered in `ResponseFailedClassificationTests`).
///  4. empty-string text/reasoning deltas forwarded, not dropped.
final class ModelClientAuditV12Tests: XCTestCase {

    // MARK: Finding 1 — x-openai-subagent request header.

    func testSubagentHeaderEmittedOnWebSocketPlanWhenLabelPresent() throws {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t",
                                     subagentLabel: "review")
        let plan = try WebSocketResponsesClient.buildRequestPlan(
            prompt: Prompt(instructions: "i", input: [.userText("hi")]),
            settings: settings,
            apiKey: "k",
            maxOutputTokens: nil)
        XCTAssertEqual(plan.headers["x-openai-subagent"], "review")
    }

    func testSubagentHeaderOmittedOnWebSocketPlanWhenLabelNil() throws {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t")
        let plan = try WebSocketResponsesClient.buildRequestPlan(
            prompt: Prompt(instructions: "i", input: [.userText("hi")]),
            settings: settings,
            apiKey: "k",
            maxOutputTokens: nil)
        XCTAssertNil(plan.headers["x-openai-subagent"],
                     "a primary (non-sub-agent) turn must not carry the header")
    }

    func testSubagentHeaderOmittedForEmptyLabel() throws {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t",
                                     subagentLabel: "")
        let plan = try WebSocketResponsesClient.buildRequestPlan(
            prompt: Prompt(instructions: "i", input: [.userText("hi")]),
            settings: settings,
            apiKey: "k",
            maxOutputTokens: nil)
        XCTAssertNil(plan.headers["x-openai-subagent"])
    }

    // MARK: x-codex-turn-metadata request header (per-turn metadata).

    func testTurnMetadataHeaderEmittedOnWebSocketPlanWhenPresent() throws {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t",
                                     turnMetadata: #"{"session_id":"s","sandbox":"seatbelt"}"#)
        let plan = try WebSocketResponsesClient.buildRequestPlan(
            prompt: Prompt(instructions: "i", input: [.userText("hi")]),
            settings: settings,
            apiKey: "k",
            maxOutputTokens: nil)
        XCTAssertEqual(plan.headers["x-codex-turn-metadata"],
                       #"{"session_id":"s","sandbox":"seatbelt"}"#)
    }

    func testTurnMetadataHeaderOmittedOnWebSocketPlanWhenNil() throws {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t")
        let plan = try WebSocketResponsesClient.buildRequestPlan(
            prompt: Prompt(instructions: "i", input: [.userText("hi")]),
            settings: settings,
            apiKey: "k",
            maxOutputTokens: nil)
        XCTAssertNil(plan.headers["x-codex-turn-metadata"],
                     "header omitted when no per-turn metadata is present")
    }

    func testSubagentLabelDefaultsNilOnModelSettings() {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t")
        XCTAssertNil(settings.subagentLabel)
    }

    // MARK: Finding 2 — service_tier gated on catalog support.

    func testServiceTierEmittedWhenGateNil() {
        // Legacy behaviour: caller did not resolve a catalog entry → emit as-is.
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t",
                                     serviceTier: "priority")
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]),
            settings, maxOutputTokens: nil)
        XCTAssertEqual(body["service_tier"] as? String, "priority")
    }

    func testServiceTierEmittedWhenGateTrue() {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t",
                                     serviceTier: "priority",
                                     supportsServiceTier: true)
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]),
            settings, maxOutputTokens: nil)
        XCTAssertEqual(body["service_tier"] as? String, "priority")
    }

    func testServiceTierSuppressedWhenGateFalse() {
        // Upstream `service_tier.filter(|t| model_info.supports_service_tier(t))`
        // drops a tier the resolved model does not advertise.
        let settings = ModelSettings(model: "gpt-5.4-mini", threadId: "t",
                                     serviceTier: "priority",
                                     supportsServiceTier: false)
        let body = OpenAIResponsesClient.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]),
            settings, maxOutputTokens: nil)
        XCTAssertNil(body["service_tier"],
                     "an unsupported tier must be dropped before serialization")
    }

    func testRemoteCompactionServiceTierSuppressedWhenGateFalse() {
        let settings = ModelSettings(model: "gpt-5.4-mini", threadId: "t",
                                     serviceTier: "priority",
                                     supportsServiceTier: false)
        let body = RemoteCompaction.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]), settings)
        XCTAssertNil(body["service_tier"])
    }

    func testRemoteCompactionServiceTierEmittedWhenSupported() {
        let settings = ModelSettings(model: "gpt-5.5", threadId: "t",
                                     serviceTier: "priority",
                                     supportsServiceTier: true)
        let body = RemoteCompaction.buildRequestBody(
            Prompt(instructions: "i", input: [.userText("hi")]), settings)
        XCTAssertEqual(body["service_tier"] as? String, "priority")
    }

    // MARK: ModelsCatalog service-tier support mirrors `models.json`.

    func testCatalogSupportsServiceTierMatchesJSON() {
        // gpt-5.5 advertises the `priority` tier; gpt-5.4-mini advertises none.
        guard let gpt55 = ModelsCatalog.entry(for: "gpt-5.5") else {
            return XCTFail("gpt-5.5 missing from bundled catalog")
        }
        XCTAssertTrue(gpt55.supportsServiceTier("priority"))
        XCTAssertFalse(gpt55.supportsServiceTier("flex"))

        if let mini = ModelsCatalog.entry(for: "gpt-5.4-mini") {
            XCTAssertFalse(mini.supportsServiceTier("priority"),
                           "an empty service_tiers list supports no tier")
        }
    }
}
