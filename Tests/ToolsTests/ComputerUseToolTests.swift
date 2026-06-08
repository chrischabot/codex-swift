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

    // MARK: - Bearer precedence (#7: session OAuth token preferred over env key)

    /// CLAIM: `resolveBearer` prefers the injected (session OAuth) token over the
    /// env `OPENAI_API_KEY`. ORACLE: an explicit precedence table. SEVERITY:
    /// strong — this decides which credential drives the desktop loop.
    func testResolveBearerPrefersProvidedOverEnv() {
        XCTAssertEqual(ComputerUseTool.resolveBearer(provided: "oauth-tok", envKey: "env-key"), "oauth-tok",
                       "a present session OAuth token must win over OPENAI_API_KEY")
    }

    /// A blank/absent provider (nil, empty, whitespace) must fall through to the
    /// env key — never shadow it with an empty string.
    func testResolveBearerFallsBackToEnvWhenProviderBlank() {
        for blank in [nil, "", "   ", "\n\t"] as [String?] {
            XCTAssertEqual(ComputerUseTool.resolveBearer(provided: blank, envKey: "env-key"), "env-key",
                           "a blank provider (\(String(describing: blank))) must fall through to env")
        }
    }

    /// Both blank → nil (the tool then emits the actionable no-bearer error).
    func testResolveBearerNilWhenBothBlank() {
        for p in [nil, "", "  "] as [String?] {
            for e in [nil, "", "  "] as [String?] {
                XCTAssertNil(ComputerUseTool.resolveBearer(provided: p, envKey: e),
                             "blank/blank must be nil (p=\(String(describing: p)) e=\(String(describing: e)))")
            }
        }
    }

    /// Surrounding whitespace is trimmed off the chosen credential so a stray
    /// newline from a token file never corrupts the Authorization header.
    func testResolveBearerTrimsChosenCredential() {
        XCTAssertEqual(ComputerUseTool.resolveBearer(provided: "  tok-123\n", envKey: nil), "tok-123")
        XCTAssertEqual(ComputerUseTool.resolveBearer(provided: nil, envKey: " env-key "), "env-key")
    }

    /// CLAIM: the tool actually CONSULTS the injected provider, and when it (and
    /// env) yield nothing, returns the actionable error naming BOTH credential
    /// sources — never touching the desktop. ORACLE: the error text + a flag the
    /// provider closure flips. SEVERITY: strong — proves the new auth seam is
    /// wired, not dead code.
    func testProviderConsultedAndNoBearerErrorNamesBothSources() async {
        let consulted = ConsultFlag()
        let tool = ComputerUseTool(env: [:], tokenProvider: {
            await consulted.mark(); return nil   // present provider, but yields no token
        })
        let router = ToolRouter(limits: Limits())
        await router.register(tool)
        let r = await router.dispatch(
            ToolCall(callId: "c1", name: "computer_use",
                     argumentsJSON: #"{"task":"open Calculator"}"#),
            cwd: "/tmp", deadline: .fromNow(.seconds(5)))
        let wasConsulted = await consulted.value
        XCTAssertTrue(wasConsulted, "the tokenProvider must be consulted during run()")
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.output.contains("OPENAI_API_KEY"),
                      "no-bearer error must name OPENAI_API_KEY; got: \(r.output)")
        XCTAssertTrue(r.output.contains("OAuth"),
                      "no-bearer error must name the session OAuth token path; got: \(r.output)")
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

/// Observes whether the injected token provider was actually invoked.
private actor ConsultFlag {
    private(set) var value = false
    func mark() { value = true }
}
#endif
