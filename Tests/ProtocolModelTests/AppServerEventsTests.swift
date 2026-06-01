import XCTest
import Foundation
@testable import ProtocolModel
@testable import WireProtocol

/// Audit unit "app-server-events": wire-fidelity tests for the v9 findings that
/// have observable wire shape (CommandExecution null-emit, fileChange/collab
/// ThreadItem variants, model/rerouted reason enum, typed mcpServer/model
/// notifications).
final class AppServerEventsTests: XCTestCase {

    private func encodeObject<T: Encodable>(_ v: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(v)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: finding 2 — CommandExecution null-able fields emit explicit null

    /// Upstream `CommandExecution` declares process_id/aggregated_output/exit_code/
    /// duration_ms as Option with NO skip_serializing_if (v2/item.rs:248-270), so
    /// item/started serializes all four keys as explicit `null` (item_builders.rs:88-105).
    func testCommandExecutionEmitsExplicitNullForOptionalFields() throws {
        let item: ThreadItem = .commandExecution(
            id: ItemId("cmd_1"), command: ["echo hi"], cwd: "/tmp", status: .inProgress,
            commandActions: [], aggregatedOutput: nil, exitCode: nil,
            processId: nil, source: .agent, durationMs: nil)
        let obj = try encodeObject(item)
        for key in ["processId", "aggregatedOutput", "exitCode", "durationMs"] {
            XCTAssertTrue(obj.keys.contains(key),
                          "\(key) must be present (no skip_serializing_if upstream)")
            XCTAssertTrue(obj[key] is NSNull,
                          "\(key) must serialize as explicit JSON null when nil")
        }
        // Round-trips back to the same value.
        let back = try JSONDecoder().decode(
            ThreadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)
    }

    func testCommandExecutionEncodesPresentOptionalValues() throws {
        let item: ThreadItem = .commandExecution(
            id: ItemId("cmd_2"), command: ["ls"], cwd: "/tmp", status: .completed,
            commandActions: [], aggregatedOutput: "out", exitCode: 0,
            processId: "pid-9", source: .agent, durationMs: 42)
        let obj = try encodeObject(item)
        XCTAssertEqual(obj["aggregatedOutput"] as? String, "out")
        XCTAssertEqual(obj["exitCode"] as? Int, 0)
        XCTAssertEqual(obj["processId"] as? String, "pid-9")
        XCTAssertEqual(obj["durationMs"] as? Int, 42)
    }

    // MARK: finding 3 — fileChange ThreadItem + AppliedPatchDelta projection

    func testFileChangeItemWireShape() throws {
        let item: ThreadItem = .fileChange(
            id: ItemId("fc_1"),
            changes: [
                ThreadItem.FileChange(path: "a.txt", kind: .add, diff: "+hi\n"),
                ThreadItem.FileChange(path: "b.txt",
                                      kind: .update(movePath: "c.txt"),
                                      diff: "--- b\n+++ c\n"),
            ],
            status: .completed)
        let obj = try encodeObject(item)
        XCTAssertEqual(obj["type"] as? String, "fileChange")
        let changes = try XCTUnwrap(obj["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 2)
        let kind0 = try XCTUnwrap(changes[0]["kind"] as? [String: Any])
        XCTAssertEqual(kind0["type"] as? String, "add")
        let kind1 = try XCTUnwrap(changes[1]["kind"] as? [String: Any])
        XCTAssertEqual(kind1["type"] as? String, "update")
        // Wire key is snake_case `move_path` (serde struct-variant field is
        // NOT renamed by the enum-level `rename_all = "camelCase"`).
        XCTAssertEqual(kind1["move_path"] as? String, "c.txt")
        XCTAssertNil(kind1["movePath"])
        let back = try JSONDecoder().decode(
            ThreadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)
    }

    // MARK: finding 8 — model/rerouted reason is the constrained enum

    func testModelRerouteReasonSerializesAsCamelCaseString() throws {
        let data = try JSONEncoder().encode(ModelRerouteReason.highRiskCyberActivity)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"highRiskCyberActivity\"")
    }

    func testModelReroutedNotificationCarriesEnumReason() throws {
        let n = ServerNotification.modelRerouted(
            threadId: ThreadId("thr_1"), turnId: TurnId("turn_1"),
            from: "gpt-5", to: "gpt-5-cyber",
            reason: .highRiskCyberActivity)
        XCTAssertEqual(n.method, "model/rerouted")
        let msg = n.toMessage()
        guard case .notification(let note) = msg else { return XCTFail("expected notification") }
        let params = try XCTUnwrap(note.params?.objectValue)
        XCTAssertEqual(params["reason"], .string("highRiskCyberActivity"))
        XCTAssertEqual(params["fromModel"], .string("gpt-5"))
        XCTAssertEqual(params["toModel"], .string("gpt-5-cyber"))
    }

    // MARK: finding 9 — typed mcpServer/model notifications

    func testMcpServerStatusUpdatedMethodAndPayload() throws {
        let n = ServerNotification.mcpServerStatusUpdated(
            name: "fs", status: .ready, error: nil)
        XCTAssertEqual(n.method, "mcpServer/startupStatus/updated")
        guard case .notification(let note) = n.toMessage() else { return XCTFail("notification") }
        let params = try XCTUnwrap(note.params?.objectValue)
        XCTAssertEqual(params["name"], .string("fs"))
        XCTAssertEqual(params["status"], .string("ready"))
        // Upstream `McpServerStatusUpdatedNotification.error: Option<String>`
        // has NO `skip_serializing_if`, so serde emits `error: null` when nil.
        XCTAssertEqual(params["error"], .null, "error must be explicit null when nil")

        let withErr = ServerNotification.mcpServerStatusUpdated(
            name: "fs", status: .failed, error: "boom")
        guard case .notification(let note2) = withErr.toMessage() else { return XCTFail() }
        let p2 = try XCTUnwrap(note2.params?.objectValue)
        XCTAssertEqual(p2["error"], .string("boom"))
        XCTAssertEqual(p2["status"], .string("failed"))
    }

    func testModelVerificationMethodAndPayload() throws {
        let n = ServerNotification.modelVerification(
            threadId: ThreadId("thr_1"), turnId: TurnId("turn_1"),
            verifications: [.trustedAccessForCyber])
        XCTAssertEqual(n.method, "model/verification")
        guard case .notification(let note) = n.toMessage() else { return XCTFail() }
        let params = try XCTUnwrap(note.params?.objectValue)
        XCTAssertEqual(params["threadId"], .string("thr_1"))
        XCTAssertEqual(params["turnId"], .string("turn_1"))
        XCTAssertEqual(params["verifications"], .array([.string("trustedAccessForCyber")]))
    }

    func testModelVerificationStreamTokenMapping() throws {
        // The model stream emits the upstream core snake_case vocabulary
        // (`trusted_access_for_cyber`, codex-api responses.rs parse_model_verification);
        // the v2 enum rawValue is the camelCase notification wire form.
        XCTAssertEqual(ModelVerification(streamToken: "trusted_access_for_cyber"),
                       .trustedAccessForCyber)
        // Tolerate the camelCase form too (idempotent if already mapped).
        XCTAssertEqual(ModelVerification(streamToken: "trustedAccessForCyber"),
                       .trustedAccessForCyber)
        // Unknown tokens are dropped, matching upstream which keeps only known variants.
        XCTAssertNil(ModelVerification(streamToken: "unknown"))
        // A compactMap over a mixed stream list keeps only the known token,
        // mirroring the SessionEngine emit path.
        let mapped = ["trusted_access_for_cyber", "unknown"]
            .compactMap { ModelVerification(streamToken: $0) }
        XCTAssertEqual(mapped, [.trustedAccessForCyber])
    }

    // MARK: finding 4 — collabAgentToolCall ThreadItem round-trips

    func testCollabAgentToolCallWireShapeAndRoundTrip() throws {
        let item: ThreadItem = .collabAgentToolCall(
            id: ItemId("collab_1"), tool: .spawnAgent, status: .inProgress,
            senderThreadId: "thr_sender",
            receiverThreadIds: ["thr_child"],
            prompt: "do the thing", model: "gpt-5",
            reasoningEffort: .high,
            agentsStates: ["thr_child": ThreadItem.CollabAgentState(
                status: .running, message: nil)])
        let obj = try encodeObject(item)
        XCTAssertEqual(obj["type"] as? String, "collabAgentToolCall")
        XCTAssertEqual(obj["tool"] as? String, "spawnAgent")
        XCTAssertEqual(obj["status"] as? String, "inProgress")
        XCTAssertEqual(obj["senderThreadId"] as? String, "thr_sender")
        XCTAssertEqual(obj["receiverThreadIds"] as? [String], ["thr_child"])
        XCTAssertEqual(obj["reasoningEffort"] as? String, "high")
        let states = try XCTUnwrap(obj["agentsStates"] as? [String: Any])
        let child = try XCTUnwrap(states["thr_child"] as? [String: Any])
        XCTAssertEqual(child["status"] as? String, "running")
        XCTAssertTrue(child["message"] is NSNull,
                      "CollabAgentState.message has no skip_serializing_if → explicit null")
        let back = try JSONDecoder().decode(
            ThreadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)
    }

    func testCollabAgentToolCallEmitsNullForAbsentOptionals() throws {
        let item: ThreadItem = .collabAgentToolCall(
            id: ItemId("collab_2"), tool: .wait, status: .completed,
            senderThreadId: "thr_sender", receiverThreadIds: [],
            prompt: nil, model: nil, reasoningEffort: nil, agentsStates: [:])
        let obj = try encodeObject(item)
        for key in ["prompt", "model", "reasoningEffort"] {
            XCTAssertTrue(obj.keys.contains(key) && obj[key] is NSNull,
                          "\(key) must serialize as explicit null when nil")
        }
    }
}
