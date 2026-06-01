import XCTest
import Foundation
#if canImport(AppKit)
import CoreGraphics
@testable import ComputerUse

/// Severe tests for the computer-use hardening fixes (#2 multi-monitor, #4
/// keypress Unicode fallback, #5 maxSteps clamp, #6 scroll Int32 clamp, #9
/// safety-check gating). These exercise the pure decision/mapping logic without
/// driving the desktop or hitting the network.
final class ComputerUseHardeningTests: XCTestCase {

    // #2 — eyes and hands must target the SAME display. The executor must size
    // and map against the MAIN display (CGMainDisplayID, what `screencapture -D 1`
    // captures), NOT NSScreen.main (which follows keyboard focus and diverges on
    // multi-monitor).
    func testMapsAgainstMainDisplay() throws {
        let exec = ComputerUseExecutor(targetWidth: 1280)
        let main = CGDisplayBounds(CGMainDisplayID())
        try XCTSkipUnless(main.width > 0 && main.height > 0,
                          "no attached display (headless CI) — mapping equality is moot")
        XCTAssertEqual(exec.screenBoundsForTesting, main,
            "coordinate map must use CGMainDisplayID bounds (matches `screencapture -D 1`)")
        // Center of model space maps to the center of the main display.
        let c = exec.mapModelPointForTesting(Double(exec.targetWidth) / 2,
                                             Double(exec.targetHeight) / 2)
        XCTAssertEqual(c.x, main.midX, accuracy: 1.0)
        XCTAssertEqual(c.y, main.midY, accuracy: 1.0)
        // Corners map to the display corners (no offset onto another screen).
        let origin = exec.mapModelPointForTesting(0, 0)
        XCTAssertEqual(origin.x, main.minX, accuracy: 1.0)
        XCTAssertEqual(origin.y, main.minY, accuracy: 1.0)
    }

    // #4 — keypress must not silently drop punctuation/symbols.
    func testKeyDispatchClassifiesKeys() {
        // Letters/digits/named keys + UNSHIFTED punctuation map to a virtual
        // keycode (so chords like ⌘- / ⌘/ carry their modifier).
        for k in ["A", "ENTER", "5", "/", "-", "=", ";", ".", "[", "`"] {
            if case .keycode = ComputerUseExecutor.keyDispatch(k) {} else { XCTFail("\(k)→keycode") }
        }
        // SHIFTED symbols have no direct keycode → Unicode injection (instead of
        // the old silent no-op).
        XCTAssertEqual(ComputerUseExecutor.keyDispatch("+"), .unicode("+"))
        XCTAssertEqual(ComputerUseExecutor.keyDispatch(":"), .unicode(":"))
        XCTAssertEqual(ComputerUseExecutor.keyDispatch("?"), .unicode("?"))
        // Multi-char unknown tokens have no realization.
        XCTAssertEqual(ComputerUseExecutor.keyDispatch("FOOBAR"), .unsupported)
    }

    // #6 — scroll deltas are untrusted; the Int32 conversion must never trap.
    func testScrollDeltaClampNeverTraps() {
        XCTAssertEqual(ComputerUseExecutor.clampInt32(5.4), 5)
        XCTAssertEqual(ComputerUseExecutor.clampInt32(-5.6), -6)
        XCTAssertEqual(ComputerUseExecutor.clampInt32(0), 0)
        XCTAssertEqual(ComputerUseExecutor.clampInt32(1e30), Int32.max)   // would trap unclamped
        XCTAssertEqual(ComputerUseExecutor.clampInt32(-1e30), Int32.min)
        XCTAssertEqual(ComputerUseExecutor.clampInt32(.nan), 0)
        XCTAssertEqual(ComputerUseExecutor.clampInt32(.infinity), 0)      // non-finite → 0
        XCTAssertEqual(ComputerUseExecutor.clampInt32(-.infinity), 0)
        // A scroll with a huge untrusted delta must not crash.
        let exec = ComputerUseExecutor(targetWidth: 1280)
        exec.scroll(x: 10, y: 10, scrollX: 0, scrollY: 9.9e30)   // no trap
    }

    // #5 — maxSteps clamp prevents the `1...0` range trap.
    func testMaxStepsClamp() {
        XCTAssertEqual(ComputerUseLoop.clampedMaxSteps(0), 1)
        XCTAssertEqual(ComputerUseLoop.clampedMaxSteps(-5), 1)
        XCTAssertEqual(ComputerUseLoop.clampedMaxSteps(1), 1)
        XCTAssertEqual(ComputerUseLoop.clampedMaxSteps(40), 40)
    }

    // #9 — confirmRiskyActions must actually gate pending_safety_checks.
    func testSafetyCheckGating() {
        let codes = ["malicious_instructions"]
        // Default: honoring checks + a denying handler → BLOCK.
        XCTAssertTrue(ComputerUseLoop.shouldBlockRiskyAction(
            confirmRiskyActions: true, codes: codes, confirm: { _ in false }))
        // --no-confirm (confirmRiskyActions=false) → never block.
        XCTAssertFalse(ComputerUseLoop.shouldBlockRiskyAction(
            confirmRiskyActions: false, codes: codes, confirm: { _ in false }))
        // Explicit approval → don't block.
        XCTAssertFalse(ComputerUseLoop.shouldBlockRiskyAction(
            confirmRiskyActions: true, codes: codes, confirm: { _ in true }))
        // The default Options are SAFE: honor checks, and the default handler denies.
        let opts = ComputerUseLoop.Options()
        XCTAssertTrue(opts.confirmRiskyActions)
        XCTAssertFalse(opts.confirmHandler(codes), "default confirm handler must deny")
    }

    // #9 (refinement) — the integrated tool's per-code policy: auto-proceed on
    // benign navigation checks, BLOCK higher-signal / unrecognized codes.
    func testIntegratedSafetyPolicyPerCode() {
        // Mirror ComputerUseTool's handler so the policy is pinned by a test.
        let autoAck: Set<String> = ["sensitive_domain", "irrelevant_domain"]
        let handler: ([String]) -> Bool = { $0.allSatisfy { autoAck.contains($0) } }
        XCTAssertTrue(handler(["sensitive_domain"]), "benign navigation check proceeds")
        XCTAssertTrue(handler(["sensitive_domain", "irrelevant_domain"]))
        XCTAssertFalse(handler(["malicious_instructions"]), "high-signal code must block")
        XCTAssertFalse(handler(["sensitive_domain", "malicious_instructions"]),
                       "a mix containing a high-signal code must block")
        XCTAssertFalse(handler(["some_future_code"]), "unrecognized code blocks (fail-safe)")
        // And blocking is what shouldBlockRiskyAction reports for those.
        XCTAssertTrue(ComputerUseLoop.shouldBlockRiskyAction(
            confirmRiskyActions: true, codes: ["malicious_instructions"], confirm: handler))
        XCTAssertFalse(ComputerUseLoop.shouldBlockRiskyAction(
            confirmRiskyActions: true, codes: ["sensitive_domain"], confirm: handler))
    }

    // #3 — perform()'s delays now use `try await Task.sleep`, so cancellation
    // PROPAGATES (an interrupt stops the loop instead of finishing the batch).
    func testPerformPropagatesCancellation() async {
        let exec = ComputerUseExecutor(targetWidth: 1280)
        guard let loop = ComputerUseLoop(executor: exec, options: ComputerUseLoop.Options(),
                                         env: ["OPENAI_API_KEY": "x"]) else {
            return XCTFail("loop init")
        }
        // "screenshot" performs no input event — just the settle Task.sleep, which
        // must throw CancellationError in a cancelled task.
        let task = Task { try await loop.performForTesting(["type": "screenshot"]) }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected CancellationError to propagate out of perform")
        } catch is CancellationError {
            // success
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
#endif
