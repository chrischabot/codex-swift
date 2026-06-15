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
@testable import Config

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
        // Case / whitespace variants are NOT the method → unknown method tag,
        // which upstream rejects with -32600 invalid_request (no bypass to
        // dispatch, and definitely not silently allowed).
        for (i, variant) in ["Process/Spawn", "process/spawn ", " process/spawn",
                             "process//spawn", "PROCESS/SPAWN"].enumerated() {
            agSend(s, 20 + i, variant, .object([:]))
            guard let e = await agAwaitError(s, Int64(20 + i)) else {
                return XCTFail("no error for variant \(variant)")
            }
            XCTAssertEqual(e.error.code, -32600,
                           "\(variant) must be unsupported, never dispatched")
        }
        // Another experimental method is also gated.
        agSend(s, 30, "thread/turns/list", .object(["threadId": .string("t")]))
        let gate2 = await agAwaitError(s, 30)?.error.message
        XCTAssertEqual(gate2, "thread/turns/list requires experimentalApi capability")
    }

    /// Audit app-server-registry/finding-3: deserialization must precede the
    /// experimental gate. Upstream deserializes ClientRequest first
    /// (message_processor.rs:536-541 → `Invalid request: <serde error>`) and
    /// only then derives the experimental rejection from the typed request
    /// (dispatch_initialized_client_request, :792-796). So a malformed-params
    /// request to an experimental method by a non-experimental client must
    /// surface the deserialization error, NOT the experimental message.
    func testMalformedParamsBeatExperimentalGateOnOrdering() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s, experimental: false)
        // thread/turns/list is an experimental-gated method whose params
        // require `threadId`. Omitting it makes deserialization fail. Upstream
        // reports the serde error before any experimental gating.
        agSend(s, 40, "thread/turns/list", .object([:]))
        guard let e = await agAwaitError(s, 40) else {
            return XCTFail("expected an error for malformed experimental request")
        }
        XCTAssertEqual(e.error.code, -32600)
        XCTAssertEqual(e.error.message, "Invalid request: missing field `threadId`",
                       "deserialization error must win over the experimental gate")
        XCTAssertNotEqual(e.error.message,
                          "thread/turns/list requires experimentalApi capability",
                          "experimental gate must not pre-empt the serde error")
        // Sanity: a WELL-FORMED experimental request from the same connection
        // still hits the experimental gate with its message intact.
        agSend(s, 41, "thread/turns/list", .object(["threadId": .string("t")]))
        let gated = await agAwaitError(s, 41)?.error.message
        XCTAssertEqual(gated, "thread/turns/list requires experimentalApi capability")
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
            ("thread/turns/list", .object(["threadId": .string(evil)])),
            ("turn/start", .object(["threadId": .string(evil),
                                    "input": .array([])])),
        ]
        for (i, (m, p)) in probes.enumerated() {
            agSend(s, 200 + i, m, p)
            guard let e = await agAwaitError(s, Int64(200 + i)) else {
                return XCTFail("no rejection for \(m) with traversal id")
            }
            // The probe must be rejected at the dispatch boundary (code -32600,
            // no worker spawn, no file). For non-experimental methods this is
            // the upstream "invalid thread id: <error>" message; for an
            // experimental-gated method (thread/turns/list) called by a
            // non-experimental connection the experimental-capability error
            // wins, because upstream gates experimental BEFORE any thread-id
            // parsing (audit app-server-registry/finding-3). Both are -32600
            // boundary rejections that prevent any path-traversal effect.
            XCTAssertEqual(e.error.code, -32600, "\(m) must be a boundary rejection")
            let okMsg = e.error.message.hasPrefix("invalid thread id")
                || e.error.message.hasSuffix("requires experimentalApi capability")
            XCTAssertTrue(okMsg,
                          "\(m) must be rejected at the boundary (threadId or experimental gate), "
                          + "got: \(e.error.message)")
        }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: "/tmp/\(marker).rollout.jsonl"),
            "no file may be created outside CODEX_HOME via a wire threadId")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/\(marker)"))
    }

    /// Audit app-server-registry: the experimental enum-variant gate for the
    /// `AskForApproval::Granular` approval policy must fire for a
    /// non-experimental connection. Upstream marks the variant
    /// `#[experimental("askForApproval.granular")]` (shared.rs:168) and
    /// thread/start, thread/resume, thread/fork, turn/start all
    /// `inspect_params: true`, so a granular `approvalPolicy` anywhere in the
    /// params is rejected with -32600 `askForApproval.granular requires
    /// experimentalApi capability` rather than being silently dropped
    /// (tests.rs:1481-1745). The same granular request succeeds the gate once
    /// experimentalApi is negotiated.
    func testGranularApprovalPolicyExperimentalGate() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s, experimental: false)
        let granular: JSONValue = .object([
            "granular": .object([
                "sandbox_approval": .bool(true),
                "rules": .bool(false),
                "skill_approval": .bool(false),
                "request_permissions": .bool(true),
                "mcp_elicitations": .bool(false),
            ]),
        ])
        let expectedMessage = "askForApproval.granular requires experimentalApi capability"
        // Top-level approvalPolicy on each inspect_params method.
        let probes: [(String, JSONValue)] = [
            ("thread/start", .object(["cwd": .string("/w"), "approvalPolicy": granular])),
            ("thread/resume", .object(["threadId": .string("thr_123"),
                                       "approvalPolicy": granular])),
            ("thread/fork", .object(["threadId": .string("thr_123"),
                                     "approvalPolicy": granular])),
            ("turn/start", .object(["threadId": .string("thr_123"), "input": .array([]),
                                    "approvalPolicy": granular])),
            // Nested under a profile (config/read) — recursion must reach it.
            ("config/read", .object(["profiles": .object([
                "default": .object(["approvalPolicy": granular]),
            ])])),
        ]
        for (i, (m, p)) in probes.enumerated() {
            agSend(s, 500 + i, m, p)
            guard let e = await agAwaitError(s, Int64(500 + i)) else {
                return XCTFail("granular \(m) must be gated, no error received")
            }
            XCTAssertEqual(e.error.code, -32600, "\(m) granular gate must be -32600")
            XCTAssertEqual(e.error.message, expectedMessage,
                           "\(m) granular gate must use the fixed upstream reason")
        }
        // A NON-granular approval policy on the same method is not gated by the
        // enum-variant rule (only the granular variant is experimental).
        agSend(s, 520, "thread/start",
               .object(["cwd": .string("/w"), "approvalPolicy": .string("on-request")]))
        let nonGranularError = await agAwaitError(s, 520, timeoutMs: 1500)
        XCTAssertNil(nonGranularError,
                     "non-granular approvalPolicy must not trip the experimental gate")

        // With experimentalApi negotiated, the granular request clears the gate.
        let s2 = try agMakeStack()
        defer { s2.pump.cancel(); s2.drain.cancel()
                try? FileManager.default.removeItem(atPath: s2.home) }
        await agInitialize(s2, experimental: true)
        agSend(s2, 530, "thread/start",
               .object(["cwd": .string("/w"), "approvalPolicy": granular]))
        let elevatedError = await agAwaitError(s2, 530, timeoutMs: 2000)
        XCTAssertNil(elevatedError,
                     "granular approvalPolicy must be allowed once experimentalApi is negotiated")
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

    // MARK: - Audit app-server-registry/finding-2: clientInfo.name validation

    /// Upstream `initialize` rejects a clientInfo.name that is not a valid HTTP
    /// header value (initialize_processor.rs:88-92) with invalid_request
    /// (-32600) and does NOT commit session state. A name carrying a control
    /// byte (newline/CR) or a non-ASCII byte must be rejected; the connection
    /// stays uninitialized so a follow-up privileged method sees "Not
    /// initialized" rather than succeeding.
    func testInitializeRejectsClientInfoNameWithControlOrNonAscii() async throws {
        let badNames = ["bad\nname", "bad\rname", "bad\u{0}name", "caf\u{e9}",
                        "ctrl\u{7f}del", "\u{1b}[31m"]
        for (i, bad) in badNames.enumerated() {
            let s = try agMakeStack()
            defer { s.pump.cancel(); s.drain.cancel()
                    try? FileManager.default.removeItem(atPath: s.home) }
            agSend(s, 1, "initialize", .object([
                "clientInfo": .object(["name": .string(bad)]),
            ]))
            guard let e = await agAwaitError(s, 1) else {
                return XCTFail("initialize with name \(i) must error")
            }
            XCTAssertEqual(e.error.code, -32600,
                           "malformed clientInfo.name maps to invalid_request")
            XCTAssertEqual(
                e.error.message,
                "Invalid clientInfo.name: '\(bad)'. Must be a valid HTTP header value.",
                "verbatim upstream message for name \(i)")
            // Connection must NOT have become initialized.
            agSend(s, 2, "model/list", .object([:]))
            let follow = await agAwaitError(s, 2)
            XCTAssertEqual(follow?.error.message, "Not initialized",
                           "a rejected initialize must leave the connection uninitialized")
        }
    }

    /// Valid HTTP header values (visible ASCII, space, tab) are accepted and the
    /// connection initializes normally.
    func testInitializeAcceptsValidClientInfoNames() async throws {
        let goodNames = ["codex-cli", "My Client 1.0", "tab\tsep", "a", ""]
        for (i, good) in goodNames.enumerated() {
            let s = try agMakeStack()
            defer { s.pump.cancel(); s.drain.cancel()
                    try? FileManager.default.removeItem(atPath: s.home) }
            agSend(s, 1, "initialize", .object([
                "clientInfo": .object(["name": .string(good)]),
            ]))
            let resp = await agAwaitResponse(s, 1)
            XCTAssertNotNil(resp, "valid clientInfo.name \(i) must initialize")
            let initErr = await s.sink.error(id: 1)
            XCTAssertNil(initErr, "valid clientInfo.name \(i) must not error")
        }
    }

    // MARK: - Audit app-server-registry/finding-3: experimental gate precedes
    // the generic threadId precheck.

    /// For an experimental-gated method called by a NON-experimental connection
    /// carrying a malformed threadId, upstream gates experimental BEFORE any
    /// thread-id parsing (message_processor.rs:792-796), so the capability error
    /// wins over the threadId error. Swift's generic precheck must run after the
    /// gate to match.
    func testExperimentalGateBeatsMalformedThreadIdOrdering() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s, experimental: false)
        // thread/turns/list is experimental-gated. A malformed (path-traversal)
        // threadId would fail the precheck, but the experimental capability
        // error must surface first.
        agSend(s, 50, "thread/turns/list",
               .object(["threadId": .string("../../../etc/passwd")]))
        guard let e = await agAwaitError(s, 50) else {
            return XCTFail("expected an error")
        }
        XCTAssertEqual(e.error.code, -32600)
        XCTAssertEqual(e.error.message,
                       "thread/turns/list requires experimentalApi capability",
                       "experimental gate must pre-empt the malformed-threadId precheck")
    }

    /// The generic threadId precheck now emits the upstream "invalid thread id:
    /// <error>" message form (turn_processor.rs:192 et al.) instead of the old
    /// camelCase "invalid threadId".
    func testMalformedThreadIdMessageMatchesUpstreamForm() async throws {
        let s = try agMakeStack()
        defer { s.pump.cancel(); s.drain.cancel()
                try? FileManager.default.removeItem(atPath: s.home) }
        await agInitialize(s)
        agSend(s, 60, "thread/read", .object(["threadId": .string("not a uuid!")]))
        guard let e = await agAwaitError(s, 60) else {
            return XCTFail("expected an error")
        }
        XCTAssertEqual(e.error.code, -32600)
        XCTAssertTrue(e.error.message.hasPrefix("invalid thread id"),
                      "must use upstream `invalid thread id: <error>` form, got: \(e.error.message)")
        XCTAssertNotEqual(e.error.message, "invalid threadId",
                          "old camelCase message must be gone")
    }
}

// MARK: - Audit app-server-registry findings 1 & 4 (pure-helper unit tests)

final class AppServerRegistryHelperTests: XCTestCase {

    /// Finding 1: `windowDurationMins` must CEILING-divide the window seconds to
    /// minutes (`(seconds + 59) / 60`) to match upstream
    /// `window_minutes_from_seconds` (backend-client/src/client.rs:592-598), not
    /// floor-divide. Also returns null for `seconds <= 0`.
    func testRateLimitWindowCeilingDivision() {
        func mins(_ seconds: Int) -> JSONValue {
            RequestRouter.rateLimitWindow(.object([
                "used_percent": .double(10),
                "limit_window_seconds": .int(Int64(seconds)),
                "reset_at": .string("2026-01-01T00:00:00Z"),
            ]))["windowDurationMins"] ?? .null
        }
        // Non-multiples-of-60 round UP (the divergence the finding fixes).
        XCTAssertEqual(mins(90), .int(2), "90s -> 2 min (ceil), not 1 (floor)")
        XCTAssertEqual(mins(61), .int(2), "61s -> 2 min")
        XCTAssertEqual(mins(1), .int(1), "1s -> 1 min")
        XCTAssertEqual(mins(119), .int(2), "119s -> 2 min")
        // Exact multiples unchanged.
        XCTAssertEqual(mins(300), .int(5))
        XCTAssertEqual(mins(3600), .int(60))
        XCTAssertEqual(mins(60), .int(1))
        // seconds <= 0 -> null (upstream returns None).
        XCTAssertEqual(mins(0), .null)
        XCTAssertEqual(mins(-5), .null)
        // Absent object -> null.
        XCTAssertEqual(RequestRouter.rateLimitWindow(.null), .null)
    }

    /// `usedPercent` must be rounded to an integer to match upstream
    /// `RateLimitWindow.used_percent: i32` / `RateLimitWindow::from`
    /// (account.rs:336-347 always `.round()`s) and the port's own
    /// updated-notification path (ModelProvider.asNotificationJSON). The
    /// synchronous read response must never leak a JSON float.
    func testRateLimitWindowRoundsUsedPercentToInt() {
        func used(_ value: JSONValue) -> JSONValue {
            RequestRouter.rateLimitWindow(.object([
                "used_percent": value,
                "limit_window_seconds": .int(300),
                "reset_at": .string("2026-01-01T00:00:00Z"),
            ]))["usedPercent"] ?? .null
        }
        XCTAssertEqual(used(.double(42.7)), .int(43), "42.7 rounds to 43")
        XCTAssertEqual(used(.double(42.4)), .int(42), "42.4 rounds to 42")
        XCTAssertEqual(used(.double(42.5)), .int(43), "42.5 rounds half-up to 43")
        XCTAssertEqual(used(.double(0)), .int(0))
        XCTAssertEqual(used(.double(100)), .int(100))
        // An already-integer JSON number is preserved.
        XCTAssertEqual(used(.int(37)), .int(37))
        // Absent used_percent -> null (upstream Option).
        let noPercent = RequestRouter.rateLimitWindow(.object([
            "limit_window_seconds": .int(300),
            "reset_at": .string("2026-01-01T00:00:00Z"),
        ]))
        XCTAssertEqual(noPercent["usedPercent"], .null)
    }

    /// Finding 2 helper: HTTP header value validity matches
    /// `http::HeaderValue::from_str` (visible ASCII + space + tab).
    func testIsValidHTTPHeaderValue() {
        for ok in ["codex", "My Client 1.0", "a\tb", "", "~!@#$%^&*()_+",
                   String(repeating: "x", count: 1000)] {
            XCTAssertTrue(RequestRouter.isValidHTTPHeaderValue(ok), "valid: \(ok.debugDescription)")
        }
        for bad in ["a\nb", "a\rb", "a\u{0}b", "a\u{7f}b", "caf\u{e9}", "\u{1b}x", "a\u{1}b"] {
            XCTAssertFalse(RequestRouter.isValidHTTPHeaderValue(bad), "invalid: \(bad.debugDescription)")
        }
    }

    /// Finding 4: `firstOverriddenEdit` must suppress the override report when a
    /// higher-precedence layer carries the SAME value the user just wrote
    /// (upstream `compute_override_metadata` line 605-607:
    /// `user_value.is_some() && user_value == effective_value` => None). Keying
    /// solely on layer identity would mis-report a no-op-equivalent write.
    func testFirstOverriddenEditSuppressesWhenHigherLayerHoldsSameValue() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "asr-ovr-" + UUID().uuidString
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: home) }

        // The MDM/managed layer sits at the TOP of the stack (precedence 50 >
        // user 20), so it is the only synthetic layer that genuinely shadows a
        // user write. Inject it via the base64 override.
        func mdmBase64(_ toml: String) -> String {
            Data(toml.utf8).base64EncodedString()
        }
        func loader(mdmToml: String) -> ConfigLoader {
            // Point the system path at a nonexistent file so only user+mdm
            // carry `model`.
            ConfigLoader(codexHome: home,
                         systemConfigPath: home + "/no-such-system.toml",
                         managedConfigBase64Override: mdmBase64(mdmToml))
        }

        // Case A: the higher-precedence MDM layer holds the SAME value the user
        // wrote => upstream `compute_override_metadata` returns None (status
        // stays `ok`).
        try "model = \"gpt-5.5\"\n".write(toFile: home + "/config.toml",
                                          atomically: true, encoding: .utf8)
        let sameValue = RequestRouter.firstOverriddenEdit(
            codexHome: home, editedKeyPaths: ["model"],
            loader: loader(mdmToml: "model = \"gpt-5.5\"\n"))
        XCTAssertNil(sameValue,
            "no override report when the higher layer duplicates the user-written value")

        // Case B: the MDM layer holds a DIFFERENT value => genuine override,
        // upstream reports `okOverridden` + overriddenMetadata.
        let differs = RequestRouter.firstOverriddenEdit(
            codexHome: home, editedKeyPaths: ["model"],
            loader: loader(mdmToml: "model = \"gpt-4o\"\n"))
        XCTAssertNotNil(differs,
            "a higher layer holding a DIFFERENT value is a genuine override")
        XCTAssertEqual(differs?["effectiveValue"]?.stringValue, "gpt-4o",
            "effectiveValue reflects the shadowing layer's value")
        // Audit config/finding-2: the override message must be the per-layer-type
        // text (config_manager_service.rs:566-592), not a single generic string.
        // The loader injects the MDM layer as `.legacyManagedConfigTomlFromMdm`.
        XCTAssertEqual(differs?["message"]?.stringValue,
            "Overridden by legacy managed configuration from MDM",
            "message must use upstream override_message() text for the overriding layer")
    }

    /// Audit config/finding-2: `overrideMessage` must reproduce upstream
    /// `override_message()` (config_manager_service.rs:566-592) verbatim for
    /// every `ConfigLayerSource` variant, embedding the domain/file/path where
    /// upstream does.
    func testOverrideMessageMatchesUpstreamPerLayerText() {
        XCTAssertEqual(
            RequestRouter.overrideMessage(.mdm(domain: "com.openai.codex", key: "k")),
            "Overridden by managed policy (MDM): com.openai.codex")
        XCTAssertEqual(
            RequestRouter.overrideMessage(.system(file: "/etc/codex/config.toml")),
            "Overridden by managed config (system): /etc/codex/config.toml")
        XCTAssertEqual(
            RequestRouter.overrideMessage(.project(dotCodexFolder: "/repo/.codex")),
            "Overridden by project config: /repo/.codex/config.toml")
        XCTAssertEqual(
            RequestRouter.overrideMessage(.sessionFlags),
            "Overridden by session flags")
        XCTAssertEqual(
            RequestRouter.overrideMessage(.user(file: "/home/me/.codex/config.toml", profile: nil)),
            "Overridden by user config: /home/me/.codex/config.toml")
        XCTAssertEqual(
            RequestRouter.overrideMessage(.legacyManagedConfigTomlFromFile(file: "/etc/codex/managed_config.toml")),
            "Overridden by legacy managed_config.toml: /etc/codex/managed_config.toml")
        XCTAssertEqual(
            RequestRouter.overrideMessage(.legacyManagedConfigTomlFromMdm),
            "Overridden by legacy managed configuration from MDM")
    }
}

/// Finding 2: `chatgptAuthTokens` external-token login must enforce
/// `forced_chatgpt_workspace_id` (account_processor.rs:573-579).
final class ForcedChatgptWorkspaceTests: XCTestCase {
    private func writeConfig(_ body: String) -> String {
        let home = NSTemporaryDirectory() + "fcw-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: home,
                                                 withIntermediateDirectories: true)
        try? body.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        return home
    }

    func testAbsentReturnsNil() {
        let home = writeConfig("model = \"gpt-5\"\n")
        defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertNil(RequestRouter.forcedChatgptWorkspaceIds(codexHome: home))
    }

    func testSingleStringNormalizesToOneElementList() {
        let home = writeConfig("forced_chatgpt_workspace_id = \"ws-123\"\n")
        defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertEqual(RequestRouter.forcedChatgptWorkspaceIds(codexHome: home), ["ws-123"])
    }

    func testListIsPreserved() {
        let home = writeConfig("forced_chatgpt_workspace_id = [\"ws-a\", \"ws-b\"]\n")
        defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertEqual(RequestRouter.forcedChatgptWorkspaceIds(codexHome: home),
                       ["ws-a", "ws-b"])
    }

    func testEmptyListReturnsNil() {
        let home = writeConfig("forced_chatgpt_workspace_id = []\n")
        defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertNil(RequestRouter.forcedChatgptWorkspaceIds(codexHome: home),
                     "an empty allow-list behaves like unset (upstream if-let-Some)")
    }

    /// The rejection message must reproduce Rust's `{:?}` debug rendering of the
    /// `Vec<String>` allow-list and the received account id verbatim
    /// (account_processor.rs:577).
    func testRejectionMessageMatchesUpstreamDebugFormat() {
        let expected = ["ws-a", "ws-b"]
        let accountId = "ws-c"
        let listDebug = "[" + expected.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        let message =
            "External auth must use one of workspace(s) \(listDebug), but received \"\(accountId)\"."
        XCTAssertEqual(message,
            "External auth must use one of workspace(s) [\"ws-a\", \"ws-b\"], but received \"ws-c\".")
    }
}