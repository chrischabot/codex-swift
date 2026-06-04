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
@testable import Channels

/// Severe tests for the ADDONS #1/#2 channels/* RPC family + the load-bearing
/// owner-gate security config. The process-global ChannelManagerHolder is
/// set/reset per test (XCTest runs methods serially within a class).
final class ChannelsRpcTests: XCTestCase {

    // MARK: stack

    private actor Sink {
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
    private struct Stack {
        let conn: InMemoryConnection
        let home: String
        let sink: Sink
        let pump: Task<Void, Never>
        let drain: Task<Void, Never>
        func teardown() {
            pump.cancel(); drain.cancel()
            try? FileManager.default.removeItem(atPath: home)
            ChannelManagerHolder.shared.reset()
        }
    }
    private func makeStack(ownerTrusted: Bool = true) throws -> Stack {
        let home = NSTemporaryDirectory() + "ch-" + UUID().uuidString
        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        let model = MockModelClient(repeating: .hello("ok"), times: 16)
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link) { c in
                SessionEngine(config: c, model: model, store: store,
                              router: ToolRouter(limits: limits), limits: limits)
            }
            return WorkerHandle(link: link, task: Task { await rt.run() })
        }
        let supervisor = SessionSupervisor(factory: factory, maxSessions: 4)
        let router = RequestRouter(supervisor: supervisor, store: store, codexHome: home,
                                   allowsOwnerOnlyRPC: ownerTrusted)
        let conn = InMemoryConnection()
        let sink = Sink()
        let pump = Task { for await m in conn.incoming() { await router.handle(m, conn) } }
        let drain = Task { for await m in conn.clientOutbound() { await sink.append(m) } }
        return Stack(conn: conn, home: home, sink: sink, pump: pump, drain: drain)
    }
    private func send(_ s: Stack, _ id: Int, _ method: String, _ params: JSONValue?) {
        s.conn.clientSend(.request(JSONRPCRequest(id: .int(Int64(id)), method: method, params: params)))
    }
    private func awaitResponse(_ s: Stack, _ id: Int64, ms: Int = 4000) async -> JSONRPCResponse? {
        let deadline = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < deadline {
            if let r = await s.sink.response(id: id) { return r }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }
    private func awaitError(_ s: Stack, _ id: Int64, ms: Int = 4000) async -> JSONRPCError? {
        let deadline = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < deadline {
            if let e = await s.sink.error(id: id) { return e }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }
    private func initialize(_ s: Stack) async {
        send(s, 1, "initialize", .object([
            "clientInfo": .object(["name": .string("ch-test")]),
            "capabilities": .object([:]),
        ]))
        _ = await awaitResponse(s, 1)
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
    }
    private func decodeStatuses(_ r: JSONRPCResponse) -> [ChannelStatusWire]? {
        guard let d = try? JSONEncoder().encode(r.result) else { return nil }
        return (try? JSONDecoder().decode(ChannelStatusListResponse.self, from: d))?.data
    }
    @discardableResult
    private func installManager(_ ids: [String]) async -> ChannelManager {
        let manager = ChannelManager(host: ChEchoHost())
        for id in ids { await manager.register(ChStubChannel(id: id)) }
        ChannelManagerHolder.shared.set(manager)
        return manager
    }

    // MARK: owner gate

    func testWebTierRefusedOnAllMethods() async throws {
        let s = try makeStack(ownerTrusted: false)   // the WebGateway tier
        defer { s.teardown() }
        let m = await installManager(["telegram"])
        await initialize(s)
        let methods: [(Int, String, JSONValue?)] = [
            (2, "channels/list", .object([:])),
            (3, "channels/start", .object(["id": .string("telegram")])),
            (4, "channels/stop", .object(["id": .string("telegram")])),
            (5, "channels/status", .object([:])),
        ]
        for (id, method, params) in methods {
            send(s, id, method, params)
            let e = await awaitError(s, Int64(id))
            XCTAssertEqual(e?.error.message, "method not available on this transport",
                           "\(method) must refuse on the web tier")
        }
        // The channel was never started by a web-tier caller.
        let st = await m.status("telegram")
        XCTAssertEqual(st?.state, .stopped, "a web-tier channels/start must not start a channel")
    }

    // MARK: deny-default

    func testDenyDefaultNoHolder() async throws {
        let s = try makeStack(); defer { s.teardown() }
        ChannelManagerHolder.shared.reset()   // channels OFF
        await initialize(s)
        send(s, 2, "channels/list", .object([:]))
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no list response") }
        XCTAssertEqual(decodeStatuses(r)?.count, 0, "no holder → empty, not an error")
        send(s, 3, "channels/start", .object(["id": .string("telegram")]))
        let e = await awaitError(s, 3)
        XCTAssertEqual(e?.error.message, "channels feature is not enabled")
    }

    // MARK: list / status / start / stop

    func testListReturnsRegisteredChannels() async throws {
        let s = try makeStack(); defer { s.teardown() }
        _ = await installManager(["telegram"])
        await initialize(s)
        send(s, 2, "channels/list", nil)   // absent params → default
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no list response") }
        let statuses = decodeStatuses(r)
        XCTAssertEqual(statuses?.map(\.id), ["telegram"])
        XCTAssertEqual(statuses?.first?.state, "stopped", "registered but not started")
    }

    func testStatusFiltersById() async throws {
        let s = try makeStack(); defer { s.teardown() }
        _ = await installManager(["telegram", "other"])
        await initialize(s)
        send(s, 2, "channels/status", .object(["id": .string("telegram")]))
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no status response") }
        XCTAssertEqual(decodeStatuses(r)?.map(\.id), ["telegram"], "filtered to the requested id")
    }

    func testStartUnknownChannelRejected() async throws {
        let s = try makeStack(); defer { s.teardown() }
        _ = await installManager(["telegram"])
        await initialize(s)
        send(s, 2, "channels/start", .object(["id": .string("nope")]))
        let e = await awaitError(s, 2)
        XCTAssertEqual(e?.error.message, "unknown channel 'nope'")
    }

    func testStartThenStop() async throws {
        let s = try makeStack(); defer { s.teardown() }
        let m = await installManager(["telegram"])
        await initialize(s)
        send(s, 2, "channels/start", .object(["id": .string("telegram")]))
        _ = await awaitResponse(s, 2)
        // It transitions out of .stopped (starting/running).
        var started = false
        for _ in 0..<100 {
            if let st = await m.status("telegram"), st.state != .stopped { started = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(started, "channels/start moved the channel out of .stopped")
        send(s, 3, "channels/stop", .object(["id": .string("telegram")]))
        _ = await awaitResponse(s, 3)
        let st = await m.status("telegram")
        XCTAssertEqual(st?.state, .stopped, "channels/stop returns it to .stopped")
    }

    // MARK: THE security config (process-agnostic owner gate)

    func testChannelSessionConfigOwnerVsNonOwner() {
        // CLAIM: the owner-gate is enforced via SessionConfig (which crosses to a
        // spawned worker), NOT only the in-process ChannelAuthorityBox. A
        // non-owner sender's turn is locked down so it can't escalate even in the
        // default spawned mode.
        let owner = ChannelGlue.channelSessionConfig(
            threadId: "t1", senderIsOwner: true, defaultCwd: "/tmp", defaultModel: "m")
        XCTAssertEqual(owner.approvalPolicy, .default, "owner → normal approval")
        XCTAssertEqual(owner.sandboxMode, .workspaceWrite)
        XCTAssertEqual(owner.threadId.raw, "t1", "durable thread, not ephemeral")
        XCTAssertFalse(owner.ephemeral)

        let nonOwner = ChannelGlue.channelSessionConfig(
            threadId: "t1", senderIsOwner: false, defaultCwd: "/tmp", defaultModel: "m")
        XCTAssertEqual(nonOwner.approvalPolicy, .never,
                       "non-owner → .never (privileged tools denied inline, no unanswerable prompt)")
        XCTAssertEqual(nonOwner.sandboxMode, .readOnly, "non-owner → read-only (no writes)")
        XCTAssertFalse(nonOwner.networkAccess, "non-owner → no network egress")
        XCTAssertFalse(nonOwner.ephemeral, "conversation continuity is preserved")
        XCTAssertEqual(nonOwner.threadId.raw, "t1")
    }
}

// MARK: fixtures

/// A no-op host that echoes (we only exercise the manager's run-state, not turns).
private actor ChEchoHost: ChannelHost {
    func deliver(_ msg: InboundMessage) async -> ChannelReply {
        ChannelReply(text: "echo", status: "completed")
    }
}

/// A channel whose start() blocks (cancellation-aware) so the manager sees it as
/// running until stopped.
private actor ChStubChannel: Channel {
    nonisolated let id: String
    init(id: String) { self.id = id }
    func start(_ host: any ChannelHost) async throws {
        while !Task.isCancelled { try await Task.sleep(for: .milliseconds(50)) }
    }
    func stop() async {}
}
