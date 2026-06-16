import XCTest
@testable import MemoryStore

final class WikiLinkLinterTests: XCTestCase {

    func testLinkExtraction() {
        let body = "See [[moe|Mixture of Experts]] and [[transformers]] plus [[ rag ]]."
        XCTAssertEqual(WikiLinkLinter.links(in: body), ["moe", "transformers", "rag"])
    }

    func testBrokenLinkDetected() {
        let pages = [
            WikiLintPage(slug: "a", body: "links to [[b]] and [[ghost]]", category: "concept"),
            WikiLintPage(slug: "b", body: "back to [[a]]", category: "concept"),
        ]
        let issues = WikiLinkLinter.lint(pages)
        XCTAssertEqual(issues.filter { $0.kind == .brokenLink }.map(\.target), ["ghost"])
    }

    func testValidSlugsSupersetAllowsExternalLinks() {
        let pages = [WikiLintPage(slug: "a", body: "see [[b]]", category: "concept")]
        // b isn't in the batch but IS a known page → not broken
        let issues = WikiLinkLinter.lint(pages, validSlugs: ["a", "b"])
        XCTAssertTrue(issues.filter { $0.kind == .brokenLink }.isEmpty)
    }

    func testSeeAlsoReciprocity() {
        let pages = [
            WikiLintPage(slug: "a", body: "body\n\n## See Also\n- [[b]]\n", category: "concept"),
            WikiLintPage(slug: "b", body: "body, no see-also back to a", category: "concept"),
        ]
        let issues = WikiLinkLinter.lint(pages)
        let nonReciprocal = issues.filter { $0.kind == .nonReciprocalSeeAlso }
        XCTAssertEqual(nonReciprocal.count, 1)
        XCTAssertEqual(nonReciprocal[0].page, "a")
        XCTAssertEqual(nonReciprocal[0].target, "b")
    }

    func testReciprocalSeeAlsoIsClean() {
        let pages = [
            WikiLintPage(slug: "a", body: "x\n## See Also\n- [[b]]\n", category: "concept"),
            WikiLintPage(slug: "b", body: "y\n## See Also\n- [[a]]\n", category: "concept"),
        ]
        XCTAssertTrue(WikiLinkLinter.lint(pages).filter { $0.kind == .nonReciprocalSeeAlso }.isEmpty)
    }

    func testSeeAlsoSectionStopsAtNextHeading() {
        // [[c]] is below the See Also section (under a later heading) → not a see-also edge
        let body = "## See Also\n- [[b]]\n\n## References\n- [[c]]\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: body), ["b"])
    }

    func testProseSeeAlsoIsNotASection() {
        // "See also [[b]]" in a sentence (no heading) must NOT count as a see-also edge.
        let body = "Background. See also [[b]] for context. More text."
        XCTAssertTrue(WikiLinkLinter.seeAlsoLinks(in: body).isEmpty)
        // and a real heading still works
        let withHeading = "x\n### See Also\n- [[b]]\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: withHeading), ["b"])
        // a page with only prose "see also" should not be flagged non-reciprocal
        let pages = [
            WikiLintPage(slug: "a", body: "See also [[b]] inline.", category: "concept"),
            WikiLintPage(slug: "b", body: "no backlink", category: "concept"),
        ]
        XCTAssertTrue(WikiLinkLinter.lint(pages).filter { $0.kind == .nonReciprocalSeeAlso }.isEmpty)
    }

    func testUngroundedSynthesisFlagged() {
        let pages = [
            WikiLintPage(slug: "plan1", body: "a plan that cites nothing", category: "plan", claimLinkCount: 0),
            WikiLintPage(slug: "rep1", body: "report citing [[plan1]]", category: "report", claimLinkCount: 0),
            WikiLintPage(slug: "rep2", body: "report with no links", category: "report", claimLinkCount: 3), // grounded via claims
            WikiLintPage(slug: "note1", body: "a concept with nothing", category: "concept"),  // not grounding-required
        ]
        let ungrounded = WikiLinkLinter.lint(pages, validSlugs: ["plan1", "rep1", "rep2", "note1"])
            .filter { $0.kind == .ungrounded }.map(\.page)
        XCTAssertEqual(ungrounded, ["plan1"])   // only the citation-less plan
    }

    // MULTIPLE See-Also blocks: links in the 2nd+ block must NOT count as content (the prior
    // first-block-only excision let an ungrounded page slip through by stuffing links into a
    // second `## See Also`). A SETEXT-headed content section AFTER the see-also block must be
    // preserved (the prior ATX-only boundary ate it, falsely flagging a grounded page).
    func testMultipleSeeAlsoBlocksAndSetextBoundary() {
        // (a) two See-Also blocks, 0 claims, no real content link → ungrounded
        let twoBlocks = "# T\n\n## Sources\n- https://e/a\n\n## See Also\n- [[r1]]\n\n## See Also\n- [[r2]]\n"
        let aIssues = WikiLinkLinter.lint(
            [WikiLintPage(slug: "t", body: twoBlocks, category: "synthesis", claimLinkCount: 0)],
            validSlugs: ["t", "r1", "r2"])
        XCTAssertTrue(aIssues.contains { $0.kind == .ungrounded },
                      "links in a 2nd See-Also block are navigation, not content grounding")
        // seeAlsoLinks now collects from ALL blocks
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: twoBlocks)), ["r1", "r2"])

        // (b) a setext-headed content section after See-Also keeps its content link → grounded
        let setext = "# T\nno links yet\n\n## See Also\n- [[nav]]\n\nReal Content\n============\ncites [[real]]\n"
        let bIssues = WikiLinkLinter.lint(
            [WikiLintPage(slug: "t", body: setext, category: "synthesis", claimLinkCount: 0)],
            validSlugs: ["t", "nav", "real"])
        XCTAssertFalse(bIssues.contains { $0.kind == .ungrounded },
                       "a real content link under a setext heading after See-Also still grounds")
        XCTAssertEqual(WikiLinkLinter.bodyExcludingSeeAlso(setext).contains("[[real]]"), true)
        XCTAssertEqual(WikiLinkLinter.bodyExcludingSeeAlso(setext).contains("[[nav]]"), false)
    }

    // A See-Also edge is NAVIGATION, not a citation: a grounding-required page whose ONLY
    // [[link]] sits under a "See Also" heading (and 0 claims) cites nothing real → ungrounded.
    // A page with the SAME link as a CONTENT link (body, not see-also) is grounded.
    func testSeeAlsoOnlyLinkDoesNotGroundButContentLinkDoes() {
        let pages = [
            // only a see-also link, 0 claims → ungrounded
            WikiLintPage(slug: "a", body: "intro\n\n## See Also\n- [[b]]\n", category: "report",
                         claimLinkCount: 0),
            // a real content citation (not under See Also) → grounded
            WikiLintPage(slug: "b", body: "this report builds on [[a]] directly.\n\n## See Also\n- [[a]]\n",
                         category: "report", claimLinkCount: 0),
        ]
        let ungrounded = WikiLinkLinter.lint(pages, validSlugs: ["a", "b"])
            .filter { $0.kind == .ungrounded }.map(\.page)
        XCTAssertEqual(ungrounded, ["a"], "see-also-only is ungrounded; a content link grounds")
    }
}
