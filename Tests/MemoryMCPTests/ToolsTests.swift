import XCTest
import Foundation
@testable import MemoryMCP
@testable import MemoryStore
@testable import MemoryInfer
@testable import MemoryRetrieve
@testable import MemoryScore
@testable import Tools
import InfraPrimitives

private actor TrappingInferenceProvider: LocalInferenceProvider {
    nonisolated let embeddingDimension: Int

    init(embeddingDimension: Int) {
        self.embeddingDimension = embeddingDimension
    }

    func extract(_ batch: ChunkBatch, schema: ExtractionSchema,
                 deadline: InfraPrimitives.Deadline) async throws -> ExtractionResult {
        throw InferenceError.providerUnavailable("unexpected extract call")
    }

    func contextualize(_ chunk: Chunk, in document: DocumentDigest,
                       deadline: InfraPrimitives.Deadline) async throws -> String {
        throw InferenceError.providerUnavailable("unexpected contextualize call")
    }

    func embed(_ texts: [String], deadline: InfraPrimitives.Deadline) async throws -> [MemoryInfer.Embedding] {
        throw InferenceError.providerUnavailable("unexpected embed call")
    }

    func rerank(_ query: String, candidates: [String],
                deadline: InfraPrimitives.Deadline) async throws -> [Float] {
        throw InferenceError.providerUnavailable("unexpected rerank call")
    }

    func logprob(_ text: String, given: String?,
                 deadline: InfraPrimitives.Deadline) async throws -> Double {
        throw InferenceError.providerUnavailable("unexpected logprob call")
    }
}

final class ToolsTests: XCTestCase {
    private func seededStore(dim: Int = 16) async throws -> (String, MemoryStore) {
        let path = NSTemporaryDirectory() + "mcp-prod-\(UUID().uuidString).db"
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: dim))
        let inference = MockInferenceProvider(embeddingDimension: dim)
        let docId = try await store.upsertDocument(DocumentRow(
            source: .manual,
            sourceURI: "wiki://source/agent-memory",
            title: "Agent Memory",
            bodyPath: "inline:wiki://source/agent-memory",
            fetchedAt: 0,
            contentSHA: Data(count: 32),
            rawBytes: 100))
        let texts = [
            "agent memory systems need source-backed citations for trustworthy production analysis",
            "developer relations teams evaluate launches by comparing what changed against prior docs and adoption signals",
            "product market fit for coding agents depends on workflow frequency latency privacy and integration depth",
        ]
        let embeddings = try await inference.embed(texts, deadline: .fromNow(.seconds(1)))
        for (idx, text) in texts.enumerated() {
            _ = try await store.insertChunk(
                ChunkRow(documentId: docId, idx: idx,
                         text: text, rawText: text,
                         tokenCount: text.split(separator: " ").count,
                         createdAt: Int64(idx)),
                embeddingValues: embeddings[idx].values)
        }
        return (path, store)
    }

    private func jsonObject(_ output: String) throws -> [String: Any] {
        let data = Data(output.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

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

    func testWikiProductionToolsReturnCitationsAndNoUncitedClaims() async throws {
        let (path, store) = try await seededStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let calls: [(any Tool, String)] = [
            (WikiBriefTool(store: store),
             #"{"topic":"agent memory production analysis","k":5}"#),
            (WikiCompareTool(store: store),
             #"{"subject":"new coding agent memory release","baseline_query":"developer relations launches","k":5}"#),
            (WikiAngleTool(store: store),
             #"{"topic":"agent memory","audience":"devrel","format":"blog","k":5}"#),
            (WikiPMFitTool(store: store),
             #"{"product_idea":"source backed agent memory wiki","market":"coding agents","target_user":"developer relations","k":5}"#),
        ]
        for (tool, args) in calls {
            let result = try await tool.run(
                ToolCall(callId: tool.name, name: tool.name, argumentsJSON: args),
                cwd: "/")
            XCTAssertTrue(result.success, tool.name)
            let object = try jsonObject(result.output)
            XCTAssertEqual(object["status"] as? String, "ok", tool.name)
            let citations = try XCTUnwrap(object["citations"] as? [[String: Any]], tool.name)
            XCTAssertFalse(citations.isEmpty, tool.name)
            let uncited = try XCTUnwrap(object["uncited_claims"] as? [String], tool.name)
            XCTAssertTrue(uncited.isEmpty, tool.name)
            let retrieval = try XCTUnwrap(object["retrieval"] as? [String: Any], tool.name)
            XCTAssertEqual(retrieval["mode"] as? String, "lexical", tool.name)
            XCTAssertEqual(retrieval["cloud_spend_usd"] as? Double, 0, tool.name)
        }
    }

    func testWikiBriefReturnsInsufficientEvidenceInsteadOfInventing() async throws {
        let path = NSTemporaryDirectory() + "mcp-empty-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8))
        let tool = WikiBriefTool(store: store)
        let result = try await tool.run(
            ToolCall(callId: "empty", name: tool.name,
                     argumentsJSON: #"{"topic":"no matching topic","k":5}"#),
            cwd: "/")
        XCTAssertTrue(result.success)
        let object = try jsonObject(result.output)
        XCTAssertEqual(object["status"] as? String, "insufficient_evidence")
        XCTAssertEqual((object["citations"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(object["confidence"] as? String, "none")
    }

    func testWikiProductionToolsDoNotCallInferenceFromToolset() async throws {
        let (path, store) = try await seededStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let inference = TrappingInferenceProvider(embeddingDimension: 16)
        let retriever = MemoryRetriever(store: store, inference: inference)
        let gate = BrainGate(store: store, caller: { _, _, _ in
            throw InferenceError.providerUnavailable("unexpected BrainGate caller")
        })
        let toolset = MemoryToolset(store: store,
                                    retriever: retriever,
                                    inference: inference,
                                    personas: PersonaState(),
                                    gate: gate)
        let argsByName: [String: String] = [
            "wiki_brief": #"{"topic":"agent memory production analysis","k":5}"#,
            "wiki_compare": #"{"subject":"agent memory release","baseline_query":"developer relations","k":5}"#,
            "wiki_angle": #"{"topic":"agent memory","k":5}"#,
            "wiki_pmfit": #"{"product_idea":"source backed agent memory wiki","market":"coding agents","k":5}"#,
        ]
        for tool in toolset.tools() {
            guard let arguments = argsByName[tool.name] else { continue }
            let result = try await tool.run(
                ToolCall(callId: tool.name, name: tool.name,
                         argumentsJSON: arguments),
                cwd: "/")
            XCTAssertTrue(result.success, tool.name)
            let object = try jsonObject(result.output)
            let retrieval = try XCTUnwrap(object["retrieval"] as? [String: Any], tool.name)
            XCTAssertEqual(retrieval["cloud_spend_usd"] as? Double, 0, tool.name)
        }
    }

    func testWikiProductionToolsRejectMissingRequiredArguments() async throws {
        let (path, store) = try await seededStore()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let calls: [(any Tool, String)] = [
            (WikiBriefTool(store: store), #"{}"#),
            (WikiCompareTool(store: store), #"{}"#),
            (WikiPMFitTool(store: store), #"{}"#),
        ]
        for (tool, args) in calls {
            let result = try await tool.run(
                ToolCall(callId: tool.name, name: tool.name, argumentsJSON: args),
                cwd: "/")
            XCTAssertFalse(result.success, tool.name)
            XCTAssertTrue(result.output.contains("invalid"), tool.name)
        }
    }

    func testMemoryToolsRejectOutOfRangeLimitsBeforeArithmeticOrPrefix() async throws {
        let (path, store) = try await seededStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let inference = MockInferenceProvider(embeddingDimension: 16)
        let retriever = MemoryRetriever(store: store, inference: inference)
        let personas = PersonaState()

        let hybrid = HybridSearchTool(retriever: retriever, personas: personas)
        let badHybrid = try await hybrid.run(
            ToolCall(callId: "hybrid", name: hybrid.name,
                     argumentsJSON: #"{"query":"agent memory","k":-1}"#),
            cwd: "/")
        XCTAssertFalse(badHybrid.success)

        let ask = AskLocalBrainTool(retriever: retriever, inference: inference)
        let badAsk = try await ask.run(
            ToolCall(callId: "ask", name: ask.name,
                     argumentsJSON: #"{"question":"agent memory","k":-1}"#),
            cwd: "/")
        XCTAssertFalse(badAsk.success)

        let brief = WikiBriefTool(store: store)
        let badBrief = try await brief.run(
            ToolCall(callId: "brief", name: brief.name,
                     argumentsJSON: #"{"topic":"agent memory","k":9223372036854775807}"#),
            cwd: "/")
        XCTAssertFalse(badBrief.success)

        let angle = WikiAngleTool(store: store)
        let badAngle = try await angle.run(
            ToolCall(callId: "angle", name: angle.name,
                     argumentsJSON: #"{"topic":"agent memory","angle_count":9223372036854775807}"#),
            cwd: "/")
        XCTAssertFalse(badAngle.success)
    }
}
