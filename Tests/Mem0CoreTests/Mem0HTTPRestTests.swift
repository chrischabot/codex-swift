import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Mem0Core

final class Mem0StubURLProtocol: URLProtocol {
    struct Route: Sendable { var status: Int; var body: String }
    nonisolated(unsafe) static var routes: [String: Route] = [:]
    nonisolated(unsafe) static var queuedRoutes: [String: [Route]] = [:]
    nonisolated(unsafe) static var authorizations: [String?] = []
    static func reset() {
        routes = [:]
        queuedRoutes = [:]
        authorizations = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
        let route: Route
        if var queue = Self.queuedRoutes[path], !queue.isEmpty {
            route = queue.removeFirst()
            Self.queuedRoutes[path] = queue
        } else {
            route = Self.routes[path] ?? Route(status: 404, body: "{}")
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: route.status,
                                   httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(route.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [Mem0StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

private actor Mem0TokenBox {
    var token: String

    init(_ token: String) {
        self.token = token
    }

    func get() -> String { token }

    func refresh(_ next: String) -> String {
        token = next
        return token
    }
}

final class Mem0HTTPProviderTests: XCTestCase {
    override func setUp() { super.setUp(); Mem0StubURLProtocol.reset() }
    override func tearDown() { Mem0StubURLProtocol.reset(); super.tearDown() }

    func testEmbedderParsesAndSortsByIndex() async throws {
        Mem0StubURLProtocol.routes["/v1/embeddings"] = .init(
            status: 200, body: #"{"data":[{"embedding":[2.0],"index":1},{"embedding":[1.0],"index":0}]}"#)
        let e = Mem0OpenAIEmbedder(baseURL: "http://stub.local/v1", apiKey: "k", model: "m", dims: 1, session: stubSession())
        let vs = try await e.embedBatch(["a", "b"], .add)
        XCTAssertEqual(vs, [[1.0], [2.0]])
    }

    func testLLMParsesContent() async throws {
        Mem0StubURLProtocol.routes["/v1/chat/completions"] = .init(
            status: 200, body: #"{"choices":[{"message":{"content":"{\"memory\": []}"}}]}"#)
        let llm = Mem0OpenAILLM(baseURL: "http://stub.local/v1", apiKey: "k", model: "gpt-4o-mini", session: stubSession())
        let out = try await llm.generate([.user("hi")], GenerateOptions(responseFormatJSON: true))
        XCTAssertEqual(out, "{\"memory\": []}")
    }

    func testLLMNon2xxThrows() async {
        Mem0StubURLProtocol.routes["/v1/chat/completions"] = .init(status: 500, body: "boom")
        let llm = Mem0OpenAILLM(baseURL: "http://stub.local/v1", apiKey: "k", session: stubSession())
        do {
            _ = try await llm.generate([.user("hi")], GenerateOptions())
            XCTFail("expected throw")
        } catch { /* expected */ }
    }

    func testEmbedderUsesSessionAuthProviderAndRefreshesOn401() async throws {
        Mem0StubURLProtocol.queuedRoutes["/v1/embeddings"] = [
            .init(status: 401, body: "expired"),
            .init(status: 200, body: #"{"data":[{"embedding":[1.0],"index":0}]}"#),
        ]
        let tokenBox = Mem0TokenBox("old-token")
        let auth = Mem0AuthProvider(
            accessToken: { await tokenBox.get() },
            refreshToken: { await tokenBox.refresh("new-token") })
        let e = Mem0OpenAIEmbedder(baseURL: "http://stub.local/v1", model: "m",
                                   dims: 1, session: stubSession(), authProvider: auth)
        let vs = try await e.embedBatch(["a"], .add)
        XCTAssertEqual(vs, [[1.0]])
        XCTAssertEqual(Mem0StubURLProtocol.authorizations, ["Bearer old-token", "Bearer new-token"])
    }

    func testReasoningModelDetection() {
        XCTAssertTrue(mem0IsReasoningModel("o3-mini"))
        XCTAssertTrue(mem0IsReasoningModel("gpt-5"))
        XCTAssertFalse(mem0IsReasoningModel("gpt-4o-mini"))
    }
}

final class Mem0RestHandlerTests: XCTestCase {
    private func engine(_ llm: [String] = []) -> Mem0Engine {
        Mem0Engine(config: Mem0Config(),
                   embedder: MockEmbedder(dims: 32),
                   llm: llm.isEmpty ? MockLLM() : MockLLM(responses: llm),
                   vectorStore: InMemoryVectorStore(),
                   historyStore: InMemoryHistoryStore())
    }

    private func parse(_ r: Mem0RestResponse) -> JSONValue? { JSONValue.parse(r.body) }

    func testHealth() async {
        let r = await Mem0RestHandler.handle(method: "GET", path: "/health", query: [:], body: nil, engine: engine())
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(parse(r)?.objectValue?["status"]?.stringValue, "ok")
    }

    func testAddRawGetAllSearchUpdateDeleteHistoryReset() async {
        let mem = engine()
        // add raw
        let addBody = Data(#"{"messages":"I love hiking","user_id":"u1","infer":false}"#.utf8)
        let add = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories", query: [:], body: addBody, engine: mem)
        XCTAssertEqual(add.status, 200)
        let results = parse(add)?.objectValue?["results"]?.arrayValue
        XCTAssertEqual(results?.count, 1)
        let id = results![0].objectValue!["id"]!.stringValue!

        // get one
        let got = await Mem0RestHandler.handle(method: "GET", path: "/v1/memories/\(id)",
                                               query: ["user_id": "u1"], body: nil, engine: mem)
        XCTAssertEqual(got.status, 200)
        XCTAssertEqual(parse(got)?.objectValue?["memory"]?.stringValue, "I love hiking")

        // get all
        let all = await Mem0RestHandler.handle(method: "GET", path: "/v1/memories", query: ["user_id": "u1"], body: nil, engine: mem)
        XCTAssertEqual(parse(all)?.objectValue?["results"]?.arrayValue?.count, 1)

        // search
        let searchBody = Data(#"{"query":"hiking","user_id":"u1"}"#.utf8)
        let search = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories/search", query: [:], body: searchBody, engine: mem)
        XCTAssertFalse(parse(search)?.objectValue?["results"]?.arrayValue?.isEmpty ?? true)

        // update
        let upd = await Mem0RestHandler.handle(method: "PUT", path: "/v1/memories/\(id)",
                                               query: ["user_id": "u1"],
                                               body: Data(#"{"data":"I love trail running"}"#.utf8), engine: mem)
        XCTAssertEqual(upd.status, 200)

        // history (ADD + UPDATE)
        let hist = await Mem0RestHandler.handle(method: "GET", path: "/v1/memories/\(id)/history",
                                                query: ["user_id": "u1"], body: nil, engine: mem)
        XCTAssertGreaterThanOrEqual(parse(hist)?.objectValue?["history"]?.arrayValue?.count ?? 0, 2)

        // delete
        let del = await Mem0RestHandler.handle(method: "DELETE", path: "/v1/memories/\(id)",
                                               query: ["user_id": "u1"], body: nil, engine: mem)
        XCTAssertEqual(del.status, 200)

        // reset
        let reset = await Mem0RestHandler.handle(method: "POST", path: "/v1/reset", query: [:], body: nil, engine: mem)
        XCTAssertEqual(reset.status, 200)
    }

    func testGetMissingReturns404() async {
        let r = await Mem0RestHandler.handle(method: "GET", path: "/v1/memories/nope",
                                             query: ["user_id": "u1"], body: nil, engine: engine())
        XCTAssertEqual(r.status, 404)
    }

    func testAddWithoutScopeReturns400() async {
        let r = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories", query: [:],
                                             body: Data(#"{"messages":"x","infer":false}"#.utf8), engine: engine())
        XCTAssertEqual(r.status, 400)
    }

    func testDirectIDRoutesRequireAndEnforceScope() async {
        let mem = engine()
        let add = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories", query: [:],
                                               body: Data(#"{"messages":"u1 secret","user_id":"u1","infer":false}"#.utf8),
                                               engine: mem)
        let id = parse(add)?.objectValue?["results"]?.arrayValue?.first?.objectValue?["id"]?.stringValue
        XCTAssertNotNil(id)

        let unscoped = await Mem0RestHandler.handle(method: "GET", path: "/v1/memories/\(id!)",
                                                    query: [:], body: nil, engine: mem)
        XCTAssertEqual(unscoped.status, 400)

        let wrong = await Mem0RestHandler.handle(method: "GET", path: "/v1/memories/\(id!)",
                                                 query: ["user_id": "u2"], body: nil, engine: mem)
        XCTAssertEqual(wrong.status, 404)

        let wrongUpdate = await Mem0RestHandler.handle(method: "PUT", path: "/v1/memories/\(id!)",
                                                       query: ["user_id": "u2"],
                                                       body: Data(#"{"data":"stolen"}"#.utf8),
                                                       engine: mem)
        XCTAssertEqual(wrongUpdate.status, 404)

        let rightUpdate = await Mem0RestHandler.handle(method: "PUT", path: "/v1/memories/\(id!)",
                                                       query: ["user_id": "u1"],
                                                       body: Data(#"{"data":"still u1","metadata":{"user_id":"u2","category":"prefs"}}"#.utf8),
                                                       engine: mem)
        XCTAssertEqual(rightUpdate.status, 200)

        let stillU1 = await Mem0RestHandler.handle(method: "GET", path: "/v1/memories/\(id!)",
                                                   query: ["user_id": "u1"], body: nil, engine: mem)
        XCTAssertEqual(stillU1.status, 200)
        XCTAssertEqual(parse(stillU1)?.objectValue?["user_id"]?.stringValue, "u1")
        XCTAssertEqual(parse(stillU1)?.objectValue?["metadata"]?.objectValue?["category"]?.stringValue, "prefs")

        let moved = await Mem0RestHandler.handle(method: "GET", path: "/v1/memories/\(id!)",
                                                 query: ["user_id": "u2"], body: nil, engine: mem)
        XCTAssertEqual(moved.status, 404)
    }

    func testSearchFiltersCannotOverrideTopLevelScope() async {
        let mem = engine()
        _ = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories", query: [:],
                                         body: Data(#"{"messages":"u1 hiking","user_id":"u1","infer":false}"#.utf8),
                                         engine: mem)
        _ = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories", query: [:],
                                         body: Data(#"{"messages":"u2 hiking","user_id":"u2","infer":false}"#.utf8),
                                         engine: mem)

        let body = Data(#"{"query":"hiking","user_id":"u1","filters":{"user_id":"u2"}}"#.utf8)
        let search = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories/search",
                                                  query: [:], body: body, engine: mem)
        XCTAssertEqual(search.status, 200)
        let results = parse(search)?.objectValue?["results"]?.arrayValue ?? []
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.objectValue?["user_id"]?.stringValue == "u1" })
    }

    func testSearchAdvancedFiltersCannotOverrideTopLevelScope() async {
        let mem = engine()
        _ = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories", query: [:],
                                         body: Data(#"{"messages":"u1 hiking public","user_id":"u1","infer":false}"#.utf8),
                                         engine: mem)
        _ = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories", query: [:],
                                         body: Data(#"{"messages":"u2 hiking secret","user_id":"u2","infer":false}"#.utf8),
                                         engine: mem)

        let body = Data(#"{"query":"hiking","user_id":"u1","filters":{"AND":[{"user_id":"u2"}]},"top_k":10}"#.utf8)
        let search = await Mem0RestHandler.handle(method: "POST", path: "/v1/memories/search",
                                                  query: [:], body: body, engine: mem)

        XCTAssertEqual(search.status, 200)
        let results = parse(search)?.objectValue?["results"]?.arrayValue ?? []
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.objectValue?["user_id"]?.stringValue == "u1" })
        XCTAssertFalse(results.contains { $0.objectValue?["memory"]?.stringValue?.contains("u2") == true })
    }
}
