import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import InfraPrimitives
@testable import ProtocolModel

/// P3.1: SubagentStart / SubagentStop hooks fire around a thread-spawned
/// subagent's lifecycle (upstream `HookEventName::SubagentStart`/`SubagentStop`),
/// carrying the subagent-specific payload (agent_id / agent_type / turn_id /
/// last_assistant_message / stop_hook_active). The subagent's own engine stays
/// hookless so it does NOT also fire session-start/stop.
final class SubagentHooksTests: XCTestCase {

    func testSubagentSpawnFiresStartAndStopHooksWithPayload() async throws {
        let dir = NSTemporaryDirectory() + "subhook-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let startFile = dir + "/start.json"
        let stopFile = dir + "/stop.json"
        let work = dir + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let store = try ThreadStore(codexHome: dir + "/home", limits: Limits())

        // Each hook command captures its stdin payload to a file.
        let hooks = HookEngine(hooks: [
            HookDefinition(eventName: .subagentStart, command: "cat > \(startFile)"),
            HookDefinition(eventName: .subagentStop, command: "cat > \(stopFile)"),
        ])
        let model = MockModelClient(repeating: .hello("subagent done"), times: 8)
        let runner = SessionEngineAgentRunner.make(
            store: store, limits: Limits(), model: model,
            router: { _ in ToolRouter(limits: Limits()) },
            cwd: work, hooks: hooks,
            parentSessionId: "thr_parent_123", parentTurnId: "turn_77")

        let spec = AgentSpawnSpec(path: AgentPath.root.child("researcher"),
                                  name: "researcher", prompt: "do research",
                                  model: nil, role: "explorer")
        let result = await runner(spec)
        XCTAssertEqual(result.status, .completed, "subagent turn completes")

        func payload(_ path: String) throws -> [String: Any] {
            let d = try Data(contentsOf: URL(fileURLWithPath: path))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        }

        // SubagentStart payload: parent session + the new subagent's identity.
        let start = try payload(startFile)
        XCTAssertEqual(start["hook_event_name"] as? String, "SubagentStart")
        XCTAssertEqual(start["session_id"] as? String, "thr_parent_123")
        XCTAssertEqual(start["turn_id"] as? String, "turn_77")
        XCTAssertEqual(start["agent_type"] as? String, "explorer")
        XCTAssertEqual(start["model"] as? String, "gpt-5.5")
        XCTAssertEqual(start["agent_id"] as? String, "/root/researcher")

        // SubagentStop payload: adds stop_hook_active + last_assistant_message +
        // agent_transcript_path (upstream `SubagentStopCommandInput`).
        let stop = try payload(stopFile)
        XCTAssertEqual(stop["hook_event_name"] as? String, "SubagentStop")
        XCTAssertEqual(stop["agent_type"] as? String, "explorer")
        XCTAssertEqual(stop["agent_id"] as? String, "/root/researcher")
        XCTAssertNotNil(stop["stop_hook_active"], "stop_hook_active present")
        XCTAssertTrue(stop.keys.contains("agent_transcript_path"), "agent_transcript_path present")
        XCTAssertTrue(stop.keys.contains("last_assistant_message"), "last_assistant_message present (nullable)")
    }

    /// The subagent variants round-trip through the event-name vocabulary
    /// (wire / pascalCase / config-key / parse), so hook configs can target them.
    func testSubagentHookEventNameVocabulary() {
        XCTAssertEqual(HookEventName.subagentStart.wire, "subagent-start")
        XCTAssertEqual(HookEventName.subagentStop.wire, "subagent-stop")
        XCTAssertEqual(HookEventName.subagentStart.pascalCase, "SubagentStart")
        XCTAssertEqual(HookEventName.subagentStop.pascalCase, "SubagentStop")
        XCTAssertEqual(HookEventName.subagentStart.configKey, "subagent_start")
        XCTAssertEqual(HookEventName.from(wire: "subagent-stop"), .subagentStop)
        XCTAssertEqual(HookEventName.from(wire: "SubagentStart"), .subagentStart)
        XCTAssertEqual(HookEventName.from(wire: "subagent_stop"), .subagentStop)
    }
}
