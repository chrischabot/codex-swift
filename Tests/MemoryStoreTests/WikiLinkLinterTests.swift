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

    // A fenced literal "## See Also" is inert; content around it survives.
    func testFencedSeeAlsoIsInert() {
        let fenced = "# T\ncites [[real]]\n\n```\n## See Also\n- [[fakeInFence]]\n```\n\nmore at [[real2]]\n"
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(fenced).contains("[[real2]]"),
                      "content after a fenced ## See Also must not be eaten")
        XCTAssertTrue(WikiLinkLinter.seeAlsoLinks(in: fenced).isEmpty,
                      "a fenced ## See Also creates no real see-also section")
    }

    // THE CONTRACT (a 7-round adversarial panel converged on this): EVERY [[link]] under a See
    // Also heading, to the next heading/fence, is NAVIGATION — never a content/grounding
    // citation. Splitting nav from content within a See-Also section is ambiguous in free-form
    // prose (the panel produced directly-conflicting realistic cases), so we fail closed: a
    // grounding citation must live in the body or under its own heading. A link-FREE trailing
    // note is the only prose split out (it carries no links, so no verdict depends on it).
    func testAllLinksUnderSeeAlsoAreNavigation() {
        // trailing link-bearing prose after a list → nav (not content)
        let afterList = "## See Also\n- [[nav]]\n\nGrounded in the analysis at [[real]].\n"
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: afterList)), ["nav", "real"])
        XCTAssertFalse(WikiLinkLinter.bodyExcludingSeeAlso(afterList).contains("[[real]]"))
        // bare links + trailing link-bearing prose, glued or blank-separated → all nav
        let bareTrailing = "## See Also\n[[nav1]]\nThe rest is in [[real]].\n"
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: bareTrailing)), ["nav1", "real"])
        // a grounding-required page whose ONLY links are see-also nav (any layout) is UNGROUNDED
        let report = "# R\n\n## See Also\n[[nav1]] and [[nav2]] are related; details in [[more]].\n"
        let g = WikiLinkLinter.lint([WikiLintPage(slug: "r", body: report, category: "report", claimLinkCount: 0)],
                                    validSlugs: ["r", "nav1", "nav2", "more"])
        XCTAssertTrue(g.contains { $0.kind == .ungrounded }, "see-also-only report cites nothing real → ungrounded")
        // a link-FREE trailing note IS content (no links → no verdict impact, but readable text)
        let note = "## See Also\n- [[nav]]\n\nThat is all for now.\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: note), ["nav"])
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(note).contains("That is all"))
    }

    // A See-Also written as MULTIPLE prose sentences, each carrying links, is ALL navigation —
    // not just the first sentence (the round-7 carriesLink asymmetry kept only line 1). Both
    // sentences' links are see-also edges (so reciprocity sees them and they don't ground).
    func testMultiSentenceProseSeeAlsoIsAllNavigation() {
        let body = "## See Also\nSee [[foo]] for the derivation.\nThe [[bar]] page has worked examples.\n"
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: body)), ["foo", "bar"],
                       "every link in a prose see-also is a nav edge, not only the first line's")
        XCTAssertFalse(WikiLinkLinter.bodyExcludingSeeAlso(body).contains("[[bar]]"))
    }

    // SETEXT ("See Also" + ---- underline) and BOLD ("**See Also**") headings must be
    // recognized too — not just ATX — or a navigation-only page slips past the grounding gate.
    // (Panel: isSeeAlsoHeading was ATX-only, letting an ungrounded plan/synthesis through.)
    func testSetextAndBoldSeeAlsoHeadings() {
        let setext = "# Migration Plan\n\nSee Also\n--------\n- [[architecture-overview]]\n- [[rollback-runbook]]\n"
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: setext)), ["architecture-overview", "rollback-runbook"],
                       "a setext See Also heading starts a section")
        let gs = WikiLinkLinter.lint([WikiLintPage(slug: "p", body: setext, category: "plan", claimLinkCount: 0)],
                                     validSlugs: ["p", "architecture-overview", "rollback-runbook"])
        XCTAssertTrue(gs.contains { $0.kind == .ungrounded }, "setext-see-also-only plan is ungrounded (was a gate bypass)")

        let bold = "# Architecture Synthesis\n\n**See Also**\n\n- [[data-flow]]\n- [[service-mesh]]\n"
        XCTAssertEqual(Set(WikiLinkLinter.seeAlsoLinks(in: bold)), ["data-flow", "service-mesh"],
                       "a **See Also** heading starts a section")
        let gb = WikiLinkLinter.lint([WikiLintPage(slug: "s", body: bold, category: "synthesis", claimLinkCount: 0)],
                                     validSlugs: ["s", "data-flow", "service-mesh"])
        XCTAssertTrue(gb.contains { $0.kind == .ungrounded }, "bold-see-also-only synthesis is ungrounded")
    }

    // A ≥4-space-indented ``` line is an INDENTED CODE BLOCK per CommonMark, NOT a fence — it
    // must not open a fence scan that swallows the real "## See Also" to EOF. (Panel.)
    func testIndentedBackticksAreNotAFence() {
        let body = "# R grounded on [[src]].\n\nA snippet:\n\n    ```text\n\n## See Also\n- [[companion]]\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: body), ["companion"],
                       "an indented-code ``` must not eat the real See Also heading")
    }

    // A page TITLE beginning "See also …" must NOT be mistaken for a See-Also section heading
    // (strict exact-match). (Panel: a research topic starting "See also" became the # H1.)
    func testTitleBeginningSeeAlsoIsNotASeeAlsoSection() {
        let body = "# See also: the GPU vendor landscape\n\nSynthesis grounded in [[real-claim]].\n\n## See Also\n- [[prior-r1]]\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: body), ["prior-r1"],
                       "the title is not a see-also heading; only the real ## See Also section counts")
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(body).contains("[[real-claim]]"),
                      "the body citation under the title stays content")
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

        // (e) a LINK-FREE trailing note after the list is content; a link-bearing trailing
        // line is navigation (all links under See-Also are nav — see the contract tests below).
        let note = "## See Also\n- [[nav]]\n\nThat is all for this release.\n"
        XCTAssertEqual(WikiLinkLinter.seeAlsoLinks(in: note), ["nav"])
        XCTAssertTrue(WikiLinkLinter.bodyExcludingSeeAlso(note).contains("That is all"))
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
