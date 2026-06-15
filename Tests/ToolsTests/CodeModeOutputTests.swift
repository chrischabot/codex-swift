#if canImport(JavaScriptCore)
import XCTest
import Foundation
@testable import Tools

/// P5b wave 1: code-mode output-helper surface (image/generatedImage/text +
/// store/load) and the #27732 reject-remote-image-URL security rule.
final class CodeModeOutputTests: XCTestCase {
    private let noopDispatch: @Sendable (String, String, String, Int) async -> String = { _, _, _, _ in "{}" }

    private func run(_ source: String) async -> (out: String, ok: Bool) {
        await CodeModeRuntime.evaluate(source: source, dispatch: noopDispatch, timeoutMs: 5000)
    }

    func testImageDataUrlAccepted() async {
        let (out, ok) = await run(#"image("data:image/png;base64,AAA");"#)
        XCTAssertTrue(ok, "data: image accepted; got: \(out)")
        XCTAssertTrue(out.contains("\"type\":\"image\""), out)
        XCTAssertTrue(out.contains("data:image/png;base64,AAA"), out)
    }

    func testRemoteImageUrlRejectedByHelper() async {
        let (out, ok) = await run(#"image("https://evil.example/x.png");"#)
        XCTAssertFalse(ok, "remote image URL must fail")
        XCTAssertTrue(out.contains("remote image URLs are not supported"), out)
    }

    func testRemoteImageUrlRejectedHostSideEvenIfPushedDirectly() async {
        // A script can bypass the JS helper and push to __codex_output directly;
        // the host-side rule must STILL reject the remote URL (authoritative).
        let (out, ok) = await run(
            #"__codex_output.push({type:'image', image_url:'http://evil.example/x'});"#)
        XCTAssertFalse(ok, "host-side rule must reject a directly-pushed remote URL")
        XCTAssertTrue(out.contains("remote image URLs are not supported"), out)
    }

    func testGeneratedImageRejectsRemoteAndAcceptsData() async {
        let (badOut, badOk) = await run(
            #"generatedImage({image_url:"https://x/y.png"});"#)
        XCTAssertFalse(badOk, badOut)
        let (out, ok) = await run(
            #"generatedImage({image_url:"data:image/png;base64,ZZZ", output_hint:"png"});"#)
        XCTAssertTrue(ok, out)
        XCTAssertTrue(out.contains("\"type\":\"generated_image\""), out)
        XCTAssertTrue(out.contains("\"output_hint\":\"png\""), out)
    }

    func testTextOutputItem() async {
        let (out, ok) = await run(#"text("hello-codemode");"#)
        XCTAssertTrue(ok, out)
        XCTAssertTrue(out.contains("\"type\":\"text\"") && out.contains("hello-codemode"), out)
    }

    func testStoreLoadRoundTrip() async {
        let (out, ok) = await run("""
        store('k', 42);
        store('s', 'v');
        text(String(load('k')) + '-' + load('s'));
        text(load('missing') === null ? 'null-ok' : 'BAD');
        """)
        XCTAssertTrue(ok, out)
        XCTAssertTrue(out.contains("42-v"), out)
        XCTAssertTrue(out.contains("null-ok"), out)
    }

    // --- P5b adversarial-review fixes (#27732 hardening) ---

    func testNaNInOutputDoesNotCrashHost() async {
        // CRITICAL: a non-finite Double in __codex_output used to abort the
        // whole process (JSONSerialization NSException not caught by `try?`).
        // We now serialize via JSC's JSON.stringify (NaN -> null), so the run
        // must complete normally with the item rendered.
        let (out, ok) = await run("""
        text('before-nan');
        __codex_output.push({type:'text', text:'b', n: 0/0, m: 1/0});
        """)
        XCTAssertTrue(ok, "NaN/Infinity in output must not crash; got: \(out)")
        XCTAssertTrue(out.contains("before-nan"), out)
        XCTAssertTrue(out.contains("\"n\":null"), out)   // NaN -> null
    }

    func testWhitespaceSmuggledRemoteUrlRejectedHostSide() async {
        // MAJOR: leading whitespace/control chars must not smuggle a remote URL
        // past the host allow-list (which strips code<=32 then requires data:).
        let (out, ok) = await run(
            #"__codex_output.push({type:'image', image_url:'  \t https://evil.example/x'});"#)
        XCTAssertFalse(ok, "whitespace-prefixed remote URL must be rejected: \(out)")
        XCTAssertTrue(out.contains("remote image URLs are not supported"), out)
    }

    func testNonStringImageUrlRejectedHostSide() async {
        // NIT/type-confusion: a non-String image_url must fail closed, not pass
        // the validation by skipping the `as? String` cast.
        let (out, ok) = await run(
            #"__codex_output.push({type:'image', image_url:123});"#)
        XCTAssertFalse(ok, "non-string image_url must be rejected: \(out)")
        XCTAssertTrue(out.contains("remote image URLs are not supported"), out)
    }

    // --- P5b wave 2: exit() / notify() / tools.<name>() surface parity ---

    func testExitTerminatesCleanlyWithFinalMessage() async {
        let (out, ok) = await run("""
        text('first');
        exit('done-early');
        text('SHOULD-NOT-RUN');
        """)
        XCTAssertTrue(ok, "exit() must terminate cleanly, not as an error: \(out)")
        XCTAssertTrue(out.contains("first"), out)
        XCTAssertTrue(out.contains("done-early"), out)
        XCTAssertFalse(out.contains("SHOULD-NOT-RUN"), "code after exit() must not run: \(out)")
    }

    func testExitWithNoArgStillCleanAndNotAnError() async {
        let (out, ok) = await run(#"text('kept'); exit();"#)
        XCTAssertTrue(ok, "bare exit() is a clean termination: \(out)")
        XCTAssertFalse(out.contains("code-mode error"), out)
        XCTAssertTrue(out.contains("kept"), out)
    }

    func testRealErrorCannotBeLaunderedAsCleanExit() async {
        // #1 (MAJOR review fix): a script must NOT be able to fake a clean exit
        // and then throw a genuine error to launder a real failure into success.
        // Clean-exit is decided by the sentinel's exception identity, not a
        // script-writable flag.
        let (out, ok) = await run("""
        globalThis.__codex_exited = true;   // attempt to spoof the old flag
        null.foo;                           // genuine TypeError
        """)
        XCTAssertFalse(ok, "a real error must be reported, not laundered: \(out)")
        XCTAssertTrue(out.contains("code-mode error"), out)
    }

    func testToolsProxyIsNotMistakenForThenable() async {
        // #3 (review fix): tools.then must be undefined so awaiting/returning the
        // proxy doesn't trigger thenable resolution (which would hang sync eval).
        let (out, ok) = await run(#"text(typeof tools.then);"#)
        XCTAssertTrue(ok, out)
        XCTAssertTrue(out.contains("undefined"), out)
    }

    func testNotifyCollectedAndEmptyRejected() async {
        let (out, ok) = await run(#"notify('working on it'); text('ok');"#)
        XCTAssertTrue(ok, out)
        XCTAssertTrue(out.contains("[notify]") && out.contains("working on it"), out)
        // Empty notify must throw (matches upstream "non-empty text" rule).
        let (bad, badOk) = await run(#"notify('   ');"#)
        XCTAssertFalse(badOk, "empty notify must fail: \(bad)")
    }

    func testToolsProxyForwardsToCallTool() async {
        // tools.<name>(args) must forward to the same dispatch bridge as
        // callTool; the noop dispatch returns "{}", so the call resolves.
        let (out, ok) = await run("""
        var r = tools.echo({a: 1});
        text('called:' + (r !== undefined));
        """)
        XCTAssertTrue(ok, out)
        XCTAssertTrue(out.contains("called:true"), out)
    }

    func testNoHelpersUsedLeavesOutputUnchanged() async {
        // Regression: a script that uses no output helpers behaves exactly as
        // before (return value + console only; no "[code-mode output]" block).
        let (out, ok) = await run(#"console.log("hi-no-helpers"); return 1+1;"#)
        XCTAssertTrue(ok, out)
        XCTAssertFalse(out.contains("[code-mode output]"), "no helpers → no output block")
        XCTAssertTrue(out.contains("hi-no-helpers"), out)   // console captured
        XCTAssertTrue(out.contains("2"), out)               // return value captured
    }
}
#endif
