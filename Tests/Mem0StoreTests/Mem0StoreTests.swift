import XCTest
import Mem0Core
@testable import Mem0Store

final class Mem0StoreTests: XCTestCase {
    private func tempPath() -> String {
        NSTemporaryDirectory() + "mem0-\(UUID().uuidString).db"
    }

    private func rec(_ id: String, _ vector: [Float], _ data: String, _ user: String) -> VectorRecord {
        var p: JSONObject = [:]
        p["data"] = .string(data)
        p["text_lemmatized"] = .string(Mem0NLP.lemmatizeForBM25(data))
        p["user_id"] = .string(user)
        p["created_at"] = .string("2026-01-01T00:00:00Z")
        return VectorRecord(id: id, vector: vector, payload: p)
    }

    func testPersistenceAcrossReopen() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let store = try Mem0SQLiteStore(path: path)
            try await store.insert([rec("a", [1, 0], "persisted memory", "u1")])
        }
        let store2 = try Mem0SQLiteStore(path: path)
        let got = try await store2.get("a")
        XCTAssertNotNil(got)
        XCTAssertEqual(got?.payload["data"]?.stringValue, "persisted memory")
    }

    func testCosineSearchAndFilter() async throws {
        let store = try Mem0SQLiteStore(path: ":memory:")
        try await store.insert([
            rec("a", [1, 0], "I like cats", "u1"),
            rec("b", [0, 1], "I like dogs", "u1"),
            rec("c", [1, 0], "other user", "u2"),
        ])
        let hits = try await store.search("", [1, 0], topK: 10, filters: ["user_id": .string("u1")])
        XCTAssertEqual(hits.first?.id, "a")
        XCTAssertTrue(hits.allSatisfy { $0.payload["user_id"]?.stringValue == "u1" })
    }

    func testKeywordBM25() async throws {
        let store = try Mem0SQLiteStore(path: ":memory:")
        try await store.insert([
            rec("a", [1, 0], "I enjoy hiking mountains", "u1"),
            rec("b", [0, 1], "I enjoy cooking pasta", "u1"),
        ])
        let q = Mem0NLP.lemmatizeForBM25("hiking")
        let hits = try await store.keywordSearch(q, topK: 10, filters: ["user_id": .string("u1")])
        XCTAssertEqual(hits?.count, 1)
        XCTAssertEqual(hits?.first?.id, "a")
    }

    func testHistoryRoundtripAndOrdering() async throws {
        let store = try Mem0SQLiteStore(path: ":memory:")
        try await store.addHistory(memoryID: "m1", oldMemory: nil, newMemory: "hello", event: "ADD",
                                   createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                                   isDeleted: 0, actorID: "alice", role: "user",
                                   userID: "u1", agentID: "a1", runID: "r1")
        try await store.addHistory(memoryID: "m1", oldMemory: "hello", newMemory: "hi", event: "UPDATE",
                                   createdAt: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:01Z",
                                   isDeleted: 0, actorID: nil, role: nil,
                                   userID: "u1", agentID: "a1", runID: "r1")
        let hist = try await store.getHistory("m1")
        XCTAssertEqual(hist.count, 2)
        XCTAssertEqual(hist[0].event, "ADD")
        XCTAssertEqual(hist[0].actorID, "alice")
        XCTAssertEqual(hist[0].userID, "u1")
        XCTAssertEqual(hist[0].agentID, "a1")
        XCTAssertEqual(hist[0].runID, "r1")
        XCTAssertEqual(hist[1].event, "UPDATE")
        XCTAssertEqual(hist[1].oldMemory, "hello")
    }

    func testMessageBufferEviction() async throws {
        let store = try Mem0SQLiteStore(path: ":memory:")
        for i in 0..<15 {
            try await store.saveMessages([.user("m\(i)")], scope: "user_id=u1")
        }
        let last = try await store.getLastMessages("user_id=u1", limit: 10)
        XCTAssertEqual(last.count, 10)
    }

    func testEngineOverSQLiteStore() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Mem0SQLiteStore(path: path)
        let mem = Mem0Engine(config: Mem0Config(historyDbPath: path),
                             embedder: MockEmbedder(dims: 32), llm: MockLLM(),
                             vectorStore: store, historyStore: store)
        let res = try await mem.add("I love trail running", AddOptions(userID: "u1", infer: false))
        XCTAssertEqual(res.count, 1)
        let all = try await mem.getAll(["user_id": .string("u1")], topK: 20)
        XCTAssertEqual(all.objectValue?["results"]?.arrayValue?.count, 1)
        let search = try await mem.search("running", ["user_id": .string("u1")], SearchOptions())
        XCTAssertFalse(search.objectValue?["results"]?.arrayValue?.isEmpty ?? true)
        try await mem.reset()
        let after = try await mem.getAll(["user_id": .string("u1")], topK: 20)
        XCTAssertEqual(after.objectValue?["results"]?.arrayValue?.count, 0)
    }
}
