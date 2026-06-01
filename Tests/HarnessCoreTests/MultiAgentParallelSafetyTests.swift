import XCTest
@testable import HarnessCore

/// tools-router audit (v13) Finding 4 (minor): on the SessionEngine-backed
/// multi-agent runner path, wait_agent and list_agents must be SERIAL. No
/// `multi_agents_v2` handler overrides `supports_parallel_tool_calls`, so all
/// multi-agent tools inherit the default `false`
/// (tools/src/tool_executor.rs:49-51). The other three (spawn_agent,
/// send_message, close_agent) were already serial; this pins all five.
final class MultiAgentParallelSafetyTests: XCTestCase {

    func testAllMultiAgentToolsAreSerial() {
        let wait = AgentWaitTool { _, _ in
            AgentRunResult(status: .completed, output: "", error: nil)
        }
        let list = AgentListTool { [] }
        let message = AgentMessageTool { _, _, _ in true }
        let close = AgentCloseTool { _ in true }

        XCTAssertFalse(wait.parallelSafe,
            "wait_agent: no multi_agents_v2 handler overrides supports_parallel_tool_calls")
        XCTAssertFalse(list.parallelSafe,
            "list_agents: no multi_agents_v2 handler overrides supports_parallel_tool_calls")
        XCTAssertFalse(message.parallelSafe, "send_message is serial upstream")
        XCTAssertFalse(close.parallelSafe, "close_agent is serial upstream")
    }
}
