import XCTest
import Foundation
@testable import ProtocolModel
@testable import WireProtocol

final class ProtocolModelTests: XCTestCase {

    private func req(_ method: String, _ params: JSONValue?, id: RequestId = .int(1)) -> JSONRPCRequest {
        JSONRPCRequest(id: id, method: method, params: params)
    }

    func testParseInitializeAndTurnStart() throws {
        let initJSON: JSONValue = .object([
            "clientInfo": .object(["name": .string("codex_vscode")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ])
        guard case .initialize(_, let p) = try ClientRequest.parse(req("initialize", initJSON)) else {
            return XCTFail("expected initialize")
        }
        XCTAssertEqual(p.clientInfo.name, "codex_vscode")
        XCTAssertEqual(p.capabilities?.experimentalApi, true)

        let turnJSON: JSONValue = .object([
            "threadId": .string("thr_1"),
            "input": .array([.object(["type": .string("text"), "text": .string("hi")])])
        ])
        guard case .turnStart(_, let tp) = try ClientRequest.parse(req("turn/start", turnJSON)) else {
            return XCTFail("expected turnStart")
        }
        XCTAssertEqual(tp.threadId, ThreadId("thr_1"))
        XCTAssertEqual(tp.input.first?.text, "hi")
    }

    func testUnknownMethodBecomesUnsupported() throws {
        // Only methods that are NOT part of the Codex protocol map to .unsupported.
        let r = try ClientRequest.parse(req("totally/unknown/method", .object([:])))
        guard case .unsupported(_, let m) = r else { return XCTFail("expected unsupported") }
        XCTAssertEqual(m, "totally/unknown/method")
    }

    func testKnownCodexMethodsAreDispatchedNotUnsupported() throws {
        // A real Codex method with no dedicated typed case → .generic (dispatched).
        guard case .generic(_, let gm, _) =
            try ClientRequest.parse(req("plugin/list", .object([:]))) else {
            return XCTFail("expected generic dispatch for a known Codex method")
        }
        XCTAssertEqual(gm, "plugin/list")
        // Typed goal/memory/model methods parse to their typed cases.
        guard case .threadGoalSet(_, let gp) = try ClientRequest.parse(
            req("thread/goal/set", .object(["threadId": .string("t"),
                                            "objective": .string("ship")]))) else {
            return XCTFail("expected threadGoalSet")
        }
        XCTAssertEqual(gp.objective, "ship")
        guard case .threadMemoryModeSet(_, let mp) = try ClientRequest.parse(
            req("thread/memoryMode/set", .object(["threadId": .string("t"),
                                                  "mode": .string("disabled")]))) else {
            return XCTFail("expected threadMemoryModeSet")
        }
        XCTAssertEqual(mp.mode, .disabled)
        guard case .modelList = try ClientRequest.parse(req("model/list", nil)) else {
            return XCTFail("expected modelList with empty params default")
        }
    }

    func testBadParamsForKnownMethodThrows() {
        XCTAssertThrowsError(try ClientRequest.parse(req("turn/start", .object(["wrong": .int(1)])))) { e in
            guard case ProtocolError.invalidParams = e else { return XCTFail("expected invalidParams: \(e)") }
        }
    }

    func testThreadListMissingVsMalformedParams() throws {
        // Missing → defaults
        guard case .threadList(_, let d) = try ClientRequest.parse(req("thread/list", nil)) else {
            return XCTFail()
        }
        XCTAssertNil(d.cursor)
        // Malformed (limit must be int) → invalidParams (not swallowed)
        XCTAssertThrowsError(try ClientRequest.parse(req("thread/list", .object(["limit": .string("nope")])))) { e in
            guard case ProtocolError.invalidParams = e else { return XCTFail("expected invalidParams") }
        }
    }

    func testPinnedRequestOptionalFieldsDecode() throws {
        guard case .threadStart(_, let start) = try ClientRequest.parse(
            req("thread/start", .object([
                "cwd": .string("/tmp/work"),
                "approvalPolicy": .string("on-request"),
                "approvalsReviewer": .string("auto_review"),
                "config": .object(["profile": .string("dev")]),
                "sandbox": .string("workspace-write"),
                "serviceName": .string("codex-swift-test"),
                "serviceTier": .string("default"),
                "sessionStartSource": .string("startup"),
                "threadSource": .string("user"),
            ]))) else { return XCTFail("expected threadStart") }
        XCTAssertEqual(start.approvalPolicy, .string("on-request"))
        XCTAssertEqual(start.approvalsReviewer, "auto_review")
        XCTAssertEqual(start.config, .object(["profile": .string("dev")]))
        XCTAssertEqual(start.sandbox, "workspace-write")
        XCTAssertEqual(start.serviceName, "codex-swift-test")
        XCTAssertEqual(start.sessionStartSource, "startup")

        guard case .threadResume(_, let resume) = try ClientRequest.parse(
            req("thread/resume", .object([
                "threadId": .string("thr_resume"),
                "cwd": .string("/tmp/resume"),
                "model": .string("gpt-test"),
                "modelProvider": .string("openai"),
                "personality": .string("friendly"),
                "serviceTier": .string("priority"),
            ]))) else { return XCTFail("expected threadResume") }
        XCTAssertEqual(resume.cwd, "/tmp/resume")
        XCTAssertEqual(resume.modelProvider, "openai")
        XCTAssertEqual(resume.personality, "friendly")

        guard case .turnStart(_, let turn) = try ClientRequest.parse(
            req("turn/start", .object([
                "threadId": .string("thr_turn"),
                "input": .array([.object(["type": .string("text"), "text": .string("hi")])]),
                "cwd": .string("/tmp/turn"),
                "effort": .string("high"),
                "outputSchema": .object(["type": .string("object")]),
                "sandboxPolicy": .object(["type": .string("readOnly")]),
                "summary": .string("auto"),
            ]))) else { return XCTFail("expected turnStart") }
        XCTAssertEqual(turn.cwd, "/tmp/turn")
        XCTAssertEqual(turn.effort, "high")
        XCTAssertEqual(turn.outputSchema, .object(["type": .string("object")]))
        XCTAssertEqual(turn.sandboxPolicy, .object(["type": .string("readOnly")]))

        guard case .mcpServerStatusList(_, let mcp) = try ClientRequest.parse(
            req("mcpServerStatus/list", .object(["detail": .string("toolsAndAuthOnly")]))) else {
            return XCTFail("expected mcpServerStatusList")
        }
        XCTAssertEqual(mcp.detail, "toolsAndAuthOnly")
    }

    func testReviewStartUsesPinnedTargetShape() throws {
        let params: JSONValue = .object([
            "threadId": .string("thr_review"),
            "delivery": .string("inline"),
            "target": .object([
                "type": .string("custom"),
                "instructions": .string("Review the changed files for logic bugs."),
            ]),
        ])
        guard case .reviewStart(_, let review) = try ClientRequest.parse(req("review/start", params)) else {
            return XCTFail("expected reviewStart")
        }
        XCTAssertEqual(review.threadId, ThreadId("thr_review"))
        XCTAssertEqual(review.delivery, "inline")
        XCTAssertEqual(review.reviewInstructions, "Review the changed files for logic bugs.")
        XCTAssertEqual(review.reviewInput, [TurnInput(text: "Review the changed files for logic bugs.")])
    }

    func testThreadItemRoundTrip() throws {
        let items: [ThreadItem] = [
            .userMessage(id: ItemId("u1"), content: [UserMessageContent(text: "hello")]),
            .agentMessage(id: ItemId("a1"), text: "hi there"),
            .commandExecution(id: ItemId("c1"), command: ["ls", "-la"], cwd: "/tmp",
                              status: .completed, aggregatedOutput: "out", exitCode: 0),
            .fileChange(id: ItemId("f1"),
                        changes: [.init(path: "a.txt", kind: "modify", diff: "@@")],
                        status: .completed),
            .contextCompaction(id: ItemId("k1")),
        ]
        for it in items {
            let data = try JSONEncoder().encode(it)
            let back = try JSONDecoder().decode(ThreadItem.self, from: data)
            XCTAssertEqual(back, it)
        }
    }

    /// P5.3 / compaction-F6: the on-wire discriminator for the compaction
    /// marker item is `"contextCompaction"` (camelCase, matching the rest of
    /// the Swift `ThreadItem` surface — upstream Rust's
    /// `TurnItem::ContextCompaction(ContextCompactionItem { id })` carries
    /// only an `id`, and our wrapper-less encoding has the same shape).
    func testContextCompactionWireDiscriminator() throws {
        let item: ThreadItem = .contextCompaction(id: ItemId("cmp_42"))
        let data = try JSONEncoder().encode(item)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "contextCompaction",
                       "compaction marker uses the camelCase discriminator")
        XCTAssertEqual(obj?["id"] as? String, "cmp_42",
                       "ContextCompactionItem carries only `id` like upstream")
        // Decode also accepts the same shape.
        let back = try JSONDecoder().decode(ThreadItem.self, from: data)
        XCTAssertEqual(back, item)
    }

    /// P2.5 / H-12: upstream `ThreadItem` is a large tagged enum (mcpToolCall,
    /// webSearch, hookPrompt, dynamicToolCall, ...) whose variants Swift does
    /// not yet model. Previously the decoder threw on any unrecognized
    /// `type`, which would crash the `item/started` / `item/completed`
    /// notification pipeline the moment upstream emitted one of those items.
    /// The tolerant `.unknown` fallback captures the JSON verbatim so the
    /// notification can be logged, observed, and re-emitted losslessly.
    func testThreadItemUnknownTypeDecodesAsFallback() throws {
        let json = """
        {
          "type": "newUnknownType",
          "id": "tk_1",
          "server": "weather",
          "tool": "forecast",
          "extraFutureField": [1, 2, 3]
        }
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(ThreadItem.self, from: json)
        guard case .unknown(let id, let typeName, let raw) = item else {
            return XCTFail("expected .unknown ThreadItem, got \(item)")
        }
        XCTAssertEqual(id, ItemId("tk_1"))
        XCTAssertEqual(typeName, "newUnknownType")
        guard case .object(let fields) = raw else {
            return XCTFail("raw should be a JSON object")
        }
        XCTAssertEqual(fields["server"], .string("weather"))
        XCTAssertEqual(fields["tool"], .string("forecast"))
        XCTAssertEqual(fields["extraFutureField"],
                       .array([.int(1), .int(2), .int(3)]))
        XCTAssertEqual(item.typeName, "newUnknownType")
        XCTAssertEqual(item.id, ItemId("tk_1"))
    }

    /// P2.5 / H-12: a `.unknown` item must re-emit byte-equivalent JSON so
    /// downstream consumers (rollouts, replay, observability) see the same
    /// shape upstream sent. We compare the parsed JSON object (key order is
    /// not guaranteed across the Foundation encoder).
    func testThreadItemUnknownTypeRoundTrips() throws {
        let json = """
        {
          "type": "mcpToolCall",
          "id": "mcp_42",
          "server": "fs",
          "tool": "readFile",
          "status": "completed",
          "arguments": {"path": "/tmp/x"},
          "result": null,
          "error": null,
          "durationMs": 12
        }
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(ThreadItem.self, from: json)
        guard case .unknown = item else {
            return XCTFail("expected .unknown fallback for mcpToolCall")
        }
        let encoded = try JSONEncoder().encode(item)
        let original = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let roundTripped = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(original?["type"] as? String,
                       roundTripped?["type"] as? String)
        XCTAssertEqual(original?["id"] as? String,
                       roundTripped?["id"] as? String)
        XCTAssertEqual(original?["server"] as? String,
                       roundTripped?["server"] as? String)
        XCTAssertEqual(original?["tool"] as? String,
                       roundTripped?["tool"] as? String)
        XCTAssertEqual(original?["status"] as? String,
                       roundTripped?["status"] as? String)
        XCTAssertEqual(original?["durationMs"] as? Int,
                       roundTripped?["durationMs"] as? Int)
        XCTAssertEqual((original?["arguments"] as? [String: Any])?["path"] as? String,
                       (roundTripped?["arguments"] as? [String: Any])?["path"] as? String)
        // Decoding the re-encoded JSON yields the same case.
        let again = try JSONDecoder().decode(ThreadItem.self, from: encoded)
        XCTAssertEqual(again, item)
    }

    /// P2.5: also covers the audit-listed item types that previously threw —
    /// `mcpToolCall`, `webSearch`, `backgroundTerminal` — confirming the
    /// notification pipeline can decode them without crashing. Extended in
    /// the P2.5 sweep follow-up to cover the remaining unmodeled upstream
    /// `ThreadItemDetails` / streamed-item variants the reviewer flagged:
    /// `collabAgentToolCall` (per upstream `CollabToolCallItem` in
    /// `codex-rs/exec/src/exec_events.rs`), `imageView`, `imageGeneration`
    /// (per upstream `ImageGeneration*` events in
    /// `codex-rs/rollout-trace/src/protocol_event.rs` /
    /// `codex-rs/tools/src/tool_spec.rs`), and the review-mode lifecycle
    /// markers `enteredReviewMode` / `exitedReviewMode` (per upstream
    /// `EventMsg::{Entered,Exited}ReviewMode` in
    /// `codex-rs/protocol/src/protocol.rs`). The exact payload shapes are
    /// intentionally minimal — the contract under test is "tolerant decode
    /// to `.unknown`, never throws", not field-level parity (which is
    /// validated separately when these variants get first-class Swift
    /// models).
    func testThreadItemAuditListedTypesDecodeTolerantly() throws {
        let payloads = [
            // Already-covered audit-listed variants:
            #"{"type":"mcpToolCall","id":"a"}"#,
            #"{"type":"webSearch","id":"b","query":"foo"}"#,
            #"{"type":"backgroundTerminal","id":"c"}"#,
            #"{"type":"hookPrompt","id":"d","fragments":[]}"#,
            #"{"type":"dynamicToolCall","id":"e","tool":"x","arguments":{}}"#,
            #"{"type":"plan","id":"f","text":"step 1"}"#,
            // P2.5 sweep follow-up — the five remaining unmodeled variants:
            // 1. collabAgentToolCall (upstream `CollabToolCall`).
            #"""
            {"type":"collabAgentToolCall","id":"g","tool":"spawn_agent",\#
            "senderThreadId":"thr_1","receiverThreadIds":["thr_2"],\#
            "agentsStates":{},"status":"in_progress"}
            """#,
            // 2. imageView — agent-emitted image attachment for viewing.
            #"{"type":"imageView","id":"h","url":"https://example.com/x.png"}"#,
            // 3. imageGeneration — upstream `ImageGeneration` tool item.
            #"""
            {"type":"imageGeneration","id":"i","status":"completed",\#
            "outputFormat":"png","revisedPrompt":"a red sphere"}
            """#,
            // 4/5. Review-mode lifecycle markers.
            #"{"type":"enteredReviewMode","id":"j","prompt":"review my changes"}"#,
            #"""
            {"type":"exitedReviewMode","id":"k","reviewOutput":\#
            {"overallExplanation":"looks good"}}
            """#,
        ]
        for raw in payloads {
            let item = try JSONDecoder().decode(
                ThreadItem.self, from: raw.data(using: .utf8)!)
            guard case .unknown(_, let typeName, _) = item else {
                return XCTFail("\(raw) should decode as .unknown")
            }
            // Sanity-check that the captured discriminator survived the
            // tolerant decode — this is what re-emission and observability
            // rely on for the unmodeled variants.
            XCTAssertFalse(typeName.isEmpty,
                           "tolerant fallback must capture the upstream type name")
        }
    }

    func testServerNotificationWireShapesAndV1Alias() throws {
        let n = ServerNotification.turnStarted(
            threadId: ThreadId("thr_1"),
            turn: TurnObject(id: TurnId("turn_1"), status: .inProgress))
        guard case .notification(let v2) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(v2.method, "turn/started")
        XCTAssertEqual(v2.params?["threadId"]?.stringValue, "thr_1")

        guard case .notification(let v1) = n.toMessage(v1Alias: true) else { return XCTFail() }
        XCTAssertEqual(v1.method, "task_started")

        let done = ServerNotification.turnCompleted(
            threadId: ThreadId("thr_1"),
            turn: TurnObject(id: TurnId("turn_1"), status: .completed))
        guard case .notification(let dv1) = done.toMessage(v1Alias: true) else { return XCTFail() }
        XCTAssertEqual(dv1.method, "task_complete")

        guard case .notification(let archived) = ServerNotification.threadArchived(
            threadId: ThreadId("thr_1")).toMessage() else { return XCTFail() }
        XCTAssertEqual(archived.method, "thread/archived")
        XCTAssertEqual(archived.params?["threadId"]?.stringValue, "thr_1")

        guard case .notification(let unarchived) = ServerNotification.threadUnarchived(
            threadId: ThreadId("thr_1")).toMessage() else { return XCTFail() }
        XCTAssertEqual(unarchived.method, "thread/unarchived")
        XCTAssertEqual(unarchived.params?["threadId"]?.stringValue, "thr_1")
    }

    /// Parity P2.1 / C3 / H-01, H-02, H-08: `turn/aborted` is a distinct
    /// notification (no longer folded into `turn/completed`). The wire shape
    /// must carry `threadId`, `turnId`, the canonical `reason`, and the
    /// optional lifecycle fields (`completedAt`, `durationMs`,
    /// `lastAgentMessage`). Optional fields are *omitted* when nil so v2
    /// clients can rely on presence to disambiguate "unknown" from "zero".
    func testTurnAbortedNotificationCarriesUpstreamFields() throws {
        // All optional fields populated.
        let full = ServerNotification.turnAborted(
            threadId: ThreadId("thr_42"),
            turnId: TurnId("turn_42"),
            reason: "interrupted",
            completedAt: 1_716_500_000,
            durationMs: 1_234,
            lastAgentMessage: "I was thinking about it...")
        guard case .notification(let n) = full.toMessage() else {
            return XCTFail("expected notification frame")
        }
        XCTAssertEqual(n.method, "turn/aborted")
        XCTAssertEqual(n.params?["threadId"]?.stringValue, "thr_42")
        XCTAssertEqual(n.params?["turnId"]?.stringValue, "turn_42")
        XCTAssertEqual(n.params?["reason"]?.stringValue, "interrupted")
        XCTAssertEqual(n.params?["completedAt"]?.intValue, Int64(1_716_500_000))
        XCTAssertEqual(n.params?["durationMs"]?.intValue, Int64(1_234))
        XCTAssertEqual(n.params?["lastAgentMessage"]?.stringValue,
                       "I was thinking about it...")

        // Nil-optional fields are omitted from the wire (parity with
        // upstream `skip_serializing_if = "Option::is_none"`), so clients can
        // tell "field unknown" from "field present".
        let minimal = ServerNotification.turnAborted(
            threadId: ThreadId("thr_x"),
            turnId: TurnId("turn_x"),
            reason: "replaced",
            completedAt: nil,
            durationMs: nil,
            lastAgentMessage: nil)
        guard case .notification(let m) = minimal.toMessage() else {
            return XCTFail("expected notification frame")
        }
        XCTAssertEqual(m.method, "turn/aborted")
        XCTAssertEqual(m.params?["reason"]?.stringValue, "replaced")
        XCTAssertNil(m.params?["completedAt"],
                     "completedAt must be omitted when nil")
        XCTAssertNil(m.params?["durationMs"],
                     "durationMs must be omitted when nil")
        XCTAssertNil(m.params?["lastAgentMessage"],
                     "lastAgentMessage must be omitted when nil")
    }

    /// Parity P2.1 / H-08: `TurnObject` carries upstream `Turn`'s four
    /// lifecycle fields (`startedAt`, `completedAt`, `durationMs`,
    /// `itemsView`). Optional fields are omitted from the wire when nil.
    func testTurnObjectCarriesLifecycleFields() throws {
        // All four populated → round-trips through JSON faithfully.
        let full = TurnObject(
            id: TurnId("turn_full"),
            status: .completed,
            itemsView: .full,
            startedAt: 1_716_500_000,
            completedAt: 1_716_500_005,
            durationMs: 5_000)
        let data = try JSONEncoder().encode(full)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, "turn_full")
        XCTAssertEqual(obj["status"] as? String, "completed")
        XCTAssertEqual(obj["itemsView"] as? String, "full")
        XCTAssertEqual(obj["startedAt"] as? Int, 1_716_500_000)
        XCTAssertEqual(obj["completedAt"] as? Int, 1_716_500_005)
        XCTAssertEqual(obj["durationMs"] as? Int, 5_000)
        let back = try JSONDecoder().decode(TurnObject.self, from: data)
        XCTAssertEqual(back, full)

        // Nil-optional fields are omitted from the wire (parity with upstream
        // `skip_serializing_if = "Option::is_none"`).
        let bare = TurnObject(id: TurnId("turn_bare"), status: .inProgress)
        let bareData = try JSONEncoder().encode(bare)
        let bareObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bareData) as? [String: Any])
        XCTAssertNil(bareObj["startedAt"], "startedAt omitted when nil")
        XCTAssertNil(bareObj["completedAt"], "completedAt omitted when nil")
        XCTAssertNil(bareObj["durationMs"], "durationMs omitted when nil")
        XCTAssertNil(bareObj["itemsView"], "itemsView omitted when nil")
        // Round-trip preserves nils.
        let bareBack = try JSONDecoder().decode(TurnObject.self, from: bareData)
        XCTAssertEqual(bareBack, bare)
        XCTAssertNil(bareBack.startedAt)
        XCTAssertNil(bareBack.itemsView)

        // `itemsView` decodes upstream's three canonical values.
        for raw in ["notLoaded", "summary", "full"] {
            let json = "{\"id\":\"t\",\"items\":[],\"status\":\"inProgress\",\"itemsView\":\"\(raw)\"}"
            let decoded = try JSONDecoder().decode(
                TurnObject.self, from: Data(json.utf8))
            XCTAssertNotNil(decoded.itemsView,
                            "itemsView=\(raw) should decode to enum")
        }
    }

    /// Parity P2.3 (H-06): the `error` notification must carry `willRetry`
    /// (so transient stream errors mid-retry can be suppressed by clients)
    /// and `turnId` (so the error can be associated with a turn for UI
    /// grouping). Wire keys are camelCase to match the upstream
    /// `ErrorNotification` JSON schema and the rest of the v2 surface.
    func testErrorNotificationCarriesWillRetryAndTurnId() throws {
        // Active-turn case: every field populated, will_retry=true.
        let withTurn = ServerNotification.error(
            threadId: ThreadId("thr_abc"),
            turnId: TurnId("turn_42"),
            willRetry: true,
            ErrorBody(message: "transient 503", codexErrorInfo: "StreamError"))
        guard case .notification(let n) = withTurn.toMessage() else {
            return XCTFail("expected notification frame")
        }
        XCTAssertEqual(n.method, "error")
        let params = n.params
        XCTAssertEqual(params?["threadId"]?.stringValue, "thr_abc")
        XCTAssertEqual(params?["turnId"]?.stringValue, "turn_42")
        // `willRetry` must be a JSON boolean, not a string/number.
        if case .bool(let b)? = params?["willRetry"] { XCTAssertTrue(b) }
        else { XCTFail("willRetry should serialize as JSON bool, got \(String(describing: params?["willRetry"]))") }
        XCTAssertEqual(params?["error"]?["message"]?.stringValue, "transient 503")
        XCTAssertEqual(params?["error"]?["codexErrorInfo"]?.stringValue, "StreamError")

        // Pre-turn / supervisor case: no active turn, will_retry=false. The
        // optional `turnId` must be omitted from the wire (not encoded as
        // null) so v2 clients can rely on `turnId` being absent when the
        // error is not tied to a specific turn.
        let preTurn = ServerNotification.error(
            threadId: ThreadId("thr_abc"),
            turnId: nil,
            willRetry: false,
            ErrorBody(message: "queue overload", codexErrorInfo: "Overloaded"))
        guard case .notification(let pn) = preTurn.toMessage() else {
            return XCTFail("expected notification frame")
        }
        let pparams = pn.params
        XCTAssertEqual(pparams?["threadId"]?.stringValue, "thr_abc")
        XCTAssertNil(pparams?["turnId"], "turnId must be omitted when nil")
        if case .bool(let b)? = pparams?["willRetry"] { XCTAssertFalse(b) }
        else { XCTFail("willRetry should serialize as JSON bool") }
    }

    func testServerRequestDecisionDecode() throws {
        let sr = ServerRequest.commandApproval(.int(9), .init(
            threadId: ThreadId("t"), turnId: TurnId("tn"), itemId: ItemId("i"),
            command: ["rm", "-rf", "/"], cwd: "/", reason: "danger"))
        guard case .request(let m) = sr.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "item/commandExecution/requestApproval")
        let dec = try ServerRequest.decodeDecision(.object(["decision": .string("decline")]))
        XCTAssertEqual(dec, .decline)
    }

    func testMcpElicitationServerRequestPreservesFormPayload() throws {
        let sr = ServerRequest.mcpElicitation(.int(9), .init(
            threadId: ThreadId("thr_123"),
            turnId: TurnId("turn_123"),
            serverName: "codex_apps",
            mode: "form",
            meta: .null,
            message: "Allow this request?",
            requestedSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "confirmed": .object(["type": .string("boolean")])
                ]),
                "required": .array([.string("confirmed")]),
            ])))
        guard case .request(let wire) = sr.toMessage() else {
            return XCTFail("expected server request")
        }
        XCTAssertEqual(wire.method, "mcpServer/elicitation/request")
        XCTAssertEqual(wire.params?["threadId"]?.stringValue, "thr_123")
        XCTAssertEqual(wire.params?["turnId"]?.stringValue, "turn_123")
        XCTAssertEqual(wire.params?["serverName"]?.stringValue, "codex_apps")
        XCTAssertEqual(wire.params?["mode"]?.stringValue, "form")
        XCTAssertEqual(wire.params?["_meta"], .null)
        XCTAssertEqual(wire.params?["requestedSchema"]?["properties"]?["confirmed"]?["type"]?
            .stringValue, "boolean")
        let rebuilt = ServerRequest.reconstruct(method: wire.method, id: wire.id,
                                                params: wire.params ?? .object([:]))
        guard case .mcpElicitation(_, let params)? = rebuilt else {
            return XCTFail("expected reconstructed mcp elicitation")
        }
        XCTAssertEqual(params.requestedSchema?["required"]?.arrayValue?.first?.stringValue,
                       "confirmed")
    }

    // MARK: - P2.4 / H-09 / H-10 — SandboxPolicy + AskForApproval wire shape

    /// Each `SandboxPolicy` variant must serialise as upstream's tagged
    /// enum: `{"type": "<camelCaseVariant>", ...fields}`. Field names are
    /// camelCase (`writableRoots`, `networkAccess`, `excludeTmpdirEnvVar`,
    /// `excludeSlashTmp`) to match
    /// `codex-rs/app-server-protocol/src/protocol/v2/permissions.rs`.
    func testSandboxPolicyEncodesAsTaggedEnum() throws {
        // dangerFullAccess → bare `{"type":"dangerFullAccess"}`
        let danger = try JSONBridge.value(SandboxPolicy.dangerFullAccess)
        XCTAssertEqual(danger["type"]?.stringValue, "dangerFullAccess")
        XCTAssertNil(danger["writableRoots"])
        XCTAssertNil(danger["networkAccess"])

        // readOnly → `{"type":"readOnly","networkAccess":false}`
        let ro = try JSONBridge.value(SandboxPolicy.readOnly(networkAccess: false))
        XCTAssertEqual(ro["type"]?.stringValue, "readOnly")
        XCTAssertEqual(ro["networkAccess"], .bool(false))

        let roNet = try JSONBridge.value(SandboxPolicy.readOnly(networkAccess: true))
        XCTAssertEqual(roNet["networkAccess"], .bool(true))

        // workspaceWrite → all four fields present, camelCase
        let ww = try JSONBridge.value(SandboxPolicy.workspaceWrite(
            writableRoots: ["/tmp/work", "/var/repo"],
            networkAccess: true,
            excludeTmpdirEnvVar: true,
            excludeSlashTmp: false))
        XCTAssertEqual(ww["type"]?.stringValue, "workspaceWrite")
        XCTAssertEqual(ww["writableRoots"], .array([.string("/tmp/work"),
                                                     .string("/var/repo")]))
        XCTAssertEqual(ww["networkAccess"], .bool(true))
        XCTAssertEqual(ww["excludeTmpdirEnvVar"], .bool(true))
        XCTAssertEqual(ww["excludeSlashTmp"], .bool(false))

        // externalSandbox → `networkAccess` is the kebab-style enum
        let ext = try JSONBridge.value(SandboxPolicy.externalSandbox(networkAccess: .enabled))
        XCTAssertEqual(ext["type"]?.stringValue, "externalSandbox")
        XCTAssertEqual(ext["networkAccess"]?.stringValue, "enabled")
        let ext2 = try JSONBridge.value(SandboxPolicy.externalSandbox(networkAccess: .restricted))
        XCTAssertEqual(ext2["networkAccess"]?.stringValue, "restricted")
    }

    /// Decoder must accept both the tagged-enum form (upstream) AND the
    /// legacy plain-string form Swift used to emit before this fix.
    func testSandboxPolicyDecodesTaggedAndLegacyForms() throws {
        // Legacy plain-string forms (from the previous Swift wire shape).
        for legacy in ["danger-full-access", "read-only", "workspace-write"] {
            let p = try JSONBridge.decode(SandboxPolicy.self, from: .string(legacy))
            switch (legacy, p) {
            case ("danger-full-access", .dangerFullAccess): break
            case ("read-only", .readOnly): break
            case ("workspace-write", .workspaceWrite): break
            default: XCTFail("unexpected mapping for \(legacy) -> \(p)")
            }
        }

        // Canonical upstream tagged form (camelCase tag + fields).
        let tagged: JSONValue = .object([
            "type": .string("workspaceWrite"),
            "writableRoots": .array([.string("/repo")]),
            "networkAccess": .bool(true),
            "excludeTmpdirEnvVar": .bool(false),
            "excludeSlashTmp": .bool(false),
        ])
        let policy = try JSONBridge.decode(SandboxPolicy.self, from: tagged)
        guard case .workspaceWrite(let roots, let net, _, _) = policy else {
            return XCTFail("expected workspaceWrite")
        }
        XCTAssertEqual(roots, ["/repo"])
        XCTAssertTrue(net)

        // Also accept hyphen tag values (defensive — older clients).
        let hyph: JSONValue = .object(["type": .string("read-only"),
                                       "networkAccess": .bool(true)])
        let ro = try JSONBridge.decode(SandboxPolicy.self, from: hyph)
        guard case .readOnly(let n) = ro else { return XCTFail("expected readOnly") }
        XCTAssertTrue(n)

        // externalSandbox decodes with the NetworkAccess enum string.
        let ext: JSONValue = .object(["type": .string("externalSandbox"),
                                      "networkAccess": .string("enabled")])
        let extP = try JSONBridge.decode(SandboxPolicy.self, from: ext)
        guard case .externalSandbox(let na) = extP else {
            return XCTFail("expected externalSandbox")
        }
        XCTAssertEqual(na, .enabled)

        // Round-trip: tagged-form encode → decode preserves data.
        let original = SandboxPolicy.workspaceWrite(
            writableRoots: ["/a", "/b"], networkAccess: true,
            excludeTmpdirEnvVar: true, excludeSlashTmp: true)
        let json = try JSONBridge.value(original)
        let back = try JSONBridge.decode(SandboxPolicy.self, from: json)
        XCTAssertEqual(back, original)
    }

    /// `ApprovalPolicy.unlessTrusted` must serialise as upstream's `"untrusted"`
    /// (the rename baked into Codex `AskForApproval`). Decoding accepts both
    /// `"untrusted"` (canonical) and `"unless-trusted"` (legacy Swift / older
    /// config files).
    func testAskForApprovalUsesUntrustedWireValue() throws {
        // Canonical wire emission.
        let raw = try JSONBridge.value(ApprovalPolicy.unlessTrusted)
        XCTAssertEqual(raw.stringValue, "untrusted",
                       "ApprovalPolicy.unlessTrusted must wire as upstream `untrusted`")

        // Other variants stay on the kebab values upstream emits.
        XCTAssertEqual(try JSONBridge.value(ApprovalPolicy.never).stringValue, "never")
        XCTAssertEqual(try JSONBridge.value(ApprovalPolicy.onFailure).stringValue, "on-failure")
        XCTAssertEqual(try JSONBridge.value(ApprovalPolicy.onRequest).stringValue, "on-request")

        // Decoding the canonical value round-trips.
        let decoded = try JSONBridge.decode(ApprovalPolicy.self, from: .string("untrusted"))
        XCTAssertEqual(decoded, .unlessTrusted)
    }

    /// Back-compat: existing config files / clients that still send the
    /// legacy `"unless-trusted"` value must continue to deserialise to
    /// `.unlessTrusted` rather than falling back to the default.
    func testAskForApprovalAcceptsLegacyUnlessTrusted() throws {
        let legacy = try JSONBridge.decode(ApprovalPolicy.self,
                                            from: .string("unless-trusted"))
        XCTAssertEqual(legacy, .unlessTrusted)

        // And so do the fuzzy `init(fromOptional:)` aliases.
        XCTAssertEqual(ApprovalPolicy(fromOptional: "untrusted"), .unlessTrusted)
        XCTAssertEqual(ApprovalPolicy(fromOptional: "unless-trusted"), .unlessTrusted)
        XCTAssertEqual(ApprovalPolicy(fromOptional: "unlessTrusted"), .unlessTrusted)
    }

    /// P4.1 / H-20: granular ApprovalPolicy must decode from the
    /// externally-tagged `{"granular": {<config>}}` wire form (matching
    /// upstream `AskForApproval::Granular(GranularApprovalConfig)` serde
    /// encoding). Round-tripping back to JSON must produce the same shape
    /// with snake_case field names, and the three optional booleans
    /// (`skill_approval`, `request_permissions`) must default to `false`
    /// when omitted (matching `#[serde(default)]` upstream).
    func testGranularApprovalPolicyDecodes() throws {
        // Full payload — all five fields set to varied values.
        let full: JSONValue = .object([
            "granular": .object([
                "sandbox_approval": .bool(true),
                "rules": .bool(false),
                "skill_approval": .bool(true),
                "request_permissions": .bool(false),
                "mcp_elicitations": .bool(true),
            ])
        ])
        let decoded = try JSONBridge.decode(ApprovalPolicy.self, from: full)
        guard case .granular(let cfg) = decoded else {
            return XCTFail("expected .granular variant, got \(decoded)")
        }
        XCTAssertEqual(cfg.sandboxApproval, true)
        XCTAssertEqual(cfg.rules, false)
        XCTAssertEqual(cfg.skillApproval, true)
        XCTAssertEqual(cfg.requestPermissions, false)
        XCTAssertEqual(cfg.mcpElicitations, true)

        // The `#[serde(default)]` upstream fields default to false on omit.
        let minimal: JSONValue = .object([
            "granular": .object([
                "sandbox_approval": .bool(true),
                "rules": .bool(false),
                "mcp_elicitations": .bool(true),
            ])
        ])
        let decodedMin = try JSONBridge.decode(ApprovalPolicy.self, from: minimal)
        guard case .granular(let minCfg) = decodedMin else {
            return XCTFail("expected .granular variant from minimal payload")
        }
        XCTAssertEqual(minCfg.sandboxApproval, true)
        XCTAssertEqual(minCfg.rules, false)
        XCTAssertEqual(minCfg.skillApproval, false,
                       "missing skill_approval must default to false")
        XCTAssertEqual(minCfg.requestPermissions, false,
                       "missing request_permissions must default to false")
        XCTAssertEqual(minCfg.mcpElicitations, true)

        // Round-trip: encode the decoded policy back and ensure it matches
        // the externally-tagged shape upstream emits.
        let reEncoded = try JSONBridge.value(decoded)
        guard case .object(let outer) = reEncoded,
              outer.count == 1,
              case .object(let inner)? = outer["granular"] else {
            return XCTFail("expected {\"granular\": {...}} shape, got \(reEncoded)")
        }
        XCTAssertEqual(inner["sandbox_approval"], .bool(true))
        XCTAssertEqual(inner["rules"], .bool(false))
        XCTAssertEqual(inner["skill_approval"], .bool(true))
        XCTAssertEqual(inner["request_permissions"], .bool(false))
        XCTAssertEqual(inner["mcp_elicitations"], .bool(true))

        // The discriminator `wireValue` returns `"granular"` so callers
        // embedding the policy into legacy flat-string fields still see a
        // sensible tag.
        XCTAssertEqual(decoded.wireValue, "granular")
    }

    /// P4.1 / H-21: the structured `external-sandbox` SandboxPolicy variant
    /// must round-trip through the tagged-enum wire form and the legacy
    /// plain-string form so cloud/container deployments that report
    /// `external-sandbox` keep their network setting through decode →
    /// re-encode → decode cycles.
    func testExternalSandboxPolicyRendersCorrectly() throws {
        // Tagged form: networkAccess="enabled".
        let tagged: JSONValue = .object([
            "type": .string("externalSandbox"),
            "networkAccess": .string("enabled"),
        ])
        let decoded = try JSONBridge.decode(SandboxPolicy.self, from: tagged)
        guard case .externalSandbox(let net) = decoded else {
            return XCTFail("expected .externalSandbox, got \(decoded)")
        }
        XCTAssertEqual(net, .enabled)
        // Round-trip preserves the variant + network access.
        let reEncoded = try JSONBridge.value(decoded)
        let back = try JSONBridge.decode(SandboxPolicy.self, from: reEncoded)
        XCTAssertEqual(back, decoded)
        // The legacy `modeKind` projection collapses external-sandbox to
        // `dangerFullAccess` for callers stuck on the flat string surface.
        XCTAssertEqual(decoded.modeKind, .dangerFullAccess)

        // Legacy plain-string decode path: `"external-sandbox"` resolves to
        // `.externalSandbox(.restricted)` (the default network setting).
        let legacy = try JSONBridge.decode(SandboxPolicy.self,
                                           from: .string("external-sandbox"))
        guard case .externalSandbox(let legacyNet) = legacy else {
            return XCTFail("expected .externalSandbox from legacy string")
        }
        XCTAssertEqual(legacyNet, .restricted,
                       "legacy plain-string decode defaults network_access to restricted")
    }

    // MARK: - P3.4 / H-17 / H-18: plan + request_user_input + request_permissions

    /// Plan update wire shape: `{threadId, turnId, plan: [{step, status}],
    /// explanation?}`. Snake-case `in_progress` from upstream `StepStatus`.
    func testPlanUpdateNotificationCarriesUpstreamFields() throws {
        let plan: [PlanItemArg] = [
            PlanItemArg(step: "draft", status: .inProgress),
            PlanItemArg(step: "ship", status: .pending),
        ]
        let n = ServerNotification.planUpdate(
            threadId: ThreadId("thr_p"),
            turnId: TurnId("turn_p"),
            explanation: "do work",
            plan: plan)
        guard case .notification(let msg) = n.toMessage() else {
            return XCTFail("expected notification frame")
        }
        XCTAssertEqual(msg.method, "item/plan/updated")
        XCTAssertEqual(msg.params?["threadId"]?.stringValue, "thr_p")
        XCTAssertEqual(msg.params?["turnId"]?.stringValue, "turn_p")
        XCTAssertEqual(msg.params?["explanation"]?.stringValue, "do work")
        guard case .array(let items)? = msg.params?["plan"] else {
            return XCTFail("plan should serialise as a JSON array")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["step"]?.stringValue, "draft")
        XCTAssertEqual(items[0]["status"]?.stringValue, "in_progress")
        XCTAssertEqual(items[1]["status"]?.stringValue, "pending")

        let bare = ServerNotification.planUpdate(
            threadId: ThreadId("thr_p"), turnId: TurnId("turn_p"),
            explanation: nil, plan: [])
        guard case .notification(let bm) = bare.toMessage() else { return XCTFail() }
        XCTAssertNil(bm.params?["explanation"],
                     "explanation must be omitted when nil")
    }

    /// request_user_input wire shape mirrors upstream `RequestUserInputEvent`
    /// plus a `threadId` envelope: `{threadId, turnId, callId, questions: [...]}`.
    func testRequestUserInputNotificationCarriesUpstreamFields() throws {
        let q = RequestUserInputQuestion(
            id: "db_password",
            header: "DB pwd",
            question: "What is the database password?",
            isOther: true, isSecret: true,
            options: [RequestUserInputQuestionOption(
                label: "Use stored", description: "from keychain")])
        let n = ServerNotification.requestUserInput(
            threadId: ThreadId("thr_u"),
            turnId: TurnId("turn_u"),
            callId: "rui_1",
            questions: [q])
        guard case .notification(let msg) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(msg.method, "item/requestUserInput")
        XCTAssertEqual(msg.params?["threadId"]?.stringValue, "thr_u")
        XCTAssertEqual(msg.params?["turnId"]?.stringValue, "turn_u")
        XCTAssertEqual(msg.params?["callId"]?.stringValue, "rui_1")
        guard case .array(let qs)? = msg.params?["questions"] else {
            return XCTFail("questions should be an array")
        }
        XCTAssertEqual(qs.count, 1)
        XCTAssertEqual(qs[0]["id"]?.stringValue, "db_password")
        if case .bool(let v)? = qs[0]["isOther"] { XCTAssertTrue(v) }
        else { XCTFail("isOther should be a boolean") }
        if case .bool(let v)? = qs[0]["isSecret"] { XCTAssertTrue(v) }
        else { XCTFail("isSecret should be a boolean") }
    }

    /// request_permissions wire shape mirrors upstream
    /// `RequestPermissionsEvent`: `{threadId, turnId, callId, reason?,
    /// permissions: {network?, file_system?}}`.
    func testRequestPermissionsNotificationCarriesUpstreamFields() throws {
        let n = ServerNotification.requestPermissions(
            threadId: ThreadId("thr_r"),
            turnId: TurnId("turn_r"),
            callId: "rp_1",
            reason: "fetch deps",
            permissions: RequestPermissionProfile(
                network: NetworkPermissions(enabled: true),
                fileSystem: FileSystemPermissions(read: ["/tmp/x"], write: nil)))
        guard case .notification(let msg) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(msg.method, "item/requestPermissions")
        XCTAssertEqual(msg.params?["threadId"]?.stringValue, "thr_r")
        XCTAssertEqual(msg.params?["callId"]?.stringValue, "rp_1")
        XCTAssertEqual(msg.params?["reason"]?.stringValue, "fetch deps")
        XCTAssertEqual(msg.params?["permissions"]?["network"]?["enabled"],
                       .bool(true))
        guard case .array(let reads)? = msg.params?["permissions"]?["file_system"]?["read"] else {
            return XCTFail("expected file_system.read array")
        }
        XCTAssertEqual(reads.first?.stringValue, "/tmp/x")

        let bare = ServerNotification.requestPermissions(
            threadId: ThreadId("thr_r"), turnId: TurnId("turn_r"),
            callId: "rp_2", reason: nil,
            permissions: RequestPermissionProfile(
                network: NetworkPermissions(enabled: true)))
        guard case .notification(let bm) = bare.toMessage() else { return XCTFail() }
        XCTAssertNil(bm.params?["reason"], "reason omitted when nil")
    }

    /// Round-trip the typed `RequestPermissionsResponse` so the host can hand
    /// the JSON back to the tool unchanged. Snake-case wire field
    /// `strict_auto_review` (upstream Rust) decodes correctly.
    func testRequestPermissionsResponseRoundTrip() throws {
        let json = #"{"permissions":{"network":{"enabled":true}},"scope":"session","strict_auto_review":true}"#
        let decoded = try JSONDecoder().decode(
            RequestPermissionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.scope, .session)
        XCTAssertTrue(decoded.strictAutoReview)
        XCTAssertEqual(decoded.permissions.network?.enabled, true)
        let encoded = try JSONEncoder().encode(decoded)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(obj["scope"] as? String, "session")
        XCTAssertEqual(obj["strict_auto_review"] as? Bool, true)
    }

    /// Upstream `RequestPermissionsResponse.strict_auto_review` is annotated
    /// `#[serde(default, skip_serializing_if = "std::ops::Not::not")]` — the
    /// key MUST be omitted from the wire JSON when `false`, and present (and
    /// `true`) when `true`. Asserts wire-compatibility with codex-rs clients
    /// that may treat absence as the default.
    func testRequestPermissionsResponseOmitsStrictAutoReviewWhenFalse() throws {
        // False → key absent.
        let respFalse = RequestPermissionsResponse(
            permissions: RequestPermissionProfile(
                network: NetworkPermissions(enabled: true)),
            scope: .turn,
            strictAutoReview: false)
        let dataFalse = try JSONEncoder().encode(respFalse)
        let objFalse = try XCTUnwrap(
            JSONSerialization.jsonObject(with: dataFalse) as? [String: Any])
        XCTAssertNil(objFalse["strict_auto_review"],
                     "strict_auto_review must be omitted when false")
        XCTAssertEqual(objFalse["scope"] as? String, "turn")
        XCTAssertNotNil(objFalse["permissions"])

        // True → key present with value true.
        let respTrue = RequestPermissionsResponse(
            permissions: RequestPermissionProfile(
                network: NetworkPermissions(enabled: true)),
            scope: .turn,
            strictAutoReview: true)
        let dataTrue = try JSONEncoder().encode(respTrue)
        let objTrue = try XCTUnwrap(
            JSONSerialization.jsonObject(with: dataTrue) as? [String: Any])
        XCTAssertEqual(objTrue["strict_auto_review"] as? Bool, true,
                       "strict_auto_review must be present and true when true")
    }

    /// P2.2 / H-07: `thread/tokenUsage/updated` must carry the full 5-field
    /// breakdown (`inputTokens`, `cachedInputTokens`, `outputTokens`,
    /// `reasoningOutputTokens`, `totalTokens`) for BOTH `total` and `last`
    /// buckets, plus `modelContextWindow`. Parity with upstream
    /// `ThreadTokenUsageUpdatedNotification`. Swift previously emitted only
    /// `{ totalTokens }` per bucket and stripped the context window.
    func testThreadTokenUsageUpdatedFullBreakdown() throws {
        let total = TokenUsageBucket(inputTokens: 1_500,
                                     cachedInputTokens: 200,
                                     outputTokens: 300,
                                     reasoningOutputTokens: 50,
                                     totalTokens: 2_050)
        let last = TokenUsageBucket(inputTokens: 800,
                                    cachedInputTokens: 100,
                                    outputTokens: 150,
                                    reasoningOutputTokens: 25,
                                    totalTokens: 1_075)
        let notif: ServerNotification = .tokenUsageUpdated(
            threadId: ThreadId("thr_full"), turnId: TurnId("turn_full"),
            total: total, last: last, modelContextWindow: 128_000)
        let msg = notif.toMessage()
        guard case .notification(let n) = msg else {
            return XCTFail("expected notification, got \(msg)")
        }
        XCTAssertEqual(n.method, "thread/tokenUsage/updated")
        // Round-trip the params through `JSONValue` → `Data` → `Any` to
        // assert the on-wire shape (field names + presence of every
        // per-category field for both buckets + mcw).
        let data = try JSONEncoder().encode(n.params)
        let usage = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokenUsage"]
                as? [String: Any])
        XCTAssertEqual(usage["modelContextWindow"] as? Int, 128_000,
                       "P2.2 / H-07: modelContextWindow must be present")
        let totalDict = try XCTUnwrap(usage["total"] as? [String: Any])
        XCTAssertEqual(totalDict["inputTokens"]           as? Int, 1_500)
        XCTAssertEqual(totalDict["cachedInputTokens"]     as? Int, 200)
        XCTAssertEqual(totalDict["outputTokens"]          as? Int, 300)
        XCTAssertEqual(totalDict["reasoningOutputTokens"] as? Int, 50)
        XCTAssertEqual(totalDict["totalTokens"]           as? Int, 2_050)
        let lastDict = try XCTUnwrap(usage["last"] as? [String: Any])
        XCTAssertEqual(lastDict["inputTokens"]           as? Int, 800)
        XCTAssertEqual(lastDict["cachedInputTokens"]     as? Int, 100)
        XCTAssertEqual(lastDict["outputTokens"]          as? Int, 150)
        XCTAssertEqual(lastDict["reasoningOutputTokens"] as? Int, 25)
        XCTAssertEqual(lastDict["totalTokens"]           as? Int, 1_075)
    }
}
