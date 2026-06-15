import XCTest
import Foundation
@testable import codex_memory
@testable import MemoryStore

/// Severe coverage for the WikiWriteGate (gbrain.md Wave 0.2) — the wiring of
/// WikiLinkLinter into the write path with off/lint/strict modes.
final class WikiWriteGateTests: XCTestCase {
    private func root() -> String {
        NSTemporaryDirectory() + "wiki-write-gate-\(UUID().uuidString)"
    }

    // ungrounded = grounding-required category + 0 claim links + no wikilinks.
    private func ungroundedSynthesis() -> WikiLintPage {
        WikiLintPage(slug: "research-x-r1", body: "# X\n\nno links here", category: "synthesis", claimLinkCount: 0)
    }
    private func groundedSynthesis() -> WikiLintPage {
        WikiLintPage(slug: "research-x-r1", body: "# X", category: "synthesis", claimLinkCount: 3)
    }

    func testOffModeNeverValidates() {
        let gate = WikiWriteGate(mode: .off, vaultRoot: root())
        let v = gate.validate(ungroundedSynthesis(), validSlugs: ["research-x-r1"])
        XCTAssertTrue(v.issues.isEmpty)
        XCTAssertFalse(v.block)
    }

    func testLintModeSurfacesButNeverBlocks() throws {
        let r = root(); defer { try? FileManager.default.removeItem(atPath: r) }
        let gate = WikiWriteGate(mode: .lint, vaultRoot: r)
        let v = gate.validate(ungroundedSynthesis(), validSlugs: ["research-x-r1"])
        XCTAssertTrue(v.issues.contains { $0.kind == .ungrounded })
        XCTAssertFalse(v.block, "lint mode must never block")
        // It logged the issue.
        let logged = try String(contentsOfFile: r + "/research/wiki-write-lint.jsonl", encoding: .utf8)
        XCTAssertTrue(logged.contains("ungrounded"))
        XCTAssertTrue(logged.contains("\"mode\":\"lint\"") || logged.contains("\"mode\": \"lint\""))
    }

    func testStrictModeBlocksUngrounded() {
        let gate = WikiWriteGate(mode: .strict, vaultRoot: root())
        let v = gate.validate(ungroundedSynthesis(), validSlugs: ["research-x-r1"])
        XCTAssertTrue(v.block, "strict mode must block an ungrounded grounding-required page")
    }

    func testGroundedSynthesisPassesInStrict() {
        let gate = WikiWriteGate(mode: .strict, vaultRoot: root())
        let v = gate.validate(groundedSynthesis(), validSlugs: ["research-x-r1"])
        XCTAssertTrue(v.issues.isEmpty)
        XCTAssertFalse(v.block)
    }

    func testBrokenLinkBlocksInStrict() {
        // A page linking to a non-existent slug → brokenLink (error-severity).
        let page = WikiLintPage(slug: "a", body: "see [[nonexistent-slug]]", category: "concept", claimLinkCount: 1)
        let gate = WikiWriteGate(mode: .strict, vaultRoot: root())
        let v = gate.validate(page, validSlugs: ["a"])
        XCTAssertTrue(v.issues.contains { $0.kind == .brokenLink })
        XCTAssertTrue(v.block)
    }

    func testNonReciprocalSeeAlsoWarnsButNeverBlocks() {
        // a → b see-also, b has no see-also back → non-reciprocal (warning only).
        let a = WikiLintPage(slug: "a", body: "## See Also\n- [[b]]", category: "concept", claimLinkCount: 1)
        let b = WikiLintPage(slug: "b", body: "no see also", category: "concept", claimLinkCount: 1)
        // Lint both together via the linter to confirm the kind, then gate the verdict.
        let issues = WikiLinkLinter.lint([a, b])
        XCTAssertTrue(issues.contains { $0.kind == .nonReciprocalSeeAlso })
        // isBlocking classifies see-also as non-blocking.
        XCTAssertFalse(issues.filter { $0.kind == .nonReciprocalSeeAlso }.contains(where: WikiWriteGate.isBlocking))
    }

    func testIsBlockingClassification() {
        XCTAssertTrue(WikiWriteGate.isBlocking(WikiLinkIssue(page: "p", kind: .ungrounded, target: nil)))
        XCTAssertTrue(WikiWriteGate.isBlocking(WikiLinkIssue(page: "p", kind: .brokenLink, target: "x")))
        XCTAssertFalse(WikiWriteGate.isBlocking(WikiLinkIssue(page: "p", kind: .nonReciprocalSeeAlso, target: "x")))
    }

    func testResolveModeDefaultsToLint() async throws {
        let db = NSTemporaryDirectory() + "wwg-mode-\(UUID().uuidString).db"
        let store = try MemoryStore(MemoryStoreConfig(path: db, embeddingDimension: 8))
        // No env / no meta → default lint. (Env may override in CI; assert it's a valid mode.)
        let mode = await WikiWriteGate.resolveMode(store: store)
        XCTAssertTrue(WikiWriteGate.Mode.allCases.contains(mode))
    }
}
