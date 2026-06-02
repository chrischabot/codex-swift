import XCTest
import Foundation
import os
@testable import HarnessCore
@testable import Tools
@testable import InfraPrimitives
@testable import Config

/// Severe tests for ADDONS.md Phase 0 #2 — `ToolPackRegistry`, the composition-
/// root seam that registers enabled `ToolPack`s' tools into a `ToolRouter`.
final class ToolPackRegistryTests: XCTestCase {

    // MARK: fakes

    private struct FakeTool: Tool {
        let name: String
        var output: String = "ok"
        var parallelSafe: Bool { true }
        func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
            ToolResult(callId: call.callId, output: output, success: true, truncated: false)
        }
    }

    /// A pack contributing explicit tool instances (for collision tests where
    /// the tool's `output` must be distinguishable).
    private struct StaticPack: ToolPack {
        let id: String
        let toolList: [any Tool]
        func tools() -> [any Tool] { toolList }
    }

    private func dispatchOutput(_ router: ToolRouter, _ name: String) async -> String {
        await router.dispatch(ToolCall(callId: "c", name: name, argumentsJSON: "{}"),
                              cwd: "/tmp", deadline: .fromNow(.seconds(30))).output
    }

    /// Records install() calls so we can assert install-side-wiring ran.
    private actor InstallLog {
        private(set) var installed: [String] = []
        func note(_ id: String) { installed.append(id) }
        func all() -> [String] { installed }
    }

    private struct FakePack: ToolPack {
        let id: String
        let toolNames: [String]
        let log: InstallLog
        func install() async { await log.note(id) }
        func tools() -> [any Tool] { toolNames.map { FakeTool(name: $0) } }
    }

    /// A pack whose `tools()` only returns its tool once `install()` has run —
    /// proves the registry calls `install()` BEFORE `tools()`.
    private final class OrderedPack: ToolPack, @unchecked Sendable {
        let id: String
        private let didInstall = OSAllocatedUnfairLock(initialState: false)
        init(id: String) { self.id = id }
        func install() async { didInstall.withLock { $0 = true } }
        func tools() -> [any Tool] {
            didInstall.withLock { $0 } ? [FakeTool(name: "\(id).ready")] : []
        }
    }

    private func names(_ router: ToolRouter) async -> Set<String> {
        Set(await router.specs().map(\.name))
    }

    // MARK: tests

    func testEnabledPackRegistersToolsAndRunsInstall() async throws {
        let router = ToolRouter(limits: Limits())
        let log = InstallLog()
        let reg = ToolPackRegistry([FakePack(id: "alpha", toolNames: ["a1", "a2"], log: log)])

        let installed = await reg.install(on: router) { _ in true }
        let logged = await log.all()
        let n = await names(router)

        XCTAssertEqual(installed, ["alpha"])
        XCTAssertEqual(logged, ["alpha"])                       // install() ran
        XCTAssertTrue(n.isSuperset(of: ["a1", "a2"]))           // tools registered + advertised
    }

    func testDisabledPackIsSkippedEntirely() async throws {
        let router = ToolRouter(limits: Limits())
        let log = InstallLog()
        let reg = ToolPackRegistry([FakePack(id: "beta", toolNames: ["b1"], log: log)])

        let installed = await reg.install(on: router) { _ in false }
        let logged = await log.all()
        let n = await names(router)

        XCTAssertEqual(installed, [])
        XCTAssertEqual(logged, [])                              // install() must NOT run for gated-off packs
        XCTAssertFalse(n.contains("b1"))
    }

    func testMixedGateInstallsOnlyEnabled() async throws {
        let router = ToolRouter(limits: Limits())
        let log = InstallLog()
        let reg = ToolPackRegistry([
            FakePack(id: "alpha", toolNames: ["a1"], log: log),
            FakePack(id: "beta",  toolNames: ["b1"], log: log),
            FakePack(id: "gamma", toolNames: ["g1"], log: log),
        ])
        let on: Set<String> = ["alpha", "gamma"]

        let installed = await reg.install(on: router) { on.contains($0) }
        let logged = await log.all()
        let n = await names(router)

        XCTAssertEqual(installed, ["alpha", "gamma"])           // order preserved, beta excluded
        XCTAssertEqual(logged, ["alpha", "gamma"])
        XCTAssertTrue(n.isSuperset(of: ["a1", "g1"]))
        XCTAssertFalse(n.contains("b1"))
    }

    func testDuplicateEnabledIdInstalledOnce() async throws {
        let router = ToolRouter(limits: Limits())
        let log = InstallLog()
        // Two packs share id "dup"; only the FIRST enabled occurrence installs.
        let reg = ToolPackRegistry([
            FakePack(id: "dup", toolNames: ["first"],  log: log),
            FakePack(id: "dup", toolNames: ["second"], log: log),
        ])

        let installed = await reg.install(on: router) { _ in true }
        let logged = await log.all()
        let n = await names(router)

        XCTAssertEqual(installed, ["dup"])                     // installed once
        XCTAssertEqual(logged, ["dup"])                        // install() once
        XCTAssertTrue(n.contains("first"))
        XCTAssertFalse(n.contains("second"))                   // second dup skipped
    }

    func testInstallRunsBeforeToolsAreRegistered() async throws {
        let router = ToolRouter(limits: Limits())
        let reg = ToolPackRegistry([OrderedPack(id: "ord")])

        let installed = await reg.install(on: router) { _ in true }
        let n = await names(router)

        XCTAssertEqual(installed, ["ord"])
        XCTAssertTrue(n.contains("ord.ready"),
                      "install() must be called before tools() so side-wiring is ready")
    }

    func testEmptyRegistryIsNoOp() async throws {
        let router = ToolRouter(limits: Limits())
        let before = await names(router)
        let installed = await ToolPackRegistry([]).install(on: router) { _ in true }
        let after = await names(router)
        XCTAssertEqual(installed, [])
        XCTAssertEqual(after, before)                          // nothing added (the empty composition-root default)
    }

    // MARK: collision defense (review fix)

    /// A pack tool whose name collides with an already-registered (built-in)
    /// tool must be SKIPPED — the existing handler wins, never silently shadowed.
    func testPackToolCollidingWithExistingToolIsSkipped() async throws {
        let router = ToolRouter(limits: Limits())
        await router.register(FakeTool(name: "shell", output: "BUILTIN"))   // pre-existing built-in
        let reg = ToolPackRegistry([StaticPack(id: "p", toolList: [FakeTool(name: "shell", output: "PACK")])])

        let installed = await reg.install(on: router) { _ in true }
        let out = await dispatchOutput(router, "shell")

        XCTAssertEqual(installed, ["p"])           // pack still counts as installed (install() ran)
        XCTAssertEqual(out, "BUILTIN")             // existing handler preserved; pack's colliding tool skipped
    }

    /// An intra-pack duplicate tool name keeps the FIRST and skips the rest.
    func testIntraPackDuplicateNameKeepsFirst() async throws {
        let router = ToolRouter(limits: Limits())
        let reg = ToolPackRegistry([StaticPack(id: "p", toolList: [
            FakeTool(name: "dup", output: "FIRST"),
            FakeTool(name: "dup", output: "SECOND"),
        ])])

        await reg.install(on: router) { _ in true }
        let out = await dispatchOutput(router, "dup")

        XCTAssertEqual(out, "FIRST")
    }

    /// A cross-pack collision keeps the FIRST pack's tool (registry order).
    func testCrossPackCollisionKeepsFirstPack() async throws {
        let router = ToolRouter(limits: Limits())
        let reg = ToolPackRegistry([
            StaticPack(id: "a", toolList: [FakeTool(name: "shared", output: "A")]),
            StaticPack(id: "b", toolList: [FakeTool(name: "shared", output: "B")]),
        ])

        let installed = await reg.install(on: router) { _ in true }
        let out = await dispatchOutput(router, "shared")

        XCTAssertEqual(installed, ["a", "b"])      // both install; b's colliding tool is skipped
        XCTAssertEqual(out, "A")
    }

    // MARK: self-prune + Config convenience (review gaps)

    /// An enabled pack whose `tools()` returns [] (self-pruned: backend not
    /// configured) still counts as installed — install() ran — but adds no tools.
    func testEnabledPackWithNoToolsStillCountsInstalled() async throws {
        let router = ToolRouter(limits: Limits())
        let log = InstallLog()
        let before = await names(router)

        let installed = await ToolPackRegistry([FakePack(id: "empty", toolNames: [], log: log)])
            .install(on: router) { _ in true }
        let logged = await log.all()
        let after = await names(router)

        XCTAssertEqual(installed, ["empty"])       // gate passed + install() ran
        XCTAssertEqual(logged, ["empty"])
        XCTAssertEqual(after, before)              // self-pruned → no tools
    }

    /// The Config overload (what both composition roots call) gates by
    /// `[features].<id>` (deny-default).
    func testConfigConvenienceGatesByFeatureFlag() async throws {
        let router = ToolRouter(limits: Limits())
        let log = InstallLog()
        let cfg = Config(layers: [ConfigLayer(name: "test",
            values: ["features": .object(["alpha": .bool(true)])])])   // beta absent → off
        let reg = ToolPackRegistry([
            FakePack(id: "alpha", toolNames: ["a1"], log: log),
            FakePack(id: "beta",  toolNames: ["b1"], log: log),
        ])

        let installed = await reg.install(on: router, config: cfg)
        let n = await names(router)

        XCTAssertEqual(installed, ["alpha"])       // alpha on, beta deny-default off
        XCTAssertTrue(n.contains("a1"))
        XCTAssertFalse(n.contains("b1"))
    }

    /// Documents the "don't route deferred packs here" rule: the registry
    /// ADVERTISES every tool a pack returns, including the normally-deferred
    /// `workflow` tool — which is exactly why WorkflowsToolPack is NOT in the
    /// composition-root list.
    func testWorkflowsToolPackThroughRegistryAdvertisesAllItsTools() async throws {
        let router = ToolRouter(limits: Limits())
        let pack = WorkflowsToolPack()
        let expected = Set(pack.tools().map(\.name))

        let installed = await ToolPackRegistry([pack]).install(on: router) { _ in true }
        let n = await names(router)

        XCTAssertEqual(installed, ["workflows"])
        XCTAssertTrue(n.isSuperset(of: expected),
                      "registry advertises all pack tools (incl. deferred workflow) — so deferred packs must not be routed here")
    }
}
