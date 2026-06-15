import XCTest
import InfraPrimitives
@testable import MemoryInfer

/// Prompt version-stamp + regression gate (gbrain.md §9.6 #2). Each hardcoded
/// extraction/contextualise prompt is rendered for a FIXED canonical input and
/// hashed; the recorded SHA-8 is the drift gate. Editing the instruction scaffold
/// (or the shared `ContextSanitizer.dataPreamble`) changes the hash → this test
/// fails until you bump the matching `promptVersion` and update the recorded hash.
/// That coupling is the point: a prompt cannot silently change without a version bump.
final class PromptVersionGateTests: XCTestCase {
    private func sha8(_ s: String) -> String { String(Hashing.sha256Hex(s).prefix(8)) }

    private func canonicalBatch() -> ChunkBatch {
        ChunkBatch(documentTitle: "Canonical Title", documentURI: "doc://canonical",
                   chunks: [Chunk(localId: "c0", rawText: "canonical chunk body", idx: 0)])
    }

    func testExtractionPromptIsVersionStamped() {
        XCTAssertEqual(ExtractionPrompt.promptVersion, "extract-graph-v1")
        let rendered = ExtractionPrompt.render(batch: canonicalBatch(), schema: .default)
        XCTAssertEqual(sha8(rendered), "4079bc2e",
                       "extraction prompt drifted — bump ExtractionPrompt.promptVersion + update this hash. actual=\(sha8(rendered))")
    }

    func testContextualisePromptIsVersionStamped() {
        XCTAssertEqual(ContextualisePrompt.promptVersion, "contextualise-v1")
        let doc = DocumentDigest(title: "Canonical Title", uri: "doc://canonical", summary: "canonical summary")
        let chunk = Chunk(localId: "c0", rawText: "canonical chunk body", idx: 0)
        let rendered = ContextualisePrompt.render(chunk: chunk, document: doc)
        XCTAssertEqual(sha8(rendered), "09612847",
                       "contextualise prompt drifted — bump ContextualisePrompt.promptVersion + update this hash. actual=\(sha8(rendered))")
    }
}
