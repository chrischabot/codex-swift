import XCTest
import Foundation
@testable import Push
@testable import Channels
@testable import EgressGuard
@testable import DeliveryCore
@testable import Tools
import ProtocolModel
import HarnessCore

/// Severe tests for the ADDONS #7 push primitive: target parsing, EgressGuard
/// SSRF rejection at the sinks, durable at-least-once routing + retry, and the
/// owner/allowlist gating of the push_send tool.
final class PushTests: XCTestCase {

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "push-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// An EgressGuard whose resolver maps any host containing "internal" to a
    /// loopback IP (→ deny) and everything else to a public IP (→ allow).
    private func egress() -> EgressGuard {
        EgressGuard(EgressPolicy(allowedHosts: [], allowHTTP: false, resolve: { host in
            host.contains("internal") ? ["127.0.0.1"] : ["93.184.216.34"]
        }))
    }

    // MARK: target parsing

    func testTargetParsing() {
        XCTAssertEqual(PushTarget.parse("ntfy:alerts"), PushTarget(scheme: "ntfy", rest: "alerts"))
        XCTAssertEqual(PushTarget.parse("webhook:https://h.example/x"),
                       PushTarget(scheme: "webhook", rest: "https://h.example/x"))
        XCTAssertEqual(PushTarget.parse("TELEGRAM:12345")?.scheme, "telegram", "scheme lowercased")
        XCTAssertNil(PushTarget.parse("nocolon"))
        XCTAssertNil(PushTarget.parse(":rest"))
        XCTAssertNil(PushTarget.parse("scheme:"))
    }

    // MARK: SSRF rejection

    func testWebhookSinkRejectsInternalTarget() async {
        let http = StubHTTP(statuses: [200])
        let sink = WebhookSink(egress: egress(), http: http)
        let r = await sink.send(OutboundMessage(conversationId: "https://internal.svc/hook", text: "x"))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.detail.contains("egress denied"), "an internal webhook target is blocked: \(r.detail)")
        let calls = await http.calls()
        XCTAssertTrue(calls.isEmpty, "no HTTP POST is made for a denied target")
    }

    func testWebhookSinkDeliversToPublicTarget() async {
        let http = StubHTTP(statuses: [200])
        let sink = WebhookSink(egress: egress(), http: http)
        let r = await sink.send(OutboundMessage(conversationId: "https://hooks.example/x", text: "hi"))
        XCTAssertTrue(r.ok, "a public target with a 200 is delivered: \(r.detail)")
        let calls = await http.calls()
        XCTAssertEqual(calls.count, 1)
    }

    func testNtfySinkRejectsTopicWithPath() async {
        let http = StubHTTP(statuses: [200])
        let sink = NtfySink(baseURL: "https://ntfy.example", egress: egress(), http: http)
        let r = await sink.send(OutboundMessage(conversationId: "a/b/../etc", text: "x"))
        XCTAssertFalse(r.ok, "a topic smuggling path segments is refused")
        let calls = await http.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testNtfySinkDelivers() async {
        let http = StubHTTP(statuses: [200])
        let sink = NtfySink(baseURL: "https://ntfy.example", egress: egress(), http: http)
        let r = await sink.send(OutboundMessage(conversationId: "alerts", text: "ping"))
        XCTAssertTrue(r.ok, "\(r.detail)")
        let calls = await http.calls()
        XCTAssertEqual(calls.first?.0.absoluteString, "https://ntfy.example/alerts")
    }

    // MARK: router (durable)

    func testRouterRoutesAndDelivers() async {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir)
        let sink = RecordingSink(id: "ntfy")
        await router.register(scheme: "ntfy", sink: sink)
        let r = await router.send(target: "ntfy:alerts", text: "hello")
        XCTAssertTrue(r.ok, "\(r.detail)")
        let got = await sink.received()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.conversationId, "alerts")
        XCTAssertEqual(got.first?.text, "hello")
    }

    func testRouterUnknownSchemeFails() async {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir)
        let r = await router.send(target: "telegram:123", text: "x")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.detail.contains("no sink registered"), r.detail)
    }

    func testRouterRetriesTransientFailure() async {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir, maxAttempts: 5)
        let sink = RecordingSink(id: "ntfy", failFirst: 1)   // fail once, then succeed
        await router.register(scheme: "ntfy", sink: sink)
        let r = await router.send(target: "ntfy:alerts", text: "retry-me")
        XCTAssertTrue(r.ok, "the durable queue retries a transient failure: \(r.detail)")
        let got = await sink.received()
        XCTAssertEqual(got.count, 2, "delivered on the 2nd attempt (1 transient failure)")
    }

    func testRouterDoesNotRetryPermanentFailure() async {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir, maxAttempts: 5)
        let sink = RecordingSink(id: "ntfy", permanent: true)   // permanent failure
        await router.register(scheme: "ntfy", sink: sink)
        let r = await router.send(target: "ntfy:alerts", text: "x")
        XCTAssertFalse(r.ok)
        let got = await sink.received()
        XCTAssertEqual(got.count, 1, "a permanent failure (e.g. egress deny / 4xx) must NOT be retried")
    }

    // MARK: tool pack

    func testPushToolPackEmitsToolOrSelfPrunes() async {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let pack = PushToolPack(router: PushRouter(directory: dir))
        XCTAssertEqual(pack.id, "push")
        XCTAssertEqual(pack.tools().map(\.name), ["push_send"])
        XCTAssertEqual(PushToolPack(router: nil).tools().count, 0, "self-prunes with no backend")
    }

    // MARK: push_send tool

    func testPushSendToolRequiresApproval() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let tool = PushSendTool(router: PushRouter(directory: dir))
        let call = ToolCall(callId: "c", name: "push_send",
                            argumentsJSON: #"{"target":"ntfy:alerts","text":"hi"}"#)
        guard case .required = tool.approvalRequirement(call) else {
            return XCTFail("push_send must declare .required approval (owner consent for outbound)")
        }
    }

    func testPushSendToolEnforcesAllowlist() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir)
        await router.register(scheme: "ntfy", sink: RecordingSink(id: "ntfy"))
        let tool = PushSendTool(router: router, allowedTargets: ["ntfy:ok"])
        let bad = ToolCall(callId: "c", name: "push_send",
                           argumentsJSON: #"{"target":"ntfy:evil","text":"x"}"#)
        let r = try await tool.run(bad, cwd: "/")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("not in the allowed"), r.output)
    }

    func testPushSendToolDeliversAllowedTarget() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir)
        let sink = RecordingSink(id: "ntfy")
        await router.register(scheme: "ntfy", sink: sink)
        let tool = PushSendTool(router: router, allowedTargets: ["ntfy:ok"])
        let good = ToolCall(callId: "c", name: "push_send",
                            argumentsJSON: #"{"target":"ntfy:ok","text":"yo"}"#)
        let r = try await tool.run(good, cwd: "/")
        XCTAssertTrue(r.success, r.output)
        let got = await sink.received()
        XCTAssertEqual(got.first?.text, "yo")
    }
}

// MARK: fixtures

actor StubHTTP: PushHTTPClient {
    private var _calls: [(URL, Data, String)] = []
    private let statuses: [Int]
    private var idx = 0
    init(statuses: [Int]) { self.statuses = statuses }
    func post(url: URL, body: Data, contentType: String, pinnedIPs: [String]) async -> PushHTTPResult {
        _calls.append((url, body, contentType))
        let s = statuses[Swift.min(idx, statuses.count - 1)]; idx += 1
        return .status(s)
    }
    func calls() -> [(URL, Data, String)] { _calls }
}

/// A ChannelOutbound sink that records messages and can fail the first N sends
/// (to exercise the durable retry path).
actor RecordingSink: ChannelOutbound {
    nonisolated let id: String
    private var messages: [OutboundMessage] = []
    private var remainingFailures: Int
    private let permanent: Bool
    init(id: String, failFirst: Int = 0, permanent: Bool = false) {
        self.id = id; self.remainingFailures = failFirst; self.permanent = permanent
    }
    func send(_ message: OutboundMessage) async -> OutboundReceipt {
        messages.append(message)
        if permanent { return .failedPermanent("nope") }
        if remainingFailures > 0 { remainingFailures -= 1; return .failed("transient") }
        return .delivered
    }
    func received() -> [OutboundMessage] { messages }
}
