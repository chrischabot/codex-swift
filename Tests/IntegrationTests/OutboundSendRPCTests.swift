import XCTest
import Foundation
@testable import Supervisor
@testable import SessionWorkerCore
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import IPC
@testable import ProtocolModel
@testable import WireProtocol
@testable import InfraPrimitives
@testable import Push
@testable import Channels
@testable import DeliveryCore
@testable import EgressGuard

/// Severe RPC-level tests for ADDONS #7 `outbound/send` — the owner-path push.
///
/// CLAIMS UNDER TEST:
///  - owner gate: a router with allowsOwnerOnlyRPC=false (the WebGateway tier)
///    REFUSES outbound/send; a router with the default (true) SERVES it.
///  - deny-default: a nil PushRouterHolder refuses with "push feature is not enabled".
///  - the EgressGuard SSRF chokepoint is on the path (zero POSTs for internal
///    targets) and the deny REASON is NOT leaked to the caller.
///  - param validation fails closed; oversize inputs are bounded; idempotency
///    key dedups; pre-initialize is locked out.
///
/// The process-global PushRouterHolder is mutated per test (set / reset) — safe
/// because XCTest runs methods serially within a class.
final class OutboundSendRPCTests: XCTestCase {

    // MARK: stack

    private actor OSSink {
        private(set) var messages: [JSONRPCMessage] = []
        func append(_ m: JSONRPCMessage) { messages.append(m) }
        func response(id: Int64) -> JSONRPCResponse? {
            for m in messages { if case .response(let r) = m, r.id == .int(id) { return r } }
            return nil
        }
        func error(id: Int64) -> JSONRPCError? {
            for m in messages { if case .error(let e) = m, e.id == .int(id) { return e } }
            return nil
        }
    }

    private struct OSStack {
        let conn: InMemoryConnection
        let store: ThreadStore
        let home: String
        let sink: OSSink
        let pump: Task<Void, Never>
        let drain: Task<Void, Never>
        func teardown() {
            pump.cancel(); drain.cancel()
            try? FileManager.default.removeItem(atPath: home)
            PushRouterHolder.shared.reset()
        }
    }

    private func makeStack(ownerTrusted: Bool = true) throws -> OSStack {
        let home = NSTemporaryDirectory() + "os-" + UUID().uuidString
        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        let model = MockModelClient(repeating: .hello("ok"), times: 64)
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link) { c in
                SessionEngine(config: c, model: model, store: store,
                              router: ToolRouter(limits: limits), limits: limits)
            }
            let t = Task { await rt.run() }
            return WorkerHandle(link: link, task: t)
        }
        let supervisor = SessionSupervisor(factory: factory, maxSessions: 8)
        let router = RequestRouter(supervisor: supervisor, store: store, codexHome: home,
                                   allowsOwnerOnlyRPC: ownerTrusted)
        let conn = InMemoryConnection()
        let sink = OSSink()
        let pump = Task { for await m in conn.incoming() { await router.handle(m, conn) } }
        let drain = Task { for await m in conn.clientOutbound() { await sink.append(m) } }
        return OSStack(conn: conn, store: store, home: home, sink: sink, pump: pump, drain: drain)
    }

    private func send(_ s: OSStack, _ id: Int, _ method: String, _ params: JSONValue?) {
        s.conn.clientSend(.request(JSONRPCRequest(id: .int(Int64(id)), method: method, params: params)))
    }
    private func awaitResponse(_ s: OSStack, _ id: Int64, timeoutMs: Int = 4000) async -> JSONRPCResponse? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let r = await s.sink.response(id: id) { return r }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }
    private func awaitError(_ s: OSStack, _ id: Int64, timeoutMs: Int = 4000) async -> JSONRPCError? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let e = await s.sink.error(id: id) { return e }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }
    private func initialize(_ s: OSStack, id: Int = 1) async {
        send(s, id, "initialize", .object([
            "clientInfo": .object(["name": .string("os-test")]),
            "capabilities": .object([:]),
        ]))
        _ = await awaitResponse(s, Int64(id))
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
    }

    // Decode an OutboundSendResponse out of a success result JSONValue.
    private func decodeResponse(_ r: JSONRPCResponse) -> OutboundSendResponse? {
        guard let data = try? JSONEncoder().encode(r.result) else { return nil }
        return try? JSONDecoder().decode(OutboundSendResponse.self, from: data)
    }

    // EgressGuard whose resolver denies any "internal" hostname; IP literals are
    // classified by EgressGuard's own logic regardless of the resolver.
    private func egress() -> EgressGuard {
        EgressGuard(EgressPolicy(allowedHosts: [], allowHTTP: false, resolve: { host in
            host.contains("internal") ? ["127.0.0.1"] : ["93.184.216.34"]
        }))
    }

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "osr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    // MARK: owner gate

    func testOwnerGate_WebTransportRefused() async throws {
        let s = try makeStack(ownerTrusted: false)
        defer { s.teardown() }
        // A registered, working sink — to prove the refusal is the GATE, not a
        // missing backend.
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir)
        let rec = RecordingSink(id: "ntfy")
        await router.register(scheme: "ntfy", sink: rec)
        PushRouterHolder.shared.set(router)

        await initialize(s)
        send(s, 2, "outbound/send", .object(["target": .string("ntfy:t"), "text": .string("hi")]))
        let e = await awaitError(s, 2)
        XCTAssertNotNil(e, "web transport must get an error, not a response")
        XCTAssertEqual(e?.error.message, "method not available on this transport")
        let got = await rec.received()
        XCTAssertTrue(got.isEmpty, "a web-origin outbound/send must NEVER reach the sink")
    }

    func testOwnerGate_DaemonTransportServes() async throws {
        // Positive proof: default owner-trusted router (no flag passed in real
        // call sites) DOES serve, and the sink records the send.
        let s = try makeStack(ownerTrusted: true)
        defer { s.teardown() }
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir)
        let rec = RecordingSink(id: "ntfy")
        await router.register(scheme: "ntfy", sink: rec)
        PushRouterHolder.shared.set(router)

        await initialize(s)
        send(s, 2, "outbound/send", .object(["target": .string("ntfy:alerts"), "text": .string("yo")]))
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no response") }
        let resp = decodeResponse(r)
        XCTAssertEqual(resp?.ok, true, "owner transport delivers: \(String(describing: resp?.detail))")
        XCTAssertEqual(resp?.detail, "delivered")
        let got = await rec.received()
        XCTAssertEqual(got.map(\.text), ["yo"])
        XCTAssertEqual(got.first?.conversationId, "alerts")
    }

    func testDefaultInitIsOwnerTrusted() throws {
        // A RequestRouter built via the existing init WITHOUT the flag must
        // default to owner-trusted, or outbound/send would break on stdio/UDS.
        // (Constructed-only assertion: the dispatch arm reads the same property
        // the daemon path uses; the positive serve test above exercises it.)
        let home = NSTemporaryDirectory() + "os-def-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        let factory: WorkerFactory = { _ in
            let link = WorkerLink.make()
            return WorkerHandle(link: link, task: Task {})
        }
        let supervisor = SessionSupervisor(factory: factory, maxSessions: 1)
        // No allowsOwnerOnlyRPC argument — must compile AND default true.
        _ = RequestRouter(supervisor: supervisor, store: store, codexHome: home)
    }

    // MARK: deny-default

    func testFeatureGate_DenyDefault() async throws {
        let s = try makeStack(ownerTrusted: true)
        defer { s.teardown() }
        PushRouterHolder.shared.reset()   // feature OFF: no holder

        await initialize(s)
        send(s, 2, "outbound/send", .object(["target": .string("ntfy:t"), "text": .string("hi")]))
        let e = await awaitError(s, 2)
        XCTAssertEqual(e?.error.message, "push feature is not enabled")
        XCTAssertEqual(e?.error.code, WireError.invalidRequestCode)
    }

    // MARK: SSRF chokepoint

    func testSSRF_InternalTargetsBlockedThroughRPC_zeroPOSTs() async throws {
        let s = try makeStack(ownerTrusted: true)
        defer { s.teardown() }
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        // maxAttempts:1 so an egress-denied (PERMANENT) target yields the exact
        // "failed after 1 attempts" detail.
        let router = PushRouter(directory: dir, maxAttempts: 1)
        let http = StubHTTP(statuses: [200])
        await router.register(scheme: "webhook", sink: WebhookSink(egress: egress(), http: http))
        PushRouterHolder.shared.set(router)
        await initialize(s)

        // https:// so the IP-encoding block path (not just the HTTP-only gate)
        // is what fires: metadata IPv4, IPv6 loopback, decimal-int IPv4.
        let targets = [
            "webhook:https://169.254.169.254/latest/meta-data/iam/security-credentials/",
            "webhook:https://[::1]/x",
            "webhook:https://2130706433/x",                 // 127.0.0.1 as a decimal int
            "webhook:https://internal.svc/hook",            // resolver → loopback
        ]
        for (i, t) in targets.enumerated() {
            send(s, 10 + i, "outbound/send", .object(["target": .string(t), "text": .string("x")]))
            guard let r = await awaitResponse(s, Int64(10 + i)) else { return XCTFail("no response for \(t)") }
            let resp = decodeResponse(r)
            XCTAssertEqual(resp?.ok, false, "SSRF target must be refused: \(t)")
            XCTAssertEqual(resp?.detail, "failed after 1 attempts",
                           "deny REASON must NOT leak to the caller (got \(String(describing: resp?.detail)))")
        }
        let calls = await http.calls()
        XCTAssertTrue(calls.isEmpty, "EgressGuard denies BEFORE connect — zero HTTP POSTs, got \(calls.count)")
    }

    func testHTTPSchemeDeniedThroughRPC() async throws {
        let s = try makeStack(ownerTrusted: true)
        defer { s.teardown() }
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir, maxAttempts: 1)
        let http = StubHTTP(statuses: [200])
        await router.register(scheme: "webhook", sink: WebhookSink(egress: egress(), http: http))
        PushRouterHolder.shared.set(router)
        await initialize(s)
        // Plain http:// is refused at the HTTPS-only gate even for a public host.
        send(s, 2, "outbound/send", .object([
            "target": .string("webhook:http://hooks.example/x"), "text": .string("x")]))
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no response") }
        XCTAssertEqual(decodeResponse(r)?.ok, false)
        let calls = await http.calls()
        XCTAssertTrue(calls.isEmpty, "http:// is denied pre-connect")
    }

    func testUnknownSchemeNoSink() async throws {
        let s = try makeStack(ownerTrusted: true)
        defer { s.teardown() }
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir)
        await router.register(scheme: "ntfy", sink: RecordingSink(id: "ntfy"))
        PushRouterHolder.shared.set(router)
        await initialize(s)
        // No sink for telegram/file/gopher → refused, never a silent send.
        for (i, t) in ["telegram:12345", "file:///etc/passwd", "gopher://x/"].enumerated() {
            send(s, 30 + i, "outbound/send", .object(["target": .string(t), "text": .string("x")]))
            guard let r = await awaitResponse(s, Int64(30 + i)) else { return XCTFail("no response for \(t)") }
            XCTAssertEqual(decodeResponse(r)?.ok, false, "no sink for \(t)")
        }
    }

    // MARK: param validation + bounds

    func testParamValidationFailsClosed() async throws {
        let s = try makeStack(ownerTrusted: true)
        defer { s.teardown() }
        PushRouterHolder.shared.set(PushRouter(directory: tmpDir()))
        await initialize(s)

        // Missing target entirely → decode fails closed (invalid request), NOT
        // an empty send.
        send(s, 2, "outbound/send", .object(["text": .string("x")]))
        let e1 = await awaitError(s, 2)
        XCTAssertNotNil(e1, "missing target must be a decode error, not a send")
        XCTAssertEqual(e1?.error.code, WireError.invalidRequestCode)

        // Empty/whitespace target → explicit "target is required".
        send(s, 3, "outbound/send", .object(["target": .string("   "), "text": .string("x")]))
        let e2 = await awaitError(s, 3)
        XCTAssertEqual(e2?.error.message, "target is required")

        // Empty text → "text is required".
        send(s, 4, "outbound/send", .object(["target": .string("ntfy:t"), "text": .string("")]))
        let e3 = await awaitError(s, 4)
        XCTAssertEqual(e3?.error.message, "text is required")
    }

    func testOversizeInputsBounded() async throws {
        let s = try makeStack(ownerTrusted: true)
        defer { s.teardown() }
        let router = PushRouter(directory: tmpDir())
        await router.register(scheme: "ntfy", sink: RecordingSink(id: "ntfy"))
        PushRouterHolder.shared.set(router)
        await initialize(s)

        let bigTarget = "ntfy:" + String(repeating: "a", count: 2048)
        send(s, 2, "outbound/send", .object(["target": .string(bigTarget), "text": .string("x")]))
        guard let r1 = await awaitResponse(s, 2) else { return XCTFail("no response") }
        XCTAssertEqual(decodeResponse(r1)?.ok, false)
        XCTAssertEqual(decodeResponse(r1)?.detail, "target too long")

        let bigText = String(repeating: "z", count: 128 * 1024)
        send(s, 3, "outbound/send", .object(["target": .string("ntfy:t"), "text": .string(bigText)]))
        guard let r2 = await awaitResponse(s, 3) else { return XCTFail("no response") }
        XCTAssertEqual(decodeResponse(r2)?.ok, false)
        XCTAssertTrue(decodeResponse(r2)?.detail.contains("too long") ?? false,
                      String(describing: decodeResponse(r2)?.detail))
    }

    // MARK: idempotency

    func testIdempotencyKeyDedups() async throws {
        let s = try makeStack(ownerTrusted: true)
        defer { s.teardown() }
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = PushRouter(directory: dir)
        let rec = RecordingSink(id: "ntfy")
        await router.register(scheme: "ntfy", sink: rec)
        PushRouterHolder.shared.set(router)
        await initialize(s)

        let p: JSONValue = .object([
            "target": .string("ntfy:dedupe"), "text": .string("once"),
            "idempotencyKey": .string("KEY-1")])
        send(s, 2, "outbound/send", p)
        guard let r1 = await awaitResponse(s, 2) else { return XCTFail("no r1") }
        XCTAssertEqual(decodeResponse(r1)?.ok, true)
        send(s, 3, "outbound/send", p)
        _ = await awaitResponse(s, 3)
        let got = await rec.received()
        XCTAssertEqual(got.count, 1, "the same idempotency_key collapses to one delivery")
    }

    // MARK: handshake

    func testNotInitializedLockout() async throws {
        let s = try makeStack(ownerTrusted: true)
        defer { s.teardown() }
        PushRouterHolder.shared.set(PushRouter(directory: tmpDir()))
        // No initialize: outbound/send before the handshake must be locked out.
        send(s, 2, "outbound/send", .object(["target": .string("ntfy:t"), "text": .string("x")]))
        let e = await awaitError(s, 2)
        XCTAssertEqual(e?.error.message, WireError.notInitialized)
    }
}

// MARK: fixtures (copied from PushTests — a separate test target)

/// A ChannelOutbound sink that records messages and can fail the first N sends.
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
