import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Mem0Core

final class Mem0HTTPServerTests: XCTestCase {
    private func req(_ url: String, _ method: String, _ body: Data?) async throws -> (Data, Int) {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = 5
        return try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: r) { d, resp, e in
                if let e { cont.resume(throwing: e); return }
                cont.resume(returning: (d ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0))
            }.resume()
        }
    }

    func testServeHealthAddGetAll() async throws {
        let engine = Mem0Engine(config: Mem0Config(),
                                embedder: MockEmbedder(dims: 32), llm: MockLLM(),
                                vectorStore: InMemoryVectorStore(), historyStore: InMemoryHistoryStore())
        let server = Mem0HTTPServer(engine: engine)
        let port = try server.start(host: "127.0.0.1", port: 0)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"

        let (h, hs) = try await req("\(base)/health", "GET", nil)
        XCTAssertEqual(hs, 200)
        XCTAssertEqual(JSONValue.parse(h)?.objectValue?["status"]?.stringValue, "ok")

        let addBody = Data(#"{"messages":"I love hiking","user_id":"u1","infer":false}"#.utf8)
        let (a, asc) = try await req("\(base)/v1/memories", "POST", addBody)
        XCTAssertEqual(asc, 200)
        XCTAssertNotNil(JSONValue.parse(a)?.objectValue?["results"]?.arrayValue?.first?
            .objectValue?["id"]?.stringValue)

        let (g, gs) = try await req("\(base)/v1/memories?user_id=u1", "GET", nil)
        XCTAssertEqual(gs, 200)
        XCTAssertEqual(JSONValue.parse(g)?.objectValue?["results"]?.arrayValue?.count, 1)

        let (_, ms) = try await req("\(base)/v1/memories/does-not-exist?user_id=u1", "GET", nil)
        XCTAssertEqual(ms, 404)
    }

    func testRejectsOversizedRequestBodiesBeforeDispatch() async throws {
        let engine = Mem0Engine(config: Mem0Config(),
                                embedder: MockEmbedder(dims: 32), llm: MockLLM(),
                                vectorStore: InMemoryVectorStore(), historyStore: InMemoryHistoryStore())
        let server = Mem0HTTPServer(engine: engine)
        let port = try server.start(host: "127.0.0.1", port: 0)
        defer { server.stop() }
        let body = Data(repeating: UInt8(ascii: "x"), count: Mem0HTTPServer.maxRequestBodyBytes + 1)

        let (data, status) = try await req("http://127.0.0.1:\(port)/v1/memories", "POST", body)

        XCTAssertEqual(status, 413)
        XCTAssertEqual(JSONValue.parse(data)?.objectValue?["error"]?.stringValue, "payload too large")
    }
}
