import XCTest
import Foundation
@testable import GoogleWorkspace
@testable import Connectors
@testable import EgressGuard
@testable import Tools
import ProtocolModel

/// Tests for the typed Google read helpers (#2): each maps a small schema to a
/// fixed service/path on the SAME host-pinned client, is read-only, and refuses
/// a path-reshaping id.
final class GoogleTypedToolsTests: XCTestCase {

    private func client(_ http: StubGoogleHTTP) -> GoogleAPIClient {
        let store = MemoryTokenStore(OAuthTokens(accessToken: "TOK", refreshToken: "RT",
                                                 expiresAt: 9_999_999_999, scope: "", tokenType: "Bearer"))
        let oauth = GoogleOAuthClient(
            config: GoogleOAuthConfig(clientId: "x", scopes: []),
            egress: EgressGuard(EgressPolicy(allowedHosts: [], allowHTTP: true, resolve: { _ in ["93.184.216.34"] })),
            http: NeverHTTP(), now: { 1000 })
        return GoogleAPIClient(connector: GoogleConnector(client: oauth, store: store, now: { 1000 }),
                               http: http, maxRetries: 0, sleep: { _ in })
    }
    private func ok() -> StubGoogleHTTP { StubGoogleHTTP(scripted: [.response(status: 200, body: Data("{}".utf8))]) }
    private func qitems(_ url: URL) -> [String: String] {
        var m: [String: String] = [:]
        for i in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { m[i.name] = i.value }
        return m
    }
    private func call(_ name: String, _ json: String) -> ToolCall {
        ToolCall(callId: "c", name: name, argumentsJSON: json)
    }

    func testTypedToolsAreReadOnly() {
        // No approvalRequirement override → default .none (these are reads).
        let c = client(ok())
        for t: any Tool in [GmailSearchTool(client: c), DriveGetTool(client: c), CalendarAgendaTool(client: c)] {
            guard case .none = t.approvalRequirement(call(t.name, "{}")) else {
                return XCTFail("\(t.name) must be read-only (.none approval)")
            }
        }
    }

    func testGmailSearchBuildsQuery() async throws {
        let http = ok()
        let r = try await GmailSearchTool(client: client(http)).run(
            call("gmail_search", #"{"query":"from:alice is:unread","max_results":5}"#), cwd: "/")
        XCTAssertTrue(r.success)
        let req = await http.lastRequest()
        let url = try XCTUnwrap(req?.url)
        XCTAssertEqual(url.host, "gmail.googleapis.com")
        XCTAssertTrue(url.path.hasSuffix("/users/me/messages"), url.path)
        let q = qitems(url)
        XCTAssertEqual(q["q"], "from:alice is:unread")
        XCTAssertEqual(q["maxResults"], "5")
    }

    func testGmailSearchClampsMaxResults() async throws {
        let http = ok()
        _ = try await GmailSearchTool(client: client(http)).run(
            call("gmail_search", #"{"query":"x","max_results":9999}"#), cwd: "/")
        let last = await http.lastRequest()
        let url = try XCTUnwrap(last?.url)
        XCTAssertEqual(qitems(url)["maxResults"], "100", "clamped to 100")
    }

    func testDriveGetBuildsPath() async throws {
        let http = ok()
        let r = try await DriveGetTool(client: client(http)).run(
            call("drive_get", #"{"file_id":"abc123"}"#), cwd: "/")
        XCTAssertTrue(r.success)
        let last = await http.lastRequest()
        let url = try XCTUnwrap(last?.url)
        XCTAssertEqual(url.host, "www.googleapis.com")
        XCTAssertTrue(url.path.contains("/files/abc123"), url.path)
    }

    func testDriveGetRejectsPathReshapingId() async throws {
        let http = ok()
        for bad in ["a/b", "..", "."] {
            let r = try await DriveGetTool(client: client(http)).run(
                call("drive_get", #"{"file_id":"\#(bad)"}"#), cwd: "/")
            XCTAssertFalse(r.success, "file_id '\(bad)' must be rejected before any request")
        }
        let req = await http.lastRequest()
        XCTAssertNil(req, "no request is made for a reshaping file_id")
    }

    func testCalendarAgendaDefaultsAndOrdering() async throws {
        let http = ok()
        _ = try await CalendarAgendaTool(client: client(http)).run(call("calendar_agenda", "{}"), cwd: "/")
        let last = await http.lastRequest()
        let url = try XCTUnwrap(last?.url)
        XCTAssertEqual(url.host, "www.googleapis.com")
        XCTAssertTrue(url.path.contains("/calendars/primary/events"), url.path)
        let q = qitems(url)
        XCTAssertEqual(q["singleEvents"], "true")
        XCTAssertEqual(q["orderBy"], "startTime")
        XCTAssertEqual(q["maxResults"], "10")
        XCTAssertNotNil(q["timeMin"], "defaults timeMin to now")
    }

    func testTypedToolsInPack() {
        let c = client(ok())
        let names = GoogleToolPack(client: c).tools().map(\.name)
        XCTAssertEqual(Set(names), ["google_api", "gmail_search", "drive_get", "calendar_agenda"])
        XCTAssertTrue(GoogleToolPack(client: nil).tools().isEmpty, "self-prunes when unconfigured")
    }
}
