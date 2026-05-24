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

final class ResumeTests: XCTestCase {

    func testResumeAfterQuiesceReconstructsAndContinues() async throws {
        let home = NSTemporaryDirectory() + "resume-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        let model = MockModelClient(repeating: .hello("persisted answer"), times: 8)
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link) { c in
                SessionEngine(config: c, model: model, store: store,
                              router: ToolRouter(limits: limits), limits: limits)
            }
            let t = Task { await rt.run() }
            return WorkerHandle(link: link, task: t)
        }
        let supervisor = SessionSupervisor(factory: factory)
        let router = RequestRouter(supervisor: supervisor, store: store, codexHome: home)
        let conn = InMemoryConnection()
        let pump = Task { for await m in conn.incoming() { await router.handle(m, conn) } }
        defer { pump.cancel() }

        func send(_ id: Int, _ method: String, _ params: JSONValue?) {
            conn.clientSend(.request(JSONRPCRequest(id: .int(Int64(id)), method: method, params: params)))
        }
        func awaitResponse(_ id: Int) async -> JSONRPCResponse? {
            for await m in conn.clientOutbound() {
                if case .response(let r) = m, r.id == .int(Int64(id)) { return r }
            }
            return nil
        }
        func awaitTurnCompleted() async {
            for await m in conn.clientOutbound() {
                if case .notification(let n) = m, n.method == "turn/completed" { return }
            }
        }

        // initialize + thread/start
        send(1, "initialize", .object(["clientInfo": .object(["name": .string("t")])]))
        _ = await awaitResponse(1)
        conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
        send(2, "thread/start", .object(["cwd": .string("/work")]))
        guard let startResp = await awaitResponse(2),
              let env = try? JSONBridge.decode(ThreadResultEnvelope.self, from: startResp.result) else {
            return XCTFail("thread/start failed")
        }
        let tid = env.thread.id

        // Run a turn; it persists a user + assistant message durably.
        send(3, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"), "text": .string("remember this")])]),
        ]))
        _ = await awaitResponse(3)
        await awaitTurnCompleted()

        // Quiesce = idle-unload/pause. Worker is released; state is on disk.
        await supervisor.quiesce(tid)
        let boundAfterQuiesce = await supervisor.isBound(tid)
        XCTAssertFalse(boundAfterQuiesce, "worker unbound after quiesce")

        // Disk is the source of truth: reconstruction shows prior history.
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .agentMessage(_, let t) = $0 { return t == "persisted answer" }; return false
        }, "prior assistant message must survive the unload")
        XCTAssertEqual(rebuilt.lastTurnStatus, .completed)

        // thread/resume rebinds a fresh worker from disk …
        send(4, "thread/resume", .object(["threadId": .string(tid.raw)]))
        guard let resumeResp = await awaitResponse(4),
              let renv = try? JSONBridge.decode(ThreadResultEnvelope.self, from: resumeResp.result) else {
            return XCTFail("thread/resume failed")
        }
        XCTAssertEqual(renv.thread.id, tid)
        let boundAfterResume = await supervisor.isBound(tid)
        XCTAssertTrue(boundAfterResume, "worker rebound after resume")

        // … and a subsequent turn continues on the resumed session.
        send(5, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"), "text": .string("continue")])]),
        ]))
        _ = await awaitResponse(5)
        await awaitTurnCompleted()
        let finalRebuilt = try await store.reconstruct(tid)
        let userMsgs = finalRebuilt.items.filter { if case .userMessage = $0 { return true }; return false }
        XCTAssertGreaterThanOrEqual(userMsgs.count, 2, "history accumulates across resume (continuity)")
    }

    func testThreadUnsubscribeIdleUnloadQuiescesAndResumeReconstructs() async throws {
        let home = NSTemporaryDirectory() + "unsubscribe-idle-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        var configuredLimits = Limits()
        configuredLimits.idleUnload = .seconds(1)
        configuredLimits.heartbeatInterval = .milliseconds(50)
        configuredLimits.watchdogMissedHeartbeats = 2
        let limits = configuredLimits
        let store = try ThreadStore(codexHome: home, limits: limits)
        let model = MockModelClient(repeating: .hello("idle persisted"), times: 8)
        let terminations = Counter()
        let factory: WorkerFactory = { cfg in
            let link = WorkerLink.make()
            let rt = WorkerRuntime(link: link, heartbeatInterval: .milliseconds(20)) { c in
                SessionEngine(config: c, model: model, store: store,
                              router: ToolRouter(limits: limits), limits: limits)
            }
            let task = Task { await rt.run() }
            return WorkerHandle(link: link, task: task, terminate: {
                Task { await terminations.inc() }
            })
        }
        let supervisor = SessionSupervisor(factory: factory, limits: limits)
        let router = RequestRouter(supervisor: supervisor, store: store, codexHome: home)
        let conn = InMemoryConnection()
        let pump = Task { for await m in conn.incoming() { await router.handle(m, conn) } }
        defer { pump.cancel() }

        func send(_ id: Int, _ method: String, _ params: JSONValue?) {
            conn.clientSend(.request(JSONRPCRequest(id: .int(Int64(id)), method: method, params: params)))
        }
        func awaitResponse(_ id: Int) async -> JSONRPCResponse? {
            for await m in conn.clientOutbound() {
                if case .response(let r) = m, r.id == .int(Int64(id)) { return r }
            }
            return nil
        }
        func awaitTurnCompleted() async {
            for await m in conn.clientOutbound() {
                if case .notification(let n) = m, n.method == "turn/completed" { return }
            }
        }

        send(1, "initialize", .object(["clientInfo": .object(["name": .string("idle")])]))
        _ = await awaitResponse(1)
        conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
        send(2, "thread/start", .object(["cwd": .string(home)]))
        guard let startResp = await awaitResponse(2),
              let env = try? JSONBridge.decode(ThreadResultEnvelope.self, from: startResp.result) else {
            return XCTFail("thread/start failed")
        }
        let tid = env.thread.id

        send(3, "thread/resume", .object(["threadId": .string(tid.raw)]))
        _ = await awaitResponse(3)
        let subscribersAfterDuplicateResume = await supervisor.subscriberCount(tid)
        XCTAssertEqual(subscribersAfterDuplicateResume, 1,
                       "one connection must not duplicate-subscribe to a thread")

        send(4, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"), "text": .string("persist before idle")])]),
        ]))
        _ = await awaitResponse(4)
        await awaitTurnCompleted()

        send(5, "thread/unsubscribe", .object(["threadId": .string(tid.raw)]))
        guard let unsubResp = await awaitResponse(5),
              let unsub = try? JSONBridge.decode(ThreadUnsubscribeResponse.self, from: unsubResp.result) else {
            return XCTFail("thread/unsubscribe failed")
        }
        XCTAssertEqual(unsub.status, .unsubscribed)
        let subscribersAfterUnsubscribe = await supervisor.subscriberCount(tid)
        XCTAssertEqual(subscribersAfterUnsubscribe, 0)

        let unloaded = await eventually(timeoutMs: 2_500) {
            await supervisor.isBound(tid) == false
        }
        XCTAssertTrue(unloaded, "idle-unsubscribed worker should quiesce and unload")
        let terminationCount = await terminations.value()
        XCTAssertEqual(terminationCount, 0,
                       "graceful idle unload should not use hard terminate")
        let rebuilt = try await store.reconstruct(tid)
        XCTAssertTrue(rebuilt.items.contains {
            if case .agentMessage(_, let text) = $0 { return text == "idle persisted" }
            return false
        }, "durable history must survive idle unload")

        send(6, "thread/resume", .object(["threadId": .string(tid.raw)]))
        guard let resumeResp = await awaitResponse(6),
              let renv = try? JSONBridge.decode(ThreadResultEnvelope.self, from: resumeResp.result) else {
            return XCTFail("thread/resume after idle unload failed")
        }
        XCTAssertEqual(renv.thread.id, tid)
        let rebound = await supervisor.isBound(tid)
        XCTAssertTrue(rebound, "resume should bind a fresh worker")

        send(7, "turn/start", .object([
            "threadId": .string(tid.raw),
            "input": .array([.object(["type": .string("text"), "text": .string("continue after idle")])]),
        ]))
        _ = await awaitResponse(7)
        await awaitTurnCompleted()
        let final = try await store.reconstruct(tid)
        let userMessages = final.items.filter { if case .userMessage = $0 { return true }; return false }
        XCTAssertGreaterThanOrEqual(userMessages.count, 2,
                                    "resumed worker should continue the durable thread")
    }
}

private actor Counter {
    private var n = 0
    func inc() { n += 1 }
    func value() -> Int { n }
}

private func eventually(timeoutMs: Int = 2_000,
                        intervalMs: UInt64 = 20,
                        _ predicate: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(intervalMs))
    }
    return await predicate()
}
