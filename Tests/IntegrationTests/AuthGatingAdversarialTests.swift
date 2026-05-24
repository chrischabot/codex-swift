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

/// Single-consumer drain of an InMemoryConnection's outbound stream.
private actor AGSink {
    private(set) var messages: [JSONRPCMessage] = []
    func append(_ m: JSONRPCMessage) { messages.append(m) }
    func error(id: Int64) -> JSONRPCError? {
        for m in messages { if case .error(let e) = m, e.id == .int(id) { return e } }
        return nil
    }
    func response(id: Int64) -> JSONRPCResponse? {
        for m in messages { if case .response(let r) = m, r.id == .int(id) { return r } }
        return nil
    }
    func count() -> Int { messages.count }
    func errorsWithMessage(_ s: String) -> Int {
        messages.reduce(0) {
            if case .error(let e) = $1, e.error.message == s { return $0 + 1 }
            return $0
        }
    }
}

private struct AGStack {
    let conn: InMemoryConnection
    let supervisor: SessionSupervisor
    let store: ThreadStore
    let home: String
    let sink: AGSink
    let pump: Task<Void, Never>
    let drain: Task<Void, Never>
}

private func agMakeStack(maxSessions: Int = 1024) throws -> AGStack {
    let home = NSTemporaryDirectory() + "ag-" + UUID().uuidString
    let limits = Limits()
    let store = try ThreadStore(codexHome: home, limits: limits)
    let model = MockModelClient(repeating: .hello("ok"), times: 4096)
    let factory: WorkerFactory = { cfg in
        let link = WorkerLink.make()
        let rt = WorkerRuntime(link: link) { c in
            SessionEngine(config: c, model: model, store: store,
                          router: ToolRouter(limits: limits), limits: limits)
        }
        let t = Task { await rt.run() }
        return WorkerHandle(link: link, task: t)
    }
    let supervisor = SessionSupervisor(factory: factory, maxSessions: maxSessions)
    let router = RequestRouter(supervisor: supervisor, store: store, codexHome: home)
    let conn = InMemoryConnection()
    let sink = AGSink()
    let pump = Task { for await m in conn.incoming() { await router.handle(m, conn) } }
    let drain = Task { for await m in conn.clientOutbound() { await sink.append(m) } }
    return AGStack(conn: conn, supervisor: supervisor, store: store,
                   home: home, sink: sink, pump: pump, drain: drain)
}

private func agSend(_ s: AGStack, _ id: Int, _ method: String, _ params: JSONValue?) {
    s.conn.clientSend(.request(JSONRPCRequest(id: .int(Int64(id)),
                                              method: method, params: params)))
}
private func agAwaitResponse(_ s: AGStack, _ id: Int64,
                             timeoutMs: Int = 4000) async -> JSONRPCResponse? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if let r = await s.sink.response(id: id) { return r }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}
private func agAwaitError(_ s: AGStack, _ id: Int64,
                          timeoutMs: Int = 4000) async -> JSONRPCError? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        if let e = await s.sink.error(id: id) { return e }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}
private func agInitialize(_ s: AGStack, experimental: Bool = false,
                          id: Int = 1) async {
    agSend(s, id, "initialize", .object([
        "clientInfo": .object(["name": .string("adv")]),
        "capabilities": .object(["experimentalApi": .bool(experimental)]),
    ]))
    _ = await agAwaitResponse(s, Int64(id))
    s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
}

final class AuthGatingAdversarialTests: XCTestCase {

    func testPreInitializeLockoutForEveryPrivilegedMethod() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        let methods = [
            "thread/start", "thread/resume", "thread/list", "thread/read",
            "thread/rollback", "thread/goal/set", "thread/goal/get",
            "turn/start", "turn/steer", "turn/interrupt", "thread/compact/start",
            "thread/shellCommand", "review/start", "model/list", "config/read",
            "skills/list", "mcpServerStatus/list", "process/spawn",
            "fs/readFile", "command/exec", "account/read",
        ]
        for (i, m) in methods.enumerated() {
            agSend(s, 100 + i, m, .object([:]))
        }
        for (i, _) in methods.enumerated() {
            guard let e = await agAwaitError(s, Int64(100 + i)) else {
                return XCTFail("no error for \(methods[i]) pre-initialize")
            }
            XCTAssertEqual(e.error.message, "Not initialized",
                           "\(methods[i]) must be locked out before initialize")
        }
    }

    func testDoubleInitializeRejectedAndNoCapabilityElevation() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s, experimental: false, id: 1)
        // Second initialize attempting to elevate to experimentalApi:true.
        agSend(s, 2, "initialize", .object([
            "clientInfo": .object(["name": .string("adv")]),
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ]))
        guard let e = await agAwaitError(s, 2) else {
            return XCTFail("double initialize must error")
        }
        XCTAssertEqual(e.error.message, "Already initialized")
        // Experimental method still gated → caps were NOT elevated.
        agSend(s, 3, "process/spawn", .object([:]))
        guard let g = await agAwaitError(s, 3) else {
            return XCTFail("expected experimental gate error")
        }
        XCTAssertEqual(g.error.message, "process/spawn requires experimentalApi capability")
    }

    func testExperimentalGatingNotBypassable() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s, experimental: false)
        // Exact experimental method → gated.
        agSend(s, 10, "process/spawn", .object([:]))
        let gate1 = await agAwaitError(s, 10)?.error.message
        XCTAssertEqual(gate1, "process/spawn requires experimentalApi capability")
        // Case / whitespace variants are NOT the method → -32601 (no bypass
        // to dispatch, and definitely not silently allowed).
        for (i, variant) in ["Process/Spawn", "process/spawn ", " process/spawn",
                             "process//spawn", "PROCESS/SPAWN"].enumerated() {
            agSend(s, 20 + i, variant, .object([:]))
            guard let e = await agAwaitError(s, Int64(20 + i)) else {
                return XCTFail("no error for variant \(variant)")
            }
            XCTAssertEqual(e.error.code, -32601,
                           "\(variant) must be unsupported, never dispatched")
        }
        // Another experimental method is also gated.
        agSend(s, 30, "thread/turns/list", .object(["threadId": .string("t")]))
        let gate2 = await agAwaitError(s, 30)?.error.message
        XCTAssertEqual(gate2, "thread/turns/list requires experimentalApi capability")
    }

    func testWireBoundaryThreadIdTraversalRejected() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s)
        let marker = "ag_pwn_\(UUID().uuidString)"
        let evil = "../../../../tmp/\(marker)"
        let probes: [(String, JSONValue)] = [
            ("thread/resume", .object(["threadId": .string(evil)])),
            ("thread/read", .object(["threadId": .string(evil)])),
            ("thread/rollback", .object(["threadId": .string(evil), "numTurns": .int(1)])),
            ("thread/goal/get", .object(["threadId": .string(evil)])),
            ("turn/start", .object(["threadId": .string(evil),
                                    "input": .array([])])),
        ]
        for (i, (m, p)) in probes.enumerated() {
            agSend(s, 200 + i, m, p)
            guard let e = await agAwaitError(s, Int64(200 + i)) else {
                return XCTFail("no rejection for \(m) with traversal id")
            }
            XCTAssertEqual(e.error.message, "invalid threadId",
                           "\(m) must reject a path-traversal threadId at the boundary")
        }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: "/tmp/\(marker).rollout.jsonl"),
            "no file may be created outside CODEX_HOME via a wire threadId")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/\(marker)"))
    }

    func testSessionFloodAdmissionControl() async throws {
        let s = try agMakeStack(maxSessions: 3)
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s)
        for i in 0..<12 { agSend(s, 300 + i, "thread/start",
                                 .object(["cwd": .string("/w")])) }
        var ok = 0
        var overloaded = 0
        for i in 0..<12 {
            if await agAwaitResponse(s, Int64(300 + i), timeoutMs: 3000) != nil {
                ok += 1
            } else if let e = await s.sink.error(id: Int64(300 + i)) {
                if e.error.code == -32001 { overloaded += 1 }
            }
        }
        XCTAssertLessThanOrEqual(ok, 3, "no more than maxSessions bind")
        XCTAssertGreaterThanOrEqual(overloaded, 1,
                                    "excess thread/start is shed with -32001")
        let bound = await s.supervisor.atCapacity()
        XCTAssertTrue(bound, "supervisor reports at-capacity under the flood")
    }

    func testTypeConfusedAndOversizeParamsHandledCleanly() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s)
        // params as array, threadId as number, input as string, giant method.
        agSend(s, 400, "turn/start", .array([.int(1), .int(2)]))
        agSend(s, 401, "turn/start", .object(["threadId": .int(123),
                                              "input": .string("not-an-array")]))
        agSend(s, 402, "thread/goal/set",
               .object(["threadId": .string("t"),
                        "objective": .array([.bool(true)])]))
        let giant = String(repeating: "a", count: 20_000)
        agSend(s, 403, giant, .object([:]))
        for id in [400, 401, 402, 403] {
            // Either a clean JSON-RPC error or (for 402's well-formed id) a
            // response — never a crash / wedge.
            let gotErr = await agAwaitError(s, Int64(id), timeoutMs: 2500) != nil
            let gotResp = await s.sink.response(id: Int64(id)) != nil
            XCTAssertTrue(gotErr || gotResp,
                          "request \(id) produced a clean reply (no wedge)")
        }
        // Router still healthy afterward.
        agSend(s, 410, "model/list", .object([:]))
        let healthyResp = await agAwaitResponse(s, 410)
        XCTAssertNotNil(healthyResp,
                        "router remains responsive after malformed barrage")
    }

    func testNotificationFloodDoesNotWedgeRouter() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s)
        for _ in 0..<5000 {
            s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
            s.conn.clientSend(.notification(JSONRPCNotification(
                method: "garbage/\(UUID().uuidString)")))
        }
        agSend(s, 500, "thread/start", .object(["cwd": .string("/w")]))
        let postFloodResp = await agAwaitResponse(s, 500, timeoutMs: 6000)
        XCTAssertNotNil(postFloodResp,
                        "router still serves requests after a notification flood")
    }
}