import XCTest
import Foundation
@testable import MemoryMCP
@testable import MemoryStore
@testable import MemoryInfer
@testable import MemoryRetrieve
@testable import MemoryScore
@testable import Tools

final class ToolsTests: XCTestCase {
    func testPersonaStateRoundTrip() async {
        let s = PersonaState()
        let initial = await s.activeName()
        XCTAssertEqual(initial, "cto")
        let ok = await s.setActive("researcher")
        XCTAssertTrue(ok)
        let now = await s.activeName()
        XCTAssertEqual(now, "researcher")
        let bogus = await s.setActive("nonsense")
        XCTAssertFalse(bogus)
    }

    func testHybridSearchToolEndToEnd() async throws {
        let path = NSTemporaryDirectory() + "mcp-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 16))
        let inference = MockInferenceProvider(embeddingDimension: 16)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual, sourceURI: "memo:1",
            bodyPath: "rollout:1", fetchedAt: 0,
            contentSHA: Data(count: 32), rawBytes: 1))
        let target = "swift safe modern actors"
        let emb = try await inference.embed([target], deadline: .fromNow(.seconds(1)))
        _ = try await store.insertChunk(
            ChunkRow(documentId: docId, idx: 0, text: target, rawText: target,
                     tokenCount: 4, createdAt: 0),
            embeddingValues: emb[0].values)
        let retriever = MemoryRetriever(store: store, inference: inference)
        let personas = PersonaState()
        let tool = HybridSearchTool(retriever: retriever, personas: personas)
        let call = ToolCall(callId: "1", name: tool.name,
                            argumentsJSON: #"{"query":"swift actors","k":3}"#)
        let result = try await tool.run(call, cwd: "/")
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("chunk_id"))
    }

    func testSetAndLensPersonaTools() async throws {
        let personas = PersonaState()
        let setTool = SetPersonaTool(personas: personas)
        let set = try await setTool.run(
            ToolCall(callId: "1", name: setTool.name,
                     argumentsJSON: #"{"persona":"researcher"}"#), cwd: "/")
        XCTAssertTrue(set.success)
        let lens = PersonaLensTool(personas: personas)
        let lensResult = try await lens.run(
            ToolCall(callId: "2", name: lens.name, argumentsJSON: "{}"), cwd: "/")
        XCTAssertTrue(lensResult.output.contains("researcher"))
    }
}
