import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import InfraPrimitives

final class RequestPermissionsTests: XCTestCase {

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "rp-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Audit tools-router finding 1: upstream pushes the RequestPermissionsHandler
    /// ONLY when `config.request_permissions_tool_enabled` (`spec_plan.rs:402-404`),
    /// which resolves from `Feature::RequestPermissionsTool` — a stable feature OFF
    /// by default (`features/src/tests.rs:129`). So a default-config session does
    /// NOT advertise `request_permissions`; the port must match.
    func testRequestPermissionsToolNotRegisteredByDefault() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [root]))
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router, sandbox: sandbox)
        let names = await router.specs().map { $0.name }
        XCTAssertFalse(names.contains("request_permissions"),
                       "request_permissions must be OFF by default (Feature::RequestPermissionsTool default_enabled==false); got \(names)")
        // Default flag mirrors the upstream feature default.
        XCTAssertFalse(DefaultTools.defaultRequestPermissionsToolEnabled)
    }

    /// When the host opts in (mirroring `request_permissions_tool_enabled == true`)
    /// the tool IS advertised — at upstream slot (6), after request_user_input and
    /// before apply_patch (`spec_plan.rs:402-404`).
    func testRequestPermissionsToolRegisteredWhenEnabled() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [root]))
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router, sandbox: sandbox,
                                    requestPermissionsToolEnabled: true)
        let names = await router.specs().map { $0.name }
        XCTAssertTrue(names.contains("request_permissions"),
                      "request_permissions must be advertised when enabled (P3.4 / H-17); got \(names)")
        guard let rpIdx = names.firstIndex(of: "request_permissions"),
              let ruiIdx = names.firstIndex(of: "request_user_input"),
              let apIdx = names.firstIndex(of: "apply_patch") else {
            return XCTFail("expected request_user_input/request_permissions/apply_patch; got \(names)")
        }
        XCTAssertLessThan(ruiIdx, rpIdx, "request_user_input precedes request_permissions")
        XCTAssertLessThan(rpIdx, apIdx, "request_permissions precedes apply_patch")
    }

    func testRequestPermissionsSchemaMatchesUpstream() {
        let tool = RequestPermissionsTool()
        XCTAssertEqual(tool.name, "request_permissions")
        guard let d = tool.jsonSchema.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return XCTFail("schema is not valid JSON: \(tool.jsonSchema)")
        }
        XCTAssertEqual(obj["type"] as? String, "object")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false,
                       "upstream request_permissions is strict")
        XCTAssertEqual(obj["required"] as? [String], ["permissions"],
                       "only `permissions` is required upstream")
        let props = obj["properties"] as? [String: Any] ?? [:]
        XCTAssertNotNil(props["reason"], "reason is optional but exposed")
        guard let permissions = props["permissions"] as? [String: Any] else {
            return XCTFail("missing permissions property")
        }
        XCTAssertEqual(permissions["type"] as? String, "object")
        XCTAssertEqual(permissions["additionalProperties"] as? Bool, false)
        let permsProps = permissions["properties"] as? [String: Any] ?? [:]
        // Upstream exposes `network` + `file_system` (snake_case key).
        XCTAssertNotNil(permsProps["network"], "network bucket must be exposed")
        XCTAssertNotNil(permsProps["file_system"], "file_system bucket must be exposed (snake_case)")
        // file_system bucket exposes `read` and `write` arrays.
        if let fs = permsProps["file_system"] as? [String: Any],
           let fsProps = fs["properties"] as? [String: Any] {
            XCTAssertNotNil(fsProps["read"])
            XCTAssertNotNil(fsProps["write"])
        } else {
            XCTFail("missing file_system.properties")
        }
        // network bucket exposes `enabled` boolean.
        if let net = permsProps["network"] as? [String: Any],
           let netProps = net["properties"] as? [String: Any],
           let enabled = netProps["enabled"] as? [String: Any] {
            XCTAssertEqual(enabled["type"] as? String, "boolean")
        } else {
            XCTFail("missing network.properties.enabled (boolean)")
        }
    }

    func testRequestPermissionsResultShape() async throws {
        let tool = RequestPermissionsTool()
        let callId = "rp-1"
        // Host subscribes and replies with the canonical
        // RequestPermissionsResponse shape.
        await RequestPermissionsBus.shared.subscribe(callId: callId) { payload in
            XCTAssertTrue(payload.contains("\"network\""),
                          "payload should include the requested network bucket: \(payload)")
            Task {
                let reply = #"{"permissions":{"network":{"enabled":true}},"scope":"turn","strict_auto_review":false}"#
                await RequestPermissionsBus.shared.respond(callId: callId, replyJSON: reply)
            }
        }
        defer { Task { await RequestPermissionsBus.shared.unsubscribe(callId: callId) } }

        let args = #"{"reason":"need to fetch deps","permissions":{"network":{"enabled":true}}}"#
        let r = try await tool.run(
            ToolCall(callId: callId, name: "request_permissions", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertTrue(r.success, r.output)
        guard let d = r.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return XCTFail("result is not RequestPermissionsResponse JSON: \(r.output)")
        }
        XCTAssertNotNil(obj["permissions"], "response must carry granted permissions")
        XCTAssertEqual(obj["scope"] as? String, "turn",
                       "default upstream scope is `turn`")
    }

    func testRequestPermissionsRejectsEmptyProfile() async throws {
        let tool = RequestPermissionsTool()
        // Empty bucket — upstream rejects with
        // "request_permissions requires at least one permission".
        let r = try await tool.run(
            ToolCall(callId: "x", name: "request_permissions",
                     argumentsJSON: #"{"permissions":{}}"#),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("requires at least one permission"),
                      "got: \(r.output)")
    }

    func testRequestPermissionsRejectsEmptyFilesystemLists() async throws {
        let tool = RequestPermissionsTool()
        let r = try await tool.run(
            ToolCall(callId: "x", name: "request_permissions",
                     argumentsJSON: #"{"permissions":{"file_system":{"read":[],"write":[]}}}"#),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("requires at least one permission"),
                      "got: \(r.output)")
    }

    func testRequestPermissionsFailsFastWithoutChannel() async throws {
        let tool = RequestPermissionsTool()
        let args = #"{"permissions":{"network":{"enabled":true}}}"#
        let r = try await tool.run(
            ToolCall(callId: "x-no-channel", name: "request_permissions",
                     argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("no permission channel"),
                      "got: \(r.output)")
    }
}
