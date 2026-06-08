import XCTest
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import Persistence
@testable import ProtocolModel
@testable import InfraPrimitives
import WireProtocol

final class PersistenceTests: XCTestCase {
    private func tmpHome() -> String {
        let p = NSTemporaryDirectory() + "codexkit-test-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    /// Locate a durable thread's rollout file. Upstream's date-partitioned
    /// layout puts it at `sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`, so the
    /// test discovers it by recursive search rather than assuming a flat path.
    /// Falls back to the legacy flat path for any pre-migration fixtures.
    private func findRollout(_ home: String, _ id: ThreadId) -> String {
        let sessions = home + "/sessions"
        if let en = FileManager.default.enumerator(atPath: sessions) {
            for case let rel as String in en
            where rel.hasSuffix("-\(id.raw).jsonl") || rel.hasSuffix("\(id.raw).rollout.jsonl") {
                return sessions + "/" + rel
            }
        }
        return home + "/sessions/\(id.raw).rollout.jsonl"
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
        // persistence-rollout finding 2: `turn_id` is NOT serialized into the
        // token_count payload (upstream TokenCountEvent has no turn_id). On
        // read-back with no preceding turn cursor it recovers as an empty
        // TurnId; the usage fields round-trip intact.
        XCTAssertEqual(recs.first, .tokenCount(turnId: TurnId(""), total: 5,
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

    func testCompactionEmitsContextCompactedSidecarEventMsg() async throws {
        // P1.1 / F4 fix: a `.compacted` record must produce TWO lines on disk —
        // the top-level "compacted" record AND a sidecar event_msg of the
        // upstream-VALID fieldless type "context_compacted" (the canonical
        // `EventMsg::ContextCompacted(ContextCompactedEvent)` unit variant).
        // The previous `auto_compacted` shape with phase/reason/tokens_* fields
        // is NOT a real upstream EventMsg and would fail to deserialize there.
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

        // Line 1: the top-level "compacted" record carries the rich signal.
        let first = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["type"] as? String, "compacted")
        let firstPayload = try XCTUnwrap(first["payload"] as? [String: Any])
        // persistence-rollout finding 2: upstream `CompactedItem`
        // (protocol.rs:2794) is `{message, replacement_history}` with NO
        // `turn_id`; we omit it for byte-parity. The reader recovers the turn
        // from the running cursor.
        XCTAssertNil(firstPayload["turn_id"],
                     "compacted payload must NOT carry turn_id (finding 2)")
        XCTAssertEqual(firstPayload["message"] as? String, "compacted summary text")

        // Line 2: the sidecar event_msg of the fieldless upstream type
        // "context_compacted" — no phase/reason/tokens_* keys.
        let second = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(second["type"] as? String, "event_msg")
        let payload = try XCTUnwrap(second["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "context_compacted")
        XCTAssertNil(payload["phase"], "context_compacted is a fieldless unit event")
        XCTAssertNil(payload["reason"])
        XCTAssertNil(payload["tokens_before"])
        XCTAssertNil(payload["tokens_after"])
        XCTAssertNil(payload["tokens_saved"])
    }

    func testCompactionSidecarIsFieldlessRegardlessOfInputFields() async throws {
        // Even when no phase/reason are supplied, the sidecar is the same
        // canonical fieldless `context_compacted` event.
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
        XCTAssertEqual(payload["type"] as? String, "context_compacted")
        XCTAssertNil(payload["phase"])
        XCTAssertNil(payload["reason"])
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
        // 6 records. P9.4 / cross-impl resume dedup: the upstream
        // `response_item` (assistant message) line at index 2 is the
        // history-bearing record. The IMMEDIATELY-FOLLOWING `agent_message`
        // event_msg (line 510) carries the SAME turn/role/text, so it is
        // recognised as the UI-only sidecar of that response_item and DROPPED
        // from history — matching upstream `reconstruct_history_from_rollout`
        // (which builds history exclusively from `ResponseItem` lines and
        // ignores `EventMsg::AgentMessage` entirely). Without dedup the
        // assistant message would be double-counted.
        XCTAssertEqual(recs.count, 6, "agent_message sidecar must be deduped against response_item")
        // P2.2 / H-03, H-04: reader now hydrates `model_context_window` on
        // `task_started` and `last_agent_message` on `task_complete` so
        // round-trip records carry those wire-fidelity fields.
        XCTAssertEqual(recs.first, .turnBoundary(turnId: tid, status: .inProgress,
                                                  modelContextWindow: 128_000))
        XCTAssertEqual(recs[1], .userInput(turnId: tid, input: [TurnInput(text: "hello from rust")]))
        // recs[2]: the upstream `response_item` message → assistant item.
        if case .item(tid, .agentMessage(_, let text)) = recs[2] {
            XCTAssertEqual(text, "assistant response", "response_item message → assistant item")
        } else {
            XCTFail("expected upstream response_item to reconstruct an assistant item")
        }
        // The `agent_message` sidecar that followed it produced NO second
        // assistant item — exactly one assistant `.agentMessage` survives.
        let assistantCount = recs.filter {
            if case .item(_, .agentMessage) = $0 { return true }
            return false
        }.count
        XCTAssertEqual(assistantCount, 1, "exactly one assistant item after dedup")
        XCTAssertEqual(recs[3], .compacted(turnId: tid, summary: "summary from rust"))
        XCTAssertEqual(recs[4], .tokenCount(turnId: tid, total: 42,
                                             modelContextWindow: 128_000))
        XCTAssertEqual(recs[5], .turnBoundary(turnId: tid, status: .completed,
                                               lastAgentMessage: "assistant response"))
    }

    // MARK: P9.4 — user/assistant text persisted as RolloutItem::ResponseItem
    // (cross-impl resume). Upstream durably records each turn's user input and
    // assistant message as `response_item` rollout lines and rebuilds model
    // history EXCLUSIVELY from those (rollout_reconstruction.rs); the
    // `user_message`/`agent_message` event_msg lines are UI-only sidecars
    // (user_message also serves turn-boundary detection). These tests assert
    // the Swift port now (a) WRITES the response_item lines for both roles in
    // addition to the event_msg sidecars, and (b) does NOT double-count on read.

    /// A user-input turn and an assistant-text item each persist BOTH a durable
    /// `response_item` (history-bearing) line AND the legacy event_msg sidecar
    /// — so an upstream codex reader that reconstructs from `response_item`
    /// lines sees the user turn and assistant message (previously it rebuilt
    /// EMPTY model history because the Swift port only wrote event_msg lines).
    func testUserAndAssistantTextPersistedAsResponseItemPlusEventSidecar() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/dualwrite.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_dw")
        try await w.append(.turnBoundary(turnId: tid, status: .inProgress))
        try await w.append(.userInput(turnId: tid, input: [TurnInput(text: "user asks")]))
        try await w.append(.item(turnId: tid,
                                 item: .agentMessage(id: ItemId("a1"), text: "assistant replies")))
        try await w.append(.turnBoundary(turnId: tid, status: .completed))
        _ = try await w.durabilityBarrier()
        await w.close()

        // Parse every raw rollout line into (type, payload-type, role, message).
        let rawLines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        struct Parsed { let type: String; let payloadType: String?; let role: String?; let message: String? }
        let parsed: [Parsed] = rawLines.compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { return nil }
            let p = obj["payload"] as? [String: Any] ?? [:]
            let content = p["content"] as? [[String: Any]] ?? []
            let joined = content.compactMap { $0["text"] as? String }.joined()
            return Parsed(type: type, payloadType: p["type"] as? String,
                          role: p["role"] as? String,
                          message: (p["message"] as? String) ?? (joined.isEmpty ? nil : joined))
        }

        // (a) A `response_item` message line with role:user carrying the user text.
        XCTAssertTrue(parsed.contains {
            $0.type == "response_item" && $0.payloadType == "message"
                && $0.role == "user" && $0.message == "user asks"
        }, "user input must be durably persisted as a response_item (role:user) line")
        // (b) A `response_item` message line with role:assistant carrying the reply.
        XCTAssertTrue(parsed.contains {
            $0.type == "response_item" && $0.payloadType == "message"
                && $0.role == "assistant" && $0.message == "assistant replies"
        }, "assistant text must be durably persisted as a response_item (role:assistant) line")
        // The event_msg sidecars are ALSO emitted (UI parity / turn detection).
        XCTAssertTrue(parsed.contains {
            $0.type == "event_msg" && $0.payloadType == "user_message" && $0.message == "user asks"
        }, "user_message event_msg sidecar must still be emitted for UI/turn-detection")
        XCTAssertTrue(parsed.contains {
            $0.type == "event_msg" && $0.payloadType == "agent_message" && $0.message == "assistant replies"
        }, "agent_message event_msg sidecar must still be emitted for UI parity")

        // (c) Round-trip reconstruction is NOT double-counted: exactly one user
        // message and one assistant message survive even though each was
        // dual-written (response_item + event_msg).
        let recs = try RolloutReader().readAll(path: path)
        let userMsgs = recs.filter {
            if case .item(_, .userMessage) = $0 { return true }
            if case .userInput = $0 { return true }
            return false
        }
        let assistantMsgs = recs.filter {
            if case .item(_, .agentMessage) = $0 { return true }
            return false
        }
        XCTAssertEqual(userMsgs.count, 1, "user text must reconstruct exactly once (no double-count)")
        XCTAssertEqual(assistantMsgs.count, 1, "assistant text must reconstruct exactly once (no double-count)")
        // History prefers the response_item: the user turn reads back as a
        // `.item(.userMessage)` (response_item), not a `.userInput` (event).
        if case .item(tid, .userMessage(_, let content)) = userMsgs[0] {
            XCTAssertEqual(content.first?.text, "user asks")
        } else {
            XCTFail("user history must come from the response_item line, not the event sidecar")
        }
    }

    /// Multi-line user input with an image part round-trips through the
    /// response_item (role:user) line: text parts → input_text, image → input_image.
    func testUserInputImageRoundTripsViaResponseItem() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/dwimg.jsonl"
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let tid = TurnId("turn_img")
        var img = TurnInput(text: "")
        img.type = "image"; img.text = nil; img.url = "data:image/png;base64,AAAA"
        try await w.append(.turnBoundary(turnId: tid, status: .inProgress))
        try await w.append(.userInput(turnId: tid, input: [TurnInput(text: "look at this"), img]))
        _ = try await w.durabilityBarrier()
        await w.close()

        let rawLines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let userResponseItem = rawLines.compactMap { line -> [[String: Any]]? in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["type"] as? String) == "response_item",
                  let p = obj["payload"] as? [String: Any],
                  (p["role"] as? String) == "user" else { return nil }
            return p["content"] as? [[String: Any]]
        }.first
        let content = try XCTUnwrap(userResponseItem, "expected a user response_item line")
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "look at this")
        XCTAssertTrue(content.contains { $0["type"] as? String == "input_image" },
                      "image part must serialize as input_image in the response_item")

        // Round-trip: exactly one user message survives (no double-count).
        let recs = try RolloutReader().readAll(path: path)
        let userMsgs = recs.filter {
            if case .item(_, .userMessage) = $0 { return true }
            if case .userInput = $0 { return true }
            return false
        }
        XCTAssertEqual(userMsgs.count, 1)
    }

    /// Legacy / upstream rollouts that carry ONLY a `user_message` /
    /// `agent_message` event_msg (NO paired response_item) must still
    /// reconstruct the message — dedup only suppresses a sidecar that
    /// duplicates an immediately-preceding response_item of the same turn/role.
    func testLegacyEventOnlyMessagesStillReconstructWithoutResponseItem() throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/legacy.jsonl"
        let lines = [
            #"{"timestamp":"2026-01-27T12:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
            #"{"timestamp":"2026-01-27T12:00:00.100Z","type":"event_msg","payload":{"type":"user_message","message":"legacy user","local_images":[],"text_elements":[]}}"#,
            #"{"timestamp":"2026-01-27T12:00:00.200Z","type":"event_msg","payload":{"type":"agent_message","message":"legacy assistant","phase":null,"memory_citation":null}}"#,
        ]
        FileManager.default.createFile(atPath: path,
            contents: Data((lines.joined(separator: "\n") + "\n").utf8))
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertTrue(recs.contains {
            if case .userInput(_, let input) = $0 { return input.first?.text == "legacy user" }
            return false
        }, "legacy user_message-only rollout must still reconstruct the user input")
        XCTAssertTrue(recs.contains {
            if case .item(_, .agentMessage(_, let text)) = $0 { return text == "legacy assistant" }
            return false
        }, "legacy agent_message-only rollout must still reconstruct the assistant message")
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

        let path = findRollout(home, thread)
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

    func testReconstructionWithCompactionReplacementHistoryReplays() async throws {
        // P1.1 / F2 fix: when a `.compacted` record carries a
        // `replacementHistory` (the post-compaction baseline), reconstruction
        // must RESET history to that vector and keep replaying subsequent
        // records on top — mirroring upstream `rollout_reconstruction.rs`
        // replace-then-replay — instead of collapsing to a single summary.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/work"))
        let t = TurnId("turn_1")
        try await store.record(id, .userInput(turnId: t, input: [TurnInput(text: "q1")]))
        try await store.record(id, .item(turnId: t, item: .agentMessage(id: ItemId("a1"), text: "a1")))
        // Post-compaction baseline: a user "bridge" message + an assistant note.
        let replacement: [ThreadItem] = [
            .userMessage(id: ItemId("bridge"),
                         content: [UserMessageContent(text: "condensed history")]),
            .agentMessage(id: ItemId("note"), text: "baseline note"),
        ]
        try await store.record(id, .compacted(turnId: t, summary: "SUMMARY",
                                              replacementHistory: replacement))
        try await store.record(id, .item(turnId: t, item: .agentMessage(id: ItemId("a2"), text: "a2")))
        try await store.durabilityBarrier(id)

        let rebuilt = try await store.reconstruct(id)
        // Baseline (2 items from replacement_history) + 1 post-compaction item.
        XCTAssertEqual(rebuilt.items.count, 3,
                       "replacement_history baseline must replace prior items, then replay suffix")
        if case .userMessage(_, let content) = rebuilt.items[0] {
            XCTAssertEqual(content.first?.text, "condensed history")
        } else { XCTFail("expected replacement_history user bridge first") }
        if case .agentMessage(_, let s) = rebuilt.items[1] {
            XCTAssertEqual(s, "baseline note")
        } else { XCTFail("expected replacement_history assistant note") }
        if case .agentMessage(_, let s) = rebuilt.items[2] {
            XCTAssertEqual(s, "a2", "post-compaction item replayed on top of baseline")
        } else { XCTFail("expected post-compaction item") }

        // turnsList must reflect the same replace-then-replay shape.
        let turns = try await store.turnsList(id)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].items.count, 3,
                       "turnsFrom must also honor replacement_history")
    }

    func testSessionMetaForkedFromIdRoundTrips() async throws {
        // P1.1 / F5: a forked thread carries `forked_from_id` in session_meta;
        // it is emitted as snake_case when present and round-trips via the
        // reader; a non-forked thread omits the field entirely.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let parent = ThreadId.generate()
        let id = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/work",
                                                 forkedFromId: parent.raw))
        try await store.record(id, .turnBoundary(turnId: TurnId("t0"), status: .inProgress))
        try await store.durabilityBarrier(id)

        let path = findRollout(home, id)
        let head = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(head.utf8))
                                 as? [String: Any])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["forked_from_id"] as? String, parent.raw,
                       "forked_from_id emitted (snake_case) for a forked thread")
        XCTAssertEqual(payload["source"] as? String, "vscode",
                       "persistence-rollout finding 1: default source is the app-server default \"vscode\" (SessionSource::VSCode), not \"mcp\"")

        // Reader hydrates forkedFromId back onto the .sessionMeta record.
        let recs = try RolloutReader().readAll(path: path)
        if case .sessionMeta(_, _, _, _, _, _, _, _, _, _, _, let forkedFromId, _, _, _, _, _) = recs.first {
            XCTAssertEqual(forkedFromId, parent.raw)
        } else {
            XCTFail("first record must be .sessionMeta")
        }
    }

    func testGeneratedThreadIdFilenameSegmentIsBareUuid() async throws {
        // P1.1 / F1: the trailing `<id>` segment of the rollout filename
        // (`rollout-<ts>-<id>.jsonl`) must be a bare RFC-4122 UUID so upstream
        // `Uuid::parse_str` in list.rs can recover the timestamp/uuid and
        // discover the file. A `thr_`-prefixed id would make every upstream
        // filesystem scan skip the rollout.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId.generate()
        // Generated ids are now bare lowercased UUIDs (no `thr_` prefix).
        XCTAssertFalse(id.raw.hasPrefix("thr_"),
                       "generated thread id must not carry the thr_ prefix")
        XCTAssertNotNil(UUID(uuidString: id.raw),
                        "generated thread id must parse as a bare RFC-4122 UUID")
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/work"))
        try await store.record(id, .turnBoundary(turnId: TurnId("t0"), status: .inProgress))
        try await store.durabilityBarrier(id)
        let path = findRollout(home, id)
        // Extract the trailing segment after `rollout-<ts>-` and confirm it is
        // a parseable UUID (the upstream filename-discovery invariant).
        let filename = (path as NSString).lastPathComponent
        XCTAssertTrue(filename.hasPrefix("rollout-"))
        XCTAssertTrue(filename.hasSuffix("-\(id.raw).jsonl"))
        XCTAssertNotNil(UUID(uuidString: id.raw),
                        "filename id segment must be a bare UUID upstream can parse")
    }

    func testRolloutPathUsesLocalWallClockNotUTC() async throws {
        // persistence-rollout finding 1: the date-partition directory
        // (`sessions/YYYY/MM/DD`) and the filename timestamp
        // (`rollout-YYYY-MM-DDThh-mm-ss-<id>.jsonl`) must be computed in the
        // operator's LOCAL time, mirroring upstream `precompute_log_file_info`
        // (rollout/src/recorder.rs:1329-1346 `OffsetDateTime::now_local()`),
        // NOT UTC. We assert both segments match `localtime_r`-derived
        // components for the creation instant, which diverges from `gmtime_r`
        // whenever the host is not at UTC offset 0.
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId.generate()
        let before = Int(Date().timeIntervalSince1970)
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/work"))
        try await store.record(id, .turnBoundary(turnId: TurnId("t0"), status: .inProgress))
        try await store.durabilityBarrier(id)
        let after = Int(Date().timeIntervalSince1970)

        let path = findRollout(home, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "durable rollout must be on disk")

        // The path must be `<home>/sessions/YYYY/MM/DD/rollout-...-<id>.jsonl`.
        let rel = path.replacingOccurrences(of: home + "/sessions/", with: "")
        let comps = rel.split(separator: "/").map(String.init)
        XCTAssertEqual(comps.count, 4, "expected date-partitioned layout sessions/YYYY/MM/DD/<file>")
        let (yearDir, monthDir, dayDir, file) = (comps[0], comps[1], comps[2], comps[3])

        // Derive the expected LOCAL components for the creation instant. Because
        // the create call straddles a wall-clock second, accept either the
        // `before` or `after` second's local rendering.
        func localParts(_ secs: Int) -> (String, String, String, String) {
            var t = time_t(secs)
            var tmv = tm()
            localtime_r(&t, &tmv)
            let dir = String(format: "%04d/%02d/%02d", tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday)
            let stamp = String(format: "%04d-%02d-%02dT%02d-%02d-%02d",
                               tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                               tmv.tm_hour, tmv.tm_min, tmv.tm_sec)
            let p = dir.split(separator: "/").map(String.init)
            return (p[0], p[1], p[2], stamp)
        }
        let lb = localParts(before)
        let la = localParts(after)
        XCTAssertTrue([lb.0, la.0].contains(yearDir), "year dir \(yearDir) must match local time")
        XCTAssertTrue([lb.1, la.1].contains(monthDir), "month dir \(monthDir) must match local time")
        XCTAssertTrue([lb.2, la.2].contains(dayDir), "day dir \(dayDir) must match local time")
        // Filename carries the same local timestamp (to the second).
        XCTAssertTrue(file.hasPrefix("rollout-\(lb.3)-") || file.hasPrefix("rollout-\(la.3)-"),
                      "filename \(file) must embed the local-time stamp \(lb.3)/\(la.3)")

        // Severe check: when the host is NOT at UTC offset 0, the chosen path
        // must NOT match the UTC (`gmtime_r`) rendering — proving we switched
        // off gmtime_r. Skipped on UTC hosts where the two coincide.
        let offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: Double(before)))
        if offset != 0 {
            func utcStamp(_ secs: Int) -> String {
                var t = time_t(secs)
                var tmv = tm()
                gmtime_r(&t, &tmv)
                return String(format: "%04d-%02d-%02dT%02d-%02d-%02d",
                              tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                              tmv.tm_hour, tmv.tm_min, tmv.tm_sec)
            }
            // The local stamps used in the filename must differ from the UTC
            // stamps (offset is whole minutes, so the hh-mm-ss differs).
            XCTAssertNotEqual(lb.3, utcStamp(before),
                              "on a non-UTC host the local stamp must differ from gmtime_r")
        }
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
        // … but nothing was written to disk and it is not listed. `findRollout`
        // searches the whole sessions tree, so this catches a file written
        // under any layout (flat or date-partitioned).
        XCTAssertFalse(FileManager.default.fileExists(atPath: findRollout(home, id)))
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
                                baseInstructions: "## be helpful",
                                originator: SessionConfig.portDefaultOriginator)
        _ = try await store.create(cfg)

        // Append a non-meta record so the writer has something to flush, then
        // force a fsync barrier so the file content is observable on disk.
        try await store.record(id, .turnBoundary(turnId: TurnId("t0"),
                                                  status: .inProgress))
        try await store.durabilityBarrier(id)

        let path = findRollout(home, id)
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
        // persistence-rollout finding 3: `originator` is a BARE originator id
        // (upstream `originator().value`, default `codex_cli_rs`), NOT a
        // `<id>/<version>` string. The version travels separately in
        // `cli_version`.
        let originator = try XCTUnwrap(payload["originator"] as? String)
        XCTAssertEqual(originator, "codex_swift",
                       "originator is the bare default id, not `<id>/<version>`")
        XCTAssertFalse(originator.contains("/"),
                       "originator must NOT embed the version (finding 3)")
        XCTAssertEqual(payload["cli_version"] as? String, "0.1.0",
                       "cli_version carries the version separately")
        XCTAssertEqual(payload["source"] as? String, "vscode",
                       "persistence-rollout finding 1: default source is the app-server default \"vscode\" (SessionSource::VSCode #[default]), not \"mcp\"")
        XCTAssertNil(payload["forked_from_id"],
                     "forked_from_id omitted for a non-forked thread (skip_if_none)")
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
                              let baseInstructions, _, _, _, _, _, _, _, _, _, _) = recs.first {
            XCTAssertEqual(tid, id)
            XCTAssertEqual(cwd, "/tmp/some/work")
            XCTAssertEqual(modelProvider, "openai")
            XCTAssertEqual(baseInstructions, "## be helpful")
        } else {
            XCTFail("first decoded record must be .sessionMeta, got \(String(describing: recs.first))")
        }
    }

    // persistence-rollout finding 3: the recorded `session_meta.model_provider`
    // is the LIVE provider id from SessionConfig (upstream recorder.rs:685), not
    // a hardcoded "openai".
    func testSessionMetaRecordsConfiguredModelProvider() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId("provider_thread")
        let cfg = SessionConfig(threadId: id, cwd: "/tmp/p",
                                modelProvider: "anthropic")
        _ = try await store.create(cfg)
        try await store.record(id, .turnBoundary(turnId: TurnId("t0"), status: .inProgress))
        try await store.durabilityBarrier(id)

        let path = findRollout(home, id)
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let head = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[0].utf8)) as? [String: Any])
        let payload = try XCTUnwrap(head["payload"] as? [String: Any])
        XCTAssertEqual(payload["model_provider"] as? String, "anthropic",
                       "session_meta.model_provider reflects the configured provider")

        // And the listing / summary read paths surface the recorded provider,
        // not a hardcoded "openai".
        let summary = try await store.conversationSummary(id: id)
        XCTAssertEqual(summary?.modelProvider, "anthropic",
                       "conversationSummary recovers the recorded provider from session_meta")
        let listed = try await store.list()
        XCTAssertEqual(listed.first(where: { $0.id == id })?.modelProvider, "anthropic",
                       "list recovers the recorded provider from the session_meta head line")
    }

    // persistence-rollout finding: conversationSummary.updatedAt must carry
    // MILLISECOND fractional-second precision (upstream recorder.rs:1693
    // `to_rfc3339_opts(SecondsFormat::Millis, true)`), while timestamp
    // (created_at) keeps whole-second precision (recorder.rs:1692
    // `SecondsFormat::Secs`). The Z suffix is used for UTC on both.
    func testConversationSummaryUpdatedAtUsesMillisAndTimestampUsesSeconds() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId("ts_precision_thread")
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/tmp/ts"))
        try await store.record(id, .userInput(turnId: TurnId("t0"), input: [TurnInput(text: "hi")]))
        try await store.durabilityBarrier(id)

        let maybeSummary = try await store.conversationSummary(id: id)
        let summary = try XCTUnwrap(maybeSummary)
        let timestamp = try XCTUnwrap(summary.timestamp)
        let updatedAt = try XCTUnwrap(summary.updatedAt)

        // created_at: whole seconds, no fractional component, Z suffix.
        // Shape: YYYY-MM-DDThh:mm:ssZ
        let secsRegex = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#
        XCTAssertNotNil(timestamp.range(of: secsRegex, options: .regularExpression),
                        "timestamp (created_at) must be whole-second RFC3339: \(timestamp)")

        // updated_at: exactly three fractional digits (millis), Z suffix.
        // Shape: YYYY-MM-DDThh:mm:ss.SSSZ
        let millisRegex = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        XCTAssertNotNil(updatedAt.range(of: millisRegex, options: .regularExpression),
                        "updatedAt must be millisecond RFC3339 (.SSSZ): \(updatedAt)")

        // The fractional-seconds shape is the only intended difference: stripping
        // updated_at's ".SSS" must leave a seconds-form string identical in shape
        // to created_at (both are UTC Z timestamps).
        XCTAssertFalse(timestamp.contains("."),
                       "created_at must NOT carry fractional seconds")
        XCTAssertTrue(updatedAt.contains("."),
                      "updated_at must carry fractional seconds")
    }

    // persistence-rollout finding 1: a client-supplied sessionStartSource
    // (ThreadStartParams.sessionStartSource → SessionConfig.sessionStartSource)
    // is recorded verbatim into session_meta.source, overriding the "vscode"
    // default. Mirrors upstream recorder.rs:683 recording the configured
    // session_source.
    func testSessionMetaHonorsClientSuppliedSessionStartSource() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId("source_override_thread")
        let cfg = SessionConfig(threadId: id, cwd: "/tmp/p",
                                sessionStartSource: "cli")
        _ = try await store.create(cfg)
        try await store.record(id, .turnBoundary(turnId: TurnId("t0"), status: .inProgress))
        try await store.durabilityBarrier(id)

        let path = findRollout(home, id)
        let head = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            (try String(contentsOfFile: path, encoding: .utf8)
                .split(separator: "\n").first.map(String.init) ?? "").utf8))
            as? [String: Any])
        let payload = try XCTUnwrap(head["payload"] as? [String: Any])
        XCTAssertEqual(payload["source"] as? String, "cli",
                       "client-supplied sessionStartSource overrides the vscode default")
    }

    // persistence-rollout finding 2: SessionMeta.model_provider and
    // base_instructions have NO #[serde(skip_serializing_if)] upstream
    // (protocol.rs:2742-2746), so both keys are ALWAYS present — emitted as JSON
    // null when nil — for byte parity, unlike the adjacent skippable fields.
    func testSessionMetaEmitsNullProviderAndBaseInstructionsWhenNil() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        // RolloutRecord.sessionMeta with nil provider + nil base_instructions.
        let rec = RolloutRecord.sessionMeta(
            threadId: ThreadId("nilmeta"), cwd: "/w", originator: "o",
            cliVersion: "1", source: "vscode", modelProvider: nil,
            baseInstructions: nil, memoryMode: nil,
            gitCommitHash: nil, gitBranch: nil, gitRepositoryURL: nil,
            forkedFromId: nil)
        let line = try RolloutWriter.encodeLine(rec)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        // The keys must be PRESENT (not omitted) and hold JSON null (NSNull).
        XCTAssertTrue(payload.keys.contains("model_provider"),
                      "model_provider key is always emitted (no skip_serializing_if)")
        XCTAssertTrue(payload["model_provider"] is NSNull,
                      "model_provider is JSON null when nil")
        XCTAssertTrue(payload.keys.contains("base_instructions"),
                      "base_instructions key is always emitted (no skip_serializing_if)")
        XCTAssertTrue(payload["base_instructions"] is NSNull,
                      "base_instructions is JSON null when nil")

        // Round-trips: a reader replaying the null-bearing line reads both back
        // as nil (tolerant `as?` cast), preserving semantics.
        let recs = try RolloutReader().readAll(
            path: try writeTempLine(line, home: home))
        guard case let .sessionMeta(_, _, _, _, _, mp, bi, _, _, _, _, _, _, _, _, _, _)
            = recs.first
        else { return XCTFail("expected .sessionMeta") }
        XCTAssertNil(mp, "null model_provider reads back as nil")
        XCTAssertNil(bi, "null base_instructions reads back as nil")
    }

    /// Helper: write a single encoded rollout line to a temp file under `home`
    /// and return its path (for reader round-trip assertions).
    private func writeTempLine(_ line: Data, home: String) throws -> String {
        let path = home + "/nullmeta.jsonl"
        var data = line; data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    // persistence-rollout finding 2: sub-agent provenance (thread_source,
    // agent_nickname, agent_role, agent_path) and dynamic_tools are OMITTED from
    // a top-level session_meta (upstream skip_serializing_if = Option::is_none),
    // so a default Swift session is byte-faithful.
    func testSessionMetaOmitsSubAgentFieldsByDefault() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId("toplevel_thread")
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/tmp/p"))
        try await store.record(id, .turnBoundary(turnId: TurnId("t0"), status: .inProgress))
        try await store.durabilityBarrier(id)

        let path = findRollout(home, id)
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let head = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[0].utf8)) as? [String: Any])
        let payload = try XCTUnwrap(head["payload"] as? [String: Any])
        for key in ["thread_source", "agent_nickname", "agent_role",
                    "agent_path", "dynamic_tools"] {
            XCTAssertNil(payload[key],
                         "\(key) must be omitted for a top-level session (skip_if_none)")
        }
    }

    // persistence-rollout finding 2: when a sub-agent / dynamic-tools session
    // DOES set these fields they serialize (snake_case, agent_role under its
    // canonical key) and round-trip — and agent_role tolerates the upstream
    // legacy `agent_type` alias on the way back in.
    func testSessionMetaSubAgentFieldsRoundTrip() async throws {
        let path = NSTemporaryDirectory() + "subagent-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let w = try RolloutWriter(path: path, limits: smallLimits())
        let rec = RolloutRecord.sessionMeta(
            threadId: ThreadId("sub_1"), cwd: "/tmp/p", originator: "codex_swift",
            cliVersion: "0.1.0", source: "mcp", modelProvider: "openai",
            baseInstructions: nil, memoryMode: nil,
            gitCommitHash: nil, gitBranch: nil, gitRepositoryURL: nil,
            forkedFromId: nil, threadSource: "subAgent",
            agentNickname: "lively-otter", agentRole: "reviewer",
            agentPath: "/agents/reviewer",
            dynamicTools: [.object(["name": .string("custom_tool")])])
        try await w.append(rec)
        _ = try await w.durabilityBarrier(); await w.close()

        let head = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(String(contentsOfFile: path, encoding: .utf8)
                .split(separator: "\n").map(String.init)[0].utf8)) as? [String: Any])
        let payload = try XCTUnwrap(head["payload"] as? [String: Any])
        XCTAssertEqual(payload["thread_source"] as? String, "subAgent")
        XCTAssertEqual(payload["agent_nickname"] as? String, "lively-otter")
        XCTAssertEqual(payload["agent_role"] as? String, "reviewer",
                       "emitted under the canonical agent_role key")
        XCTAssertNil(payload["agent_type"], "agent_type is only a read-time alias")
        XCTAssertEqual(payload["agent_path"] as? String, "/agents/reviewer")
        XCTAssertNotNil(payload["dynamic_tools"], "dynamic_tools emitted when present")

        let recs = try RolloutReader().readAll(path: path)
        guard case let .sessionMeta(_, _, _, _, _, _, _, _, _, _, _, _,
                                    threadSource, nickname, role, agentPath, dyn) = recs.first
        else { return XCTFail("expected .sessionMeta") }
        XCTAssertEqual(threadSource, "subAgent")
        XCTAssertEqual(nickname, "lively-otter")
        XCTAssertEqual(role, "reviewer")
        XCTAssertEqual(agentPath, "/agents/reviewer")
        XCTAssertEqual(dyn?.count, 1)
    }

    // persistence-rollout finding 2: a session_meta written with the upstream
    // legacy `agent_type` key reads back into `agentRole` (serde alias).
    func testSessionMetaAgentTypeAliasReadsAsAgentRole() throws {
        let line = #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"session_meta","payload":{"id":"t","cwd":"/w","originator":"o","cli_version":"1","source":"mcp","agent_type":"legacy-role"}}"#
        let path = NSTemporaryDirectory() + "alias-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let recs = try RolloutReader().readAll(path: path)
        guard case let .sessionMeta(_, _, _, _, _, _, _, _, _, _, _, _, _, _, role, _, _) = recs.first
        else { return XCTFail("expected .sessionMeta") }
        XCTAssertEqual(role, "legacy-role",
                       "upstream legacy agent_type alias hydrates agentRole")
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
            .reasoning(id: ItemId("r1"), summary: ["kept reasoning"], content: []),
        ]
        try await w.append(.compacted(turnId: tid,
                                       summary: "post-compact summary",
                                       phase: "pre_turn",
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
        // persistence-rollout finding 1: upstream marks the message/reasoning
        // `id` with `#[serde(default, skip_serializing)]`, so it is NEVER
        // serialized and round-trips as empty. Compare content per-field,
        // excluding the (intentionally omitted) id.
        if case .userMessage(_, let c) = hydrated[0] {
            XCTAssertEqual(c.first?.text, "original Q")
        } else { XCTFail("expected userMessage") }
        if case .agentMessage(_, let s) = hydrated[1] {
            XCTAssertEqual(s, "summary placeholder")
        } else { XCTFail("expected agentMessage") }
        if case .reasoning(_, let summary, _, _) = hydrated[2] {
            XCTAssertEqual(summary, ["kept reasoning"])
        } else { XCTFail("expected reasoning") }
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
                                         approvalPolicy: "untrusted",
                                         sandboxPolicy: .workspaceWrite(
                                            writableRoots: ["/some/dir"],
                                            networkAccess: true),
                                         summary: "concise",
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
        // P1.4 / H-51: the three REQUIRED upstream TurnContextItem fields.
        XCTAssertEqual(payload["approval_policy"] as? String, "untrusted",
                       "approval_policy emitted as the kebab-case AskForApproval wire string")
        XCTAssertEqual(payload["summary"] as? String, "concise",
                       "summary emitted as the lowercase ReasoningSummary wire string")
        let sandbox = try XCTUnwrap(payload["sandbox_policy"] as? [String: Any],
                                    "sandbox_policy must be the internally-tagged upstream dict")
        XCTAssertEqual(sandbox["type"] as? String, "workspace-write",
                       "sandbox_policy uses upstream kebab-case tag (not v2 camelCase)")
        XCTAssertEqual(sandbox["writable_roots"] as? [String], ["/some/dir"])
        XCTAssertEqual(sandbox["network_access"] as? Bool, true)
        XCTAssertEqual(sandbox["exclude_tmpdir_env_var"] as? Bool, false)
        XCTAssertEqual(sandbox["exclude_slash_tmp"] as? Bool, false)
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
                                         model: "gpt-5",
                                         approvalPolicy: "on-request",
                                         sandboxPolicy: .readOnly(),
                                         summary: "auto"))
        _ = try await w.durabilityBarrier(); await w.close()
        let raw = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8))
                                 as? [String: Any])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        // The REQUIRED upstream fields are always present...
        XCTAssertEqual(payload["approval_policy"] as? String, "on-request")
        XCTAssertEqual(payload["summary"] as? String, "auto")
        let sandbox = try XCTUnwrap(payload["sandbox_policy"] as? [String: Any])
        XCTAssertEqual(sandbox["type"] as? String, "read-only")
        // read-only network_access is skip-if-false upstream, so omitted here.
        XCTAssertNil(sandbox["network_access"])
        // ...while the optional fields are omitted, not null.
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
                                         approvalPolicy: "never",
                                         sandboxPolicy: .dangerFullAccess,
                                         summary: "detailed",
                                         currentDate: "2026-05-23",
                                         timezone: "UTC",
                                         realtimeActive: true))
        _ = try await w.durabilityBarrier(); await w.close()
        let recs = try RolloutReader().readAll(path: path)
        XCTAssertEqual(recs.count, 1)
        guard case .turnContext(let rTid, let rCwd, let rModel,
                                let rApproval, let rSandbox, let rSummary,
                                let rDate, let rTz, let rRT) = recs[0] else {
            XCTFail("expected .turnContext after round-trip, got \(recs[0])")
            return
        }
        XCTAssertEqual(rTid, tid)
        XCTAssertEqual(rCwd, "/Users/example/Projects/foo",
                       "P1.4: cwd must round-trip through the rollout reader")
        XCTAssertEqual(rModel, "gpt-5.1-codex")
        // P1.4 / H-51: the required fields round-trip through the reader too.
        XCTAssertEqual(rApproval, "never")
        XCTAssertEqual(rSandbox, .dangerFullAccess)
        XCTAssertEqual(rSummary, "detailed")
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
        if case .turnContext(_, let cwd, let model, let approval, let sandbox,
                             let summary, _, _, _) = recs[0] {
            XCTAssertEqual(cwd, "", "legacy records degrade cwd to empty string")
            XCTAssertEqual(model, "m")
            // P1.4 / H-51: legacy records lacking the required fields degrade
            // to the upstream defaults rather than failing to decode.
            XCTAssertEqual(approval, "on-request")
            XCTAssertEqual(sandbox, .workspaceWrite())
            XCTAssertEqual(summary, "auto")
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
        // persistence-rollout finding 1: upstream marks the message `id` with
        // `#[serde(default, skip_serializing)]`, so it is never written. We
        // omit it for byte-parity.
        XCTAssertNil(obj["id"],
                     "message id must be omitted from the wire (finding 1)")
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

    // MARK: persistence-rollout finding 1 — archive() moves the rollout file
    //       into archived_sessions/ (mirrors archive_thread.rs tests).

    /// Locate any rollout file whose name ends with the thread's id, anywhere
    /// under `home` (sessions/ or archived_sessions/). Returns nil if absent.
    private func locateRollout(_ home: String, _ id: ThreadId) -> String? {
        if let en = FileManager.default.enumerator(atPath: home) {
            for case let rel as String in en
            where rel.hasSuffix("-\(id.raw).jsonl") || rel.hasSuffix("\(id.raw).rollout.jsonl") {
                return home + "/" + rel
            }
        }
        return nil
    }

    func testArchiveMovesRolloutIntoArchivedSessions() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/w"))
        let turn = TurnId("t1")
        try await store.record(id, .userInput(turnId: turn, input: [TurnInput(text: "hi")]))
        try await store.durabilityBarrier(id)

        let activePath = try XCTUnwrap(locateRollout(home, id))
        XCTAssertTrue(activePath.contains("/sessions/"),
                      "fresh rollout lives under sessions/")

        try await store.archive(id)

        // Active file gone; file now lives under archived_sessions/<basename>.
        XCTAssertFalse(FileManager.default.fileExists(atPath: activePath),
                       "archive must MOVE the file out of sessions/")
        let fileName = (activePath as NSString).lastPathComponent
        let archivedPath = home + "/archived_sessions/" + fileName
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedPath),
                      "archived rollout must exist under archived_sessions/")

        // The thread is listed as archived and its DB rollout_path repoints.
        let arch = try await store.list(archived: true)
        XCTAssertEqual(arch.map(\.id), [id])
        let active = try await store.list(archived: false)
        XCTAssertEqual(active.map(\.id), [])

        // Reconstruct + summary honor the archived location (resolvedRolloutPath
        // reads the repointed DB path).
        let rebuilt = try await store.reconstruct(id)
        XCTAssertTrue(rebuilt.items.contains {
            if case .userMessage(_, let c) = $0 { return c.first?.text == "hi" }
            return false
        })
        let summary = try await store.conversationSummary(id: id)
        XCTAssertEqual(summary?.path, archivedPath)
    }

    func testUnarchiveRestoresRolloutToDatePartitionedTree() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/w"))
        try await store.record(id, .userInput(turnId: TurnId("t1"),
                                              input: [TurnInput(text: "hi")]))
        try await store.durabilityBarrier(id)
        let originalPath = try XCTUnwrap(locateRollout(home, id))
        let fileName = (originalPath as NSString).lastPathComponent

        try await store.archive(id)
        let archivedPath = home + "/archived_sessions/" + fileName
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedPath))

        try await store.unarchive(id)

        // Archived copy gone; restored under sessions/YYYY/MM/DD/.
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedPath),
                       "unarchive must MOVE the file out of archived_sessions/")
        let restored = try XCTUnwrap(locateRollout(home, id))
        XCTAssertTrue(restored.contains("/sessions/"),
                      "restored rollout lives under the sessions/ tree")
        XCTAssertFalse(restored.contains("/archived_sessions/"))
        // Date-partition derives from the filename stamp (rollout_date_parts).
        let parts = try XCTUnwrap(ThreadStore.rolloutDateParts(fileName))
        XCTAssertTrue(restored.hasSuffix("/sessions/\(parts.0)/\(parts.1)/\(parts.2)/\(fileName)"))

        // DB flag cleared.
        let activeAfter = try await store.list(archived: false)
        XCTAssertEqual(activeAfter.map(\.id), [id])
        let archivedAfter = try await store.list(archived: true)
        XCTAssertEqual(archivedAfter.map(\.id), [])
    }

    func testArchiveIsIdempotent() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: id, cwd: "/w"))
        try await store.durabilityBarrier(id)
        try await store.archive(id)
        let first = try XCTUnwrap(locateRollout(home, id))
        // A second archive must not move/lose the already-archived file.
        try await store.archive(id)
        let second = try XCTUnwrap(locateRollout(home, id))
        XCTAssertEqual(first, second)
        XCTAssertTrue(second.contains("/archived_sessions/"))
        let archived = try await store.list(archived: true)
        XCTAssertEqual(archived.map(\.id), [id])
    }

    func testArchivedAtRecordedAndCleared() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let db = try StateDB(path: home + "/state.sqlite3")
        // Seed a thread row directly so we can inspect the archived_at column.
        let t: Int64 = 1_700_000_000
        try await db.upsertThread(ThreadRow(
            id: "x", cwd: "/w", model: "m", createdAt: t, updatedAt: t,
            archived: false, ephemeral: false, rolloutPath: home + "/sessions/x.jsonl",
            lastCommittedSeq: 0, name: nil, memoryMode: "enabled",
            gitSha: nil, gitBranch: nil, gitOriginURL: nil))
        let seeded = try await db.getThread("x")
        XCTAssertNil(seeded?.archivedAt)

        let archivedAt: Int64 = 1_700_000_500
        try await db.markArchived("x", rolloutPath: home + "/archived_sessions/x.jsonl",
                                  archivedAt: archivedAt)
        let archivedRowOpt = try await db.getThread("x")
        let archivedRow = try XCTUnwrap(archivedRowOpt)
        XCTAssertTrue(archivedRow.archived)
        XCTAssertEqual(archivedRow.archivedAt, archivedAt)
        // archive_thread.rs asserts archived_at == updated_at.
        XCTAssertEqual(archivedRow.archivedAt, archivedRow.updatedAt)
        XCTAssertEqual(archivedRow.rolloutPath, home + "/archived_sessions/x.jsonl")

        try await db.markUnarchived("x", rolloutPath: home + "/sessions/2025/01/01/x.jsonl",
                                    updatedAt: 1_700_000_900)
        let restoredRowOpt = try await db.getThread("x")
        let restoredRow = try XCTUnwrap(restoredRowOpt)
        XCTAssertFalse(restoredRow.archived)
        XCTAssertNil(restoredRow.archivedAt)
        XCTAssertEqual(restoredRow.rolloutPath, home + "/sessions/2025/01/01/x.jsonl")
    }

    func testRolloutDatePartsParsesUpstreamFilename() {
        let parts = ThreadStore.rolloutDateParts(
            "rollout-2025-01-03T12-00-00-0123abcd.jsonl")
        XCTAssertEqual(parts?.0, "2025")
        XCTAssertEqual(parts?.1, "01")
        XCTAssertEqual(parts?.2, "03")
        // Missing the `rollout-` prefix → nil (upstream strip_prefix fails).
        XCTAssertNil(ThreadStore.rolloutDateParts("not-a-rollout.jsonl"))
        // Fewer than 10 chars after the prefix → nil (upstream `.get(..10)`).
        XCTAssertNil(ThreadStore.rolloutDateParts("rollout-202.jsonl"))
    }

    // MARK: persistence-rollout finding 2 — reader interprets an upstream
    //       `thread_rolled_back` marker (drops last N turns on replay).

    func testThreadRolledBackMarkerDropsLastTurnsOnReplay() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        // Build a NON-destructive forward-history rollout (as an upstream client
        // would write it): full history of two turns followed by a
        // thread_rolled_back{num_turns:1} marker. Our reader must reconstruct
        // only the first turn.
        let dir = home + "/sessions/2025/01/03"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/rollout-2025-01-03T12-00-00-marker.jsonl"

        var data = Data()
        func appendLine(_ d: Data) { data.append(d); data.append(0x0A) }
        let keep = TurnId("turn_keep")
        let drop = TurnId("turn_drop")
        appendLine(try RolloutWriter.encodeLine(
            .userInput(turnId: keep, input: [TurnInput(text: "keep me")])))
        appendLine(try RolloutWriter.encodeLine(.turnBoundary(turnId: keep, status: .completed)))
        appendLine(try RolloutWriter.encodeLine(
            .userInput(turnId: drop, input: [TurnInput(text: "drop me")])))
        appendLine(try RolloutWriter.encodeLine(.turnBoundary(turnId: drop, status: .completed)))
        // The durable upstream marker.
        appendLine(try RolloutWriter.threadRolledBackLine(numTurns: 1))
        try data.write(to: URL(fileURLWithPath: path))

        let records = try RolloutReader().readAll(path: path)
        // The dropped turn's records must be gone; the marker contributes none.
        let turnIds: Set<String> = Set(records.compactMap { rec -> String? in
            switch rec {
            case .userInput(let t, _), .turnBoundary(let t, _, _, _, _): return t.raw
            default: return nil
            }
        })
        XCTAssertTrue(turnIds.contains(keep.raw))
        XCTAssertFalse(turnIds.contains(drop.raw),
                       "thread_rolled_back marker must drop the last turn on replay")
        XCTAssertFalse(records.contains {
            if case .userInput(_, let input) = $0 {
                return input.first?.text == "drop me"
            }
            return false
        })
    }

    func testThreadRolledBackMarkerWireShape() throws {
        let line = try RolloutWriter.threadRolledBackLine(numTurns: 3)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "event_msg")
        XCTAssertNotNil(obj["timestamp"])
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "thread_rolled_back")
        XCTAssertEqual(payload["num_turns"] as? Int, 3)
        XCTAssertEqual(RolloutReader.threadRolledBackNumTurns(line: line), 3)
    }

    // MARK: persistence-rollout finding 3 — originator resolution

    func testDefaultOriginatorIsBareIdAndHonorsEnvOverride() {
        // No override → bare default id (mirrors upstream DEFAULT_ORIGINATOR).
        XCTAssertEqual(SessionConfig.defaultOriginator(env: [:]), "codex_swift")
        // CODEX_INTERNAL_ORIGINATOR_OVERRIDE wins (upstream get_originator_value).
        XCTAssertEqual(
            SessionConfig.defaultOriginator(
                env: ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "codex_vscode"]),
            "codex_vscode")
        // A present-but-empty override is treated as set (upstream env::var.ok()
        // returns Some("") which wins over the default).
        XCTAssertEqual(
            SessionConfig.defaultOriginator(
                env: ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": ""]),
            "")
    }

    func testSessionConfigOriginatorAndVersionFlowIntoSessionMeta() async throws {
        let home = tmpHome(); defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: smallLimits())
        let id = ThreadId("finding3_originator")
        // Configured originator/version must be persisted verbatim.
        let cfg = SessionConfig(threadId: id, cwd: "/tmp/work",
                                originator: "codex_vscode", cliVersion: "9.9.9")
        _ = try await store.create(cfg)
        try await store.record(id, .turnBoundary(turnId: TurnId("t0"), status: .inProgress))
        try await store.durabilityBarrier(id)

        let path = findRollout(home, id)
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let head = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(lines[0].utf8)) as? [String: Any])
        let payload = try XCTUnwrap(head["payload"] as? [String: Any])
        XCTAssertEqual(payload["originator"] as? String, "codex_vscode")
        XCTAssertEqual(payload["cli_version"] as? String, "9.9.9")
    }

}
