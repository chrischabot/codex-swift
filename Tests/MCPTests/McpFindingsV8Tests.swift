import XCTest
import Foundation
@testable import MCP
@testable import ProtocolModel
@testable import WireProtocol

/// Targeted unit tests for the v8 MCP audit findings:
///   1. elicitation policy (auto-deny / auto-accept / reject-by-policy)
///   2. image-content pass-through gated on `supportsImageInput`
///   3. client advertises form+url elicitation sub-capabilities
///   4. decline reply omits `content`/`_meta` (no JSON null)
///   5. clientInfo carries title "Codex" + a real version (not "0.1")
final class McpFindingsV8Tests: XCTestCase {

    // MARK: - Finding 1: elicitation policy

    /// A *form* elicitation = no `url`. We give it a non-empty `properties`
    /// schema so it is NOT auto-acceptable.
    private func formElicitation(properties: [String: JSONValue] = ["a": .object([:])])
        -> JSONValue {
        .object([
            "message": .string("Pick a value"),
            "requestedSchema": .object(["properties": .object(properties)]),
        ])
    }

    /// A schemaless confirm/approval form elicitation (empty properties).
    private func confirmElicitation() -> JSONValue {
        .object([
            "message": .string("Proceed?"),
            "requestedSchema": .object(["properties": .object([:])]),
        ])
    }

    private func urlElicitation() -> JSONValue {
        .object([
            "message": .string("Authorize"),
            "url": .string("https://example.com/oauth"),
        ])
    }

    func testNeverAlwaysDeclines() {
        // Never + a real form → decline (rejected by policy).
        let d = McpElicitationPolicy.decide(approvalPolicy: .never,
                                            autoDeny: false,
                                            autoApproved: false,
                                            params: formElicitation())
        XCTAssertEqual(d, .decline)
    }

    func testNeverAutoApprovedAutoAcceptsConfirm() {
        // Never + auto-approved (full-disk-write profile) + schemaless form
        // → auto-accept with empty content.
        let d = McpElicitationPolicy.decide(approvalPolicy: .never,
                                            autoDeny: false,
                                            autoApproved: true,
                                            params: confirmElicitation())
        XCTAssertEqual(d, .accept)
    }

    func testNeverAutoApprovedUrlNotAutoAccepted() {
        // URL elicitations are never auto-accepted; Never then declines.
        let d = McpElicitationPolicy.decide(approvalPolicy: .never,
                                            autoDeny: false,
                                            autoApproved: true,
                                            params: urlElicitation())
        XCTAssertEqual(d, .decline)
    }

    func testNeverAutoApprovedFormWithPropsDeclines() {
        // Auto-approved but the form has required properties → not
        // auto-acceptable, so Never declines.
        let d = McpElicitationPolicy.decide(approvalPolicy: .never,
                                            autoDeny: false,
                                            autoApproved: true,
                                            params: formElicitation())
        XCTAssertEqual(d, .decline)
    }

    func testAutoDenyWinsUnconditionally() {
        // auto_deny short-circuits even an otherwise auto-acceptable confirm.
        let d = McpElicitationPolicy.decide(approvalPolicy: .never,
                                            autoDeny: true,
                                            autoApproved: true,
                                            params: confirmElicitation())
        XCTAssertEqual(d, .decline)
    }

    func testOnRequestPrompts() {
        // on-request is not rejected-by-policy → surface to the frontend.
        let d = McpElicitationPolicy.decide(approvalPolicy: .onRequest,
                                            autoDeny: false,
                                            autoApproved: false,
                                            params: formElicitation())
        XCTAssertEqual(d, .prompt)
    }

    func testOnFailureAndUnlessTrustedPrompt() {
        for policy in [ApprovalPolicy.onFailure, .unlessTrusted] {
            let d = McpElicitationPolicy.decide(approvalPolicy: policy,
                                                autoDeny: false,
                                                autoApproved: false,
                                                params: formElicitation())
            XCTAssertEqual(d, .prompt, "\(policy) should prompt")
        }
    }

    func testGranularAllowsElicitationsPrompts() {
        let cfg = GranularApprovalConfig(sandboxApproval: true, rules: true,
                                         mcpElicitations: true)
        let d = McpElicitationPolicy.decide(approvalPolicy: .granular(cfg),
                                            autoDeny: false,
                                            autoApproved: false,
                                            params: formElicitation())
        XCTAssertEqual(d, .prompt)
    }

    func testGranularDisallowsElicitationsDeclines() {
        let cfg = GranularApprovalConfig(sandboxApproval: true, rules: true,
                                         mcpElicitations: false)
        let d = McpElicitationPolicy.decide(approvalPolicy: .granular(cfg),
                                            autoDeny: false,
                                            autoApproved: false,
                                            params: formElicitation())
        XCTAssertEqual(d, .decline)
    }

    func testRejectedByPolicyMatrix() {
        XCTAssertTrue(McpElicitationPolicy.isRejectedByPolicy(.never))
        XCTAssertFalse(McpElicitationPolicy.isRejectedByPolicy(.onFailure))
        XCTAssertFalse(McpElicitationPolicy.isRejectedByPolicy(.onRequest))
        XCTAssertFalse(McpElicitationPolicy.isRejectedByPolicy(.unlessTrusted))
        let off = GranularApprovalConfig(sandboxApproval: true, rules: true,
                                         mcpElicitations: false)
        XCTAssertTrue(McpElicitationPolicy.isRejectedByPolicy(.granular(off)))
        let on = GranularApprovalConfig(sandboxApproval: true, rules: true,
                                        mcpElicitations: true)
        XCTAssertFalse(McpElicitationPolicy.isRejectedByPolicy(.granular(on)))
    }

    func testCanAutoAcceptClassification() {
        XCTAssertTrue(McpElicitationPolicy.canAutoAccept(params: confirmElicitation()))
        XCTAssertFalse(McpElicitationPolicy.canAutoAccept(params: formElicitation()))
        XCTAssertFalse(McpElicitationPolicy.canAutoAccept(params: urlElicitation()))
        // No schema at all → treated as schemaless form, auto-acceptable.
        XCTAssertTrue(McpElicitationPolicy.canAutoAccept(
            params: .object(["message": .string("ok")])))
    }

    // MARK: - Finding 2: image content gated on supportsImageInput

    private func imageResult() -> [String: JSONLite] {
        [
            "content": .array([
                .object(["type": .string("image"),
                         "data": .string("base64..."),
                         "mimeType": .string("image/png")]),
                .object(["type": .string("text"), "text": .string(" caption")]),
            ]),
        ]
    }

    func testImageStrippedWhenModelLacksImageInput() {
        let result = McpResultDecoder.decode(imageResult(), supportsImageInput: false)
        XCTAssertEqual(result.content.count, 2)
        if case .object(let o)? = result.content.first {
            XCTAssertEqual(o["type"], .string("text"))
            XCTAssertEqual(o["text"], .string(McpResultDecoder.imageOmittedPlaceholder))
        } else {
            XCTFail("first block should be a placeholder text block")
        }
        XCTAssertTrue(result.text.contains(McpResultDecoder.imageOmittedPlaceholder))
    }

    func testImagePreservedWhenModelSupportsImageInput() {
        let result = McpResultDecoder.decode(imageResult(), supportsImageInput: true)
        XCTAssertEqual(result.content.count, 2)
        // The image block is preserved verbatim.
        if case .object(let o)? = result.content.first {
            XCTAssertEqual(o["type"], .string("image"))
            XCTAssertEqual(o["data"], .string("base64..."))
            XCTAssertEqual(o["mimeType"], .string("image/png"))
        } else {
            XCTFail("first block should remain an image block")
        }
        // No placeholder text contributed; only the caption text.
        XCTAssertFalse(result.text.contains(McpResultDecoder.imageOmittedPlaceholder))
        XCTAssertEqual(result.text, " caption")
    }

    func testDecodeDefaultStripsImages() {
        // Back-compat: the default (no arg) keeps stripping images.
        let result = McpResultDecoder.decode(imageResult())
        if case .object(let o)? = result.content.first {
            XCTAssertEqual(o["type"], .string("text"))
        } else {
            XCTFail("default decode should strip the image")
        }
    }

    // MARK: - Findings 3 + 5: initialize clientInfo + elicitation capability

    func testClientInfoCarriesTitleAndVersion() {
        let info = McpClientInfo.initializeClientInfo
        XCTAssertEqual(info["name"] as? String, "codex-mcp-client")
        XCTAssertEqual(info["title"] as? String, "Codex")
        // Version must NOT be the old placeholder "0.1".
        XCTAssertNotEqual(info["version"] as? String, "0.1")
        XCTAssertEqual(info["version"] as? String, "0.0.0")
    }

    // v10 finding 2 supersedes the original v8 expectation: upstream advertises
    // `ElicitationCapability::default()` → wire `{}` UNLESS the (default-off)
    // `Feature::AuthElicitation` is enabled. The default is therefore empty.
    func testElicitationCapabilityDefaultIsEmptyObject() {
        let cap = McpClientInfo.elicitationCapability
        XCTAssertTrue(cap.isEmpty,
                      "default elicitation capability must be {} (AuthElicitation off)")
    }

    // When AuthElicitation is enabled the wire shape carries form + url.
    func testElicitationCapabilityWithAuthElicitationAdvertisesFormAndUrl() {
        let cap = McpClientInfo.capability(authElicitationEnabled: true)
        XCTAssertNotNil(cap["form"], "must advertise the form sub-capability")
        XCTAssertNotNil(cap["url"], "must advertise the url sub-capability")
        // Each sub-capability is an empty object on the wire.
        XCTAssertTrue((cap["form"] as? [String: Any])?.isEmpty ?? false)
        XCTAssertTrue((cap["url"] as? [String: Any])?.isEmpty ?? false)
    }
}
