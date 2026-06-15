import XCTest
@testable import Mem0Core

/// Drift gate for the upstream-generated mem0 prompts (gbrain.md §9.6 #2). These
/// constants are GENERATED from mem0-rs (see the file header), so we never edit them
/// by hand — but a local drift (or an upstream regen) MUST be a visible, reviewed
/// event. This hashes the live constant and pins it; a mismatch means the prompt
/// changed and the recorded hash + an UPSTREAM_SYNC note need updating. Uses
/// Mem0Core's own `md5Hex` so no extra test dependency is needed.
final class Mem0PromptVersionGateTests: XCTestCase {
    func testAdditiveExtractionPromptIsPinned() {
        let h = md5Hex(Mem0PromptConstants.additiveExtractionPrompt)
        XCTAssertEqual(h, "46d4cd14875690b10377fc7b77196c41",
                       "mem0 additiveExtractionPrompt changed — review + update the pin. actual=\(h)")
    }

    func testUpdateMemoryPromptIsPinned() {
        let h = md5Hex(Mem0PromptConstants.defaultUpdateMemoryPrompt)
        XCTAssertEqual(h, "f0941e9aa7f3cafa10ca3853bfa3c25c",
                       "mem0 defaultUpdateMemoryPrompt changed — review + update the pin. actual=\(h)")
    }
}
