import XCTest
import Foundation
@testable import MemoryStore
@testable import MemoryInfer
@testable import MemoryIngest
@testable import MemoryProcess
@testable import MemoryRetrieve
@testable import MemoryMCP
@testable import MemoryScore
@testable import Tools

final class EndToEndTests: XCTestCase {
    func testIngestProcessRetrieveAndMCPRoundTrip() async throws {
        let path = NSTemporaryDirectory() + "e2e-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 16))
        let inference = MockInferenceProvider(embeddingDimension: 16)
        let processor = MemoryProcessor(store: store, inference: inference)

        // 1. Drive a synthetic document through the processor.
        let doc = IngestedDocument(
            sourceName: "memo", sourceKind: .manual, sourceURI: "memo://swift",
            title: "Swift Memo", publishedAt: nil, fetchedAt: 0,
            canonicalText: "Apple released Swift. Apple uses Swift in macOS.",
            rawBytes: 64, contentSHA: Data(count: 32))
        let report = try await processor.process(doc)
        XCTAssertGreaterThan(report.chunksWritten, 0)

        // 2. Retrieve via hybrid search.
        let retriever = MemoryRetriever(store: store, inference: inference)
        let hits = try await retriever.search("apple swift", k: 5, rerank: true)
        XCTAssertFalse(hits.isEmpty)

        // 3. Drive the MCP tool surface.
        let personas = PersonaState()
        let gate = BrainGate(store: store, caller: { _, _, _ in
            throw InferenceError.providerUnavailable("no escalation endpoint")
        })
        let toolset = MemoryToolset(store: store, retriever: retriever,
                                    inference: inference, personas: personas,
                                    gate: gate)
        let tools = toolset.tools()
        XCTAssertEqual(tools.count, 11)
        let names = tools.map(\.name).sorted()
        XCTAssertEqual(names, [
            "memory_ask_local_brain",
            "memory_escalate_to_brain",
            "memory_graph_walk",
            "memory_hybrid_search",
            "memory_persona_lens",
            "memory_recent_interesting",
            "memory_set_persona",
            "wiki_angle",
            "wiki_brief",
            "wiki_compare",
            "wiki_pmfit",
        ])
        // The escalation tool should refuse without an endpoint.
        let escalate = tools.first(where: { $0.name == "memory_escalate_to_brain" })!
        let result = try await escalate.run(
            ToolCall(callId: "1", name: escalate.name,
                     argumentsJSON: #"{"question":"x","reason":"y"}"#),
            cwd: "/")
        XCTAssertFalse(result.success)
    }
}
