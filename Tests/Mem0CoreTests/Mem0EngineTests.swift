import XCTest
@testable import Mem0Core

final class Mem0EngineTests: XCTestCase {
    private func makeEngine(_ llmResponses: [String] = []) -> Mem0Engine {
        let store = InMemoryVectorStore()
        let history = InMemoryHistoryStore()
        let llm: any Mem0LLM = llmResponses.isEmpty ? MockLLM() : MockLLM(responses: llmResponses)
        return Mem0Engine(config: Mem0Config(historyDbPath: ":memory:"),
                          embedder: MockEmbedder(dims: 64), llm: llm,
                          vectorStore: store, historyStore: history)
    }

    private func umap(_ user: String) -> JSONObject { ["user_id": .string(user)] }

    private func raw(_ user: String) -> AddOptions { AddOptions(userID: user, infer: false) }

    func testRawAddGetGetAll() async throws {
        let mem = makeEngine()
        let res = try await mem.add("I love hiking in the mountains", raw("u1"))
        XCTAssertEqual(res.count, 1)
        XCTAssertEqual(res[0].event, "ADD")

        let got = try await mem.get(res[0].id)
        XCTAssertEqual(got?.objectValue?["memory"]?.stringValue, "I love hiking in the mountains")
        XCTAssertEqual(got?.objectValue?["user_id"]?.stringValue, "u1")

        let all = try await mem.getAll(umap("u1"), topK: 20)
        XCTAssertEqual(all.objectValue?["results"]?.arrayValue?.count, 1)
    }

    func testRawAddSkipsSystemMessages() async throws {
        let mem = makeEngine()
        let msgs = MessagesInput.many([.system("you are helpful"), .user("my name is John")])
        let res = try await mem.add(msgs, raw("u2"))
        XCTAssertEqual(res.count, 1)
        XCTAssertEqual(res[0].memory, "my name is John")
    }

    func testUpdateDeleteHistory() async throws {
        let mem = makeEngine()
        let res = try await mem.add("I like tea", raw("u3"))
        let id = res[0].id

        _ = try await mem.update(id, data: "I like coffee")
        let got = try await mem.get(id)
        XCTAssertEqual(got?.objectValue?["memory"]?.stringValue, "I like coffee")

        let hist = try await mem.history(id)
        XCTAssertEqual(hist.count, 2)
        XCTAssertEqual(hist[1].event, "UPDATE")

        _ = try await mem.delete(id)
        let gone = try await mem.get(id)
        XCTAssertNil(gone)
        let hist2 = try await mem.history(id)
        XCTAssertEqual(hist2.last?.event, "DELETE")
    }

    func testDeleteAllAndReset() async throws {
        let mem = makeEngine()
        for i in 0..<3 { _ = try await mem.add(.text("fact \(i)"), raw("u4")) }
        var all = try await mem.getAll(umap("u4"), topK: 20)
        XCTAssertEqual(all.objectValue?["results"]?.arrayValue?.count, 3)

        _ = try await mem.deleteAll(userID: "u4")
        all = try await mem.getAll(umap("u4"), topK: 20)
        XCTAssertEqual(all.objectValue?["results"]?.arrayValue?.count, 0)

        _ = try await mem.add("another", raw("u4"))
        try await mem.reset()
        all = try await mem.getAll(umap("u4"), topK: 20)
        XCTAssertEqual(all.objectValue?["results"]?.arrayValue?.count, 0)
    }

    func testGetAllRequiresScope() async throws {
        let mem = makeEngine()
        do {
            _ = try await mem.getAll([:], topK: 20)
            XCTFail("expected validation error")
        } catch let e as Mem0Error {
            XCTAssertEqual(e.kind, .validation)
        }
    }

    func testInferredAddExtractsMemories() async throws {
        let llm = #"{"memory":[{"text":"User's name is John","attributed_to":"user"},{"text":"User loves hiking","attributed_to":"user"}]}"#
        let mem = makeEngine([llm])
        let res = try await mem.add("Hi, I'm John and I love hiking", AddOptions(userID: "u1"))
        XCTAssertEqual(res.count, 2)
        XCTAssertTrue(res.allSatisfy { $0.event == "ADD" })
        let all = try await mem.getAll(umap("u1"), topK: 20)
        XCTAssertEqual(all.objectValue?["results"]?.arrayValue?.count, 2)
    }

    func testInferredAddDedupsByHash() async throws {
        let llm = #"{"memory":[{"text":"User likes tea"},{"text":"User likes tea"}]}"#
        let mem = makeEngine([llm])
        let res = try await mem.add("I like tea", AddOptions(userID: "u2"))
        XCTAssertEqual(res.count, 1, "identical extracted texts must dedup by md5 hash")
    }

    func testInferredAddEmptyExtractionReturnsNothing() async throws {
        let mem = makeEngine([#"{"memory":[]}"#])
        let res = try await mem.add("just chitchat, hello!", AddOptions(userID: "u3"))
        XCTAssertEqual(res.count, 0)
    }

    func testSearchRanksRelevantFirst() async throws {
        let mem = makeEngine()
        for text in ["I love hiking in the mountains", "I enjoy cooking pasta", "My favorite color is blue"] {
            _ = try await mem.add(.text(text), raw("u4"))
        }
        let res = try await mem.search("hiking trails", umap("u4"), SearchOptions())
        let results = res.objectValue?["results"]?.arrayValue ?? []
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results[0].objectValue?["memory"]?.stringValue?.contains("hiking") ?? false)
        XCTAssertNotNil(results[0].objectValue?["score"])
    }

    func testSearchHonorsAdvancedMetadataFilters() async throws {
        let mem = makeEngine()
        _ = try await mem.add("I love sushi", AddOptions(userID: "u5", metadata: ["category": .string("food")], infer: false))
        _ = try await mem.add("I love Tokyo", AddOptions(userID: "u5", metadata: ["category": .string("travel")], infer: false))
        var filters = umap("u5")
        filters["category"] = .object(["eq": .string("food")])
        let res = try await mem.search("love", filters, SearchOptions())
        let results = res.objectValue?["results"]?.arrayValue ?? []
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].objectValue?["memory"]?.stringValue?.contains("sushi") ?? false)
    }

    func testProceduralMemory() async throws {
        let mem = makeEngine(["Step 1: open file. Step 2: edit it."])
        let res = try await mem.add(.many([.user("I opened the file then edited it")]),
                                    AddOptions(agentID: "a1", memoryType: "procedural_memory"))
        XCTAssertEqual(res.count, 1)
        XCTAssertTrue(res[0].memory.contains("Step 1"))
        let all = try await mem.getAll(["agent_id": .string("a1")], topK: 20)
        XCTAssertEqual(all.objectValue?["results"]?.arrayValue?.count, 1)
    }

    func testInvalidMemoryTypeThrows() async throws {
        let mem = makeEngine()
        do {
            _ = try await mem.add("x", AddOptions(userID: "u1", memoryType: "bogus"))
            XCTFail("expected error")
        } catch is Mem0Error { /* expected */ }
    }
}