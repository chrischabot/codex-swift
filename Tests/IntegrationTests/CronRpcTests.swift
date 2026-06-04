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
@testable import Cron

/// Severe tests for the ADDONS #6 cron/* RPC family, the migration, and the
/// unattended-turn security config. The process-global CronSchedulerHolder is
/// set/reset per test (XCTest runs methods serially within a class).
final class CronRpcTests: XCTestCase {

    // MARK: stack (mirrors the OutboundSend / AuthGating harness)

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
            CronSchedulerHolder.shared.reset()
        }
    }
    private func makeStack(ownerTrusted: Bool = true) throws -> Stack {
        let home = NSTemporaryDirectory() + "cron-" + UUID().uuidString
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
            "clientInfo": .object(["name": .string("cron-test")]),
            "capabilities": .object([:]),
        ]))
        _ = await awaitResponse(s, 1)
        s.conn.clientSend(.notification(JSONRPCNotification(method: "initialized")))
    }
    private func installScheduler() -> CronScheduler {
        let sched = CronScheduler(store: MemoryCronStore(), graceSeconds: 600, run: { _ in true })
        CronSchedulerHolder.shared.set(sched)
        return sched
    }
    private func decodeJob(_ r: JSONRPCResponse) -> CronJobWire? {
        guard let d = try? JSONEncoder().encode(r.result) else { return nil }
        return try? JSONDecoder().decode(CronJobWire.self, from: d)
    }
    private func decodeList(_ r: JSONRPCResponse) -> CronListResponse? {
        guard let d = try? JSONEncoder().encode(r.result) else { return nil }
        return try? JSONDecoder().decode(CronListResponse.self, from: d)
    }

    // MARK: deny-default

    func testDenyDefaultNoHolder() async throws {
        let s = try makeStack(); defer { s.teardown() }
        CronSchedulerHolder.shared.reset()   // feature OFF
        await initialize(s)
        // cron/list answers benignly empty.
        send(s, 2, "cron/list", .object([:]))
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no list response") }
        XCTAssertEqual(decodeList(r)?.data.count, 0, "no holder → empty list, not an error")
        // cron/add refuses.
        send(s, 3, "cron/add", .object([
            "schedule": .object(["kind": .string("every"), "every": .int(300)]),
            "prompt": .string("x")]))
        let e = await awaitError(s, 3)
        XCTAssertEqual(e?.error.message, "cron feature is not enabled")
    }

    // MARK: owner gate (web tier refused)

    func testOwnerGateWebTierRefused() async throws {
        let s = try makeStack(ownerTrusted: false)   // the WebGateway tier
        defer { s.teardown() }
        let sched = installScheduler()
        await sched.upsert(CronJob(id: "secret", schedule: .every(60),
                                   prompt: "private", deliverTo: "ntfy:x", createdAt: 1))
        await initialize(s)
        // All three cron/* methods must refuse on a non-owner transport, even
        // though the scheduler IS configured.
        send(s, 2, "cron/list", .object([:]))
        let e1 = await awaitError(s, 2)
        XCTAssertEqual(e1?.error.message, "method not available on this transport",
                       "cron/list must not leak jobs to the web tier")
        send(s, 3, "cron/add", .object([
            "schedule": .object(["kind": .string("every"), "every": .int(60)]),
            "prompt": .string("x"), "deliverTo": .string("webhook:https://evil/")]))
        let e2 = await awaitError(s, 3)
        XCTAssertEqual(e2?.error.message, "method not available on this transport")
        send(s, 4, "cron/remove", .object(["id": .string("secret")]))
        let e3 = await awaitError(s, 4)
        XCTAssertEqual(e3?.error.message, "method not available on this transport")
        // Nothing was added or removed.
        let still = await sched.job("secret")
        XCTAssertNotNil(still, "a web-tier cron/remove must not delete an owner's job")
    }

    // MARK: add + wire round-trip

    func testAddPersistsAndReplyHasWireScheduleShape() async throws {
        let s = try makeStack(); defer { s.teardown() }
        let sched = installScheduler()
        await initialize(s)
        send(s, 2, "cron/add", .object([
            "id": .string("daily"),
            "schedule": .object(["kind": .string("every"), "every": .int(86400)]),
            "prompt": .string("morning report"),
            "deliverTo": .string("ntfy:reports")]))
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no add response") }
        let job = decodeJob(r)
        // CRITICAL: the schedule serializes as the STABLE wire shape, NOT the
        // synthesized enum form {"every":{"_0":86400}}.
        XCTAssertEqual(job?.schedule.kind, "every")
        XCTAssertEqual(job?.schedule.every, 86400)
        XCTAssertEqual(job?.prompt, "morning report")
        XCTAssertEqual(job?.deliverTo, "ntfy:reports")
        XCTAssertEqual(job?.skipMemory, true, "skipMemory defaults true (unattended)")
        // And it's persisted in the scheduler.
        let stored = await sched.job("daily")
        XCTAssertEqual(stored?.prompt, "morning report")
        // Raw JSON must NOT contain the fragile synthesized key.
        let raw = (try? JSONEncoder().encode(r.result)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(raw.contains("_0"), "no synthesized enum key leaks to the wire: \(raw)")
    }

    func testListReturnsWireShape() async throws {
        let s = try makeStack(); defer { s.teardown() }
        let sched = installScheduler()
        await sched.upsert(CronJob(id: "j", schedule: .every(300), prompt: "p", createdAt: 1))
        await initialize(s)
        send(s, 2, "cron/list", nil)   // absent params → default
        guard let r = await awaitResponse(s, 2) else { return XCTFail("no list response") }
        let list = decodeList(r)
        XCTAssertEqual(list?.data.first?.schedule.kind, "every")
        XCTAssertEqual(list?.data.first?.schedule.every, 300)
    }

    // MARK: validation

    func testMalformedScheduleRejected() async throws {
        let s = try makeStack(); defer { s.teardown() }
        _ = installScheduler()
        await initialize(s)
        // every:0 is invalid.
        send(s, 2, "cron/add", .object([
            "schedule": .object(["kind": .string("every"), "every": .int(0)]),
            "prompt": .string("x")]))
        let e1 = await awaitError(s, 2)
        XCTAssertEqual(e1?.error.message, "invalid schedule")
        // unknown kind.
        send(s, 3, "cron/add", .object([
            "schedule": .object(["kind": .string("bogus")]),
            "prompt": .string("x")]))
        let e2 = await awaitError(s, 3)
        XCTAssertEqual(e2?.error.message, "invalid schedule")
    }

    func testInvalidDeliverToRejected() async throws {
        let s = try makeStack(); defer { s.teardown() }
        _ = installScheduler()
        await initialize(s)
        // No colon → not a "scheme:rest" PushTarget.
        send(s, 2, "cron/add", .object([
            "schedule": .object(["kind": .string("every"), "every": .int(60)]),
            "prompt": .string("x"),
            "deliverTo": .string("not-a-target")]))
        let e = await awaitError(s, 2)
        XCTAssertEqual(e?.error.message, "invalid deliverTo target")
    }

    func testBoundsEnforced() async throws {
        let s = try makeStack(); defer { s.teardown() }
        _ = installScheduler()
        await initialize(s)
        let bigPrompt = String(repeating: "p", count: 100_001)
        send(s, 2, "cron/add", .object([
            "schedule": .object(["kind": .string("every"), "every": .int(60)]),
            "prompt": .string(bigPrompt)]))
        let e = await awaitError(s, 2)
        XCTAssertEqual(e?.error.message, "prompt too long (max 100 KiB)")
    }

    // MARK: remove

    func testRemove() async throws {
        let s = try makeStack(); defer { s.teardown() }
        let sched = installScheduler()
        await sched.upsert(CronJob(id: "j", schedule: .every(60), prompt: "x", createdAt: 1))
        await initialize(s)
        send(s, 2, "cron/remove", .object(["id": .string("j")]))
        _ = await awaitResponse(s, 2)
        let gone = await sched.job("j")
        XCTAssertNil(gone, "cron/remove deletes the job")
    }

    // MARK: unattended-turn security config

    func testCronSessionConfigIsLockedDown() {
        // The load-bearing security property: an unattended cron turn runs under
        // .never approval (can't block on an unanswerable gate), .readOnly
        // sandbox + no network (can't write/exfiltrate), and ephemeral mirrors
        // skipMemory (no silent memory rewrite).
        let job = CronJob(id: "j", schedule: .every(60), prompt: "x",
                          skipMemory: true, createdAt: 0)
        let cfg = CronGlue.cronSessionConfig(job: job, defaultCwd: "/tmp", defaultModel: "m")
        XCTAssertEqual(cfg.approvalPolicy, .never, "unattended → never prompt for approval")
        XCTAssertEqual(cfg.sandboxMode, .readOnly)
        XCTAssertFalse(cfg.networkAccess, "no network egress from a cron turn")
        XCTAssertTrue(cfg.ephemeral, "skipMemory=true → ephemeral (no consolidation)")
        // skipMemory=false → not ephemeral (memory allowed).
        let job2 = CronJob(id: "j", schedule: .every(60), prompt: "x",
                           skipMemory: false, createdAt: 0)
        let cfg2 = CronGlue.cronSessionConfig(job: job2, defaultCwd: "/tmp", defaultModel: "m")
        XCTAssertFalse(cfg2.ephemeral)
    }

    // MARK: migration

    func testMigrationIsLossyCorrectAndIdempotent() throws {
        let home = NSTemporaryDirectory() + "cronmig-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        // automations.json: daily, manual, "300", hourly.
        let autos: [Automation] = [
            Automation(id: "a1", name: "Daily", schedule: "daily", prompt: "p1"),
            Automation(id: "a2", name: "Manual", schedule: "manual", prompt: "p2"),
            Automation(id: "a3", name: "Custom", schedule: "300", prompt: "p3"),
            Automation(id: "a4", name: "Hourly", schedule: "hourly", prompt: "p4", enabled: false),
        ]
        let autoData = try JSONEncoder().encode(autos)
        try autoData.write(to: URL(fileURLWithPath: home + "/automations.json"))

        let n = CronGlue.migrateAutomationsToCron(codexHome: home, now: { 5 })
        XCTAssertEqual(n, 3, "daily/300/hourly migrate; manual is SKIPPED")

        let cronData = try Data(contentsOf: URL(fileURLWithPath: home + "/cron_jobs.json"))
        let jobs = try JSONDecoder().decode([CronJob].self, from: cronData)
        let byId = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        XCTAssertEqual(byId["a1"]?.schedule, .every(86400))
        XCTAssertEqual(byId["a3"]?.schedule, .every(300))
        XCTAssertEqual(byId["a4"]?.schedule, .every(3600))
        XCTAssertEqual(byId["a4"]?.enabled, false, "disabled state carried over")
        XCTAssertNil(byId["a2"], "manual is not migrated")
        XCTAssertTrue(jobs.allSatisfy { $0.skipMemory }, "migrated jobs skipMemory")
        // Backup written.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/automations.json.bak"))

        // Idempotent: a second run no-ops (cron_jobs.json exists).
        let n2 = CronGlue.migrateAutomationsToCron(codexHome: home, now: { 6 })
        XCTAssertEqual(n2, 0, "second migration is a no-op")
    }

    func testMigrationCorruptInputResilient() throws {
        let home = NSTemporaryDirectory() + "cronmig2-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: home + "/automations.json"))
        let n = CronGlue.migrateAutomationsToCron(codexHome: home, now: { 0 })
        XCTAssertEqual(n, 0, "corrupt automations.json → no migration, no crash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/cron_jobs.json"))
    }
}
