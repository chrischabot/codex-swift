import XCTest
import Foundation
@testable import GoogleWorkspace
@testable import Connectors
@testable import EgressGuard
@testable import Tools
import ProtocolModel
import HarnessCore

/// Severe tests for the ADDONS #4 google_api tool: service→host containment,
/// bearer attachment + transparent auth, write-verb approval gating, and 429/5xx
/// retry-with-backoff.
final class GoogleWorkspaceTests: XCTestCase {

    /// A connector seeded with a long-lived token (no refresh needed).
    private func authedConnector() -> GoogleConnector {
        let store = MemoryTokenStore(OAuthTokens(
            accessToken: "TOK-123", refreshToken: "RT", expiresAt: 9_999_999_999,
            scope: "", tokenType: "Bearer"))
        let oauth = GoogleOAuthClient(
            config: GoogleOAuthConfig(clientId: "x", scopes: []),
            egress: EgressGuard(EgressPolicy(allowedHosts: [], allowHTTP: true, resolve: { _ in ["93.184.216.34"] })),
            http: NeverHTTP(), now: { 1000 })
        return GoogleConnector(client: oauth, store: store, now: { 1000 })
    }

    private func client(_ http: StubGoogleHTTP, connector: GoogleConnector? = nil) -> GoogleAPIClient {
        GoogleAPIClient(connector: connector ?? authedConnector(), http: http,
                        maxRetries: 4, sleep: { _ in })   // immediate backoff in tests
    }

    // MARK: URL building + host containment + bearer

    func testGetBuildsServiceURLAndAttachesBearer() async {
        let http = StubGoogleHTTP(scripted: [.response(status: 200, body: Data(#"{"files":[]}"#.utf8))])
        let r = await client(http).call(service: .drive, method: "GET", path: "/files", query: ["pageSize": "10"])
        guard case .success(let resp) = r else { return XCTFail("expected success, got \(r)") }
        XCTAssertEqual(resp.status, 200)
        let req = await http.lastRequest()
        XCTAssertEqual(req?.url.absoluteString, "https://www.googleapis.com/drive/v3/files?pageSize=10")
        XCTAssertEqual(req?.headers["Authorization"], "Bearer TOK-123")
        XCTAssertEqual(req?.method, "GET")
    }

    func testEachServiceMapsToItsAllowlistedHost() async {
        for service in GoogleService.allCases {
            let http = StubGoogleHTTP(scripted: [.response(status: 200, body: Data("{}".utf8))])
            _ = await client(http).call(service: service, method: "GET", path: "/x")
            let host = await http.lastRequest()?.url.host ?? ""
            XCTAssertEqual(host, service.host)
            XCTAssertTrue(GoogleService.allowedHosts.contains(host), "every service host is in the allowlist")
        }
    }

    // MARK: write-verb approval

    func testApprovalRequiredForWriteVerbsOnly() {
        let tool = GoogleAPITool(client: client(StubGoogleHTTP(scripted: [])))
        func req(_ method: String) -> ToolApprovalRequirement {
            tool.approvalRequirement(ToolCall(callId: "c", name: "google_api",
                argumentsJSON: #"{"service":"drive","method":"\#(method)","path":"/files"}"#))
        }
        if case .required = req("DELETE") {} else { XCTFail("DELETE must require approval") }
        if case .required = req("POST") {} else { XCTFail("POST must require approval") }
        if case .required = req("PATCH") {} else { XCTFail("PATCH must require approval") }
        if case .none = req("GET") {} else { XCTFail("GET is read-only, no approval") }
    }

    // MARK: retry / backoff

    func testRetriesOn429ThenSucceeds() async {
        let http = StubGoogleHTTP(scripted: [
            .response(status: 429, body: Data("rate".utf8)),
            .response(status: 200, body: Data(#"{"ok":true}"#.utf8)),
        ])
        let r = await client(http).call(service: .gmail, method: "GET", path: "/users/me/messages")
        guard case .success(let resp) = r else { return XCTFail("429 must be retried into success, got \(r)") }
        XCTAssertEqual(resp.status, 200)
        let n = await http.count()
        XCTAssertEqual(n, 2, "one retry after the 429")
    }

    func testRetriesOn5xx() async {
        let http = StubGoogleHTTP(scripted: [
            .response(status: 503, body: Data()),
            .response(status: 503, body: Data()),
            .response(status: 200, body: Data("{}".utf8)),
        ])
        let r = await client(http).call(service: .calendar, method: "GET", path: "/users/me/calendarList")
        guard case .success = r else { return XCTFail("5xx must be retried, got \(r)") }
        let n = await http.count()
        XCTAssertEqual(n, 3)
    }

    func testClientErrorNotRetried() async {
        let http = StubGoogleHTTP(scripted: [.response(status: 403, body: Data("forbidden".utf8))])
        let r = await client(http).call(service: .drive, method: "GET", path: "/files")
        guard case .failure(.http(let status, _)) = r else { return XCTFail("4xx must surface as http error, got \(r)") }
        XCTAssertEqual(status, 403)
        let n = await http.count()
        XCTAssertEqual(n, 1, "a 4xx is not retried")
    }

    func testPathTraversalRejected() async {
        let http = StubGoogleHTTP(scripted: [.response(status: 200, body: Data("{}".utf8))])
        // `..` would normalize on the server to escape /drive/v3 to another API
        // on the same host — must be rejected before any request.
        let r = await client(http).call(service: .drive, method: "GET", path: "/../../calendar/v3/calendars")
        guard case .failure(.invalidPath) = r else { return XCTFail("dot-segment path must be rejected, got \(r)") }
        let n = await http.count()
        XCTAssertEqual(n, 0, "no request is made for a traversal path")
    }

    func testWriteNotRetriedOn5xx() async {
        // A POST that 5xx's may have applied the write — must NOT be resent.
        let http = StubGoogleHTTP(scripted: [
            .response(status: 503, body: Data()),
            .response(status: 200, body: Data("{}".utf8)),
        ])
        let r = await client(http).call(service: .calendar, method: "POST", path: "/calendars/primary/events",
                                        body: Data("{}".utf8))
        guard case .failure(.http(let s, _)) = r else { return XCTFail("POST 5xx must surface, not retry, got \(r)") }
        XCTAssertEqual(s, 503)
        let n = await http.count()
        XCTAssertEqual(n, 1, "a non-idempotent POST is not retried on 5xx (no duplicate write)")
    }

    func testWriteRetriedOn429() async {
        // A 429 means the request was REJECTED (not applied) → safe to resend.
        let http = StubGoogleHTTP(scripted: [
            .response(status: 429, body: Data()),
            .response(status: 200, body: Data("{}".utf8)),
        ])
        let r = await client(http).call(service: .calendar, method: "POST", path: "/calendars/primary/events",
                                        body: Data("{}".utf8))
        guard case .success = r else { return XCTFail("a 429'd POST is safely retried, got \(r)") }
        let n = await http.count()
        XCTAssertEqual(n, 2)
    }

    func testBearerRedactedInErrors() {
        let s = redactBearer("failed: header Authorization: Bearer ya29.SECRET-TOKEN-abc more")
        XCTAssertFalse(s.contains("ya29.SECRET-TOKEN-abc"), "the bearer is redacted")
        XCTAssertTrue(s.contains("Bearer [redacted]"))
    }

    func testBadMethodRejected() async {
        let http = StubGoogleHTTP(scripted: [])
        let r = await client(http).call(service: .drive, method: "FROBNICATE", path: "/files")
        guard case .failure(.badMethod) = r else { return XCTFail("unknown verb must be rejected") }
    }

    func testUnauthorizedWhenNoToken() async {
        let store = MemoryTokenStore(nil)
        let oauth = GoogleOAuthClient(
            config: GoogleOAuthConfig(clientId: "x", scopes: []),
            egress: EgressGuard(EgressPolicy(resolve: { _ in ["1.2.3.4"] })),
            http: NeverHTTP())
        let conn = GoogleConnector(client: oauth, store: store)
        let http = StubGoogleHTTP(scripted: [])
        let r = await client(http, connector: conn).call(service: .drive, method: "GET", path: "/files")
        guard case .failure(.notAuthorized) = r else { return XCTFail("no token → notAuthorized, got \(r)") }
        let n = await http.count()
        XCTAssertEqual(n, 0, "no request is made when unauthorized")
    }

    func testGoogleToolPackEmitsToolOrSelfPrunes() {
        let pack = GoogleToolPack(client: client(StubGoogleHTTP(scripted: [])))
        XCTAssertEqual(pack.id, "google")
        XCTAssertEqual(pack.tools().map(\.name), ["google_api"])
        XCTAssertEqual(GoogleToolPack(client: nil).tools().count, 0)
    }

    // MARK: tool surface

    func testToolRunReturnsJSON() async throws {
        let http = StubGoogleHTTP(scripted: [.response(status: 200, body: Data(#"{"files":[{"id":"1"}]}"#.utf8))])
        let tool = GoogleAPITool(client: client(http))
        let r = try await tool.run(ToolCall(callId: "c", name: "google_api",
            argumentsJSON: #"{"service":"drive","method":"GET","path":"/files"}"#), cwd: "/")
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("\"id\":\"1\""), r.output)
    }

    func testToolRejectsUnknownService() async throws {
        let tool = GoogleAPITool(client: client(StubGoogleHTTP(scripted: [])))
        let r = try await tool.run(ToolCall(callId: "c", name: "google_api",
            argumentsJSON: #"{"service":"nope","method":"GET","path":"/x"}"#), cwd: "/")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("invalid arguments"), r.output)
    }
}

// MARK: fixtures

actor StubGoogleHTTP: GoogleHTTPClient {
    struct Req: Sendable { let method: String; let url: URL; let headers: [String: String]; let body: Data? }
    private var scripted: [GoogleHTTPResult]
    private var idx = 0
    private var requests: [Req] = []
    init(scripted: [GoogleHTTPResult]) { self.scripted = scripted }
    func request(method: String, url: URL, headers: [String: String], body: Data?) async -> GoogleHTTPResult {
        requests.append(Req(method: method, url: url, headers: headers, body: body))
        let r = scripted[Swift.min(idx, scripted.count - 1)]; idx += 1
        return r
    }
    func lastRequest() -> Req? { requests.last }
    func count() -> Int { requests.count }
}

/// An OAuthHTTPClient that must never be called (valid token → no refresh).
actor NeverHTTP: OAuthHTTPClient {
    func postForm(url: URL, fields: [String: String]) async -> Result<(status: Int, body: Data), OAuthError> {
        .failure(.transport("NeverHTTP called unexpectedly"))
    }
}
