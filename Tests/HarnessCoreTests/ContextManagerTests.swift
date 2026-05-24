import XCTest
import Foundation
@testable import HarnessCore
@testable import ProtocolModel

final class ContextManagerTests: XCTestCase {

    func testByteBasedEstimateIncludesBaseInstructions() {
        var c = ContextManager()
        c.baseInstructions = String(repeating: "x", count: 400)   // 400 bytes → 100 tokens
        XCTAssertEqual(c.estimatedTokens, 100, "no items: ceil(400/4) base tokens only")
        c.appendUser([TurnInput(text: "hello world")])
        XCTAssertGreaterThan(c.estimatedTokens, 100, "item bytes add to the estimate")
    }

    func testTotalTokenUsageIsServerPlusItemsAfterLastModelGenerated() {
        var c = ContextManager()
        c.appendUser([TurnInput(text: "q1")])
        c.appendAssistant("a1", id: ItemId("a1"))      // model-generated boundary
        c.setLastServerTotalTokens(1000)
        // Items after the last model-generated item (the assistant message):
        c.appendItem(.commandExecution(id: ItemId("c1"), command: ["echo"], cwd: "/w",
                                       status: .completed,
                                       aggregatedOutput: String(repeating: "Z", count: 80),
                                       exitCode: 0))
        let total = c.totalTokenUsage()
        XCTAssertGreaterThan(total, 1000, "server last total + post-model-generated estimate")
        // Estimate of the trailing command item alone (no server, before the
        // assistant) is excluded from the 'after' window only items recorded
        // after the assistant count.
        XCTAssertLessThan(total, 1000 + 10_000)
    }

    func testRecordTimeOutputTruncation() {
        var c = ContextManager()
        c.appendItem(.commandExecution(id: ItemId("c1"), command: ["x"], cwd: "/w",
                                       status: .completed,
                                       aggregatedOutput: String(repeating: "A", count: 100_000),
                                       exitCode: 0),
                     maxOutputBytes: 64)
        guard case .commandExecution(_, _, _, _, let out, _) = c.history[0] else {
            return XCTFail("expected commandExecution")
        }
        XCTAssertTrue((out ?? "").contains("bytes elided"),
                      "tool output is truncated on record (policy*1.2 head/tail ring)")
        XCTAssertLessThan((out ?? "").utf8.count, 100_000)
    }

    func testDropLastNUserTurnsRollback() {
        var c = ContextManager()
        c.appendUser([TurnInput(text: "u1")])
        c.appendAssistant("a1", id: ItemId("a1"))
        c.appendUser([TurnInput(text: "u2")])
        c.appendAssistant("a2", id: ItemId("a2"))
        c.appendUser([TurnInput(text: "u3")])
        let v0 = c.historyVersion
        c.dropLastNUserTurns(2)   // drop u2.. and u3..
        XCTAssertEqual(c.history.count, 2, "keeps u1 + a1; drops from the 2nd-from-last user msg")
        XCTAssertEqual(c.historyVersion, v0 + 1, "rewrite bumps history_version")
        if case .userMessage(_, let cnt) = c.history[0] {
            XCTAssertEqual(cnt.first?.text, "u1")
        } else { XCTFail("first surviving item should be u1") }
        // n >= user count → drop from the first user message.
        c.dropLastNUserTurns(99)
        XCTAssertTrue(c.history.isEmpty)
    }

    func testReplaceAndRemoveBumpVersion() {
        var c = ContextManager()
        c.appendUser([TurnInput(text: "a")])
        let v0 = c.historyVersion
        _ = c.replace([.agentMessage(id: ItemId("s"), text: "sum")])
        XCTAssertEqual(c.historyVersion, v0 + 1)
        XCTAssertEqual(c.history.count, 1)
        _ = c.removeLastItem()
        XCTAssertEqual(c.historyVersion, v0 + 2)
        XCTAssertTrue(c.history.isEmpty)
        XCTAssertEqual(c.removeFirstItem(), 0, "empty history → no-op")
    }

    // MARK: - P5.2 / H-41 — removeFirstItem removes its call/output pair
    //
    // Mirrors upstream `ContextManager::remove_first_item` +
    // `normalize::remove_corresponding_for` in
    // `core/src/context_manager/{history.rs,normalize.rs}`. Our `ThreadItem`
    // unifies a call and its output into a single `.commandExecution` entry,
    // but if history ever contains a split representation (two
    // `.commandExecution` items sharing the same `ItemId` — one for the call,
    // one for its output) both halves must drop together.

    func testRemoveFirstItemPaireToolCallAndOutput() {
        var c = ContextManager()
        // toolCall(id=A) — in-progress, no output yet
        c.appendItem(.commandExecution(id: ItemId("A"), command: ["echo", "A"],
                                       cwd: "/w", status: .inProgress,
                                       aggregatedOutput: nil, exitCode: nil))
        // toolOutput(id=A) — completed half of the same call
        c.appendItem(.commandExecution(id: ItemId("A"), command: ["echo", "A"],
                                       cwd: "/w", status: .completed,
                                       aggregatedOutput: "outA", exitCode: 0))
        c.appendItem(.agentMessage(id: ItemId("m"), text: "ack"))
        c.appendItem(.commandExecution(id: ItemId("B"), command: ["echo", "B"],
                                       cwd: "/w", status: .inProgress,
                                       aggregatedOutput: nil, exitCode: nil))
        c.appendItem(.commandExecution(id: ItemId("B"), command: ["echo", "B"],
                                       cwd: "/w", status: .completed,
                                       aggregatedOutput: "outB", exitCode: 0))

        let removed = c.removeFirstItem()
        XCTAssertEqual(removed, 2,
                       "first item is a tool-call → its paired output is removed too")
        XCTAssertEqual(c.history.count, 3)
        // No item with id "A" should remain (both halves dropped).
        let survivingIds = c.history.map(\.id.raw)
        XCTAssertFalse(survivingIds.contains("A"),
                       "tool-output for call A is GONE; the model never sees a dangling output")
        // Remaining order is exactly [agentMessage, toolCall(B), toolOutput(B)].
        guard case .agentMessage(_, let t) = c.history[0] else {
            return XCTFail("expected agentMessage at [0]")
        }
        XCTAssertEqual(t, "ack")
        guard case .commandExecution(let id1, _, _, let st1, let out1, _) = c.history[1] else {
            return XCTFail("expected commandExecution at [1]")
        }
        XCTAssertEqual(id1.raw, "B")
        XCTAssertEqual(st1, .inProgress)
        XCTAssertNil(out1)
        guard case .commandExecution(let id2, _, _, let st2, let out2, _) = c.history[2] else {
            return XCTFail("expected commandExecution at [2]")
        }
        XCTAssertEqual(id2.raw, "B")
        XCTAssertEqual(st2, .completed)
        XCTAssertEqual(out2, "outB")
    }

    func testRemoveFirstItemNoOrphansOnPlainMessage() {
        var c = ContextManager()
        c.appendItem(.agentMessage(id: ItemId("m"), text: "hello"))
        c.appendItem(.commandExecution(id: ItemId("c1"), command: ["echo"], cwd: "/w",
                                       status: .completed,
                                       aggregatedOutput: "out", exitCode: 0))
        c.appendItem(.commandExecution(id: ItemId("c2"), command: ["echo"], cwd: "/w",
                                       status: .completed,
                                       aggregatedOutput: "out2", exitCode: 0))

        let removed = c.removeFirstItem()
        XCTAssertEqual(removed, 1,
                       "agentMessage has no call/output pair → only the message is removed")
        XCTAssertEqual(c.history.count, 2)
        // Surviving items are the two commandExecutions, in order.
        guard case .commandExecution(let id1, _, _, _, _, _) = c.history[0] else {
            return XCTFail("expected commandExecution at [0]")
        }
        XCTAssertEqual(id1.raw, "c1")
        guard case .commandExecution(let id2, _, _, _, _, _) = c.history[1] else {
            return XCTFail("expected commandExecution at [1]")
        }
        XCTAssertEqual(id2.raw, "c2")
    }

    func testRemoveFirstItemHandlesOrphanCallGracefully() {
        var c = ContextManager()
        // Single tool-call with no output anywhere in history.
        c.appendItem(.commandExecution(id: ItemId("X"), command: ["echo"], cwd: "/w",
                                       status: .inProgress,
                                       aggregatedOutput: nil, exitCode: nil))

        let removed = c.removeFirstItem()
        XCTAssertEqual(removed, 1,
                       "orphan call with no paired output → just removed, no crash")
        XCTAssertEqual(c.history.count, 0)
    }

    // MARK: - P5.2 follow-up — removeLastItem also removes orphan pairs
    //
    // Upstream `ContextManager::remove_last_item`
    // (`core/src/context_manager/history.rs:172`) symmetrically calls
    // `normalize::remove_corresponding_for` on the popped item, so removing
    // the newest half of a split call/output pair also drops the older half.

    func testRemoveLastItemRemovesPairedCallAndOutput() {
        var c = ContextManager()
        c.appendItem(.agentMessage(id: ItemId("m"), text: "ack"))
        // Split pair sharing id "Z": call first, then output.
        c.appendItem(.commandExecution(id: ItemId("Z"), command: ["echo", "Z"],
                                       cwd: "/w", status: .inProgress,
                                       aggregatedOutput: nil, exitCode: nil))
        c.appendItem(.commandExecution(id: ItemId("Z"), command: ["echo", "Z"],
                                       cwd: "/w", status: .completed,
                                       aggregatedOutput: "outZ", exitCode: 0))

        let v0 = c.historyVersion
        let removed = c.removeLastItem()
        XCTAssertTrue(removed,
                      "popping a paired tool-output must report success")
        XCTAssertEqual(c.historyVersion, v0 + 1,
                       "removeLastItem bumps historyVersion exactly once per call")
        XCTAssertEqual(c.history.count, 1,
                       "BOTH halves of the Z pair must be gone — only the message remains")
        let survivingIds = c.history.map(\.id.raw)
        XCTAssertFalse(survivingIds.contains("Z"),
                       "no dangling tool-call for Z; orphan invariant preserved")
        guard case .agentMessage(_, let t) = c.history[0] else {
            return XCTFail("expected agentMessage to be the sole survivor")
        }
        XCTAssertEqual(t, "ack")
    }

    func testRemoveLastItemNoOrphansOnPlainMessage() {
        var c = ContextManager()
        c.appendItem(.commandExecution(id: ItemId("c1"), command: ["echo"], cwd: "/w",
                                       status: .completed,
                                       aggregatedOutput: "out", exitCode: 0))
        c.appendItem(.agentMessage(id: ItemId("m"), text: "bye"))

        let v0 = c.historyVersion
        let removed = c.removeLastItem()
        XCTAssertTrue(removed)
        XCTAssertEqual(c.historyVersion, v0 + 1,
                       "removeLastItem on a non-paired tail bumps historyVersion exactly once")
        XCTAssertEqual(c.history.count, 1,
                       "agentMessage has no pair → unrelated commandExecution survives")
        guard case .commandExecution(let id, _, _, _, _, _) = c.history[0] else {
            return XCTFail("expected commandExecution to survive")
        }
        XCTAssertEqual(id.raw, "c1")
    }

    // P5.2 follow-up — symmetry with `testRemoveFirstItemHandlesOrphanCallGracefully`.
    // Upstream `ContextManager::remove_last_item` calls
    // `normalize::remove_corresponding_for` on the popped item; when the
    // popped item is a tool-call whose paired output never landed in history
    // (orphan call), the corresponding-pair search finds nothing and the call
    // is simply removed without a crash. historyVersion still bumps exactly
    // once for the single removal.
    func testRemoveLastItemHandlesOrphanCallGracefully() {
        var c = ContextManager()
        // Single tool-call with no paired output anywhere in history.
        c.appendItem(.commandExecution(id: ItemId("X"), command: ["echo"], cwd: "/w",
                                       status: .inProgress,
                                       aggregatedOutput: nil, exitCode: nil))

        let v0 = c.historyVersion
        let removed = c.removeLastItem()
        XCTAssertTrue(removed,
                      "orphan call with no paired output → just removed, no crash")
        XCTAssertEqual(c.history.count, 0,
                       "the orphan call is gone; history is empty")
        XCTAssertEqual(c.historyVersion, v0 + 1,
                       "exactly one historyVersion bump even though pair-search found nothing")
    }

    // MARK: - P5.1 / H-38 — items_after_last_model_generated empty fallback
    //
    // Faithful to upstream `items_after_last_model_generated_item`
    // (`core/src/context_manager/history.rs:298`). When the history contains
    // no model-generated item (assistant message or reasoning), Rust returns
    // `&items[items.len()..]` — an EMPTY slice — by way of
    // `rposition(...).map_or(items.len(), |i| i+1)`. Previously the Swift
    // fallback returned the whole slice, which after compaction (whose new
    // history is all user-role) caused `totalTokenUsage()` to count every
    // post-compact item on top of the stale `lastServerTotalTokens`.
    func testItemsAfterLastModelGeneratedReturnsEmptyForNonModelHistory() {
        var c = ContextManager()
        c.appendUser([TurnInput(text: "u1")])
        c.appendUser([TurnInput(text: "u2")])
        c.appendItem(.commandExecution(id: ItemId("c1"), command: ["echo"], cwd: "/w",
                                       status: .completed,
                                       aggregatedOutput: "out", exitCode: 0))
        // No assistant / reasoning anywhere → tail must be empty.
        XCTAssertTrue(c.itemsAfterLastModelGenerated().isEmpty,
                      "no model-generated item → upstream returns items[len..], i.e. empty")
        // And by extension: totalTokenUsage == lastServerTotalTokens, NOT
        // lastServer + sum(history). Pre-fix this returned a vastly inflated
        // value because every user message was double-counted.
        c.setLastServerTotalTokens(2_500)
        XCTAssertEqual(c.totalTokenUsage(), 2_500,
                       "with no model-gen tail, totalTokenUsage is the server-reported value")
    }

    // MARK: - P5.1 / H-39 — recomputeTokenUsage after compaction
    //
    // Faithful to upstream `Session::recompute_token_usage`
    // (`core/src/session/mod.rs:2960`): re-baseline `last_token_usage.total`
    // to the whole-history estimate (base instructions + every item) after a
    // wholesale rewrite. Without this, a freshly compacted history continues
    // to report the stale pre-compact server total in `totalTokenUsage`.
    func testRecomputeTokenUsageAfterCompaction() {
        var c = ContextManager()
        c.baseInstructions = "system prompt"
        // Simulate a session that ran for a while and the server reported a
        // large total. After compaction this MUST be re-baselined.
        c.setLastServerTotalTokens(250_000)
        let compactHistory: [ThreadItem] = [
            .userMessage(id: ItemId("u1"), content: [UserMessageContent(text: "msg one")]),
            .userMessage(id: ItemId("u2"), content: [UserMessageContent(text: "msg two")]),
            .userMessage(id: ItemId("compact"),
                         content: [UserMessageContent(text: "tiny summary")]),
        ]
        _ = c.replace(compactHistory)
        let pre = c.estimatedTokens
        XCTAssertLessThan(pre, 250_000,
                          "test invariant: compact history estimate is far below stale total")
        let estimate = c.recomputeTokenUsage()
        XCTAssertEqual(estimate, pre, "recompute returns the whole-history estimate")
        XCTAssertEqual(c.lastServerTotalTokens, pre,
                       "lastServerTotalTokens is overwritten with the estimate, dropping the stale 250000")
        XCTAssertNotEqual(c.lastServerTotalTokens, 250_000,
                          "stale pre-compact server total must be GONE")
        // After H-38's fix, no-model-gen tail is empty, so totalTokenUsage
        // now equals the recomputed baseline.
        XCTAssertEqual(c.totalTokenUsage(), pre,
                       "post-recompute, totalTokenUsage tracks the new baseline (no double-counting)")
    }

    func testForPromptSendsFullTranscriptInOrder() {
        var c = ContextManager()
        c.appendUser([TurnInput(text: "u1")])
        c.appendAssistant("a1", id: ItemId("a1"))
        c.appendItem(.commandExecution(id: ItemId("c1"), command: ["echo"], cwd: "/w",
                                       status: .completed, aggregatedOutput: "out1", exitCode: 0))
        c.appendUser([TurnInput(text: "u2")])
        let proj = c.forPrompt(extra: [.userText("EXTRA")])
        XCTAssertEqual(proj, [
            .userText("u1"),
            .assistantText("a1"),
            .toolOutput(callId: "c1", output: "out1"),
            .userText("u2"),
            .userText("EXTRA"),
        ], "for_prompt sends the full chronological transcript incl. assistant turns")
    }
}