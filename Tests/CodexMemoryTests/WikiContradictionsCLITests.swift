import XCTest
@testable import codex_memory
import MemoryStore

/// Coverage for the wiki-contradictions CLI flag parsing (gbrain.md Wave 3.24).
/// The probe/judge/resolver logic is tested in WikiResearchTests; this guards the
/// operator-facing surface (esp. that --apply is opt-in and bad scopes are rejected).
final class WikiContradictionsCLITests: XCTestCase {
    func testParseDefaults() throws {
        let o = try CodexMemoryWikiContradictions.parse([])
        XCTAssertEqual(o.scope, .active)
        XCTAssertFalse(o.apply, "apply must default OFF — never auto-mutate without the explicit flag")
        XCTAssertFalse(o.json)
        XCTAssertEqual(o.maxJudge, 200)
    }

    func testParseAllFlags() throws {
        let o = try CodexMemoryWikiContradictions.parse(
            ["--scope", "stale", "--apply", "--json", "--max-judge", "50", "--max-usd", "1.5", "--limit", "10"])
        XCTAssertEqual(o.scope, .stale)
        XCTAssertTrue(o.apply)
        XCTAssertTrue(o.json)
        XCTAssertEqual(o.maxJudge, 50)
        XCTAssertEqual(o.maxUSD, 1.5)
        XCTAssertEqual(o.limit, 10)
    }

    func testParseRejectsBadScope() {
        XCTAssertThrowsError(try CodexMemoryWikiContradictions.parse(["--scope", "bogus"]))
    }

    func testParseRejectsUnknownFlag() {
        XCTAssertThrowsError(try CodexMemoryWikiContradictions.parse(["--nope"]))
    }

    func testParseScopeAcceptsAllClaimStatuses() throws {
        for s in ClaimStatus.allCases {
            let o = try CodexMemoryWikiContradictions.parse(["--scope", s.rawValue])
            XCTAssertEqual(o.scope, s)
        }
    }
}
