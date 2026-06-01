import XCTest
import Foundation
@testable import Tools
@testable import InfraPrimitives
#if canImport(AppKit)
@testable import Sandbox

/// Integration of the `computer_use` tool into the local tool surface. These
/// tests never drive the desktop: they exercise the advertise-gating + the
/// argument-validation / no-key short-circuits, all of which return BEFORE the
/// native action loop (and before any screenshot / CGEvent) runs.
final class ComputerUseToolTests: XCTestCase {

    private func sandbox() -> WorkspaceSandbox {
        WorkspaceSandbox(SandboxPolicy(mode: .readOnly))
    }

    /// Opt-in gating: advertised in `specs()` only when `computerUseEnabled`.
    func testAdvertisedOnlyWhenEnabled() async {
        let on = ToolRouter(limits: Limits())
        await DefaultTools.register(on: on, sandbox: sandbox(), computerUseEnabled: true)
        let onNames = await on.specs().map { $0.name }
        XCTAssertTrue(onNames.contains("computer_use"),
                      "computer_use must be advertised when computerUseEnabled:true; got \(onNames)")

        let off = ToolRouter(limits: Limits())
        await DefaultTools.register(on: off, sandbox: sandbox())   // default: disabled
        let offNames = await off.specs().map { $0.name }
        XCTAssertFalse(offNames.contains("computer_use"),
                       "computer_use must be OFF by default (upstream-parity tool list unchanged)")
    }

    /// Drives global mouse/keyboard — must take the exclusive (serial) gate.
    func testIsSerial() {
        XCTAssertFalse(ComputerUseTool().parallelSafe,
                       "computer_use controls the global desktop and must never be parallel-safe")
    }

    /// A valid task with no API key returns an actionable error and NEVER touches
    /// the desktop (loop is never constructed).
    func testNoKeyReturnsActionableError() async {
        let router = ToolRouter(limits: Limits())
        await router.register(ComputerUseTool(env: [:]))   // no OPENAI_API_KEY
        let r = await router.dispatch(
            ToolCall(callId: "c1", name: "computer_use",
                     argumentsJSON: #"{"task":"open Calculator and compute 12 x 9"}"#),
            cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("OPENAI_API_KEY"),
                      "no-key error must name the missing variable; got: \(r.output)")
    }

    /// An empty / missing task is rejected before anything else (so this is safe
    /// even if a key IS present in the test environment).
    func testRejectsEmptyTask() async {
        let router = ToolRouter(limits: Limits())
        await router.register(ComputerUseTool(env: [:]))
        for json in [#"{}"#, #"{"task":"   "}"#] {
            let r = await router.dispatch(
                ToolCall(callId: "c", name: "computer_use", argumentsJSON: json),
                cwd: "/tmp", deadline: .fromNow(.seconds(5)))
            XCTAssertFalse(r.success, "empty task must fail: \(json)")
            XCTAssertTrue(r.output.lowercased().contains("task"),
                          "empty-task error must mention the task argument; got: \(r.output)")
        }
    }

    /// The model-visible spec carries a usable schema + description.
    func testSpecShape() {
        let t = ComputerUseTool()
        XCTAssertEqual(t.name, "computer_use")
        XCTAssertTrue(t.toolDescription.contains("desktop"))
        XCTAssertTrue(t.jsonSchema.contains("\"task\""))
        XCTAssertTrue(t.jsonSchema.contains("\"required\""))
        // Schema must be valid JSON.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(t.jsonSchema.utf8)))
    }
}
#endif
