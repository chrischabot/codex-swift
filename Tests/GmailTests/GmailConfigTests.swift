import XCTest
import Foundation
@testable import Gmail
@testable import Channels
@testable import GoogleWorkspace
@testable import Connectors
@testable import EgressGuard

/// Tests for the #5 Gmail channel WIRING: the pure `GmailConfig.load` deny-default
/// gate + owner normalization, and the `pollOnce` de-dup backstop that prevents a
/// reprocess loop when `markRead` can't run (no gmail.modify scope).
final class GmailConfigTests: XCTestCase {

    // MARK: GmailConfig.load

    func testDisabledIsNil() {
        XCTAssertNil(GmailConfig.load(enabled: false))
        XCTAssertNil(GmailConfig.load(enabled: false, ownerEmails: ["a@b.com"]))
    }

    func testDefaults() {
        let c = GmailConfig.load(enabled: true)
        XCTAssertEqual(c?.ownerEmails, [])
        XCTAssertNil(c?.fromAddress)
        XCTAssertEqual(c?.pollMs, 15_000)
    }

    func testOwnerEmailsLowercasedDedupedSortedTrimmed() {
        let c = GmailConfig.load(enabled: true,
                                 ownerEmails: ["  Boss@Corp.com ", "boss@corp.com", "Alice@x.com", "", "   "])
        XCTAssertEqual(c?.ownerEmails, ["alice@x.com", "boss@corp.com"],
                       "lowercased, trimmed, empties dropped, deduped, sorted")
    }

    func testFromAddressNormalized() {
        XCTAssertEqual(GmailConfig.load(enabled: true, fromAddress: " agent@x.com ")?.fromAddress, "agent@x.com")
        XCTAssertNil(GmailConfig.load(enabled: true, fromAddress: "   ")?.fromAddress, "blank → nil")
    }

    func testPollMsClampedToFloor() {
        XCTAssertEqual(GmailConfig.load(enabled: true, pollMs: 500)?.pollMs, 2_000, "clamped to the 2s floor")
        XCTAssertEqual(GmailConfig.load(enabled: true, pollMs: 60_000)?.pollMs, 60_000)
    }

    // MARK: pollOnce de-dup backstop (markRead can't run → must not reprocess)

    func testPollOnceDoesNotReprocessWhenMarkReadFails() async {
        // Scripted Gmail: the unread query ALWAYS returns m1 (markRead 403s, so it
        // stays unread). Without the `seen` backstop, every poll would re-deliver.
        let http = ScriptedGoogleHTTP(messageJSON: GmailTests.messageJSON(
            id: "m1", threadId: "t1", from: "alice@example.com", subject: "Q",
            messageId: "<m1@x>", body: "hi"))
        let chan = Self.channel(http: http)
        let host = CountingHost()
        await chan.pollOnce(host)
        await chan.pollOnce(host)   // same m1 returned again (still unread)
        let n = await host.count()
        XCTAssertEqual(n, 1, "a still-unread message is routed ONCE across polls (seen backstop)")
    }

    // MARK: helpers

    private static func channel(http: ScriptedGoogleHTTP) -> GmailChannel {
        let store = MemoryTokenStore(OAuthTokens(accessToken: "T", refreshToken: "R",
                                                 expiresAt: 9_999_999_999, scope: "", tokenType: "Bearer"))
        let oauth = GoogleOAuthClient(config: GoogleOAuthConfig(clientId: "x", scopes: []),
                                      egress: EgressGuard(EgressPolicy(resolve: { _ in ["1.2.3.4"] })),
                                      http: NeverOAuthHTTP(), now: { 1000 })
        let connector = GoogleConnector(client: oauth, store: store, now: { 1000 })
        let api = GoogleAPIClient(connector: connector, http: http, maxRetries: 0, sleep: { _ in })
        return GmailChannel(api: api, ownerEmails: [], fromAddress: "agent@x.com", pollMs: 2000)
    }
}

/// Returns canned Gmail responses by URL path: the unread list always lists m1;
/// the message get returns `messageJSON`; modify (markRead) returns 403 (no
/// gmail.modify scope); send returns ok.
actor ScriptedGoogleHTTP: GoogleHTTPClient {
    private let messageJSON: Data
    init(messageJSON: Data) { self.messageJSON = messageJSON }
    func request(method: String, url: URL, headers: [String: String], body: Data?) async -> GoogleHTTPResult {
        let p = url.path
        if p.hasSuffix("/messages") {
            return .response(status: 200, body: Data(#"{"messages":[{"id":"m1"}]}"#.utf8))
        }
        if p.contains("/messages/m1") && method == "GET" {
            return .response(status: 200, body: messageJSON)
        }
        if p.contains("/modify") {
            return .response(status: 403, body: Data(#"{"error":"insufficient scope"}"#.utf8))
        }
        return .response(status: 200, body: Data(#"{"id":"sent"}"#.utf8))   // send
    }
}

actor CountingHost: ChannelHost {
    private var n = 0
    func deliver(_ msg: InboundMessage) async -> ChannelReply { n += 1; return ChannelReply(text: "ok", status: "completed") }
    func count() -> Int { n }
}
