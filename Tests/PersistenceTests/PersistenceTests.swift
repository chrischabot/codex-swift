import XCTest
import Foundation
@testable import Persistence
@testable import ProtocolModel
@testable import InfraPrimitives

final class PersistenceTests: XCTestCase {
    private func tmpHome() -> String {
        let p = NSTemporaryDirectory() + "codexkit-test-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private func smallLimits() -> Limits {
        var l = Limits()
        l.rolloutGroupCommitItems = 3
        l.rolloutGroupCommitInterval = .seconds(3600) // disable time-based flush
        return l.clamped()
    }

    func testTokenCountPopulatesBreakdownInEventMsg() async throws {
        // F5: token_count event_msg must carry the input/cached/output/reasoning
        // split when the provider reports it (not always-zero like before).
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        try await w.append(.tokenCount(turnId: TurnId("t"), total: 130_000,
                                        input: 100_000, cached: 25_000,
                                        output: 30_000, reasoning: 0))
        _ = try await w.durabilityBarrier(); await w.close()
        let raw = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8))
                                 as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "event_msg")
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "token_count")
        let info = try XCTUnwrap(payload["info"] as? [String: Any])
        let usage = try XCTUnwrap(info["total_token_usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 100_000,
                       "F5 fix: input_tokens populated from UsageSnapshot")
        XCTAssertEqual(usage["cached_input_tokens"] as? Int, 25_000)
        XCTAssertEqual(usage["output_tokens"] as? Int, 30_000)
        XCTAssertEqual(usage["total_tokens"] as? Int, 130_000)
    }

    func testTokenCountRoundTripsViaDecode() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        try await w.append(.tokenCount(turnId: TurnId("t"), total: 5,
                                        input: 3, cached: 1, output: 2, reasoning: 0))
        _ = try await w.durabilityBarrier(); await w.close()
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.first, .tokenCount(turnId: TurnId("t"), total: 5,
                                                input: 3, cached: 1,
                                                output: 2, reasoning: 0))
    }

    // MARK: P2.2 / H-03, H-04, H-05 — token_count / task_started / task_complete
    //                                  wire-fidelity fields.

    /// P2.2 / H-03: `task_started` must carry the live model context window
    /// (`Tokenizer.ModelCatalog.default`) instead of `null` so external
    /// consumers can render a context-usage gauge at turn start. Upstream
    /// `TurnStartedEvent.model_context_window` is populated from the model
    /// configuration; this test asserts the on-disk JSONL payload mirrors
    /// that shape.
    func testTaskStartedEmitsModelContextWindow() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_mcw")
        try await w.append(.turnBoundary(turnId: tid, status: .inProgress,
                                          modelContextWindow: 272_000))
        _ = try await w.durabilityBarrier(); await w.close()
        let raw = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8))
                                  as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "event_msg")
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "task_started")
        XCTAssertEqual(payload["turn_id"] as? String, tid.raw)
        XCTAssertEqual(payload["model_context_window"] as? Int, 272_000,
                       "P2.2 / H-03: model_context_window must be populated")
        // Round-trip preserves the value.
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.first, .turnBoundary(turnId: tid, status: .inProgress,
                                                  modelContextWindow: 272_000))
    }

    /// P2.2 / H-03: `token_count.info.model_context_window` must be populated
    /// from the live model config (not `null`).
    func testTokenCountEmitsModelContextWindow() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        try await w.append(.tokenCount(turnId: TurnId("t"),
                                        lastInput: 5, lastCached: 0,
                                        lastOutput: 3, lastReasoning: 1,
                                        lastTotal: 9,
                                        totalInput: 5, totalCached: 0,
                                        totalOutput: 3, totalReasoning: 1,
                                        totalTotal: 9,
                                        modelContextWindow: 128_000))
        _ = try await w.durabilityBarrier(); await w.close()
        let raw = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8))
                                  as? [String: Any])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        let info = try XCTUnwrap(payload["info"] as? [String: Any])
        XCTAssertEqual(info["model_context_window"] as? Int, 128_000,
                       "P2.2 / H-03: model_context_window must be populated on token_count")
    }

    /// P2.2 / H-04: `task_complete.last_agent_message` must carry the final
    /// assistant text so a thread-list preview can read it from a single
    /// rollout line (parity with upstream `TurnCompleteEvent.last_agent_message`).
    func testTaskCompletePopulatesLastAgentMessage() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_lam")
        try await w.append(.turnBoundary(turnId: tid, status: .completed,
                                          lastAgentMessage: "All done, ready to ship."))
        _ = try await w.durabilityBarrier(); await w.close()
        let raw = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8))
                                  as? [String: Any])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "task_complete")
        XCTAssertEqual(payload["last_agent_message"] as? String,
                       "All done, ready to ship.",
                       "P2.2 / H-04: last_agent_message must carry the final assistant text")
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.first,
                       .turnBoundary(turnId: tid, status: .completed,
                                     lastAgentMessage: "All done, ready to ship."))
    }

    /// P2.2 / H-05: `last_token_usage` is the per-call delta and
    /// `total_token_usage` is the session cumulative. After two sampling
    /// iterations they MUST differ (upstream `TokenUsageInfo::append_last_usage`
    /// semantics) — Swift used to write identical buckets for both.
    func testTokenCountLastVsTotalUsageDiffer() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_delta")
        // First sampling call. cumulative == this call.
        try await w.append(.tokenCount(turnId: tid,
                                        lastInput: 100, lastCached: 10,
                                        lastOutput: 20, lastReasoning: 5,
                                        lastTotal: 135,
                                        totalInput: 100, totalCached: 10,
                                        totalOutput: 20, totalReasoning: 5,
                                        totalTotal: 135,
                                        modelContextWindow: 272_000))
        // Second sampling call. last == this call's delta; total accumulates.
        try await w.append(.tokenCount(turnId: tid,
                                        lastInput: 50, lastCached: 5,
                                        lastOutput: 30, lastReasoning: 2,
                                        lastTotal: 87,
                                        totalInput: 150, totalCached: 15,
                                        totalOutput: 50, totalReasoning: 7,
                                        totalTotal: 222,
                                        modelContextWindow: 272_000))
        _ = try await w.durabilityBarrier(); await w.close()

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[1].utf8)) as? [String: Any])
        let payload = try XCTUnwrap(second["payload"] as? [String: Any])
        let info = try XCTUnwrap(payload["info"] as? [String: Any])
        let last = try XCTUnwrap(info["last_token_usage"] as? [String: Any])
        let total = try XCTUnwrap(info["total_token_usage"] as? [String: Any])
        XCTAssertEqual(last["total_tokens"]            as? Int, 87)
        XCTAssertEqual(last["input_tokens"]            as? Int, 50)
        XCTAssertEqual(last["cached_input_tokens"]     as? Int, 5)
        XCTAssertEqual(last["output_tokens"]           as? Int, 30)
        XCTAssertEqual(last["reasoning_output_tokens"] as? Int, 2)
        XCTAssertEqual(total["total_tokens"]            as? Int, 222)
        XCTAssertEqual(total["input_tokens"]            as? Int, 150)
        XCTAssertEqual(total["cached_input_tokens"]     as? Int, 15)
        XCTAssertEqual(total["output_tokens"]           as? Int, 50)
        XCTAssertEqual(total["reasoning_output_tokens"] as? Int, 7)
        XCTAssertNotEqual(last["total_tokens"] as? Int, total["total_tokens"] as? Int,
                          "P2.2 / H-05: last and total MUST diverge across calls")
        // Round-trip preserves the split.
        let recs = try RolloutReader().readAll(path: path)
        guard case .tokenCount(_, let lInp, let lCac, let lOut, let lReas, let lTot,
                                let tInp, let tCac, let tOut, let tReas, let tTot, let mcw)
            = recs[1] else { return XCTFail("expected tokenCount") }
        XCTAssertEqual(lInp, 50);  XCTAssertEqual(lCac, 5)
        XCTAssertEqual(lOut, 30); XCTAssertEqual(lReas, 2); XCTAssertEqual(lTot, 87)
        XCTAssertEqual(tInp, 150); XCTAssertEqual(tCac, 15)
        XCTAssertEqual(tOut, 50); XCTAssertEqual(tReas, 7); XCTAssertEqual(tTot, 222)
        XCTAssertEqual(mcw, 272_000)
    }

    func testCompactionEmitsRollerSidecarEventMsg() async throws {
        // F2 fix: a `.compacted` record must produce TWO lines on disk —
        // the existing top-level "compacted" record AND a sidecar event_msg
        // of type "auto_compacted" carrying phase/reason/tokens_before/after
        // so a consumer grepping `"type":"event_msg"` can find compaction.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_compact")
        try await w.append(.compacted(turnId: tid,
                                       summary: "compacted summary text",
                                       phase: "midTurn",
                                       reason: "context_limit",
                                       tokensBefore: 250_000,
                                       tokensAfter: 50_000))
        _ = try await w.durabilityBarrier(); await w.close()

        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map { String($0) }
        XCTAssertEqual(lines.count, 2, "one compacted record should write two lines")

        // Line 1: the existing top-level "compacted" record.
        let first = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["type"] as? String, "compacted")
        let firstPayload = try XCTUnwrap(first["payload"] as? [String: Any])
        XCTAssertEqual(firstPayload["turn_id"] as? String, tid.raw)
        XCTAssertEqual(firstPayload["message"] as? String, "compacted summary text")

        // Line 2: the sidecar event_msg of type "auto_compacted".
        let second = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(second["type"] as? String, "event_msg")
        let payload = try XCTUnwrap(second["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "auto_compacted")
        XCTAssertEqual(payload["turn_id"] as? String, tid.raw)
        XCTAssertEqual(payload["phase"] as? String, "midTurn")
        XCTAssertEqual(payload["reason"] as? String, "context_limit")
        XCTAssertEqual(payload["tokens_before"] as? Int, 250_000)
        XCTAssertEqual(payload["tokens_after"] as? Int, 50_000)
        XCTAssertEqual(payload["tokens_saved"] as? Int, 200_000)
    }

    func testCompactionDefaultsApplyWhenFieldsMissing() async throws {
        // Backwards compat: old call sites that don't pass phase/reason still
        // get sane defaults in the sidecar (betweenTurns / context_limit).
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        try await w.append(.compacted(turnId: TurnId("t"), summary: "x"))
        _ = try await w.durabilityBarrier(); await w.close()
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map { String($0) }
        XCTAssertEqual(lines.count, 2)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[1].utf8)) as? [String: Any])
        let payload = try XCTUnwrap(second["payload"] as? [String: Any])
        XCTAssertEqual(payload["phase"] as? String, "betweenTurns")
        XCTAssertEqual(payload["reason"] as? String, "context_limit")
        XCTAssertNil(payload["tokens_before"])
        XCTAssertNil(payload["tokens_after"])
        XCTAssertNil(payload["tokens_saved"])
    }

    func testTurnBoundaryFailedMapsErrorInfoToAbortReason() async throws {
        // P1.5 / H-52: the on-disk `reason` field is constrained to the four
        // upstream `TurnAbortReason` variants (`interrupted`, `replaced`,
        // `review_ended`, `budget_limited`) so upstream codex consumers
        // (which strict-deserialize via serde) can read our rollouts. The
        // fine-grained cause survives verbatim in the sibling `error_info`
        // field — see `testAbortReasonOnlyEmitsUpstreamCanonicalValues`.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let pairs: [(TurnId, String?, String)] = [
            (TurnId("turn_deadline"),   "DeadlineExceeded",  "budget_limited"),
            (TurnId("turn_loop"),       "LoopGuard",         "budget_limited"),
            (TurnId("turn_stream"),     "StreamError",       "replaced"),
            (TurnId("turn_model"),      "ModelError",        "replaced"),
            (TurnId("turn_hook"),       "HookBlocked",       "replaced"),
            (TurnId("turn_ctx"),        "ContextLimit",      "budget_limited"),
            (TurnId("turn_durability"), "DurabilityError",   "replaced"),
            (TurnId("turn_review"),     "ReviewEnded",       "review_ended"),
            (TurnId("turn_unknown"),    nil,                 "replaced"),
            (TurnId("turn_replaced"),   "Replaced",          "replaced"),
        ]
        for (tid, info, _) in pairs {
            try await w.append(.turnBoundary(turnId: tid, status: .failed, errorInfo: info))
        }
        _ = try await w.durabilityBarrier()
        await w.close()
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map { String($0) }
        XCTAssertEqual(lines.count, pairs.count)
        for (i, (_, info, expected)) in pairs.enumerated() {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(lines[i].utf8)) as? [String: Any])
            let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
            XCTAssertEqual(payload["type"] as? String, "turn_aborted",
                           "row \(i) should be turn_aborted")
            XCTAssertEqual(payload["reason"] as? String, expected,
                           "row \(i): \(info ?? "nil") -> expected \(expected), got \(payload["reason"] ?? "nil")")
            if let info {
                XCTAssertEqual(payload["error_info"] as? String, info,
                               "row \(i): error_info should be preserved verbatim")
            } else {
                XCTAssertNil(payload["error_info"],
                             "row \(i): no error_info when input was nil")
            }
        }
    }

    func testTurnBoundaryInterruptedKeepsInterruptedReason() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_int")
        try await w.append(.turnBoundary(turnId: tid, status: .interrupted,
                                          errorInfo: nil))
        _ = try await w.durabilityBarrier(); await w.close()
        let raw = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8))
                                 as? [String: Any])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "interrupted")
    }

    func testAbortReasonOnlyEmitsUpstreamCanonicalValues() async throws {
        // P1.5 / H-52: regression guard — every codexErrorInfo value the
        // harness ever produces MUST map to one of the four upstream
        // `TurnAbortReason` variants. Anything else would cause upstream
        // codex consumers (which strict-deserialize the enum) to error.
        let canonical: Set<String> = [
            "interrupted", "replaced", "review_ended", "budget_limited",
        ]
        let inputs: [String?] = [
            "DeadlineExceeded", "LoopGuard", "StreamError", "ModelError",
            "HookBlocked", "ContextLimit", "DurabilityError",
            "RolloutPersistenceError", "ReviewEnded", "Interrupted",
            "Replaced", "SomethingUnseen", nil,
        ]
        for info in inputs {
            let reason = RolloutWriter.abortReason(from: info)
            XCTAssertTrue(canonical.contains(reason),
                          "abortReason(\(info ?? "nil")) = \(reason); must be one of \(canonical)")
        }

        // And — for `.failed` boundaries — the original codexErrorInfo MUST
        // be preserved verbatim in the sibling `error_info` field so we
        // don't lose the fine-grained cause when the reason is collapsed.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let nonNilInfos = inputs.compactMap { $0 }
        for (i, info) in nonNilInfos.enumerated() {
            try await w.append(.turnBoundary(turnId: TurnId("t_\(i)"),
                                              status: .failed,
                                              errorInfo: info))
        }
        _ = try await w.durabilityBarrier(); await w.close()
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map { String($0) }
        XCTAssertEqual(lines.count, nonNilInfos.count)
        for (i, info) in nonNilInfos.enumerated() {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(lines[i].utf8)) as? [String: Any])
            let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
            XCTAssertEqual(payload["type"] as? String, "turn_aborted")
            let reason = try XCTUnwrap(payload["reason"] as? String)
            XCTAssertTrue(canonical.contains(reason),
                          "row \(i) (\(info)): reason \(reason) not upstream-canonical")
            XCTAssertEqual(payload["error_info"] as? String, info,
                           "row \(i): error_info must be preserved verbatim")
        }
    }

    func testRustLineDecoderUsesErrorInfoForRoundTrip() async throws {
        // P1.5 / H-52: because the on-disk `reason` is now collapsed to the
        // upstream-canonical four, the reverse mapping (rollout -> in-memory
        // RolloutRecord) must read the sibling `error_info` field first so
        // round-trip fidelity is preserved for fine-grained causes that no
        // longer survive in `reason` alone (e.g. StreamError -> replaced).
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_stream_roundtrip")
        try await w.append(.turnBoundary(turnId: tid, status: .failed,
                                          errorInfo: "StreamError"))
        _ = try await w.durabilityBarrier(); await w.close()

        // Sanity-check the on-disk shape: reason collapsed, error_info preserved.
        let raw = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8))
                                 as? [String: Any])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "replaced")
        XCTAssertEqual(payload["error_info"] as? String, "StreamError")

        // Now read it back through the Rust-line decoder and confirm the
        // reconstructed RolloutRecord preserves errorInfo == "StreamError".
        let records = try RolloutReader().readAll(path: path)
        XCTAssertEqual(records.count, 1)
        guard case .turnBoundary(let rtid, let status, let errorInfo, _, _) = records[0] else {
            return XCTFail("expected turnBoundary, got \(records[0])")
        }
        XCTAssertEqual(rtid, tid)
        XCTAssertEqual(status, .failed)
        XCTAssertEqual(errorInfo, "StreamError",
                       "round-trip must preserve StreamError via error_info")

        // And — when error_info is absent — the reverse mapping should fall
        // back to a sensible canonical default keyed off `reason`.
        let path2 = home + "/r2.jsonl"
        let line: [String: Any] = [
            "timestamp": "2026-01-01T00:00:00.000Z",
            "type": "event_msg",
            "payload": [
                "type": "turn_aborted",
                "turn_id": "turn_nobody",
                "reason": "budget_limited",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: line)
        try (data + Data([0x0A])).write(to: URL(fileURLWithPath: path2))
        let records2 = try RolloutReader().readAll(path: path2)
        XCTAssertEqual(records2.count, 1)
        guard case .turnBoundary(_, let status2, let info2, _, _) = records2[0] else {
            return XCTFail("expected turnBoundary, got \(records2[0])")
        }
        XCTAssertEqual(status2, .failed)
        XCTAssertEqual(info2, "DeadlineExceeded",
                       "missing error_info should fall back to canonical default")
    }

    func testRolloutGroupCommitAndRoundTrip() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_1")
        try await w.append(.turnBoundary(turnId: tid, status: .inProgress))
        try await w.append(.userInput(turnId: tid, input: [TurnInput(text: "hi")]))
        var committed = await w.committedRecordCount()
        XCTAssertEqual(committed, 0, "no auto-flush before threshold")
        let pending = await w.pendingRecordCount()
        XCTAssertEqual(pending, 2)
        try await w.append(.item(turnId: tid, item: .agentMessage(id: ItemId("a1"), text: "hello")))
        committed = await w.committedRecordCount()
        XCTAssertEqual(committed, 3, "group-commit flush at item threshold")
        try await w.append(.turnBoundary(turnId: tid, status: .completed))
        _ = try await w.durabilityBarrier()
        await w.close()

        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.count, 4)
        XCTAssertEqual(recs.first, .turnBoundary(turnId: tid, status: .inProgress))
        XCTAssertEqual(recs.last, .turnBoundary(turnId: tid, status: .completed))
        let rawLines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
        let firstLine = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(rawLines[0].utf8)) as? [String: Any])
        XCTAssertNotNil(firstLine["timestamp"], "writer emits Rust RolloutLine timestamp")
        XCTAssertEqual(firstLine["type"] as? String, "event_msg")
        let firstPayload = try XCTUnwrap(firstLine["payload"] as? [String: Any])
        XCTAssertEqual(firstPayload["type"] as? String, "task_started")
        XCTAssertEqual(firstPayload["turn_id"] as? String, tid.raw)
    }

    func testCrashConsistentTornTailIgnored() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        // Two complete lines + a torn (no newline) partial line.
        let good = #"{"t":"turnBoundary","turnId":"turn_1","status":"completed"}"#
        FileManager.default.createFile(atPath: path,
            contents: Data((good + "\n" + good + "\n" + "{\"t\":\"item\",\"turnId\":\"tur").utf8))
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.count, 2, "torn trailing line must be ignored (crash-consistent)")
    }

    func testRustRolloutLineEventCompatibility() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/rust-rollout.jsonl"
        let lines = [
            #"{"timestamp":"2026-01-27T12:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn_rust","started_at":null,"model_context_window":128000,"collaboration_mode_kind":"default"}}"#,
            #"{"timestamp":"2026-01-27T12:00:00.100Z","type":"event_msg","payload":{"type":"user_message","message":"hello from rust","images":null,"local_images":[],"text_elements":[]}}"#,
            #"{"timestamp":"2026-01-27T12:00:00.200Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"assistant response"}]}}"#,
            #"{"timestamp":"2026-01-27T12:00:00.300Z","type":"event_msg","payload":{"type":"agent_message","message":"assistant response","phase":null,"memory_citation":null}}"#,
            #"{"timestamp":"2026-01-27T12:00:00.400Z","type":"compacted","payload":{"message":"summary from rust","replacement_history":null}}"#,
            #"{"timestamp":"2026-01-27T12:00:00.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":42},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":42},"model_context_window":128000},"rate_limits":null}}"#,
            #"{"timestamp":"2026-01-27T12:00:01.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_rust","last_agent_message":"assistant response","completed_at":null}}"#,
        ]
        FileManager.default.createFile(atPath: path,
                                       contents: Data((lines.joined(separator: "\n") + "\n").utf8))
        let tid = TurnId("turn_rust")
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.count, 6)
        // P2.2 / H-03, H-04: reader now hydrates `model_context_window` on
        // `task_started` and `last_agent_message` on `task_complete` so
        // round-trip records carry those wire-fidelity fields.
        XCTAssertEqual(recs.first, .turnBoundary(turnId: tid, status: .inProgress,
                                                  modelContextWindow: 128_000))
        XCTAssertEqual(recs[1], .userInput(turnId: tid, input: [TurnInput(text: "hello from rust")]))
        if case .item(tid, .agentMessage(_, let text)) = recs[2] {
            XCTAssertEqual(text, "assistant response")
        } else {
            XCTFail("expected Rust agent_message to reconstruct an assistant item")
        }
        XCTAssertEqual(recs[3], .compacted(turnId: tid, summary: "summary from rust"))
        XCTAssertEqual(recs[4], .tokenCount(turnId: tid, total: 42,
                                             modelContextWindow: 128_000))
        XCTAssertEqual(recs[5], .turnBoundary(turnId: tid, status: .completed,
                                               lastAgentMessage: "assistant response"))
    }

    func testRollbackRewritePreservesRustRolloutLineShape() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let thread = ThreadId("rollback_rust_shape")
        _ = try await store.create(SessionConfig(threadId: thread, cwd: "/w"))

        let first = TurnId("turn_keep")
        try await store.record(thread, .turnBoundary(turnId: first, status: .inProgress))
        try await store.record(thread, .userInput(turnId: first, input: [TurnInput(text: "keep me")]))
        try await store.record(thread, .turnBoundary(turnId: first, status: .completed))

        let second = TurnId("turn_drop")
        try await store.record(thread, .turnBoundary(turnId: second, status: .inProgress))
        try await store.record(thread, .userInput(turnId: second, input: [TurnInput(text: "drop me")]))
        try await store.record(thread, .turnBoundary(turnId: second, status: .completed))
        try await store.durabilityBarrier(thread)

        let turns = try await store.rollback(thread, numTurns: 1)
        XCTAssertEqual(turns.map(\.id), [first])

        let path = home + "/sessions/\(thread.raw).rollout.jsonl"
        let rawLines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
        // P1.1 / F1: the rollout now opens with a `session_meta` preamble
        // line, so a 3-turn rollback retains: session_meta + 3 records of
        // the kept turn = 4 lines total.
        XCTAssertEqual(rawLines.count, 4)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(rawLines[0].utf8)) as? [String: Any])
        XCTAssertEqual(meta["type"] as? String, "session_meta",
                       "rollback must preserve the session_meta preamble")
        let firstLine = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(rawLines[1].utf8)) as? [String: Any])
        XCTAssertNil(firstLine["t"], "rollback rewrites must not downgrade core records to legacy Swift rollout shape")
        XCTAssertNotNil(firstLine["timestamp"], "rollback rewrites preserve Rust RolloutLine timestamps")
        XCTAssertEqual(firstLine["type"] as? String, "event_msg")
        let payload = try XCTUnwrap(firstLine["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "task_started")
        XCTAssertEqual(payload["turn_id"] as? String, first.raw)

        let rebuilt = try await store.reconstruct(thread)
        XCTAssertEqual(rebuilt.turns.map(\.id), [first])
        XCTAssertTrue(rebuilt.items.contains {
            if case .userMessage(_, let content) = $0 {
                return content.first?.text == "keep me"
            }
            return false
        })
    }

    func testReconstructionWithCompactionReset() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/work"))
        let t = TurnId("turn_1")
        try await store.record(id, .userInput(turnId: t, input: [TurnInput(text: "q1")]))
        try await store.record(id, .item(turnId: t, item: .agentMessage(id: ItemId("a1"), text: "a1")))
        try await store.record(id, .compacted(turnId: t, summary: "SUMMARY"))
        try await store.record(id, .item(turnId: t, item: .agentMessage(id: ItemId("a2"), text: "a2")))
        try await store.durabilityBarrier(id)

        let rebuilt = try await store.reconstruct(id)
        // compaction resets history to the summary, then later items append.
        XCTAssertEqual(rebuilt.items.count, 2)
        if case .agentMessage(_, let s) = rebuilt.items[0] { XCTAssertEqual(s, "SUMMARY") }
        else { XCTFail("expected compaction summary first") }
        if case .agentMessage(_, let s) = rebuilt.items[1] { XCTAssertEqual(s, "a2") }
        else { XCTFail("expected post-compaction item") }
        XCTAssertEqual(rebuilt.config.cwd, "/work")
    }

    func testEphemeralIsInMemoryOnly() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/w", ephemeral: true))
        try await store.record(id, .item(turnId: TurnId("t"), item: .agentMessage(id: ItemId("a"), text: "x")))
        try await store.durabilityBarrier(id)   // no-op
        // History works in-session …
        let rebuilt = try await store.reconstruct(id)
        XCTAssertEqual(rebuilt.items.count, 1)
        // … but nothing was written to disk and it is not listed.
        let rolloutPath = home + "/sessions/\(id.raw).rollout.jsonl"
        XCTAssertFalse(FileManager.default.fileExists(atPath: rolloutPath))
        let listed = try await store.list()
        XCTAssertFalse(listed.contains { $0.id == id })
        try await store.quiesce(id)
        let afterQuiesce = try await store.reconstruct(id)
        // Contract: ephemeral threads are non-recoverable; idle-unload
        // (quiesce) intentionally discards their in-memory state.
        XCTAssertEqual(afterQuiesce.items.count, 0, "ephemeral state gone after unload (by contract)")
    }

    func testReconstructAppliesLatestEnvironmentRebound() async throws {
        // A4 — proof that .environmentRebound records replay correctly:
        // reconstruct returns the most recently recorded environment, and an
        // explicit nil-URL record represents a switch back to local.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId("env_replay")
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/w"))

        try await store.record(id, .environmentRebound(
            turnId: TurnId("init"),
            environmentId: "remote-a",
            execServerUrl: "ws://127.0.0.1:1111"))
        try await store.record(id, .environmentRebound(
            turnId: TurnId("switch-1"),
            environmentId: "remote-b",
            execServerUrl: "ws://127.0.0.1:2222"))
        try await store.durabilityBarrier(id)

        var rebuilt = try await store.reconstruct(id)
        XCTAssertEqual(rebuilt.config.remoteEnvironment?.environmentId, "remote-b")
        XCTAssertEqual(rebuilt.config.remoteEnvironment?.execServerUrl,
                       "ws://127.0.0.1:2222")

        // Switch back to local — an explicit nil-URL rebind clears the env.
        try await store.record(id, .environmentRebound(
            turnId: TurnId("switch-2"),
            environmentId: "local",
            execServerUrl: nil))
        try await store.durabilityBarrier(id)
        rebuilt = try await store.reconstruct(id)
        XCTAssertNil(rebuilt.config.remoteEnvironment,
                     "explicit nil-URL rebind should clear remote env")
    }

    // MARK: P1.1 — session_meta + replacement_history

    func testSessionMetaIsFirstRecordOnFreshThread() async throws {
        // P1.1 / F1: a freshly-created (non-ephemeral) thread must write a
        // `session_meta` record as the FIRST JSONL line, carrying upstream-
        // compatible fields so codex-cli / state-DB backfill / dynamic-tools
        // backfill can identify the thread by reading just the file head.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId("p1_1_session_meta")
        let cfg = SessionConfig(threadId: id, cwd: "/tmp/some/work",
                                baseInstructions: "## be helpful")
        _ = try await store.create(cfg)

        // Append a non-meta record so the writer has something to flush, then
        // force a fsync barrier so the file content is observable on disk.
        try await store.record(id, .turnBoundary(turnId: TurnId("t0"),
                                                  status: .inProgress))
        try await store.durabilityBarrier(id)

        let path = home + "/sessions/\(id.raw).rollout.jsonl"
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2,
                                    "session_meta must precede other records")

        let head = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(head["type"] as? String, "session_meta",
                       "first record of a fresh rollout must be session_meta")
        XCTAssertNotNil(head["timestamp"],
                        "session_meta envelope carries a rust-shaped timestamp")
        let payload = try XCTUnwrap(head["payload"] as? [String: Any])
        XCTAssertEqual(payload["id"] as? String, id.raw,
                       "session_meta.id is the thread id")
        XCTAssertEqual(payload["cwd"] as? String, "/tmp/some/work",
                       "session_meta.cwd matches the session cwd")
        XCTAssertNotNil(payload["timestamp"],
                        "session_meta has an inner timestamp")
        let originator = try XCTUnwrap(payload["originator"] as? String)
        XCTAssertTrue(originator.contains("/"),
                      "originator follows `<originator>/<version>` shape")
        XCTAssertNotNil(payload["cli_version"] as? String)
        XCTAssertEqual(payload["source"] as? String, "vscode",
                       "default SessionSource matches upstream default")
        XCTAssertEqual(payload["model_provider"] as? String, "openai")
        let baseInst = try XCTUnwrap(payload["base_instructions"] as? [String: Any])
        XCTAssertEqual(baseInst["text"] as? String, "## be helpful",
                       "BaseInstructions encoded as { text: ... } (upstream shape)")

        // The next line must be the task_started event_msg (not session_meta).
        let second = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(second["type"] as? String, "event_msg",
                       "second line is the first turn boundary")

        // Round-trip: a reader replaying the file produces a .sessionMeta as
        // the first record and ignores it during item reconstruction.
        let recs = try RolloutReader().readAll(path: path)
        if case .sessionMeta(let tid, let cwd, _, _, _, let modelProvider,
                              let baseInstructions, _, _, _, _) = recs.first {
            XCTAssertEqual(tid, id)
            XCTAssertEqual(cwd, "/tmp/some/work")
            XCTAssertEqual(modelProvider, "openai")
            XCTAssertEqual(baseInstructions, "## be helpful")
        } else {
            XCTFail("first decoded record must be .sessionMeta, got \(String(describing: recs.first))")
        }
    }

    func testCompactedCarriesReplacementHistory() async throws {
        // P1.1 / F2: a .compacted record with a non-nil replacementHistory
        // must serialize the items into the JSONL `replacement_history`
        // array (so upstream rollout_reconstruction can skip pre-compaction
        // replay) AND round-trip them back through the reader.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_compact_with_history")
        let history: [ThreadItem] = [
            .userMessage(id: ItemId("u1"),
                         content: [UserMessageContent(text: "original Q")]),
            .agentMessage(id: ItemId("a1"), text: "summary placeholder"),
            .reasoning(id: ItemId("r1"), summary: "kept reasoning"),
        ]
        try await w.append(.compacted(turnId: tid,
                                       summary: "post-compact summary",
                                       phase: "betweenTurns",
                                       reason: "context_limit",
                                       tokensBefore: 10_000,
                                       tokensAfter: 2_000,
                                       replacementHistory: history))
        _ = try await w.durabilityBarrier(); await w.close()

        // Wire-shape assertion: the compacted line's payload carries the
        // `replacement_history` array with one entry per history item.
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 1)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["type"] as? String, "compacted")
        let payload = try XCTUnwrap(first["payload"] as? [String: Any])
        XCTAssertEqual(payload["message"] as? String, "post-compact summary")
        let arr = try XCTUnwrap(payload["replacement_history"] as? [Any],
                                "replacement_history must be present on the JSONL line")
        XCTAssertEqual(arr.count, history.count,
                       "replacement_history carries every item in the post-compaction history")

        // Round-trip: the reader must hydrate replacementHistory back into the
        // .compacted record.
        let recs = try RolloutReader().readAll(path: path)
        let target = recs.compactMap { rec -> [ThreadItem]? in
            if case .compacted(_, _, _, _, _, _, let h) = rec { return h } else { return nil }
        }.first
        let hydrated = try XCTUnwrap(target ?? nil,
                                     "replacement_history must round-trip through the reader")
        XCTAssertEqual(hydrated.count, history.count)
        XCTAssertEqual(hydrated, history,
                       "every replacement_history item is preserved byte-for-byte across round-trip")
    }

    func testTurnContextRolloutLineCarriesCwdAndUpstreamShape() async throws {
        // P1.4 / H-50, H-51: a `.turnContext` record must serialize to the
        // upstream `RolloutLine { timestamp, type: "turn_context", payload }`
        // envelope with `cwd`, `model`, `turn_id` in the payload so
        // `resume_candidate_matches_cwd()` can read the working directory
        // back. Forward-compat optional fields (`current_date`, `timezone`,
        // `realtime_active`) must also pass through when set.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_ctx_1")
        try await w.append(.turnContext(turnId: tid,
                                         cwd: "/some/dir",
                                         model: "m",
                                         currentDate: "2026-05-23",
                                         timezone: "America/New_York",
                                         realtimeActive: false))
        _ = try await w.durabilityBarrier(); await w.close()

        let raw = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8))
                                 as? [String: Any])
        XCTAssertNotNil(obj["timestamp"],
                        "writer must emit Rust RolloutLine timestamp on turn_context")
        XCTAssertEqual(obj["type"] as? String, "turn_context",
                       "P1.4 / H-51: envelope `type` must be `turn_context` (snake_case)")
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["cwd"] as? String, "/some/dir",
                       "P1.4 / H-50: TurnContext payload must carry cwd")
        XCTAssertEqual(payload["model"] as? String, "m")
        XCTAssertEqual(payload["turn_id"] as? String, tid.raw,
                       "P1.4: turn_id must be present in the payload")
        XCTAssertEqual(payload["current_date"] as? String, "2026-05-23")
        XCTAssertEqual(payload["timezone"] as? String, "America/New_York")
        XCTAssertEqual(payload["realtime_active"] as? Bool, false)
    }

    func testTurnContextOmitsAbsentOptionalFields() async throws {
        // P1.4 / H-50: optional upstream fields (current_date, timezone,
        // realtime_active) must be omitted from the payload when nil, to match
        // upstream's `#[serde(skip_serializing_if = "Option::is_none")]`.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        try await w.append(.turnContext(turnId: TurnId("turn_min"),
                                         cwd: "/x",
                                         model: "gpt-5"))
        _ = try await w.durabilityBarrier(); await w.close()
        let raw = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8))
                                 as? [String: Any])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertNil(payload["current_date"], "absent optional must be omitted, not null")
        XCTAssertNil(payload["timezone"])
        XCTAssertNil(payload["realtime_active"])
    }

    func testTurnContextRoundTripsCwd() async throws {
        // P1.4 / H-50: cwd (and the other forward-compat fields) must survive
        // a write/read round-trip via RolloutReader so the persisted baseline
        // is recoverable by anything that scans the rollout looking for the
        // latest TurnContext.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_rt")
        try await w.append(.turnContext(turnId: tid,
                                         cwd: "/Users/example/Projects/foo",
                                         model: "gpt-5.1-codex",
                                         currentDate: "2026-05-23",
                                         timezone: "UTC",
                                         realtimeActive: true))
        _ = try await w.durabilityBarrier(); await w.close()
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.count, 1)
        guard case .turnContext(let rTid, let rCwd, let rModel,
                                let rDate, let rTz, let rRT) = recs[0] else {
            XCTFail("expected .turnContext after round-trip, got \(recs[0])")
            return
        }
        XCTAssertEqual(rTid, tid)
        XCTAssertEqual(rCwd, "/Users/example/Projects/foo",
                       "P1.4: cwd must round-trip through the rollout reader")
        XCTAssertEqual(rModel, "gpt-5.1-codex")
        XCTAssertEqual(rDate, "2026-05-23")
        XCTAssertEqual(rTz, "UTC")
        XCTAssertEqual(rRT, true)
    }

    func testTurnContextDecoderToleratesLegacyMissingCwd() throws {
        // P1.4 / H-50: an upstream-shaped rollout written before we added
        // the `cwd` requirement (or one written by a Swift caller that
        // didn't populate it) must still decode — we degrade `cwd` to ""
        // so the rest of the record (turn_id, model) survives.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/r.jsonl"
        // Legacy native-Swift shape (no cwd) — the Codable decoder must
        // not throw on the missing key.
        let legacy = #"{"t":"turnContext","turnId":"turn_legacy","model":"m"}"#
        FileManager.default.createFile(atPath: path,
                                       contents: Data((legacy + "\n").utf8))
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.count, 1)
        if case .turnContext(_, let cwd, let model, _, _, _) = recs[0] {
            XCTAssertEqual(cwd, "", "legacy records degrade cwd to empty string")
            XCTAssertEqual(model, "m")
        } else {
            XCTFail("expected .turnContext from legacy line")
        }
    }

    // MARK: P9.3 — threadItemToResponseItem `{"type":"other"}` arm decision

    /// P9.3: `.userMessage` and `.agentMessage` already had tests via
    /// `testCompactedCarriesReplacementHistory`. This test asserts that
    /// `.contextMessage` (reachable via `insertInitialContext` in mid-turn
    /// compaction) now maps to a proper upstream `ResponseItem::Message`
    /// shape instead of the silent `{"type":"other"}` sentinel.
    func testContextMessageMapsToResponseItemMessage() throws {
        let item = ThreadItem.contextMessage(
            id: ItemId("ctx1"),
            role: "developer",
            sections: ["## Section A\nsome text", "## Section B\nmore text"])
        let obj = RolloutWriter.threadItemToResponseItem(item)

        XCTAssertEqual(obj["type"] as? String, "message",
                       "P9.3: contextMessage must map to ResponseItem::Message, not 'other'")
        XCTAssertEqual(obj["role"] as? String, "developer",
                       "role must be preserved verbatim")
        XCTAssertEqual(obj["id"] as? String, "ctx1")
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2, "each section becomes one input_text part")
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "## Section A\nsome text")
        XCTAssertEqual(content[1]["text"] as? String, "## Section B\nmore text")
    }

    /// P9.3: After serialization, a `.contextMessage` with role "developer"
    /// must round-trip through `responseItemToThreadItem` back to an
    /// equivalent `.contextMessage` (not an agentMessage or unknown).
    func testContextMessageRoundTrips() async throws {
        let original = ThreadItem.contextMessage(
            id: ItemId("ctx2"),
            role: "developer",
            sections: ["hello", "world"])
        let wire = RolloutWriter.threadItemToResponseItem(original)
        // responseItemToThreadItem is private; exercise it through a full
        // write/read cycle with a compacted record.
        let tmpDir = NSTemporaryDirectory() + "p93-ctx-rt-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let path = tmpDir + "/r.jsonl"

        let history: [ThreadItem] = [original]
        var limits = Limits()
        limits.rolloutGroupCommitItems = 1
        let w = try RolloutWriter(path: path, limits: limits.clamped())
        let rec = RolloutRecord.compacted(
            turnId: TurnId("t"),
            summary: "test",
            replacementHistory: history)
        // Encode manually using the same path as the real writer.
        let data = try RolloutWriter.encodeLine(rec)
        try (data + Data([0x0A])).write(to: URL(fileURLWithPath: path))
        await w.close()

        let recs = try RolloutReader().readAll(path: path)
        guard case .compacted(_, _, _, _, _, _, let hydrated) = recs.first else {
            XCTFail("expected .compacted record"); return
        }
        let items = try XCTUnwrap(hydrated)
        XCTAssertEqual(items.count, 1)
        guard case .contextMessage(let rid, let rrole, let rsections) = items[0] else {
            XCTFail("P9.3: contextMessage must round-trip as .contextMessage, got \(items[0])")
            return
        }
        XCTAssertEqual(rrole, "developer")
        XCTAssertEqual(rsections, ["hello", "world"])
        _ = rid  // id is regenerated on decode; value doesn't matter

        // Also verify the wire shape directly — the on-disk JSON must carry
        // the upstream ResponseItem::Message shape (not "other").
        XCTAssertEqual(wire["type"] as? String, "message",
                       "on-wire type must be 'message', not 'other'")
    }

    /// P9.3: `.userMessage` with a "user" role context must still map to
    /// `{type:"message", role:"user"}` (not "other" or "developer").
    func testUserContextMessageMapsToUserMessageRole() throws {
        // A contextMessage with role "user" (less common but valid upstream)
        // must also produce a proper ResponseItem::Message.
        let item = ThreadItem.contextMessage(
            id: ItemId("ctx3"),
            role: "user",
            sections: ["some user context"])
        let obj = RolloutWriter.threadItemToResponseItem(item)
        XCTAssertEqual(obj["type"] as? String, "message")
        XCTAssertEqual(obj["role"] as? String, "user")
        let content = obj["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
    }

    func testStateDBListAndArchive() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let a = ThreadId("thr_a"); let b = ThreadId("thr_b")
        _ = try await store.create(SessionConfig(threadId: a, cwd: "/a"))
        _ = try await store.create(SessionConfig(threadId: b, cwd: "/b"))
        var active = try await store.list(archived: false)
        XCTAssertEqual(Set(active.map { $0.id }), Set([a, b]))
        try await store.archive(a)
        active = try await store.list(archived: false)
        XCTAssertEqual(active.map { $0.id }, [b])
        let arch = try await store.list(archived: true)
        XCTAssertEqual(arch.map { $0.id }, [a])
    }
}
