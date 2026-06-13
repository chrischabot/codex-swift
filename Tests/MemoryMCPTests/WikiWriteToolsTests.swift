import XCTest
import Foundation
@testable import MemoryMCP
@testable import MemoryStore
@testable import Tools

final class WikiWriteToolsTests: XCTestCase {
    private func store() throws -> MemoryStore {
        let path = NSTemporaryDirectory() + "wiki-write-\(UUID().uuidString).db"
        return try MemoryStore(MemoryStoreConfig(path: path, embeddingDimension: 8))
    }

    private func create(_ tool: WikiCreatePageTool, title: String, body: String) async throws -> (id: Int, created: Bool, spend: Double) {
        let args = "{\"title\":\(jsonString(title)),\"body\":\(jsonString(body))}"
        let r = try await tool.run(ToolCall(callId: "c", name: tool.name, argumentsJSON: args), cwd: "/")
        XCTAssertTrue(r.success, "tool succeeded: \(r.output)")
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
            "output is a JSON object: \(r.output)")
        return (obj["id"] as? Int ?? -1, obj["created"] as? Bool ?? false, (obj["cloud_spend_usd"] as? NSNumber)?.doubleValue ?? -1)
    }

    func testCreatesPersistsAndIsZeroSpend() async throws {
        let store = try store()
        let tool = WikiCreatePageTool(store: store)
        let r = try await create(tool, title: "Synthesis Note", body: "---\ntag: ai\n---\nAlice met Bob.")
        XCTAssertTrue(r.created)
        XCTAssertGreaterThan(r.id, 0)
        XCTAssertEqual(r.spend, 0)
        // The page is now a real document, lexically searchable (zero-spend chunks).
        let _dc = try await store.documentCount()
        XCTAssertEqual(_dc, 1)
        let hits = try await store.searchLexical("Alice", k: 10)
        XCTAssertFalse(hits.isEmpty)
    }

    func testIsIdempotentOnIdenticalTitleAndBody() async throws {
        let store = try store()
        let tool = WikiCreatePageTool(store: store)
        let first = try await create(tool, title: "Note", body: "same body")
        XCTAssertTrue(first.created)
        let second = try await create(tool, title: "  note ", body: "same body") // title trims + case-insensitive
        XCTAssertFalse(second.created, "a duplicate create returns the existing page")
        XCTAssertEqual(second.id, first.id)
        let _dc = try await store.documentCount()
        XCTAssertEqual(_dc, 1, "no duplicate page")
    }

    func testSameTitleDifferentBodyCreatesNewPage() async throws {
        let store = try store()
        let tool = WikiCreatePageTool(store: store)
        _ = try await create(tool, title: "Note", body: "body one")
        let changed = try await create(tool, title: "Note", body: "body two")
        XCTAssertTrue(changed.created)
        let _dc = try await store.documentCount()
        XCTAssertEqual(_dc, 2)
    }

    func testRejectsEmptyTitle() async throws {
        let store = try store()
        let tool = WikiCreatePageTool(store: store)
        let r = try await tool.run(
            ToolCall(callId: "c", name: tool.name, argumentsJSON: #"{"title":"   ","body":"x"}"#), cwd: "/")
        XCTAssertFalse(r.success)
        let _dc = try await store.documentCount()
        XCTAssertEqual(_dc, 0)
    }
}

/// Minimal JSON string escaper for the test fixtures.
private func jsonString(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}
