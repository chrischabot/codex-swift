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

    // A See-Also section must consume ONLY its list, not trailing/interleaved CONTENT. The
    // prior next-heading-only bound absorbed prose after (or between) see-also lists, erasing
    // real citations → grounded pages falsely flagged ungrounded + content links leaking as
    // see-also edges. And a fenced literal "## See Also" must be inert.
    func testSeeAlsoDoesNotAbsorbTrailingOrInterleavedContent() {
        // (1a) prose citation AFTER the final See-Also block (no following heading) → grounds.
        let afterBlock = "# T\nintro\n\n## See Also\n- [[nav]]\n\nGrounded in the analysis at [[real]].\n"
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(afterBlock).contains("[[real]]"),
                      "a content link after the see-also list must stay in content")
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: afterBlock), ["nav"],
                       "[[real]] must NOT leak as a see-also edge")
        let a = WikiLinkLinter.lint([WikiLintPage(slug: "t", body: afterBlock, category: "report", claimLinkCount: 0)],
                                    validSlugs: ["t", "nav", "real"])
        XCTAssertFalse(a.contains { $0.kind == .ungrounded }, "the trailing [[real]] grounds the page")

        // (1b) content BETWEEN two See-Also blocks → grounds (the regression the line-wise fix introduced).
        let between = "# T\n\n## See Also\n- [[nav1]]\n\nMid prose grounded by [[mid]].\n\n## See Also\n- [[nav2]]\n"
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(between).contains("[[mid]]"))
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: between)), ["nav1", "nav2"])
        let b = WikiLinkLinter.lint([WikiLintPage(slug: "t", body: between, category: "report", claimLinkCount: 0)],
                                    validSlugs: ["t", "nav1", "nav2", "mid"])
        XCTAssertFalse(b.contains { $0.kind == .ungrounded })

        // (2) a fenced literal "## See Also" is inert; content around it survives.
        let fenced = "# T\ncites [[real]]\n\n```\n## See Also\n- [[fakeInFence]]\n```\n\nmore at [[real2]]\n"
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(fenced).contains("[[real2]]"),
                      "content after a fenced ## See Also must not be eaten")
        XCTAssertTrue(WikiLinkLinter.seeAlsoLinks(in: fenced).isEmpty,
                      "a fenced ## See Also creates no real see-also section")
    }

    // A See-Also section may open with a non-list LEAD-IN (prose intro, bare [[link]] lines,
    // or blockquote entries) before/instead of bullets. The round-3 first-line-must-be-a-list
    // bound leaked these entirely into content, defeating grounding + reciprocity. They must
    // be classified as see-also (so a see-also-only page is still ungrounded, and one-way
    // edges still flag non-reciprocal).
    func testSeeAlsoWithLeadInOrBareLinksIsStillSeeAlso() {
        // (a) prose lead-in then bullets → links are see-also, page is ungrounded
        let leadIn = "# Report\nThis report draws conclusions.\n\n## See Also\nRelated pages:\n- [[nav1]]\n- [[nav2]]\n"
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: leadIn)), ["nav1", "nav2"],
                       "a lead-in line does not stop the see-also list")
        XCTAssertFalse(WikiLinkLinter.bodyExcludingSeeAlso(leadIn).contains("[[nav1]]"),
                       "see-also nav links must not leak into content")
        let li = WikiLinkLinter.lint([WikiLintPage(slug: "rep", body: leadIn, category: "report", claimLinkCount: 0)],
                                     validSlugs: ["rep", "nav1", "nav2"])
        XCTAssertTrue(li.contains { $0.kind == .ungrounded }, "see-also-only (with lead-in) page is ungrounded")

        // (b) bare [[link]] lines with no bullets → see-also
        let bare = "## See Also\n[[nav1]]\n[[nav2]]\n"
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: bare)), ["nav1", "nav2"])

        // (c) blockquote entries → see-also
        let quoted = "## See Also\n> [[nav1]]\n> [[nav2]]\n"
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: quoted)), ["nav1", "nav2"])

        // (d) non-reciprocal still flagged when the section uses a lead-in
        let pages = [
            WikiLintPage(slug: "x", body: "intro\n\n## See Also\nSee:\n- [[b]]\n", category: "concept"),
            WikiLintPage(slug: "b", body: "no backlink", category: "concept"),
        ]
        let nonRecip = WikiLinkLinter.lint(pages).filter { $0.kind == .nonReciprocalSeeAlso }
        XCTAssertEqual(nonRecip.map(\.target), ["b"], "a one-way see-also with a lead-in still flags non-reciprocal")

        // (e) trailing prose AFTER the list still falls into content (round-3 win preserved)
        let trailing = "## See Also\n- [[nav]]\n\nGrounded at [[real]].\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: trailing), ["nav"])
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(trailing).contains("[[real]]"))
    }

    // A BULLET-LESS See-Also section (bare [[link]] / blockquote entries, no bullets) followed
    // by trailing content prose must NOT absorb that content — the round-4 sawListItem bound
    // only broke after a bullet, so bullet-less blocks swallowed real citations (false
    // ungrounded + false non-reciprocal). The end-trigger now fires on blank-then-prose for
    // any entry style.
    func testBareLinkSeeAlsoMustNotAbsorbTrailingContent() {
        let body = "## See Also\n[[nav1]]\n[[nav2]]\n\nGrounded at [[real]].\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: body), ["nav1", "nav2"],
                       "trailing content link must NOT be swept into a bullet-less see-also block")
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(body).contains("[[real]]"))

        // grounding false-negative guard: the real citation grounds the report
        let g = WikiLinkLinter.lint([WikiLintPage(slug: "r",
            body: "# R\n\n## See Also\n[[nav1]]\n\nThe analysis is grounded in [[real]].\n",
            category: "report", claimLinkCount: 0)], validSlugs: ["r", "nav1", "real"])
        XCTAssertFalse(g.contains { $0.kind == .ungrounded }, "trailing [[real]] grounds the page")

        // reciprocity false-positive guard: a body content link must not be read as see-also
        let rec = WikiLinkLinter.lint([
            WikiLintPage(slug: "a", body: "# A\n\n## See Also\n[[nav]]\n\nThis builds on [[peer]] in the body.\n", category: "concept"),
            WikiLintPage(slug: "peer", body: "no backlink", category: "concept"),
            WikiLintPage(slug: "nav", body: "nav\n\n## See Also\n[[a]]\n", category: "concept"),
        ]).filter { $0.kind == .nonReciprocalSeeAlso }
        XCTAssertFalse(rec.contains { $0.target == "peer" }, "a body content link is not a see-also edge")
    }

    // Trailing content glued DIRECTLY to a see-also entry (NO blank separator) must still end
    // the section — the round-5 blank-separator gate let `[[real]]` on the very next line leak
    // into see-also, falsely flagging the page .ungrounded (which BLOCKS the write in strict
    // mode) and the body link .nonReciprocalSeeAlso.
    func testNoBlankSeparatorBetweenEntryAndTrailingContent() {
        let body = "# R\n\n## See Also\n[[nav1]]\nThe analysis is grounded in [[real]].\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: body), ["nav1"],
                       "prose on the line right after an entry is content, not a see-also edge")
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(body).contains("[[real]]"))
        let g = WikiLinkLinter.lint([WikiLintPage(slug: "r", body: body, category: "report", claimLinkCount: 0)],
                                    validSlugs: ["r", "nav1", "real"])
        XCTAssertFalse(g.contains { $0.kind == .ungrounded }, "the directly-trailing [[real]] grounds the page")

        let rec = WikiLinkLinter.lint([
            WikiLintPage(slug: "a", body: "# A\n\n## See Also\n[[nav]]\nThis builds on [[peer]] in the body.\n", category: "concept"),
            WikiLintPage(slug: "peer", body: "no backlink", category: "concept"),
            WikiLintPage(slug: "nav", body: "nav\n\n## See Also\n[[a]]\n", category: "concept"),
        ]).filter { $0.kind == .nonReciprocalSeeAlso }
        XCTAssertFalse(rec.contains { $0.target == "peer" }, "a body content link on the next line is not a see-also edge")
    }

    // A See-Also section written entirely as PROSE with inline links (no bullets, no link-only
    // lines) running to EOF must still end at the first trailing-content prose line — the
    // round-6 break keyed on a STRUCTURED entry, so a prose-only see-also consumed the body's
    // trailing citation, falsely flagging the report .ungrounded (blocked in strict mode).
    func testProseOnlySeeAlsoDoesNotSwallowTrailingContent() {
        let body = "# Quarterly Report\n\nThe data shows growth.\n\n## See Also\n"
            + "Readers may also wish to review [[nav1]] and [[nav2]].\n"
            + "This conclusion rests on the figures in [[real]].\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: body), ["nav1", "nav2"],
                       "the prose see-also line is navigation; the trailing citation line is content")
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(body).contains("[[real]]"))
        let g = WikiLinkLinter.lint([WikiLintPage(slug: "report", body: body, category: "report", claimLinkCount: 0)],
                                    validSlugs: ["report", "nav1", "nav2", "real"])
        XCTAssertFalse(g.contains { $0.kind == .ungrounded }, "the trailing [[real]] grounds the report")

        // control: a link-free prose lead-in stays a pure lead-in (not an entry)
        let leadIn = "## See Also\nRelated pages:\n- [[nav1]]\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: leadIn), ["nav1"])
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
