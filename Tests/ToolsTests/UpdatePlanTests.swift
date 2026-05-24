import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import InfraPrimitives

final class UpdatePlanTests: XCTestCase {

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "update-plan-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testUpdatePlanToolRegistered() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [root]))
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router, sandbox: sandbox)
        let names = await router.specs().map { $0.name }
        XCTAssertTrue(names.contains("update_plan"),
                      "DefaultTools must register update_plan (P3.4 / H-18); got \(names)")
    }

    func testUpdatePlanSchemaMatchesUpstream() {
        let tool = UpdatePlanTool()
        XCTAssertEqual(tool.name, "update_plan")
        guard let d = tool.jsonSchema.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return XCTFail("schema is not valid JSON: \(tool.jsonSchema)")
        }
        XCTAssertEqual(obj["type"] as? String, "object")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false,
                       "upstream update_plan is strict (additionalProperties=false)")
        XCTAssertEqual(obj["required"] as? [String], ["plan"])
        // Upstream `plan` is an array of objects with required {step, status}.
        let props = obj["properties"] as? [String: Any] ?? [:]
        guard let plan = props["plan"] as? [String: Any] else {
            return XCTFail("missing `plan` property")
        }
        XCTAssertEqual(plan["type"] as? String, "array")
        guard let items = plan["items"] as? [String: Any] else {
            return XCTFail("missing items in plan")
        }
        XCTAssertEqual(items["type"] as? String, "object")
        XCTAssertEqual(items["additionalProperties"] as? Bool, false)
        let itemRequired = items["required"] as? [String] ?? []
        XCTAssertEqual(Set(itemRequired), Set(["step", "status"]))
        let itemProps = items["properties"] as? [String: Any] ?? [:]
        XCTAssertNotNil(itemProps["step"])
        XCTAssertNotNil(itemProps["status"])
        XCTAssertNotNil(props["explanation"], "explanation must be exposed (optional)")
    }

    func testUpdatePlanResultShape() async throws {
        let tool = UpdatePlanTool()
        // Subscribe so we can confirm the bus published the payload.
        let exp = expectation(description: "bus publish")
        let callId = "plan-1"
        await PlanUpdateBus.shared.subscribe(callId: callId) { payload in
            // Payload must be the verbatim arg JSON the tool received.
            XCTAssertTrue(payload.contains("\"plan\""), "payload should contain plan: \(payload)")
            exp.fulfill()
        }
        defer { Task { await PlanUpdateBus.shared.unsubscribe(callId: callId) } }

        let args = #"{"explanation":"do work","plan":[{"step":"draft","status":"in_progress"},{"step":"ship","status":"pending"}]}"#
        let r = try await tool.run(
            ToolCall(callId: callId, name: "update_plan", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertTrue(r.success, r.output)
        XCTAssertEqual(r.output, "Plan updated",
                       "upstream acknowledgement string is exactly `Plan updated`")
        XCTAssertFalse(r.truncated)
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testUpdatePlanRejectsInvalidStatus() async throws {
        let tool = UpdatePlanTool()
        let args = #"{"plan":[{"step":"draft","status":"started"}]}"#
        let r = try await tool.run(
            ToolCall(callId: "x", name: "update_plan", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("invalid update_plan status"),
                      "got: \(r.output)")
    }

    func testUpdatePlanRejectsMultipleInProgress() async throws {
        let tool = UpdatePlanTool()
        let args = #"{"plan":[{"step":"a","status":"in_progress"},{"step":"b","status":"in_progress"}]}"#
        let r = try await tool.run(
            ToolCall(callId: "x", name: "update_plan", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("at most one step can be in_progress"),
                      "got: \(r.output)")
    }

    func testUpdatePlanRejectsMissingPlan() async throws {
        let tool = UpdatePlanTool()
        let r = try await tool.run(
            ToolCall(callId: "x", name: "update_plan", argumentsJSON: "{}"),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("invalid update_plan arguments"),
                      "got: \(r.output)")
    }
}
