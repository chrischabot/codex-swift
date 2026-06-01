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
                                       commandActions: [], aggregatedOutput: String(repeating: "Z", count: 80),
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
                                       commandActions: [], aggregatedOutput: String(repeating: "A", count: 100_000),
                                       exitCode: 0),
                     maxOutputBytes: 64)
        guard case .commandExecution(_, _, _, _, _, let out, _, _, _, _) = c.history[0] else {
            return XCTFail("expected commandExecution")
        }
        XCTAssertTrue((out ?? "").contains("tokens truncated"),
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
                                       commandActions: [], aggregatedOutput: nil, exitCode: nil))
        // toolOutput(id=A) — completed half of the same call
        c.appendItem(.commandExecution(id: ItemId("A"), command: ["echo", "A"],
                                       cwd: "/w", status: .completed,
                                       commandActions: [], aggregatedOutput: "outA", exitCode: 0))
        c.appendItem(.agentMessage(id: ItemId("m"), text: "ack"))
        c.appendItem(.commandExecution(id: ItemId("B"), command: ["echo", "B"],
                                       cwd: "/w", status: .inProgress,
                                       commandActions: [], aggregatedOutput: nil, exitCode: nil))
        c.appendItem(.commandExecution(id: ItemId("B"), command: ["echo", "B"],
                                       cwd: "/w", status: .completed,
                                       commandActions: [], aggregatedOutput: "outB", exitCode: 0))

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
        guard case .commandExecution(let id1, _, _, let st1, _, let out1, _, _, _, _) = c.history[1] else {
            return XCTFail("expected commandExecution at [1]")
        }
        XCTAssertEqual(id1.raw, "B")
        XCTAssertEqual(st1, .inProgress)
        XCTAssertNil(out1)
        guard case .commandExecution(let id2, _, _, let st2, _, let out2, _, _, _, _) = c.history[2] else {
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
                                       commandActions: [], aggregatedOutput: "out", exitCode: 0))
        c.appendItem(.commandExecution(id: ItemId("c2"), command: ["echo"], cwd: "/w",
                                       status: .completed,
                                       commandActions: [], aggregatedOutput: "out2", exitCode: 0))

        let removed = c.removeFirstItem()
        XCTAssertEqual(removed, 1,
                       "agentMessage has no call/output pair → only the message is removed")
        XCTAssertEqual(c.history.count, 2)
        // Surviving items are the two commandExecutions, in order.
        guard case .commandExecution(let id1, _, _, _, _, _, _, _, _, _) = c.history[0] else {
            return XCTFail("expected commandExecution at [0]")
        }
        XCTAssertEqual(id1.raw, "c1")
        guard case .commandExecution(let id2, _, _, _, _, _, _, _, _, _) = c.history[1] else {
            return XCTFail("expected commandExecution at [1]")
        }
        XCTAssertEqual(id2.raw, "c2")
    }

    func testRemoveFirstItemHandlesOrphanCallGracefully() {
        var c = ContextManager()
        // Single tool-call with no output anywhere in history.
        c.appendItem(.commandExecution(id: ItemId("X"), command: ["echo"], cwd: "/w",
                                       status: .inProgress,
                                       commandActions: [], aggregatedOutput: nil, exitCode: nil))

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
                                       commandActions: [], aggregatedOutput: nil, exitCode: nil))
        c.appendItem(.commandExecution(id: ItemId("Z"), command: ["echo", "Z"],
                                       cwd: "/w", status: .completed,
                                       commandActions: [], aggregatedOutput: "outZ", exitCode: 0))

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
                                       commandActions: [], aggregatedOutput: "out", exitCode: 0))
        c.appendItem(.agentMessage(id: ItemId("m"), text: "bye"))

        let v0 = c.historyVersion
        let removed = c.removeLastItem()
        XCTAssertTrue(removed)
        XCTAssertEqual(c.historyVersion, v0 + 1,
                       "removeLastItem on a non-paired tail bumps historyVersion exactly once")
        XCTAssertEqual(c.history.count, 1,
                       "agentMessage has no pair → unrelated commandExecution survives")
        guard case .commandExecution(let id, _, _, _, _, _, _, _, _, _) = c.history[0] else {
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
                                       commandActions: [], aggregatedOutput: nil, exitCode: nil))

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
                                       commandActions: [], aggregatedOutput: "out", exitCode: 0))
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

    // MARK: - context-compaction Finding 1 — .contextCompaction is a
    // model-generated boundary (upstream `ContextCompaction => true`,
    // core/src/context_manager/history.rs:681-699).
    //
    // After a remote compaction the installed history ends with a
    // `.contextCompaction` marker. Because that marker is now model-generated,
    // `itemsAfterLastModelGenerated()` returns an EMPTY slice and
    // `totalTokenUsage()` re-baselines to the last server total instead of
    // re-counting the synthesized summary/user items appended after it.
    func testContextCompactionIsModelGeneratedBoundary() {
        var c = ContextManager()
        // A freshly compacted history: synthesized summary user message(s)
        // followed by the canonical `.contextCompaction` marker, then a few
        // post-compaction user turns layered on top.
        c.replace([
            .userMessage(id: ItemId("summary"),
                         content: [UserMessageContent(text: "compacted summary")]),
            .contextCompaction(id: ItemId("cmp")),
            .userMessage(id: ItemId("u-after"),
                         content: [UserMessageContent(text: "new question after compaction")]),
        ])
        c.setLastServerTotalTokens(40_000)
        // The boundary is the .contextCompaction marker; only the trailing
        // post-compaction user message is "after" it.
        let after = c.itemsAfterLastModelGenerated()
        XCTAssertEqual(after.count, 1,
                       ".contextCompaction is the model-generated boundary; only post-marker items follow")
        guard case .userMessage(_, let content)? = after.first,
              content.first?.text == "new question after compaction" else {
            return XCTFail("the single trailing item should be the post-compaction user message")
        }
        let tailTokens = ContextManager.estimateItemTokens(
            .userMessage(id: ItemId("u-after"),
                         content: [UserMessageContent(text: "new question after compaction")]))
        XCTAssertEqual(c.totalTokenUsage(), 40_000 + tailTokens,
                       "totalTokenUsage = lastServerTotal + only the items recorded after the compaction marker; the summary before the marker is NOT re-counted")
    }

    // A trailing `.contextCompaction` marker (no items after it) yields an
    // empty tail, so totalTokenUsage == lastServerTotalTokens exactly — the
    // load-bearing post-compaction re-baseline case.
    func testTrailingContextCompactionYieldsEmptyTail() {
        var c = ContextManager()
        c.replace([
            .userMessage(id: ItemId("summary"),
                         content: [UserMessageContent(text: "compacted summary")]),
            .contextCompaction(id: ItemId("cmp")),
        ])
        c.setLastServerTotalTokens(40_000)
        XCTAssertTrue(c.itemsAfterLastModelGenerated().isEmpty,
                      "history ending in .contextCompaction has no items after the boundary")
        XCTAssertEqual(c.totalTokenUsage(), 40_000,
                       "no tail → totalTokenUsage is exactly the server-reported total (no double-count of the summary)")
    }

    func testForPromptSendsFullTranscriptInOrder() {
        var c = ContextManager()
        c.appendUser([TurnInput(text: "u1")])
        c.appendAssistant("a1", id: ItemId("a1"))
        c.appendItem(.commandExecution(id: ItemId("c1"), command: ["echo"], cwd: "/w",
                                       status: .completed, commandActions: [], aggregatedOutput: "out1", exitCode: 0))
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

    func testForPromptReplaysReasoningWithEncryptedContent() {
        var c = ContextManager()
        c.appendUser([TurnInput(text: "u1")])
        c.appendReasoning(id: ItemId("r1"), summary: ["s"], content: ["cot"],
                          encryptedContent: "ENC")
        c.appendAssistant("a1", id: ItemId("a1"))
        let proj = c.forPrompt()
        XCTAssertEqual(proj, [
            .userText("u1"),
            .reasoning(summary: ["s"], content: ["cot"], encryptedContent: "ENC"),
            .assistantText("a1"),
        ], "reasoning items must replay into the model input for cross-turn continuity")
    }

    func testForPromptSkipsEmptyReasoningItem() {
        var c = ContextManager()
        c.appendUser([TurnInput(text: "u1")])
        c.appendReasoning(id: ItemId("r1"), summary: [], content: [],
                          encryptedContent: nil)
        let proj = c.forPrompt()
        XCTAssertEqual(proj, [.userText("u1")],
                       "an empty reasoning item contributes nothing to the input")
    }

    // MARK: Finding 1 — encrypted reasoning token estimation
    // Port of upstream `estimate_reasoning_length`
    // (core/src/context_manager/history.rs:499-505): model-visible bytes for an
    // encrypted reasoning item are `len*3/4 - 650` (saturating), NOT the
    // serialized-JSON byte length, then converted to tokens via ceil(bytes/4).

    func testEstimateReasoningLengthMatchesUpstreamFormula() {
        // len*3/4 - 650 saturating at 0.
        XCTAssertEqual(ContextManager.estimateReasoningLength(0), 0)
        XCTAssertEqual(ContextManager.estimateReasoningLength(800), 0,
                       "800*3/4=600, 600-650 saturates to 0")
        XCTAssertEqual(ContextManager.estimateReasoningLength(1000), 100,
                       "1000*3/4=750, 750-650=100")
        XCTAssertEqual(ContextManager.estimateReasoningLength(4000), 2350,
                       "4000*3/4=3000, 3000-650=2350")
    }

    func testEncryptedReasoningCostedByDecodedSizeNotJSONBytes() {
        // Upstream `estimate_response_item_model_visible_bytes` special-cases an
        // encrypted Reasoning item to `estimate_reasoning_length(content.len())`
        // model-visible bytes, then `estimate_item_token_count` converts via
        // ceil(bytes/4). For a 4000-byte encrypted blob:
        //   model-visible bytes = estimate_reasoning_length(4000) = 2350
        //   tokens              = ceil(2350/4) = 588
        let blob = String(repeating: "A", count: 4000)  // 4000 bytes encrypted
        var c = ContextManager()
        c.appendReasoning(id: ItemId("r1"), summary: [], content: [],
                          encryptedContent: blob)
        let item = c.history[0]
        XCTAssertEqual(ContextManager.modelVisibleBytes(of: item), 2350,
                       "encrypted reasoning is costed by estimate_reasoning_length, not JSON bytes")
        XCTAssertEqual(ContextManager.estimateItemTokens(item), (2350 + 3) / 4)

        // The special-cased estimate is independent of (and differs from) the
        // serialized-JSON byte path used for ordinary items: it is driven by the
        // encrypted-content length, not the serialized item.
        let jsonBytes = (try? JSONEncoder().encode(item))?.count ?? 0
        XCTAssertNotEqual(ContextManager.modelVisibleBytes(of: item), jsonBytes,
                          "the encrypted-reasoning estimate must diverge from the raw JSON-byte path")

        // The discounted size scales with the encrypted blob length: a larger
        // blob yields a strictly larger estimate.
        var c2 = ContextManager()
        c2.appendReasoning(id: ItemId("r2"), summary: [], content: [],
                           encryptedContent: String(repeating: "A", count: 8000))
        XCTAssertGreaterThan(ContextManager.modelVisibleBytes(of: c2.history[0]),
                             ContextManager.modelVisibleBytes(of: item),
                             "a larger encrypted blob costs more model-visible bytes")
    }

    func testReasoningWithoutEncryptedContentStillUsesJSONBytes() {
        // No encrypted content → falls back to the JSON-byte path (unchanged).
        var c = ContextManager()
        c.appendReasoning(id: ItemId("r1"), summary: ["short summary"],
                          content: ["chain"], encryptedContent: nil)
        let item = c.history[0]
        let jsonBytes = (try? JSONEncoder().encode(item))?.count ?? 0
        XCTAssertEqual(ContextManager.modelVisibleBytes(of: item), jsonBytes,
                       "non-encrypted reasoning is costed by serialized JSON size")
        XCTAssertEqual(ContextManager.estimateItemTokens(item), (jsonBytes + 3) / 4)
    }

    func testTotalTokenUsageDiscountsTrailingEncryptedReasoning() {
        // An encrypted reasoning item recorded after the last model-generated
        // item is counted into `totalTokenUsage()` via the discounted estimate,
        // not the inflated JSON-byte count — driving the auto-compact ladder.
        var c = ContextManager()
        c.appendUser([TurnInput(text: "q")])
        c.setLastServerTotalTokens(1000)
        let blob = String(repeating: "B", count: 4000)
        c.appendReasoning(id: ItemId("r1"), summary: [], content: [],
                          encryptedContent: blob)
        // userMessage is not model-generated; reasoning IS model-generated, so
        // it is the boundary and the window after it is empty → total == server.
        XCTAssertEqual(c.totalTokenUsage(), 1000,
                       "reasoning is the last model-generated item; window after is empty")
        // But the whole-history estimate uses the discounted reasoning size.
        let discountedTokens = (ContextManager.estimateReasoningLength(4000) + 3) / 4
        let userTokens = ContextManager.estimateItemTokens(c.history[0])
        XCTAssertEqual(c.estimatedTokens, userTokens + discountedTokens)
    }

    // MARK: - context-compaction Finding (major) — trim_function_call_history_to_fit_context_window
    //
    // Port of upstream `trim_function_call_history_to_fit_context_window`
    // (core/src/compact_remote.rs:361-388) + `is_codex_generated_item`
    // (core/src/context_manager/history.rs:701-708). Before the remote compact
    // request, while the whole-history estimate exceeds the model context
    // window, pop trailing CODEX-GENERATED items (developer messages / tool
    // outputs) until it fits or the tail is not codex-generated.

    func testTrimToFitDropsTrailingDeveloperMessagesUntilFits() {
        var c = ContextManager()
        // A big user message sets the baseline; then several large developer
        // (codex-generated) context messages push the estimate over the window.
        c.appendUser([TurnInput(text: String(repeating: "U", count: 4000))])
        for i in 0..<5 {
            c.appendItem(.contextMessage(id: ItemId("dev\(i)"), role: "developer",
                                         sections: [String(repeating: "D", count: 4000)]))
        }
        let window = ContextManager.estimateItemTokens(c.history[0]) + 50
        XCTAssertGreaterThan(c.estimatedTokens, window,
                             "test invariant: history starts over the window")
        let deleted = c.trimToFitContextWindow(contextWindow: window)
        XCTAssertGreaterThan(deleted, 0, "trailing developer messages are trimmed")
        XCTAssertLessThanOrEqual(c.estimatedTokens, window,
                                 "after trimming, the history fits the context window")
        // The user message is NEVER trimmed (not codex-generated).
        XCTAssertFalse(c.history.isEmpty)
        guard case .userMessage = c.history[0] else {
            return XCTFail("the leading user message must survive the trim")
        }
    }

    func testTrimToFitStopsAtNonCodexGeneratedTail() {
        var c = ContextManager()
        // user (not codex-gen), developer (codex-gen), then a trailing assistant
        // message which is NOT codex-generated — the loop must stop at it even
        // though we are still over the window, leaving everything intact.
        c.appendUser([TurnInput(text: String(repeating: "U", count: 4000))])
        c.appendItem(.contextMessage(id: ItemId("dev"), role: "developer",
                                     sections: [String(repeating: "D", count: 4000)]))
        c.appendAssistant(String(repeating: "A", count: 4000), id: ItemId("a1"))
        let before = c.history.count
        // Pick a window far below the current estimate so the loop wants to trim.
        let deleted = c.trimToFitContextWindow(contextWindow: 1)
        XCTAssertEqual(deleted, 0,
                       "tail is an assistant message (not codex-generated) → no trimming")
        XCTAssertEqual(c.history.count, before, "history is untouched")
    }

    func testTrimToFitDoesNotTouchUserOrAssistantOrCommandExecution() {
        var c = ContextManager()
        // Per the unified-item port divergence, .commandExecution is NOT
        // codex-generated, so a trailing tool output is never trimmed.
        c.appendItem(.commandExecution(id: ItemId("c1"), command: ["echo"], cwd: "/w",
                                       status: .completed, commandActions: [],
                                       aggregatedOutput: String(repeating: "Z", count: 4000),
                                       exitCode: 0))
        let before = c.history.count
        let deleted = c.trimToFitContextWindow(contextWindow: 1)
        XCTAssertEqual(deleted, 0,
                       ".commandExecution is not codex-generated under the unified item model")
        XCTAssertEqual(c.history.count, before)
    }

    func testTrimToFitNilWindowIsNoOp() {
        var c = ContextManager()
        c.appendItem(.contextMessage(id: ItemId("dev"), role: "developer",
                                     sections: [String(repeating: "D", count: 4000)]))
        let before = c.history.count
        XCTAssertEqual(c.trimToFitContextWindow(contextWindow: nil), 0,
                       "no declared context window → trim disabled (upstream returns 0)")
        XCTAssertEqual(c.history.count, before)
    }

    func testTrimToFitEmptyHistoryIsNoOp() {
        var c = ContextManager()
        XCTAssertEqual(c.trimToFitContextWindow(contextWindow: 1), 0,
                       "empty history → nothing to trim, no crash")
        XCTAssertTrue(c.history.isEmpty)
    }

    func testTrimToFitFitsAlreadyIsNoOp() {
        var c = ContextManager()
        c.appendItem(.contextMessage(id: ItemId("dev"), role: "developer",
                                     sections: ["small"]))
        let before = c.history.count
        XCTAssertEqual(c.trimToFitContextWindow(contextWindow: 1_000_000), 0,
                       "history already fits → no trimming")
        XCTAssertEqual(c.history.count, before)
    }

    func testIsCodexGeneratedItemMatchesUpstreamPredicate() {
        // developer-role context message → true (codex-generated).
        XCTAssertTrue(ContextManager.isCodexGeneratedItem(
            .contextMessage(id: ItemId("d"), role: "developer", sections: ["x"])))
        // user-role context message → false.
        XCTAssertFalse(ContextManager.isCodexGeneratedItem(
            .contextMessage(id: ItemId("u"), role: "user", sections: ["x"])))
        // user / assistant / reasoning → false.
        XCTAssertFalse(ContextManager.isCodexGeneratedItem(
            .userMessage(id: ItemId("u"), content: [UserMessageContent(text: "hi")])))
        XCTAssertFalse(ContextManager.isCodexGeneratedItem(
            .agentMessage(id: ItemId("a"), text: "hi")))
        // .commandExecution → false (intentional unified-item divergence).
        XCTAssertFalse(ContextManager.isCodexGeneratedItem(
            .commandExecution(id: ItemId("c"), command: ["echo"], cwd: "/w",
                              status: .completed, commandActions: [],
                              aggregatedOutput: "out", exitCode: 0)))
    }
}