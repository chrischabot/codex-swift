import XCTest
@testable import Prompts

/// Ports the behavioral contract of `core/src/review_format.rs`.
final class ReviewFormatTests: XCTestCase {

    private func finding(_ title: String, _ body: String,
                         _ path: String, _ start: UInt32, _ end: UInt32) -> ReviewFinding {
        ReviewFinding(title: title, body: body,
                      codeLocation: ReviewCodeLocation(
                        absoluteFilePath: path,
                        lineRange: ReviewLineRange(start: start, end: end)))
    }

    func testSingleFindingHeaderAndLineFormat() {
        let f = finding("Off-by-one", "Loop bound is wrong.\nUse <= here.",
                        "/repo/src/main.swift", 10, 12)
        let block = ReviewFormat.formatReviewFindingsBlock([f], selection: nil)
        let expected = [
            "",
            "Review comment:",
            "",
            "- Off-by-one — /repo/src/main.swift:10-12",
            "  Loop bound is wrong.",
            "  Use <= here.",
        ].joined(separator: "\n")
        XCTAssertEqual(block, expected)
    }

    func testMultipleFindingsUsePluralHeader() {
        let f1 = finding("A", "body a", "/a.swift", 1, 2)
        let f2 = finding("B", "body b", "/b.swift", 3, 4)
        let block = ReviewFormat.formatReviewFindingsBlock([f1, f2], selection: nil)
        XCTAssertTrue(block.contains("Full review comments:"))
        XCTAssertFalse(block.contains("Review comment:"))
        XCTAssertTrue(block.contains("- A — /a.swift:1-2"))
        XCTAssertTrue(block.contains("- B — /b.swift:3-4"))
    }

    func testSelectionMarkers() {
        let f1 = finding("A", "", "/a.swift", 1, 1)
        let f2 = finding("B", "", "/b.swift", 2, 2)
        let f3 = finding("C", "", "/c.swift", 3, 3)
        // f1 selected, f2 unselected, f3 index out-of-bounds -> defaults selected.
        let block = ReviewFormat.formatReviewFindingsBlock([f1, f2, f3],
                                                           selection: [true, false])
        XCTAssertTrue(block.contains("- [x] A — /a.swift:1-1"))
        XCTAssertTrue(block.contains("- [ ] B — /b.swift:2-2"))
        XCTAssertTrue(block.contains("- [x] C — /c.swift:3-3"))
    }

    func testRenderJoinsExplanationAndFindings() {
        let f = finding("Bug", "details", "/x.swift", 5, 5)
        let out = ReviewOutputEvent(findings: [f],
                                    overallExplanation: "  Looks mostly fine.  ")
        let text = ReviewFormat.renderReviewOutputText(out)
        // Explanation trimmed, then blank line, then trimmed findings block.
        let expected = [
            "Looks mostly fine.",
            "",
            "Review comment:",
            "",
            "- Bug — /x.swift:5-5",
            "  details",
        ].joined(separator: "\n")
        XCTAssertEqual(text, expected)
    }

    func testRenderExplanationOnly() {
        let out = ReviewOutputEvent(findings: [],
                                    overallExplanation: "All good.")
        XCTAssertEqual(ReviewFormat.renderReviewOutputText(out), "All good.")
    }

    func testRenderFindingsOnly() {
        let f = finding("Bug", "details", "/x.swift", 5, 5)
        let out = ReviewOutputEvent(findings: [f], overallExplanation: "   ")
        let text = ReviewFormat.renderReviewOutputText(out)
        XCTAssertTrue(text.hasPrefix("Review comment:"))
        XCTAssertTrue(text.contains("- Bug — /x.swift:5-5"))
    }

    func testRenderFallbackWhenEmpty() {
        let out = ReviewOutputEvent()
        XCTAssertEqual(ReviewFormat.renderReviewOutputText(out),
                       "Reviewer failed to output a response.")
    }

    func testFallbackMessageConstant() {
        XCTAssertEqual(ReviewFormat.reviewFallbackMessage,
                       "Reviewer failed to output a response.")
    }

    func testCodableWireKeysAreSnakeCase() throws {
        let f = finding("T", "B", "/p.swift", 1, 2)
        let out = ReviewOutputEvent(findings: [f], overallCorrectness: "correct",
                                    overallExplanation: "ok", overallConfidenceScore: 0.5)
        let data = try JSONEncoder().encode(out)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"overall_correctness\""))
        XCTAssertTrue(json.contains("\"overall_explanation\""))
        XCTAssertTrue(json.contains("\"overall_confidence_score\""))
        XCTAssertTrue(json.contains("\"confidence_score\""))
        XCTAssertTrue(json.contains("\"code_location\""))
        XCTAssertTrue(json.contains("\"absolute_file_path\""))
        XCTAssertTrue(json.contains("\"line_range\""))
        // round-trip
        let back = try JSONDecoder().decode(ReviewOutputEvent.self, from: data)
        XCTAssertEqual(back, out)
    }

    /// prompts finding 1 / tasks/review.rs:194 `parse_review_output_event`.
    func testParseReviewOutputEventStrictJSON() {
        let text = "{\"findings\":[],\"overall_correctness\":\"correct\","
            + "\"overall_explanation\":\"looks ok\",\"overall_confidence_score\":0.9}"
        let ev = ReviewFormat.parseReviewOutputEvent(text)
        XCTAssertEqual(ev.overallExplanation, "looks ok")
        XCTAssertEqual(ev.overallCorrectness, "correct")
        XCTAssertTrue(ev.findings.isEmpty)
    }

    /// Extracts the first `{`…last `}` substring when the blob is wrapped in
    /// prose / code fences (upstream's second parse attempt).
    func testParseReviewOutputEventExtractsEmbeddedJSON() {
        let json = "{\"findings\":[],\"overall_correctness\":\"incorrect\","
            + "\"overall_explanation\":\"bug found\",\"overall_confidence_score\":0.1}"
        let text = "Here is the review:\n```json\n" + json + "\n```\nThanks!"
        let ev = ReviewFormat.parseReviewOutputEvent(text)
        XCTAssertEqual(ev.overallExplanation, "bug found")
        XCTAssertEqual(ev.overallCorrectness, "incorrect")
    }

    /// A partial object (missing required fields) fails both parse attempts and
    /// falls back to the plain text in `overall_explanation` (upstream's
    /// `ReviewOutputEvent { overall_explanation: text, ..Default::default() }`).
    func testParseReviewOutputEventFallsBackToPlainText() {
        let text = "not even close to JSON"
        let ev = ReviewFormat.parseReviewOutputEvent(text)
        XCTAssertEqual(ev.overallExplanation, text)
        XCTAssertTrue(ev.findings.isEmpty)
        // And the rendered text is just the explanation.
        XCTAssertEqual(ReviewFormat.renderReviewOutputText(ev), text)
    }
}
