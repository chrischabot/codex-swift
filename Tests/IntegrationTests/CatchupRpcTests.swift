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

/// Round-trip tests for the June-2026 upstream-sync wire methods
/// (`thread/delete`, `permissionProfile/list`, `skills/extraRoots/set`,
/// `account/usage/read`) and the `thread/deleted` notification. Mirrors the
/// CronRpcTests harness.
final class CatchupRpcTests: XCTestCase {

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
        func notifications(_ method: String) -> [JSONRPCNotification] {
            messages.compactMap { if case .notification(let n) = $0, n.method == method { return n }; return nil }
        }
    }
    private struct Stack {
        let conn: InMemoryConnection
        let home: String
        let store: ThreadStore
        let sink: Sink
        let pump: Task<Void, Never>
        let drain: Task<Void, Never>
        func teardown() {
            pump.cancel(); drain.cancel()
            try? FileManager.default.removeItem(atPath: home)
        }
    }
    private func makeStack() throws -> Stack {
        let home = NSTemporaryDirectory() + "catchup-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
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
                                   allowsOwnerOnlyRPC: true)
        let conn = InMemoryConnection()
        let sink = Sink()
        let pump = Task { for await m in conn.incoming() { await router.handle(m, conn) } }
        let drain = Task { for await m in conn.clientOutbound() { await sink.append(m) } }
        return Stack(conn: conn, home: home, store: store, sink: sink, pump: pump, drain: drain)
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
            "clientInfo": .object(["name": .string("catchup-test")]),
            "capabilities": .object([:]),
        ]))
        _ = await awaitResponse(s, 1)
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
    }
    /// Start a thread and return its id.
    private func startThread(_ s: Stack, _ id: Int) async -> String? {
        send(s, id, "thread/start", .object(["cwd": .string(s.home)]))
        guard let r = await awaitResponse(s, Int64(id)),
              let obj = r.result.objectValue,
              let thread = obj["thread"]?.objectValue,
              let tid = thread["id"]?.stringValue else { return nil }
        return tid
    }

    // MARK: thread/delete

    func testThreadDeleteRemovesThreadAndEmitsNotification() async throws {
        let s = try makeStack(); defer { s.teardown() }
        await initialize(s)
        guard let tid = await startThread(s, 2) else { return XCTFail("no thread id") }

        // The thread exists in the active list.
        let before = (try? await s.store.list(archived: false, limit: 100)) ?? []
        XCTAssertTrue(before.contains { $0.id.raw == tid }, "thread should exist before delete")

        send(s, 3, "thread/delete", .object(["threadId": .string(tid)]))
        guard let r = await awaitResponse(s, 3) else { return XCTFail("no delete response") }
        XCTAssertEqual(r.result.objectValue?.isEmpty, true, "thread/delete → empty response")

        // The thread is gone (not merely archived).
        let after = (try? await s.store.list(archived: false, limit: 100)) ?? []
        XCTAssertFalse(after.contains { $0.id.raw == tid }, "thread should be deleted")
        let archived = (try? await s.store.list(archived: true, limit: 100)) ?? []
        XCTAssertFalse(archived.contains { $0.id.raw == tid }, "delete is permanent, not archive")

        // The thread/deleted notification was broadcast.
        let notifs = await s.sink.notifications("thread/deleted")
        XCTAssertTrue(notifs.contains { $0.params?.objectValue?["threadId"]?.stringValue == tid },
                      "thread/deleted notification carrying the id")
    }

    func testThreadDeleteNonexistentIsIdempotent() async throws {
        let s = try makeStack(); defer { s.teardown() }
        await initialize(s)
        send(s, 2, "thread/delete", .object(["threadId": .string("th_does_not_exist")]))
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no response") }
        XCTAssertEqual(r.result.objectValue?.isEmpty, true, "deleting a missing thread is a no-op success")
    }

    // MARK: permissionProfile/list

    func testPermissionProfileListBuiltins() async throws {
        let s = try makeStack(); defer { s.teardown() }
        await initialize(s)
        send(s, 2, "permissionProfile/list", .object([:]))
        guard let r = await awaitResponse(s, 2),
              let data = r.result.objectValue?["data"]?.arrayValue else {
            return XCTFail("no profile list")
        }
        let ids = data.compactMap { $0.objectValue?["id"]?.stringValue }
        XCTAssertEqual(ids, [":read-only", ":workspace", ":danger-full-access"],
                       "built-in profiles in upstream order")
        XCTAssertNil(r.result.objectValue?["nextCursor"]?.stringValue,
                     "no pagination needed → nextCursor absent/null")
    }

    func testPermissionProfileListPagination() async throws {
        let s = try makeStack(); defer { s.teardown() }
        await initialize(s)
        send(s, 2, "permissionProfile/list", .object(["limit": .int(2)]))
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no response") }
        let ids = r.result.objectValue?["data"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
        XCTAssertEqual(ids, [":read-only", ":workspace"])
        XCTAssertEqual(r.result.objectValue?["nextCursor"]?.stringValue, "2",
                       "more profiles remain → nextCursor=2")
        // Continue from the cursor.
        send(s, 3, "permissionProfile/list", .object(["cursor": .string("2")]))
        guard let r2 = await awaitResponse(s, 3) else { return XCTFail("no page 2") }
        let ids2 = r2.result.objectValue?["data"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
        XCTAssertEqual(ids2, [":danger-full-access"])
    }

    func testPermissionProfileListInvalidCursorRejected() async throws {
        let s = try makeStack(); defer { s.teardown() }
        await initialize(s)
        send(s, 2, "permissionProfile/list", .object(["cursor": .string("notanumber")]))
        let e = await awaitError(s, 2)
        XCTAssertNotNil(e, "non-numeric cursor → invalid_request")
        XCTAssertEqual(e?.error.code, -32600)
    }

    func testPermissionProfileListIncludesConfiguredProfiles() async throws {
        let s = try makeStack(); defer { s.teardown() }
        // A user-defined profile with a description.
        let toml = """
        [permissions.tight]
        description = "least privilege"
        """
        try toml.write(toFile: s.home + "/config.toml", atomically: true, encoding: .utf8)
        await initialize(s)
        send(s, 2, "permissionProfile/list", .object([:]))
        guard let r = await awaitResponse(s, 2),
              let data = r.result.objectValue?["data"]?.arrayValue else {
            return XCTFail("no list")
        }
        let tight = data.first { $0.objectValue?["id"]?.stringValue == "tight" }
        XCTAssertNotNil(tight, "configured [permissions.tight] should appear")
        XCTAssertEqual(tight?.objectValue?["description"]?.stringValue, "least privilege")
    }

    // MARK: skills/extraRoots/set

    func testSkillsExtraRootsSetSurfacesSkills() async throws {
        let s = try makeStack(); defer { s.teardown() }
        // Build an extra skill root with a SKILL.md.
        let extra = s.home + "/extra-skills"
        let skillDir = extra + "/widgetizer"
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: widgetizer
        description: makes widgets
        ---
        Body.
        """.write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)
        await initialize(s)

        // Before: not present.
        send(s, 2, "skills/list", .object(["cwds": .array([.string(s.home)])]))
        let r0 = await awaitResponse(s, 2)
        let names0 = r0?.result.objectValue?["data"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
        XCTAssertFalse(names0.contains("widgetizer"))

        send(s, 3, "skills/extraRoots/set", .object(["extraRoots": .array([.string(extra)])]))
        guard let r1 = await awaitResponse(s, 3) else { return XCTFail("no set response") }
        XCTAssertEqual(r1.result.objectValue?.isEmpty, true)

        // After: present.
        send(s, 4, "skills/list", .object(["cwds": .array([.string(s.home)])]))
        let r2 = await awaitResponse(s, 4)
        let names = r2?.result.objectValue?["data"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
        XCTAssertTrue(names.contains("widgetizer"), "extra root skill should now surface")
    }

    func testSkillsExtraRootsSetRejectsRelativePaths() async throws {
        let s = try makeStack(); defer { s.teardown() }
        await initialize(s)
        send(s, 2, "skills/extraRoots/set", .object(["extraRoots": .array([.string("relative/path")])]))
        let e = await awaitError(s, 2)
        XCTAssertNotNil(e, "relative path → invalid_request")
        XCTAssertEqual(e?.error.code, -32600)
    }

    // MARK: thread/goal/* reachable without experimentalApi (P4 / upstream #23732)

    func testGoalMethodsReachableWithoutExperimentalCapability() async throws {
        let s = try makeStack(); defer { s.teardown() }
        await initialize(s)   // capabilities: {} — no experimentalApi negotiated
        guard let tid = await startThread(s, 2) else { return XCTFail("no thread id") }

        // Goals are now Stable/default-on: thread/goal/set must NOT be rejected
        // with an experimentalApi-capability error on a plain connection.
        send(s, 3, "thread/goal/set", .object([
            "threadId": .string(tid), "objective": .string("ship the sync")]))
        if let e = await awaitError(s, 3, ms: 1500) {
            return XCTFail("goal/set must be reachable without experimentalApi; got: \(e.error.message)")
        }
        guard let r = await awaitResponse(s, 3) else { return XCTFail("no goal/set response") }
        XCTAssertNotNil(r.result.objectValue?["goal"], "goal/set returns the goal")

        // get round-trips the objective.
        send(s, 4, "thread/goal/get", .object(["threadId": .string(tid)]))
        guard let r2 = await awaitResponse(s, 4) else { return XCTFail("no goal/get response") }
        XCTAssertEqual(
            r2.result.objectValue?["goal"]?.objectValue?["objective"]?.stringValue,
            "ship the sync")
    }

    // MARK: account/usage/read

    func testAccountUsageReadRequiresAuth() async throws {
        let s = try makeStack(); defer { s.teardown() }
        await initialize(s)
        send(s, 2, "account/usage/read", nil)
        let e = await awaitError(s, 2)
        XCTAssertEqual(e?.error.message, "codex account authentication required to read token usage")
    }

    // MARK: token-usage projection (pure)

    func testProjectTokenUsageProfile() throws {
        let json = """
        {"stats":{"lifetime_tokens":12345,"peak_daily_tokens":999,
        "longest_running_turn_sec":42,"current_streak_days":3,"longest_streak_days":7,
        "daily_usage_buckets":[{"start_date":"2026-06-01","tokens":100},
        {"start_date":"2026-06-02","tokens":250}]}}
        """.data(using: .utf8)!
        let resp = try RequestRouter.projectTokenUsageProfile(json)
        XCTAssertEqual(resp.summary.lifetimeTokens, 12345)
        XCTAssertEqual(resp.summary.peakDailyTokens, 999)
        XCTAssertEqual(resp.summary.longestRunningTurnSec, 42)
        XCTAssertEqual(resp.summary.currentStreakDays, 3)
        XCTAssertEqual(resp.summary.longestStreakDays, 7)
        XCTAssertEqual(resp.dailyUsageBuckets?.count, 2)
        XCTAssertEqual(resp.dailyUsageBuckets?[1].startDate, "2026-06-02")
        XCTAssertEqual(resp.dailyUsageBuckets?[1].tokens, 250)
    }

    func testProjectTokenUsageProfileEmptyStats() throws {
        let resp = try RequestRouter.projectTokenUsageProfile("{}".data(using: .utf8)!)
        XCTAssertNil(resp.summary.lifetimeTokens)
        XCTAssertNil(resp.dailyUsageBuckets)
    }
}
