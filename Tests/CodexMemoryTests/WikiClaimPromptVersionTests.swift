import XCTest
import InfraPrimitives
@testable import codex_memory

/// Prompt version-stamp + regression gate (gbrain.md §9.6 #2) for the
/// WikiClaimExtractor system prompt. Hash a fixed-`maxClaims` render; editing the
/// prompt (or `ContextSanitizer.dataPreamble`) breaks the gate until the version is
/// bumped and the hash updated.
final class WikiClaimPromptVersionTests: XCTestCase {
    func testWikiClaimSystemPromptIsVersionStamped() {
        XCTAssertEqual(WikiClaimExtractor.promptVersion, "wiki-claim-v1")
        let rendered = WikiClaimExtractor.systemPrompt(maxClaims: 8)
        let sha8 = String(Hashing.sha256Hex(rendered).prefix(8))
        XCTAssertEqual(sha8, "e40271c2",
                       "wiki-claim prompt drifted — bump WikiClaimExtractor.promptVersion + update this hash. actual=\(sha8)")
    }
}
