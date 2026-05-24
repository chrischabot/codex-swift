import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import InfraPrimitives

final class RequestUserInputTests: XCTestCase {

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "rui-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testRequestUserInputToolRegistered() async {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                    writableRoots: [root]))
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router, sandbox: sandbox)
        let names = await router.specs().map { $0.name }
        XCTAssertTrue(names.contains("request_user_input"),
                      "DefaultTools must register request_user_input (P3.4 / H-18); got \(names)")
    }

    func testRequestUserInputSchemaMatchesUpstream() {
        let tool = RequestUserInputTool()
        XCTAssertEqual(tool.name, "request_user_input")
        guard let d = tool.jsonSchema.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return XCTFail("schema is not valid JSON: \(tool.jsonSchema)")
        }
        XCTAssertEqual(obj["type"] as? String, "object")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertEqual(obj["required"] as? [String], ["questions"])
        let props = obj["properties"] as? [String: Any] ?? [:]
        guard let qs = props["questions"] as? [String: Any] else {
            return XCTFail("missing questions property")
        }
        XCTAssertEqual(qs["type"] as? String, "array")
        guard let item = qs["items"] as? [String: Any] else {
            return XCTFail("missing items")
        }
        XCTAssertEqual(item["type"] as? String, "object")
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        let req = Set(item["required"] as? [String] ?? [])
        // Upstream requires id, header, question, options on each question.
        XCTAssertEqual(req, Set(["id", "header", "question", "options"]))
        let itemProps = item["properties"] as? [String: Any] ?? [:]
        guard let opts = itemProps["options"] as? [String: Any] else {
            return XCTFail("missing options on item")
        }
        XCTAssertEqual(opts["type"] as? String, "array")
        guard let optItem = opts["items"] as? [String: Any] else {
            return XCTFail("missing options.items")
        }
        let optReq = Set(optItem["required"] as? [String] ?? [])
        XCTAssertEqual(optReq, Set(["label", "description"]),
                       "upstream option requires {label, description}")
    }

    func testRequestUserInputResultShape() async throws {
        let tool = RequestUserInputTool()
        let callId = "rui-1"
        // Host subscribes and immediately responds with the canonical
        // RequestUserInputResponse shape.
        await RequestUserInputBus.shared.subscribe(callId: callId) { questionsJSON in
            XCTAssertTrue(questionsJSON.contains("\"db_password\""), "expected our question id in payload")
            Task {
                let reply = #"{"answers":{"db_password":{"answers":["hunter2"]}}}"#
                await RequestUserInputBus.shared.respond(callId: callId, replyJSON: reply)
            }
        }
        defer { Task { await RequestUserInputBus.shared.unsubscribe(callId: callId) } }

        let args = #"""
        {"questions":[{"id":"db_password","header":"DB pwd","question":"What is the database password?","options":[{"label":"Use stored","description":"Use the password from the keychain."},{"label":"Skip","description":"Run without DB access."}]}]}
        """#
        let r = try await tool.run(
            ToolCall(callId: callId, name: "request_user_input", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertTrue(r.success, r.output)
        // Result is the host's reply JSON, matching upstream
        // RequestUserInputResponse: {answers: {<id>: {answers:[...]}}}.
        guard let d = r.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let answers = obj["answers"] as? [String: Any] else {
            return XCTFail("result is not RequestUserInputResponse JSON: \(r.output)")
        }
        XCTAssertNotNil(answers["db_password"], "answer keyed by question id")
    }

    func testRequestUserInputRejectsEmptyQuestions() async throws {
        let tool = RequestUserInputTool()
        let r = try await tool.run(
            ToolCall(callId: "x", name: "request_user_input",
                     argumentsJSON: #"{"questions":[]}"#),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("at least one question"),
                      "got: \(r.output)")
    }

    func testRequestUserInputRejectsTooManyQuestions() async throws {
        let tool = RequestUserInputTool()
        let q = #"{"id":"a","header":"h","question":"q","options":[{"label":"l","description":"d"}]}"#
        let args = "{\"questions\":[\(q),\(q),\(q),\(q)]}"
        let r = try await tool.run(
            ToolCall(callId: "x", name: "request_user_input", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("at most three questions"),
                      "got: \(r.output)")
    }

    func testRequestUserInputRejectsMissingOptions() async throws {
        let tool = RequestUserInputTool()
        let args = #"{"questions":[{"id":"a","header":"h","question":"q","options":[]}]}"#
        let r = try await tool.run(
            ToolCall(callId: "x", name: "request_user_input", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("non-empty options"),
                      "got: \(r.output)")
    }

    func testRequestUserInputFailsFastWithoutChannel() async throws {
        let tool = RequestUserInputTool()
        // No subscriber. The tool must NOT block the turn forever.
        let args = #"{"questions":[{"id":"a","header":"h","question":"q","options":[{"label":"l","description":"d"}]}]}"#
        let r = try await tool.run(
            ToolCall(callId: "x-no-channel", name: "request_user_input", argumentsJSON: args),
            cwd: "/tmp")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("no user-input channel"),
                      "got: \(r.output)")
    }
}
