import XCTest
@testable import HarnessCore
@testable import ProtocolModel
import Tokenizer

final class CompactionHelpersTests: XCTestCase {

    private func user(_ t: String) -> ThreadItem {
        .userMessage(id: ItemId.generate("u"), content: [UserMessageContent(text: t)])
    }

    func testIsSummaryMessage() {
        XCTAssertTrue(Compaction.isSummaryMessage(Compaction.summaryPrefix + "\nbody"))
        XCTAssertFalse(Compaction.isSummaryMessage("just a user message"))
        XCTAssertFalse(Compaction.isSummaryMessage(Compaction.summaryPrefix),
                       "prefix must be followed by a newline (Codex is_summary_message)")
    }

    func testCollectUserMessagesExcludesPriorSummaries() {
        let items: [ThreadItem] = [
            user("first"),
            .agentMessage(id: ItemId("a"), text: "assistant"),
            user(Compaction.summaryPrefix + "\nold summary"),
            user("second"),
        ]
        XCTAssertEqual(Compaction.collectUserMessages(items), ["first", "second"])
    }

    func testBuildCompactedHistoryIsTokenBoundedAndSummaryLast() {
        // 3 user messages; tiny token budget keeps only the most recent.
        let msgs = ["aaaa aaaa aaaa", "bbbb bbbb bbbb", "cccc cccc cccc"]
        let summary = Compaction.summaryPrefix + "\nSUMMARY"
        let h = Compaction.buildCompactedHistory(initialContext: [],
                                                 userMessages: msgs,
                                                 summaryText: summary,
                                                 maxTokens: 4) // ~16 bytes budget
        // Last item is always the summary user message.
        guard case .userMessage(_, let last) = h.last else { return XCTFail("summary last") }
        XCTAssertEqual(last.first?.text, summary)
        // Only the most recent user message(s) fit under the budget.
        let texts = h.dropLast().compactMap { item -> String? in
            if case .userMessage(_, let c) = item { return c.first?.text }
            return nil
        }
        XCTAssertTrue(texts.allSatisfy { msgs.contains($0) || $0.hasPrefix("cccc") })
        XCTAssertFalse(texts.contains("aaaa aaaa aaaa"), "oldest dropped under budget")
    }

    func testBuildCompactedHistoryEmptySummaryFallback() {
        let h = Compaction.buildCompactedHistory(initialContext: [],
                                                 userMessages: [], summaryText: "")
        guard case .userMessage(_, let c) = h.last else { return XCTFail() }
        XCTAssertEqual(c.first?.text, "(no summary available)")
    }

    func testInsertInitialContextBeforeLastRealUser() {
        let ctx = user("INITIAL CONTEXT")
        let history: [ThreadItem] = [
            user("older"),
            user(Compaction.summaryPrefix + "\nsummary"),  // summary, not "real"
        ]
        // No real user after the summary → insert before the summary-like last.
        let out = Compaction.insertInitialContext(history, [ctx])
        // initial context is placed before the last real user ("older") here.
        guard case .userMessage(_, let first) = out.first else { return XCTFail() }
        XCTAssertEqual(first.first?.text, "INITIAL CONTEXT",
                       "inserted before the last real (non-summary) user message")
        XCTAssertEqual(out.count, 3)
    }

    func testInsertInitialContextAppendsWhenNoUserMessages() {
        let only: [ThreadItem] = [.agentMessage(id: ItemId("a"), text: "x")]
        let out = Compaction.insertInitialContext(only, [user("CTX")])
        XCTAssertEqual(out.count, 2)
        if case .userMessage(_, let c) = out.last { XCTAssertEqual(c.first?.text, "CTX") }
        else { XCTFail("appended at end when no user messages") }
    }

    // Finding: third-tier fallback — when no user/summary message exists but a
    // trailing compaction item does, upstream inserts initial context BEFORE the
    // compaction item so the compaction item stays last
    // (`insert_initial_context_before_last_real_user_or_summary`, compact.rs:419).
    func testInsertInitialContextBeforeTrailingCompactionItem() {
        let history: [ThreadItem] = [
            .agentMessage(id: ItemId("a"), text: "assistant"),
            .contextCompaction(id: ItemId("c")),
        ]
        let out = Compaction.insertInitialContext(history, [user("CTX")])
        XCTAssertEqual(out.count, 3)
        // Compaction item remains last; initial context inserted before it.
        guard case .contextCompaction = out.last else {
            return XCTFail("compaction item must remain last")
        }
        guard case .userMessage(_, let c) = out[1] else { return XCTFail("ctx before compaction") }
        XCTAssertEqual(c.first?.text, "CTX")
    }

    // A real user message still takes priority over a trailing compaction item.
    func testInsertInitialContextPrefersUserOverCompaction() {
        let history: [ThreadItem] = [
            user("real user"),
            .contextCompaction(id: ItemId("c")),
        ]
        let out = Compaction.insertInitialContext(history, [user("CTX")])
        XCTAssertEqual(out.count, 3)
        guard case .userMessage(_, let c0) = out[0] else { return XCTFail() }
        XCTAssertEqual(c0.first?.text, "CTX", "inserted before the real user message, not the compaction item")
    }

    // Finding: boundary-message truncation marker must match upstream
    // `truncate_middle_with_token_budget` ("…N tokens truncated…", token units,
    // no surrounding newlines) rather than the byte-elision HeadTailBuffer marker.
    func testTruncateToTokensZeroLimitMarker() {
        // Ported from upstream `truncate_with_token_budget_reports_truncation_at_zero_limit`.
        XCTAssertEqual(Compaction.truncateToTokens("abcdef", 0), "…2 tokens truncated…")
    }

    func testTruncateToTokensUnderLimitReturnsOriginal() {
        XCTAssertEqual(Compaction.truncateToTokens("short output", 100), "short output")
    }

    func testTruncateToTokensUtf8() {
        // Ported from upstream `truncate_middle_tokens_handles_utf8_content`.
        let s = "😀😀😀😀😀😀😀😀😀😀\nsecond line with text\n"
        XCTAssertEqual(Compaction.truncateToTokens(s, 8),
                       "😀😀😀😀…8 tokens truncated… line with text\n")
    }

    func testTruncateToTokensMarkerHasNoNewlines() {
        // The marker must not introduce leading/trailing newlines (regression
        // guard against the prior HeadTailBuffer "\n… bytes elided …\n" form).
        let out = Compaction.truncateToTokens(String(repeating: "x", count: 200), 4)
        XCTAssertTrue(out.contains("tokens truncated"))
        XCTAssertFalse(out.contains("bytes elided"))
        XCTAssertFalse(out.contains("\n… "))
    }

    // Finding: config-level model_auto_compact_token_limit min().
    func testAutoCompactLimitMinsConfigOverride() {
        let cat = ModelCatalog.default
        let windowLimit = cat.autoCompactLimit(for: "gpt-5.5")  // (272000*9)/10
        // No override → window-derived value verbatim.
        XCTAssertEqual(cat.autoCompactLimit(for: "gpt-5.5", configOverride: nil), windowLimit)
        // Override lower than window → override wins (min).
        XCTAssertEqual(cat.autoCompactLimit(for: "gpt-5.5", configOverride: 1_000), 1_000)
        // Override higher than window → window wins (min).
        XCTAssertEqual(cat.autoCompactLimit(for: "gpt-5.5", configOverride: 10_000_000), windowLimit)
    }
}