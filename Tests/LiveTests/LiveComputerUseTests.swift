import XCTest
import Foundation
@testable import HarnessCore
@testable import ModelClient
@testable import Persistence
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives

#if canImport(AppKit)

/// Live end-to-end: a real gpt-5.5 turn, given the FULL production tool surface
/// (shell, apply_patch, file tools, web_search, …) plus `computer_use`, must
/// SELECT and DISPATCH `computer_use` for a screen-only GUI task. This is the
/// "agents have it available and know how to use it" proof.
///
/// A spy stands in for the tool so the test records the model's selection
/// WITHOUT hijacking the desktop. The spy advertises the REAL tool's
/// description + schema (so the model's selection is judged against the exact
/// production spec), and:
///   - default (just OPENAI_API_KEY): returns a canned result — no desktop control.
///   - CODEX_LIVE_COMPUTER_USE=1: delegates to the REAL ComputerUseTool, so the
///     desktop is actually driven (the full integrated path, end to end).
/// The native action loop itself is separately validated live (Calculator → 108).
final class LiveComputerUseTests: XCTestCase {

    private final class CallBox: @unchecked Sendable {
        private let l = NSLock(); private var v: String?
        func set(_ s: String) { l.lock(); v = s; l.unlock() }
        func get() -> String? { l.lock(); defer { l.unlock() }; return v }
    }

    /// Wraps the real `computer_use` spec; records the args the model passed.
    private struct SpyComputerUse: Tool {
        let name = "computer_use"
        let parallelSafe = false
        let box: CallBox
        private let inner = ComputerUseTool()
        var toolDescription: String { inner.toolDescription }
        var jsonSchema: String { inner.jsonSchema }
        func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
            box.set(call.argumentsJSON)
            if ProcessInfo.processInfo.environment["CODEX_LIVE_COMPUTER_USE"] == "1" {
                return try await inner.run(call, cwd: cwd)   // real desktop control
            }
            // Canned result — proves selection/dispatch without driving the screen.
            return ToolResult(callId: call.callId,
                              output: "Computer-use actions performed:\n• opened Calculator\n• typed 12 x 9\n\nResult: The display shows 108.",
                              success: true, truncated: false)
        }
    }

    func testAgentSelectsAndDispatchesComputerUse() async throws {
        try lxSkipUnlessLiveKey()
        let home = lxTmp("cu-home"); defer { try? FileManager.default.removeItem(atPath: home) }
        let work = lxTmp("cu-work"); defer { try? FileManager.default.removeItem(atPath: work) }
        let tid = ThreadId("thr_cu_" + UUID().uuidString.prefix(8).lowercased())
        let store = try lxStore(home)

        // Full production tool surface (DefaultTools, computer_use OFF) + the spy
        // registered as `computer_use`, so the model chooses among the real tools.
        let (engine, _, router, _) = await lxFullToolEngine(
            home: home, work: work, tid: tid, store: store,
            maxOut: 900, maxIters: 6, deadline: .seconds(300))
        let box = CallBox()
        await router.register(SpyComputerUse(box: box))

        await engine.start()
        // A screen-only task: the answer lives on the GUI display, which the shell
        // cannot read — so the natural tool is computer_use.
        let prompt = "Open the macOS Calculator app and compute 12 times 9 by operating "
            + "its on-screen interface, then tell me the number shown on the calculator's "
            + "display. Use the computer_use tool to control the desktop."
        await engine.submit(.startTurn(input: [TurnInput(text: prompt)],
                                       model: "gpt-5.5", turnId: nil))
        let evs = await lxCollect(engine, untilCompletions: 1, timeout: .seconds(300))

        XCTAssertNotNil(box.get(),
            "gpt-5.5 must SELECT + DISPATCH computer_use for a screen-only GUI task")
        if let args = box.get() {
            XCTAssertTrue(args.lowercased().contains("calc"),
                "the task passed to computer_use should reference the Calculator; got: \(args)")
        }
        XCTAssertEqual(lxLastTurnStatus(evs), .completed, "the turn must complete")
    }

    /// Live #7: a bearer supplied ONLY via `tokenProvider` (env has NO
    /// OPENAI_API_KEY) must authenticate the real `/v1/responses` desktop loop —
    /// the proof that a ChatGPT-OAuth session can drive computer_use without
    /// exporting a separate API key. Drives the real desktop, so it is double-
    /// gated: a live key AND CODEX_LIVE_COMPUTER_USE=1 (the same desktop opt-in
    /// the spy path uses). Skips cleanly otherwise.
    func testProviderSuppliedBearerDrivesRealLoop() async throws {
        try lxSkipUnlessLiveKey()
        guard ProcessInfo.processInfo.environment["CODEX_LIVE_COMPUTER_USE"] == "1" else {
            throw XCTSkip("set CODEX_LIVE_COMPUTER_USE=1 (and grant Screen Recording + Accessibility) to drive the real desktop")
        }
        let liveKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        // env is EMPTY — the bearer can ONLY come from the injected provider, so a
        // success here proves the OAuth-style provider path reached the live API.
        let tool = ComputerUseTool(targetWidth: 1280, defaultMaxSteps: 8, env: [:],
                                   tokenProvider: { liveKey })
        let router = ToolRouter(limits: Limits())
        await router.register(tool)
        let r = await router.dispatch(
            ToolCall(callId: "cu_oauth", name: "computer_use",
                     argumentsJSON: #"{"task":"Open the macOS Calculator app.","max_steps":8}"#),
            cwd: "/tmp", deadline: .fromNow(.seconds(180)))
        XCTAssertFalse(r.output.contains("no bearer is available"),
                       "the provider-supplied bearer must be used (env had no key); got: \(r.output)")
        XCTAssertTrue(r.success, "the provider-bearer-driven loop must complete; got: \(r.output)")
    }
}
#endif
