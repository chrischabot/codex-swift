import XCTest
import Foundation
@testable import MemoryMCP
@testable import MemoryStore
@testable import MemoryInfer
@testable import MemoryRetrieve
@testable import Tools

/// Regression coverage for Fix #2: the MCP graph_walk tool must clamp the
/// depth argument so a hostile client can't crash the daemon by sending
/// `{"depth": 0}` or other out-of-range values.
final class MCPRegressionFixesTests: XCTestCase {
    private func tmpDB() -> String {
        NSTemporaryDirectory() + "mcp-fix-\(UUID().uuidString).db"
    }

    func testGraphWalkClampsBadDepth() async throws {
        let path = tmpDB(); defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 4))
        _ = try await store.upsertEntity(EntityRow(
            kind: .person, canonical: "Alice", firstSeen: 0, lastSeen: 0))
        let tool = GraphWalkTool(store: store)
        let call = ToolCall(callId: "1", name: tool.name,
                            argumentsJSON: #"{"seed":"Alice","depth":0}"#)
        // Must not throw or trap — depth 0 is clamped to 1.
        let result = try await tool.run(call, cwd: "/")
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("nodes"))
    }
}
