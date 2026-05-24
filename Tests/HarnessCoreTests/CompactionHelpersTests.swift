import XCTest
@testable import HarnessCore
@testable import ProtocolModel

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
}