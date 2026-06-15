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
