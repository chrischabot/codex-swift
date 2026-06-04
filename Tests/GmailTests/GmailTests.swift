import XCTest
import Foundation
@testable import Gmail
@testable import Channels
@testable import GoogleWorkspace
@testable import Connectors
@testable import EgressGuard

/// Severe tests for the ADDONS #5 Gmail channel: RFC822 build (+ header-injection
/// defense), message parsing, and the security-defining routing — NON-OWNER by
/// default, self-loop skip, threaded reply.
final class GmailTests: XCTestCase {

    // MARK: MIME build

    func testBuildRawHasThreadingAndSelfLoopHeaders() throws {
        let raw = GmailMIME.buildRaw(to: "a@b.com", subject: "Hi", body: "hello",
                                     inReplyTo: "<msg-1@b.com>", references: "<root@b.com>")
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(raw)), as: UTF8.self)
        XCTAssertTrue(mime.contains("To: a@b.com"))
        XCTAssertTrue(mime.contains("Subject: Hi"))
        XCTAssertTrue(mime.contains("In-Reply-To: <msg-1@b.com>"))
        XCTAssertTrue(mime.contains("References: <root@b.com>"))
        XCTAssertTrue(mime.contains("X-Codex-Channel: gmail"), "self-loop marker present")
        XCTAssertTrue(mime.hasSuffix("hello"))
    }

    func testBuildRawRejectsHeaderInjection() throws {
        // A subject smuggling CRLF + a Bcc must NOT produce an extra header.
        let raw = GmailMIME.buildRaw(to: "a@b.com", subject: "Hi\r\nBcc: evil@x.com", body: "x")
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(raw)), as: UTF8.self)
        XCTAssertFalse(mime.contains("\r\nBcc:"), "CRLF in a header value must be stripped — no injected Bcc header")
        XCTAssertTrue(mime.contains("Subject: Hi"), "the subject stays one header; the smuggled text is folded inline")
    }

    // MARK: parsing

    func testParseExtractsFields() throws {
        let json = Self.messageJSON(id: "m1", threadId: "t1", from: "Alice <alice@example.com>",
                                    subject: "Question", messageId: "<m1@example.com>", body: "what time?")
        let msg = try XCTUnwrap(GmailParser.parse(json))
        XCTAssertEqual(msg.fromAddress, "alice@example.com", "bare lowercased address extracted")
        XCTAssertEqual(msg.subject, "Question")
        XCTAssertEqual(msg.messageId, "<m1@example.com>")
        XCTAssertEqual(msg.body, "what time?")
        XCTAssertFalse(msg.isSelfLoop)
    }

    func testParseDetectsSelfLoop() throws {
        let json = Self.messageJSON(id: "m1", threadId: "t1", from: "me@x.com", subject: "Re: x",
                                    messageId: "<m@x>", body: "loop", selfLoop: true)
        let msg = try XCTUnwrap(GmailParser.parse(json))
        XCTAssertTrue(msg.isSelfLoop, "our own X-Codex-Channel send is detected")
    }

    // MARK: routing (THE security tests)

    func testSelfLoopMessageIsSkipped() async {
        let (chan, host, _) = makeChannel()
        let msg = GmailInboundMessage(id: "m", threadId: "t", from: "me@x.com", fromAddress: "me@x.com",
                                      subject: "Re: x", messageId: nil, references: nil, body: "loop", isSelfLoop: true)
        let delivered = await chan.processInbound(msg, host: host)
        XCTAssertFalse(delivered, "a self-loop message is skipped")
        let n = await host.count()
        XCTAssertEqual(n, 0, "host.deliver is never called for a self-loop")
    }

    func testInboundSenderIsNonOwnerByDefault() async {
        let (chan, host, _) = makeChannel(owners: [])   // default: no owners
        let msg = inbound(from: "stranger@evil.com")
        _ = await chan.processInbound(msg, host: host)
        let got = await host.last()
        XCTAssertNotNil(got)
        XCTAssertFalse(got!.senderIsOwner, "an email sender is NEVER owner by default (From is forgeable)")
        XCTAssertEqual(got!.senderId, "stranger@evil.com")
        XCTAssertEqual(got!.conversationId, "t1", "routed by threadId")
    }

    func testOwnerAllowlistMakesOwner() async {
        let (chan, host, _) = makeChannel(owners: ["boss@corp.com"])
        _ = await chan.processInbound(inbound(from: "boss@corp.com"), host: host)
        let got = await host.last()
        XCTAssertTrue(got!.senderIsOwner, "an explicitly allowlisted address is owner")
    }

    func testReplyIsThreadedAndSent() async throws {
        let (chan, host, http) = makeChannel(reply: "the answer")
        _ = await chan.processInbound(inbound(from: "alice@example.com", messageId: "<orig@example.com>"), host: host)
        // The last API call is the threaded send.
        let req = await http.lastRequest()
        XCTAssertEqual(req?.method, "POST")
        XCTAssertTrue(req?.url.absoluteString.contains("/gmail/v1/users/me/messages/send") ?? false, req?.url.absoluteString ?? "")
        let payload = try XCTUnwrap(req?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(payload["threadId"] as? String, "t1", "reply stays in the inbound thread")
        let raw = try XCTUnwrap(payload["raw"] as? String)
        let mime = String(decoding: try XCTUnwrap(Base64URL.decode(raw)), as: UTF8.self)
        XCTAssertTrue(mime.contains("To: alice@example.com"), "reply goes back to the sender")
        XCTAssertTrue(mime.contains("In-Reply-To: <orig@example.com>"), "threading header set")
        XCTAssertTrue(mime.contains("the answer"))
    }

    func testOutboundSendToEmail() async {
        let (chan, _, http) = makeChannel()
        let r = await chan.send(OutboundMessage(conversationId: "dest@x.com", text: "ping"))
        XCTAssertTrue(r.ok, r.detail)
        let req = await http.lastRequest()
        XCTAssertTrue(req?.url.absoluteString.contains("/messages/send") ?? false)
    }

    // MARK: helpers

    private func inbound(from: String, messageId: String? = "<orig@x>") -> GmailInboundMessage {
        GmailInboundMessage(id: "m1", threadId: "t1", from: from, fromAddress: GmailParser.bareAddress(from),
                            subject: "Q", messageId: messageId, references: nil, body: "hi", isSelfLoop: false)
    }

    private func makeChannel(owners: Set<String> = [], reply: String = "ok")
    -> (GmailChannel, StubHost, StubGoogleHTTP) {
        let http = StubGoogleHTTP()
        let store = MemoryTokenStore(OAuthTokens(accessToken: "T", refreshToken: "R",
                                                 expiresAt: 9_999_999_999, scope: "", tokenType: "Bearer"))
        let oauth = GoogleOAuthClient(config: GoogleOAuthConfig(clientId: "x", scopes: []),
                                      egress: EgressGuard(EgressPolicy(resolve: { _ in ["1.2.3.4"] })),
                                      http: NeverOAuthHTTP(), now: { 1000 })
        let connector = GoogleConnector(client: oauth, store: store, now: { 1000 })
        let api = GoogleAPIClient(connector: connector, http: http, maxRetries: 0, sleep: { _ in })
        let chan = GmailChannel(api: api, ownerEmails: owners, fromAddress: "agent@x.com", pollMs: 2000)
        let host = StubHost(reply: ChannelReply(text: reply, status: "completed"))
        return (chan, host, http)
    }

    /// Build a `users.messages.get` (format=full) JSON.
    static func messageJSON(id: String, threadId: String, from: String, subject: String,
                            messageId: String, body: String, selfLoop: Bool = false) -> Data {
        var headers: [[String: String]] = [
            ["name": "From", "value": from],
            ["name": "Subject", "value": subject],
            ["name": "Message-ID", "value": messageId],
        ]
        if selfLoop { headers.append(["name": "X-Codex-Channel", "value": "gmail"]) }
        let payload: [String: Any] = [
            "id": id, "threadId": threadId,
            "payload": [
                "mimeType": "text/plain",
                "headers": headers,
                "body": ["data": Base64URL.encode(Data(body.utf8))],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: ["id": id, "threadId": threadId, "payload": payload["payload"]!])
    }
}

// MARK: fixtures

actor StubHost: ChannelHost {
    private var delivered: [InboundMessage] = []
    let reply: ChannelReply
    init(reply: ChannelReply) { self.reply = reply }
    func deliver(_ msg: InboundMessage) async -> ChannelReply { delivered.append(msg); return reply }
    func count() -> Int { delivered.count }
    func last() -> InboundMessage? { delivered.last }
}

actor StubGoogleHTTP: GoogleHTTPClient {
    struct Req: Sendable { let method: String; let url: URL; let body: Data? }
    private var requests: [Req] = []
    func request(method: String, url: URL, headers: [String: String], body: Data?) async -> GoogleHTTPResult {
        requests.append(Req(method: method, url: url, body: body))
        return .response(status: 200, body: Data(#"{"id":"sent"}"#.utf8))
    }
    func lastRequest() -> Req? { requests.last }
}

actor NeverOAuthHTTP: OAuthHTTPClient {
    func postForm(url: URL, fields: [String: String]) async -> Result<(status: Int, body: Data), OAuthError> {
        .failure(.transport("unexpected"))
    }
}
