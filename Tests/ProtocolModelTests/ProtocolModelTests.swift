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
            "clientInfo": .object(["name": .string("codex_vscode"),
                                   "version": .string("1.2.3")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ])
        guard case .initialize(_, let p) = try ClientRequest.parse(req("initialize", initJSON)) else {
            return XCTFail("expected initialize")
        }
        XCTAssertEqual(p.clientInfo.name, "codex_vscode")
        XCTAssertEqual(p.clientInfo.version, "1.2.3")   // present version decodes
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

    /// Custom review target: upstream `review_prompt` (review_prompts.rs:88-94)
    /// trims the instructions and bails on an empty/whitespace-only result.
    func testCustomReviewTrimsAndRejectsEmpty() throws {
        func review(_ instr: String?) throws -> ReviewStartParams {
            var obj: [String: JSONValue] = ["type": .string("custom")]
            if let instr { obj["instructions"] = .string(instr) }
            let params: JSONValue = .object([
                "threadId": .string("t"),
                "target": .object(obj),
            ])
            guard case .reviewStart(_, let r) = try ClientRequest.parse(req("review/start", params)) else {
                throw XCTSkip("expected reviewStart")
            }
            return r
        }

        // Leading/trailing whitespace is trimmed from the rendered prompt.
        let padded = try review("  Find logic bugs.\n")
        XCTAssertEqual(padded.reviewPrompt(mergeBaseSha: nil), "Find logic bugs.")
        XCTAssertEqual(padded.reviewInput, [TurnInput(text: "Find logic bugs.")])
        XCTAssertFalse(padded.customReviewIsEmpty)

        // Whitespace-only and missing instructions are flagged empty.
        XCTAssertTrue(try review("   \n\t ").customReviewIsEmpty)
        XCTAssertTrue(try review("").customReviewIsEmpty)
        XCTAssertTrue(try review(nil).customReviewIsEmpty)

        // customReviewIsEmpty does not fire for non-custom targets.
        let base: JSONValue = .object([
            "threadId": .string("t"),
            "target": .object(["type": .string("uncommittedChanges")]),
        ])
        guard case .reviewStart(_, let unc) = try ClientRequest.parse(req("review/start", base)) else {
            return XCTFail("expected reviewStart")
        }
        XCTAssertFalse(unc.customReviewIsEmpty)
    }

    /// prompts finding D: `ReviewStartParams.userFacingHint` ports upstream
    /// `review_prompts::user_facing_hint` (core/src/review_prompts.rs:107-121),
    /// used as the `EnteredReviewMode.review` label
    /// (bespoke_event_handling.rs:944-951).
    func testReviewUserFacingHintPerTarget() throws {
        func hint(_ target: JSONValue) throws -> String {
            let params: JSONValue = .object([
                "threadId": .string("t"), "target": target,
            ])
            guard case .reviewStart(_, let r) =
                try ClientRequest.parse(req("review/start", params)) else {
                throw XCTSkip("expected reviewStart")
            }
            return r.userFacingHint
        }

        // UncommittedChanges → "current changes".
        XCTAssertEqual(try hint(.object(["type": .string("uncommittedChanges")])),
                       "current changes")
        // Missing target type also degrades to "current changes".
        XCTAssertEqual(try hint(.object([:])), "current changes")
        // BaseBranch → "changes against '<branch>'".
        XCTAssertEqual(try hint(.object([
            "type": .string("baseBranch"), "branch": .string("main"),
        ])), "changes against 'main'")
        // Commit without title → "commit <7-char-sha>".
        XCTAssertEqual(try hint(.object([
            "type": .string("commit"),
            "sha": .string("abcdef0123456789"),
        ])), "commit abcdef0")
        // Commit with title → "commit <7-char-sha>: <title>".
        XCTAssertEqual(try hint(.object([
            "type": .string("commit"),
            "sha": .string("abcdef0123456789"),
            "title": .string("fix bug"),
        ])), "commit abcdef0: fix bug")
        // Short sha (< 7 chars) is taken verbatim.
        XCTAssertEqual(try hint(.object([
            "type": .string("commit"), "sha": .string("abc"),
        ])), "commit abc")
        // Custom → trimmed instructions.
        XCTAssertEqual(try hint(.object([
            "type": .string("custom"),
            "instructions": .string("  Find logic bugs.\n"),
        ])), "Find logic bugs.")
    }

    /// Base-branch review prompt: mirrors upstream `review_prompt` for
    /// `ReviewTarget::BaseBranch` (core/src/review_prompts.rs). When the host
    /// resolves a merge-base SHA, the PRIMARY `BASE_BRANCH_PROMPT` is rendered
    /// with `{{base_branch}}` and `{{merge_base_sha}}` substituted; otherwise
    /// the BACKUP form (model computes the merge base itself) is used.
    func testReviewStartBaseBranchPromptVariants() throws {
        let params: JSONValue = .object([
            "threadId": .string("thr_review"),
            "target": .object([
                "type": .string("baseBranch"),
                "branch": .string("main"),
            ]),
        ])
        guard case .reviewStart(_, let review) = try ClientRequest.parse(req("review/start", params)) else {
            return XCTFail("expected reviewStart")
        }
        XCTAssertEqual(review.baseBranchTarget, "main")
        // Primary variant (merge base resolved) — byte-exact with upstream.
        XCTAssertEqual(
            review.reviewPrompt(mergeBaseSha: "abc123"),
            "Review the code changes against the base branch 'main'. The merge base commit for this comparison is abc123. Run `git diff abc123` to inspect the changes relative to main. Provide prioritized, actionable findings.")
        // Backup variant (no merge base) — used when git resolution fails.
        XCTAssertEqual(
            review.reviewPrompt(mergeBaseSha: nil),
            "Review the code changes against the base branch 'main'. Start by finding the merge diff between the current branch and main's upstream e.g. (`git merge-base HEAD \"$(git rev-parse --abbrev-ref \"main@{upstream}\")\"`), then run `git diff` against that SHA to see what changes we would merge into the main branch. Provide prioritized, actionable findings.")
        // Empty SHA also falls back to the backup form.
        XCTAssertEqual(review.reviewPrompt(mergeBaseSha: ""), review.reviewPrompt(mergeBaseSha: nil))
        // Synchronous default (`resolvedReviewPrompt`) uses the backup form.
        XCTAssertEqual(review.resolvedReviewPrompt, review.reviewPrompt(mergeBaseSha: nil))
    }

    /// `baseBranchTarget` only fires for base-branch targets; other targets
    /// return nil so the router leaves them on the synchronous path.
    func testReviewBaseBranchTargetGuard() throws {
        for t in ["custom", "commit", "uncommittedChanges"] {
            let params: JSONValue = .object([
                "threadId": .string("t"),
                "target": .object(["type": .string(t), "instructions": .string("x"),
                                    "sha": .string("deadbeef")]),
            ])
            guard case .reviewStart(_, let review) = try ClientRequest.parse(req("review/start", params)) else {
                return XCTFail("expected reviewStart")
            }
            XCTAssertNil(review.baseBranchTarget, "non-baseBranch target \(t) must not resolve a branch")
        }
    }

    func testThreadItemRoundTrip() throws {
        let items: [ThreadItem] = [
            .userMessage(id: ItemId("u1"), content: [UserMessageContent(text: "hello")]),
            .agentMessage(id: ItemId("a1"), text: "hi there"),
            // Upstream `command` is a single shlex-joined string on the wire,
            // so the internal `[String]` round-trips as a single joined element.
            .commandExecution(id: ItemId("c1"), command: ["ls -la"], cwd: "/tmp",
                              status: .completed, commandActions: [], aggregatedOutput: "out", exitCode: 0),
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

    /// protocol-wire-types: upstream `UserInput::Text` carries
    /// `text_elements: Vec<TextElement>` with `#[serde(default)]` and NO
    /// `skip_serializing_if`, so a text user input ALWAYS serializes
    /// `"text_elements": []` (snake_case wire key per the generated TS
    /// binding). Image / localImage variants omit the field.
    func testUserMessageTextElementsAlwaysEmittedOnText() throws {
        // Empty text input → `"text_elements": []` present.
        let item: ThreadItem = .userMessage(
            id: ItemId("u1"), content: [UserMessageContent(text: "hello")])
        let data = try JSONEncoder().encode(item)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (obj?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["type"] as? String, "text")
        XCTAssertEqual(content?["text"] as? String, "hello")
        XCTAssertNotNil(content?["text_elements"], "text variant must always emit text_elements")
        XCTAssertEqual((content?["text_elements"] as? [Any])?.count, 0)
        // camelCase `textElements` must NOT be present — wire key is snake_case.
        XCTAssertNil(content?["textElements"])

        // Image variant must NOT carry text_elements.
        var img = UserMessageContent(text: "")
        img.type = "image"; img.text = nil; img.url = "https://example.com/a.png"
        let imgData = try JSONEncoder().encode(
            ThreadItem.userMessage(id: ItemId("u2"), content: [img]))
        let imgObj = try JSONSerialization.jsonObject(with: imgData) as? [String: Any]
        let imgContent = (imgObj?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(imgContent?["type"] as? String, "image")
        XCTAssertNil(imgContent?["text_elements"], "image variant must omit text_elements")
    }

    /// A populated `textElements` round-trips, and `placeholder` is always
    /// serialized (`null` when absent) matching upstream `TextElement`.
    func testTextElementRoundTripAndPlaceholderAlwaysEmitted() throws {
        var c = UserMessageContent(text: "@file")
        c.textElements = [
            TextElement(byteRange: ByteRange(start: 0, end: 5), placeholder: "file.txt"),
            TextElement(byteRange: ByteRange(start: 5, end: 5)),
        ]
        let item: ThreadItem = .userMessage(id: ItemId("u3"), content: [c])
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(ThreadItem.self, from: data)
        XCTAssertEqual(back, item)

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let els = ((obj?["content"] as? [[String: Any]])?.first?["text_elements"]) as? [[String: Any]]
        XCTAssertEqual(els?.count, 2)
        XCTAssertEqual((els?[0]["byteRange"] as? [String: Any])?["start"] as? Int, 0)
        XCTAssertEqual(els?[0]["placeholder"] as? String, "file.txt")
        // `placeholder` is always present, explicit null when absent.
        XCTAssertTrue(els?[1].keys.contains("placeholder") ?? false,
                      "placeholder always serialized (null when absent)")
        XCTAssertTrue(els?[1]["placeholder"] is NSNull)
    }

    /// Legacy payloads without `textElements` decode tolerantly to `[]`.
    func testUserMessageDecodesLegacyWithoutTextElements() throws {
        let json = #"{"type":"userMessage","id":"u9","content":[{"type":"text","text":"hi"}]}"#
        let item = try JSONDecoder().decode(ThreadItem.self, from: Data(json.utf8))
        guard case .userMessage(_, let content) = item else { return XCTFail("expected userMessage") }
        XCTAssertEqual(content.first?.textElements, [])
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
    /// `codex-rs/tools/src/tool_spec.rs`). The exact payload shapes are
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
            // P2.5 sweep follow-up — the remaining unmodeled variants.
            // NOTE: `collabAgentToolCall` is now a MODELED ThreadItem variant
            // (v9 app-server-events finding 4), so it is no longer a tolerant
            // `.unknown` fallback and is covered by AppServerEventsTests instead.
            // 2. imageView — agent-emitted image attachment for viewing.
            #"{"type":"imageView","id":"h","url":"https://example.com/x.png"}"#,
            // 3. imageGeneration — upstream `ImageGeneration` tool item.
            #"""
            {"type":"imageGeneration","id":"i","status":"completed",\#
            "outputFormat":"png","revisedPrompt":"a red sphere"}
            """#,
            // NOTE: `enteredReviewMode` / `exitedReviewMode` are now MODELED
            // ThreadItem variants (prompts finding 1), so they are no longer
            // tolerant `.unknown` fallbacks and are covered by their own
            // field-level parity test below.
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

    /// prompts finding 1: `enteredReviewMode` / `exitedReviewMode` are typed
    /// v2 `ThreadItem` variants (app-server-protocol/v2/item.rs:355-358), each
    /// `#[serde(tag = "type", rename_all = "camelCase")]` carrying a required
    /// `review` string. Verify field-level encode/decode parity (camelCase
    /// discriminator + `review` field) and round-trip.
    func testReviewModeLifecycleItemsRoundTrip() throws {
        let entered = ThreadItem.enteredReviewMode(id: ItemId("j"),
                                                   review: "Review requested.")
        let exited = ThreadItem.exitedReviewMode(id: ItemId("k"),
                                                 review: "looks good")
        let enc = JSONEncoder()
        let dec = JSONDecoder()

        // Decode upstream-shaped wire payloads.
        let enteredItem = try dec.decode(
            ThreadItem.self,
            from: #"{"type":"enteredReviewMode","id":"j","review":"Review requested."}"#
                .data(using: .utf8)!)
        guard case .enteredReviewMode(let eid, let ereview) = enteredItem else {
            return XCTFail("expected enteredReviewMode")
        }
        XCTAssertEqual(eid.raw, "j")
        XCTAssertEqual(ereview, "Review requested.")

        let exitedItem = try dec.decode(
            ThreadItem.self,
            from: #"{"type":"exitedReviewMode","id":"k","review":"looks good"}"#
                .data(using: .utf8)!)
        guard case .exitedReviewMode(let xid, let xreview) = exitedItem else {
            return XCTFail("expected exitedReviewMode")
        }
        XCTAssertEqual(xid.raw, "k")
        XCTAssertEqual(xreview, "looks good")

        // Encode emits the camelCase discriminator + `review` field, and
        // re-decodes to an equal value.
        for item in [entered, exited] {
            let data = try enc.encode(item)
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(obj["type"] as? String, item.typeName)
            XCTAssertNotNil(obj["review"] as? String)
            XCTAssertNotNil(obj["id"])
            let round = try dec.decode(ThreadItem.self, from: data)
            XCTAssertEqual(round, item)
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

    /// Upstream `TerminalInteractionNotification`
    /// (app-server-protocol/v2/item.rs:1212): method
    /// `item/commandExecution/terminalInteraction`, all five required camelCase
    /// fields, no omission.
    func testTerminalInteractionWireShape() throws {
        let n = ServerNotification.terminalInteraction(
            threadId: ThreadId("thr_1"), turnId: TurnId("turn_1"),
            itemId: ItemId("item_1"), processId: "42", stdin: "ls\n")
        guard case .notification(let m) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "item/commandExecution/terminalInteraction")
        XCTAssertEqual(m.params?["threadId"]?.stringValue, "thr_1")
        XCTAssertEqual(m.params?["turnId"]?.stringValue, "turn_1")
        XCTAssertEqual(m.params?["itemId"]?.stringValue, "item_1")
        XCTAssertEqual(m.params?["processId"]?.stringValue, "42")
        XCTAssertEqual(m.params?["stdin"]?.stringValue, "ls\n")
    }

    /// Upstream `FileChangePatchUpdatedNotification`
    /// (app-server-protocol/v2/item.rs:1246): method `item/fileChange/patchUpdated`.
    /// `changes` carries the `FileUpdateChange` shape with the internally-tagged
    /// `kind` object (`{type:"update", move_path?}`), NOT a bare string. The
    /// `move_path` field stays snake_case because serde's enum-level
    /// `rename_all = "camelCase"` renames variant NAMES, not struct-variant
    /// FIELDS (generated TS binding: `{ "type": "update", move_path: ... }`).
    func testFileChangePatchUpdatedWireShape() throws {
        let n = ServerNotification.fileChangePatchUpdated(
            threadId: ThreadId("thr_1"), turnId: TurnId("turn_1"),
            itemId: ItemId("item_1"),
            changes: [
                .init(path: "a.txt", kind: .add, diff: "+hello"),
                .init(path: "b.txt", kind: .update(movePath: "c.txt"), diff: "@@ ..."),
                .init(path: "d.txt", kind: .delete, diff: "-bye"),
            ])
        guard case .notification(let m) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "item/fileChange/patchUpdated")
        let changes = m.params?["changes"]?.arrayValue
        XCTAssertEqual(changes?.count, 3)
        XCTAssertEqual(changes?[0]["path"]?.stringValue, "a.txt")
        XCTAssertEqual(changes?[0]["kind"]?["type"]?.stringValue, "add")
        XCTAssertEqual(changes?[0]["diff"]?.stringValue, "+hello")
        XCTAssertEqual(changes?[1]["kind"]?["type"]?.stringValue, "update")
        XCTAssertEqual(changes?[1]["kind"]?["move_path"]?.stringValue, "c.txt")
        // camelCase `movePath` must NOT be present — wire key is snake_case.
        XCTAssertNil(changes?[1]["kind"]?["movePath"])
        XCTAssertEqual(changes?[2]["kind"]?["type"]?.stringValue, "delete")
        // delete kind carries no move_path
        XCTAssertNil(changes?[2]["kind"]?["move_path"])
    }

    /// Upstream `PatchChangeKind::Update { move_path: Option<PathBuf> }`
    /// (app-server-protocol/v2/item.rs:931) has NO `#[serde(skip_serializing_if)]`,
    /// so a rename-less update serialises `move_path` as JSON `null` — the key is
    /// PRESENT, not omitted. (A bare `encodeIfPresent` would drop it and break
    /// byte-fidelity.) The wire key is snake_case `move_path` (serde struct-
    /// variant fields are NOT renamed by enum-level `rename_all`).
    func testFileChangeUpdateWithoutRenameEmitsMovePathNull() throws {
        let n = ServerNotification.fileChangePatchUpdated(
            threadId: ThreadId("thr_1"), turnId: TurnId("turn_1"),
            itemId: ItemId("item_1"),
            changes: [.init(path: "x.txt", kind: .update(movePath: nil), diff: "@@")])
        guard case .notification(let m) = n.toMessage() else { return XCTFail() }
        let kind = m.params?["changes"]?.arrayValue?[0]["kind"]
        XCTAssertEqual(kind?["type"]?.stringValue, "update")
        // Key present AND null — not omitted.
        XCTAssertNotNil(kind?["move_path"], "move_path key must be present (serde has no skip)")
        XCTAssertTrue(kind?["move_path"]?.isNull ?? false,
                      "rename-less update must emit move_path: null, got \(String(describing: kind?["move_path"]))")
        // camelCase `movePath` must NOT be present.
        XCTAssertNil(kind?["movePath"])
    }

    /// protocol-wire-types: a `FileChange` whose `kind` arrives in the
    /// upstream-shaped snake_case `move_path` form must DECODE correctly
    /// (the previous camelCase `movePath` mapping silently dropped the
    /// rename target). Also verifies the legacy camelCase form is no longer
    /// honored, matching upstream exactly.
    func testFileChangeDecodesUpstreamSnakeCaseMovePath() throws {
        let json = Data(#"""
        {"type":"fileChange","id":"f1","status":"completed","changes":[
          {"path":"b.txt","kind":{"type":"update","move_path":"c.txt"},"diff":"@@"}
        ]}
        """#.utf8)
        let item = try JSONDecoder().decode(ThreadItem.self, from: json)
        guard case .fileChange(_, let changes, _) = item else {
            return XCTFail("expected fileChange")
        }
        XCTAssertEqual(changes.first?.kind, .update(movePath: "c.txt"))

        // Re-encode round-trips to the same snake_case wire key.
        let back = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(item)) as? [String: Any]
        let kind = ((back?["changes"] as? [[String: Any]])?.first?["kind"]) as? [String: Any]
        XCTAssertEqual(kind?["move_path"] as? String, "c.txt")
        XCTAssertNil(kind?["movePath"])
    }

    /// protocol-wire-types: `TurnInput` (mirror of upstream `UserInput`) must
    /// round-trip image `detail` (image / localImage variants) and text
    /// `textElements` (text variant). Previously both were silently dropped.
    func testTurnInputRoundTripsDetailAndTextElements() throws {
        // Image variant carries `detail` (snake_case enum: high / original).
        let imgJSON = Data(#"""
        {"type":"image","url":"https://example.com/a.png","detail":"original"}
        """#.utf8)
        let img = try JSONDecoder().decode(TurnInput.self, from: imgJSON)
        XCTAssertEqual(img.detail, .original)
        XCTAssertEqual(img.url, "https://example.com/a.png")
        let imgOut = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(img)) as? [String: Any]
        XCTAssertEqual(imgOut?["detail"] as? String, "original")
        // image variant must NOT emit textElements.
        XCTAssertNil(imgOut?["textElements"])

        // localImage variant likewise carries `detail`.
        let localJSON = Data(#"""
        {"type":"localImage","path":"/tmp/a.png","detail":"high"}
        """#.utf8)
        let local = try JSONDecoder().decode(TurnInput.self, from: localJSON)
        XCTAssertEqual(local.detail, .high)

        // Text variant carries `text_elements` (snake_case wire key); `detail`
        // must be omitted.
        let textJSON = Data(#"""
        {"type":"text","text":"@file","text_elements":[
          {"byteRange":{"start":0,"end":5},"placeholder":"file.txt"}
        ]}
        """#.utf8)
        let txt = try JSONDecoder().decode(TurnInput.self, from: textJSON)
        XCTAssertEqual(txt.textElements.count, 1)
        XCTAssertEqual(txt.textElements.first?.placeholder, "file.txt")
        XCTAssertNil(txt.detail)
        let txtOut = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(txt)) as? [String: Any]
        XCTAssertNotNil(txtOut?["text_elements"])
        XCTAssertNil(txtOut?["textElements"], "wire key is snake_case text_elements")
        XCTAssertNil(txtOut?["detail"], "text variant must omit detail")
    }

    /// protocol-wire-types: `detail` on a `UserMessageContent` image variant
    /// is emitted only for image/localImage and round-trips. Absent `detail`
    /// is omitted (`#[ts(optional)]`), not emitted as null.
    func testUserMessageContentImageDetailWireShape() throws {
        var img = UserMessageContent(text: "")
        img.type = "image"; img.text = nil
        img.url = "https://example.com/a.png"; img.detail = .high
        let item: ThreadItem = .userMessage(id: ItemId("u1"), content: [img])
        let back = try JSONDecoder().decode(
            ThreadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)

        let obj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(item)) as? [String: Any]
        let content = (obj?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["detail"] as? String, "high")

        // Image variant with no detail omits the key (not null).
        var img2 = UserMessageContent(text: "")
        img2.type = "image"; img2.text = nil; img2.url = "https://x/y.png"
        let obj2 = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                ThreadItem.userMessage(id: ItemId("u2"), content: [img2]))) as? [String: Any]
        let content2 = (obj2?["content"] as? [[String: Any]])?.first
        XCTAssertNil(content2?["detail"], "absent detail must be omitted")
    }

    /// Upstream `GuardianWarningNotification`
    /// (app-server-protocol/v2/notification.rs:31-36, common.rs:1510): method
    /// `guardianWarning`, payload `{threadId, message}` — both required (no
    /// `skip_serializing_if`), so both are always present on the wire.
    func testGuardianWarningWireShape() throws {
        let n = ServerNotification.guardianWarning(
            threadId: ThreadId("thr_g"), message: "blocked by guardian")
        XCTAssertEqual(n.method, "guardianWarning")
        guard case .notification(let m) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "guardianWarning")
        XCTAssertEqual(m.params?["threadId"]?.stringValue, "thr_g")
        XCTAssertEqual(m.params?["message"]?.stringValue, "blocked by guardian")
        // Exactly the two upstream keys, nothing more.
        XCTAssertEqual(m.params?.objectValue?.keys.sorted(), ["message", "threadId"])
    }

    /// Upstream `ThreadItem::AgentMessage` (app-server-protocol/v2/item.rs:223-231)
    /// declares `phase` / `memory_citation` as `#[serde(default)]` with NO
    /// `skip_serializing_if`, so serde always serializes both — as `null` when
    /// absent. The Swift encoder must emit `"phase": null` and
    /// `"memoryCitation": null` (key PRESENT, not omitted) for byte-fidelity.
    func testAgentMessageEmitsPhaseAndMemoryCitationNull() throws {
        let item = ThreadItem.agentMessage(id: ItemId("a1"), text: "hi")
        let data = try JSONEncoder().encode(item)
        let obj = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(obj["type"]?.stringValue, "agentMessage")
        XCTAssertEqual(obj["text"]?.stringValue, "hi")
        XCTAssertNotNil(obj["phase"], "phase key must be present (serde has no skip)")
        XCTAssertTrue(obj["phase"]?.isNull ?? false, "phase must serialize as null")
        XCTAssertNotNil(obj["memoryCitation"],
                        "memoryCitation key must be present (serde has no skip)")
        XCTAssertTrue(obj["memoryCitation"]?.isNull ?? false,
                      "memoryCitation must serialize as null")
    }

    /// A frontend may send `phase` / `memoryCitation` (upstream always does);
    /// the decoder tolerates them and round-trips the modeled `(id, text)`.
    func testAgentMessageDecodeToleratesPhaseAndMemoryCitation() throws {
        let json = Data("""
        {"type":"agentMessage","id":"a1","text":"hi",
         "phase":"final_answer",
         "memoryCitation":{"entries":[{"path":"x.md","lineStart":1,"lineEnd":2,"note":"n"}],
                           "threadIds":["t1"]}}
        """.utf8)
        let item = try JSONDecoder().decode(ThreadItem.self, from: json)
        guard case .agentMessage(let id, let text) = item else {
            return XCTFail("expected agentMessage, got \(item)")
        }
        XCTAssertEqual(id, ItemId("a1"))
        XCTAssertEqual(text, "hi")
    }

    /// `MessagePhase` uses snake_case wire values
    /// (codex-protocol/src/models.rs:740-748): `commentary` / `final_answer`.
    func testMessagePhaseWireValues() throws {
        XCTAssertEqual(try JSONEncoder().encode(MessagePhase.commentary),
                       Data("\"commentary\"".utf8))
        XCTAssertEqual(try JSONEncoder().encode(MessagePhase.finalAnswer),
                       Data("\"final_answer\"".utf8))
        XCTAssertEqual(
            try JSONDecoder().decode(MessagePhase.self, from: Data("\"final_answer\"".utf8)),
            .finalAnswer)
    }

    /// `MemoryCitation` round-trips with camelCase keys
    /// (app-server-protocol/v2/item.rs:125-149): `{entries:[{path,lineStart,
    /// lineEnd,note}], threadIds}`.
    func testMemoryCitationWireShape() throws {
        let mc = MemoryCitation(
            entries: [.init(path: "a.md", lineStart: 3, lineEnd: 7, note: "see")],
            threadIds: ["t1", "t2"])
        let data = try JSONEncoder().encode(mc)
        let obj = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(obj["threadIds"]?.arrayValue?.compactMap { $0.stringValue },
                       ["t1", "t2"])
        let e0 = obj["entries"]?.arrayValue?[0]
        XCTAssertEqual(e0?["path"]?.stringValue, "a.md")
        XCTAssertEqual(e0?["lineStart"]?.intValue, 3)
        XCTAssertEqual(e0?["lineEnd"]?.intValue, 7)
        XCTAssertEqual(e0?["note"]?.stringValue, "see")
        XCTAssertEqual(try JSONDecoder().decode(MemoryCitation.self, from: data), mc)
    }

    /// Upstream `TurnStartParams` (app-server-protocol/v2/turn.rs:50-126) carries
    /// the experimental override fields `responsesapiClientMetadata`,
    /// `runtimeWorkspaceRoots`, `permissions`, `collaborationMode`. They must
    /// round-trip through the Swift params struct rather than decode-drop.
    func testTurnStartParamsRoundTripsExperimentalOverrides() throws {
        let json = Data("""
        {"threadId":"thr_1",
         "input":[{"type":"text","text":"go"}],
         "responsesapiClientMetadata":{"k":"v"},
         "runtimeWorkspaceRoots":["/a","/b"],
         "permissions":"trusted",
         "collaborationMode":{"mode":"pair"}}
        """.utf8)
        let p = try JSONDecoder().decode(TurnStartParams.self, from: json)
        XCTAssertEqual(p.responsesapiClientMetadata, ["k": "v"])
        XCTAssertEqual(p.runtimeWorkspaceRoots, ["/a", "/b"])
        XCTAssertEqual(p.permissions, "trusted")
        XCTAssertEqual(p.collaborationMode?["mode"]?.stringValue, "pair")
        // Re-encode preserves the overrides (no silent drop).
        let back = try JSONDecoder().decode(
            TurnStartParams.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(back.runtimeWorkspaceRoots, ["/a", "/b"])
        XCTAssertEqual(back.permissions, "trusted")
    }

    /// Upstream `service_tier: Option<Option<String>>`
    /// (app-server-protocol/v2 thread.rs:106/267/378, turn.rs:103) with
    /// `deserialize_double_option`/`serialize_double_option` +
    /// `skip_serializing_if = Option::is_none`. Verifies the three-state
    /// distinction (absent / explicit null / value) on both decode and encode
    /// for every params type that carries the field.
    func testServiceTierDoubleOptionThreeState() throws {
        let enc = JSONEncoder()
        // Sort keys so we can substring-check the rendered wire bytes.
        enc.outputFormatting = [.sortedKeys]

        func wire(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

        // --- ThreadStartParams -------------------------------------------
        do {
            // (a) field absent -> .none, encode omits key.
            let absent = try JSONDecoder().decode(
                ThreadStartParams.self, from: Data(#"{"cwd":"/x"}"#.utf8))
            XCTAssertEqual(absent.serviceTier, .none)
            XCTAssertFalse(wire(try enc.encode(absent)).contains("serviceTier"))
            // (b) explicit null -> .some(nil), encode emits `null`.
            let null = try JSONDecoder().decode(
                ThreadStartParams.self, from: Data(#"{"serviceTier":null}"#.utf8))
            XCTAssertEqual(null.serviceTier, .some(nil))
            XCTAssertTrue(wire(try enc.encode(null)).contains("\"serviceTier\":null"))
            // (c) string value -> .some("priority"), encode emits the string.
            let val = try JSONDecoder().decode(
                ThreadStartParams.self, from: Data(#"{"serviceTier":"priority"}"#.utf8))
            XCTAssertEqual(val.serviceTier, .some("priority"))
            XCTAssertTrue(wire(try enc.encode(val)).contains("\"serviceTier\":\"priority\""))
        }

        // --- ThreadResumeParams ------------------------------------------
        do {
            let absent = try JSONDecoder().decode(
                ThreadResumeParams.self, from: Data(#"{"threadId":"t"}"#.utf8))
            XCTAssertEqual(absent.serviceTier, .none)
            XCTAssertFalse(wire(try enc.encode(absent)).contains("serviceTier"))
            let null = try JSONDecoder().decode(
                ThreadResumeParams.self, from: Data(#"{"threadId":"t","serviceTier":null}"#.utf8))
            XCTAssertEqual(null.serviceTier, .some(nil))
            XCTAssertTrue(wire(try enc.encode(null)).contains("\"serviceTier\":null"))
            let val = try JSONDecoder().decode(
                ThreadResumeParams.self, from: Data(#"{"threadId":"t","serviceTier":"flex"}"#.utf8))
            XCTAssertEqual(val.serviceTier, .some("flex"))
            XCTAssertTrue(wire(try enc.encode(val)).contains("\"serviceTier\":\"flex\""))
        }

        // --- ThreadForkParams --------------------------------------------
        do {
            let absent = try JSONDecoder().decode(
                ThreadForkParams.self, from: Data(#"{"threadId":"t"}"#.utf8))
            XCTAssertEqual(absent.serviceTier, .none)
            XCTAssertFalse(wire(try enc.encode(absent)).contains("serviceTier"))
            let null = try JSONDecoder().decode(
                ThreadForkParams.self, from: Data(#"{"threadId":"t","serviceTier":null}"#.utf8))
            XCTAssertEqual(null.serviceTier, .some(nil))
            XCTAssertTrue(wire(try enc.encode(null)).contains("\"serviceTier\":null"))
            let val = try JSONDecoder().decode(
                ThreadForkParams.self, from: Data(#"{"threadId":"t","serviceTier":"priority"}"#.utf8))
            XCTAssertEqual(val.serviceTier, .some("priority"))
            XCTAssertTrue(wire(try enc.encode(val)).contains("\"serviceTier\":\"priority\""))
        }

        // --- TurnStartParams ---------------------------------------------
        do {
            let base = #"{"threadId":"t","input":[{"type":"text","text":"go"}]"#
            let absent = try JSONDecoder().decode(
                TurnStartParams.self, from: Data("\(base)}".utf8))
            XCTAssertEqual(absent.serviceTier, .none)
            XCTAssertFalse(wire(try enc.encode(absent)).contains("serviceTier"))
            let null = try JSONDecoder().decode(
                TurnStartParams.self, from: Data("\(base),\"serviceTier\":null}".utf8))
            XCTAssertEqual(null.serviceTier, .some(nil))
            XCTAssertTrue(wire(try enc.encode(null)).contains("\"serviceTier\":null"))
            let val = try JSONDecoder().decode(
                TurnStartParams.self, from: Data("\(base),\"serviceTier\":\"priority\"}".utf8))
            XCTAssertEqual(val.serviceTier, .some("priority"))
            XCTAssertTrue(wire(try enc.encode(val)).contains("\"serviceTier\":\"priority\""))
        }
    }

    /// Upstream [UNSTABLE] `ItemGuardianApprovalReviewStartedNotification`
    /// (app-server-protocol/v2/item.rs:1073): method
    /// `item/autoApprovalReview/started`. Optional `targetItemId` and the
    /// review's optional fields are emitted as JSON `null` (upstream has no
    /// `skip_serializing_if`). `action` is an internally-tagged enum.
    func testAutoApprovalReviewStartedWireShape() throws {
        let n = ServerNotification.autoApprovalReviewStarted(
            threadId: ThreadId("thr_1"), turnId: TurnId("turn_1"),
            startedAtMs: 1_716_500_000_000, reviewId: "rev_1",
            targetItemId: nil,
            review: GuardianApprovalReview(status: .inProgress),
            action: .command(source: .shell, command: "rm -rf /", cwd: "/work"))
        guard case .notification(let m) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "item/autoApprovalReview/started")
        XCTAssertEqual(m.params?["threadId"]?.stringValue, "thr_1")
        XCTAssertEqual(m.params?["startedAtMs"]?.intValue, Int64(1_716_500_000_000))
        XCTAssertEqual(m.params?["reviewId"]?.stringValue, "rev_1")
        // targetItemId present-as-null, not omitted
        XCTAssertEqual(m.params?["targetItemId"]?.isNull, true)
        XCTAssertEqual(m.params?["review"]?["status"]?.stringValue, "inProgress")
        XCTAssertEqual(m.params?["review"]?["riskLevel"]?.isNull, true)
        XCTAssertEqual(m.params?["review"]?["userAuthorization"]?.isNull, true)
        XCTAssertEqual(m.params?["review"]?["rationale"]?.isNull, true)
        XCTAssertEqual(m.params?["action"]?["type"]?.stringValue, "command")
        XCTAssertEqual(m.params?["action"]?["source"]?.stringValue, "shell")
        XCTAssertEqual(m.params?["action"]?["command"]?.stringValue, "rm -rf /")
        XCTAssertEqual(m.params?["action"]?["cwd"]?.stringValue, "/work")
    }

    /// Upstream [UNSTABLE] `ItemGuardianApprovalReviewCompletedNotification`
    /// (app-server-protocol/v2/item.rs:1102): method
    /// `item/autoApprovalReview/completed`. Carries `completedAtMs` and
    /// `decisionSource` ("agent"); the review reaches a terminal status and may
    /// carry a risk level / authorization / rationale.
    func testAutoApprovalReviewCompletedWireShape() throws {
        let n = ServerNotification.autoApprovalReviewCompleted(
            threadId: ThreadId("thr_1"), turnId: TurnId("turn_1"),
            startedAtMs: 1_716_500_000_000, completedAtMs: 1_716_500_001_000,
            reviewId: "rev_2", targetItemId: "item_9", decisionSource: .agent,
            review: GuardianApprovalReview(
                status: .approved, riskLevel: .low,
                userAuthorization: .high, rationale: "looks safe"),
            action: .applyPatch(cwd: "/work", files: ["/work/a.txt", "/work/b.txt"]))
        guard case .notification(let m) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "item/autoApprovalReview/completed")
        XCTAssertEqual(m.params?["completedAtMs"]?.intValue, Int64(1_716_500_001_000))
        XCTAssertEqual(m.params?["decisionSource"]?.stringValue, "agent")
        XCTAssertEqual(m.params?["targetItemId"]?.stringValue, "item_9")
        XCTAssertEqual(m.params?["review"]?["status"]?.stringValue, "approved")
        XCTAssertEqual(m.params?["review"]?["riskLevel"]?.stringValue, "low")
        XCTAssertEqual(m.params?["review"]?["userAuthorization"]?.stringValue, "high")
        XCTAssertEqual(m.params?["review"]?["rationale"]?.stringValue, "looks safe")
        XCTAssertEqual(m.params?["action"]?["type"]?.stringValue, "applyPatch")
        XCTAssertEqual(m.params?["action"]?["cwd"]?.stringValue, "/work")
        XCTAssertEqual(m.params?["action"]?["files"]?.arrayValue?.count, 2)
    }

    /// `GuardianApprovalReviewAction` is an internally-tagged enum mirroring
    /// upstream `#[serde(tag="type")]`; every variant round-trips through JSON
    /// with camelCase fields and the correct discriminator. Optional fields on
    /// the `mcpToolCall`/`requestPermissions` variants are emitted as `null`.
    func testGuardianActionAllVariantsRoundTrip() throws {
        let actions: [GuardianApprovalReviewAction] = [
            .command(source: .unifiedExec, command: "echo hi", cwd: "/w"),
            .execve(source: .shell, program: "/bin/ls", argv: ["ls", "-la"], cwd: "/w"),
            .applyPatch(cwd: "/w", files: ["/w/x"]),
            .networkAccess(target: "api", host: "example.com", protocol: "https", port: 443),
            .mcpToolCall(server: "s", toolName: "t", connectorId: nil,
                         connectorName: nil, toolTitle: nil),
            .requestPermissions(reason: nil,
                                permissions: RequestPermissionProfile()),
        ]
        for a in actions {
            let data = try JSONEncoder().encode(a)
            let back = try JSONDecoder().decode(GuardianApprovalReviewAction.self, from: data)
            XCTAssertEqual(a, back)
        }
        // mcpToolCall null fields are present-as-null (not omitted).
        let mcp = GuardianApprovalReviewAction.mcpToolCall(
            server: "s", toolName: "t", connectorId: nil,
            connectorName: nil, toolTitle: nil)
        let obj = try JSONBridge.value(mcp).objectValue
        XCTAssertEqual(obj?["type"]?.stringValue, "mcpToolCall")
        XCTAssertEqual(obj?["connectorId"]?.isNull, true)
        XCTAssertEqual(obj?["connectorName"]?.isNull, true)
        XCTAssertEqual(obj?["toolTitle"]?.isNull, true)
        // networkAccess emits an integer port and a `protocol` key.
        let net = GuardianApprovalReviewAction.networkAccess(
            target: "t", host: "h", protocol: "https", port: 8080)
        let nobj = try JSONBridge.value(net).objectValue
        XCTAssertEqual(nobj?["protocol"]?.stringValue, "https")
        XCTAssertEqual(nobj?["port"]?.intValue, Int64(8080))
    }

    /// Upstream fidelity (app-server `handle_turn_interrupted`): an interrupted
    /// turn is delivered to clients as a `turn/completed` notification carrying
    /// `turn.status == "interrupted"` (plus lifecycle fields and
    /// `itemsView: "notLoaded"`). There is NO `turn/aborted` method on the wire.
    func testInterruptedTurnEmitsTurnCompletedWithInterruptedStatus() throws {
        let n = ServerNotification.turnCompleted(
            threadId: ThreadId("thr_42"),
            turn: TurnObject(id: TurnId("turn_42"), status: .interrupted,
                             itemsView: .notLoaded,
                             startedAt: 1_716_499_000,
                             completedAt: 1_716_500_000,
                             durationMs: 1_234))
        guard case .notification(let msg) = n.toMessage() else {
            return XCTFail("expected notification frame")
        }
        XCTAssertEqual(msg.method, "turn/completed")
        XCTAssertEqual(msg.params?["threadId"]?.stringValue, "thr_42")
        XCTAssertEqual(msg.params?["turn"]?["id"]?.stringValue, "turn_42")
        XCTAssertEqual(msg.params?["turn"]?["status"]?.stringValue, "interrupted")
        XCTAssertEqual(msg.params?["turn"]?["itemsView"]?.stringValue, "notLoaded")
        XCTAssertEqual(msg.params?["turn"]?["completedAt"]?.intValue, Int64(1_716_500_000))
        XCTAssertEqual(msg.params?["turn"]?["durationMs"]?.intValue, Int64(1_234))
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

        // Upstream `Turn` (thread_data.rs:158-171): `started_at`/`completed_at`/
        // `duration_ms`/`error` are `Option` with NO `skip_serializing_if`, so
        // they are ALWAYS serialized — emitted as explicit JSON `null` when nil
        // (NOT omitted). `items_view` has `#[serde(default)]` (default `Full`)
        // and is always serialized.
        let bare = TurnObject(id: TurnId("turn_bare"), status: .inProgress)
        let bareData = try JSONEncoder().encode(bare)
        let bareObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bareData) as? [String: Any])
        XCTAssertTrue(bareObj["startedAt"] is NSNull, "startedAt emitted as null when nil")
        XCTAssertTrue(bareObj["completedAt"] is NSNull, "completedAt emitted as null when nil")
        XCTAssertTrue(bareObj["durationMs"] is NSNull, "durationMs emitted as null when nil")
        XCTAssertTrue(bareObj["error"] is NSNull, "error emitted as null when nil")
        // itemsView always present, defaulting to "full".
        XCTAssertEqual(bareObj["itemsView"] as? String, "full",
                       "itemsView always serialized (defaults to full)")
        // Round-trip preserves the values (defaulted itemsView == .full).
        let bareBack = try JSONDecoder().decode(TurnObject.self, from: bareData)
        XCTAssertEqual(bareBack, bare)
        XCTAssertNil(bareBack.startedAt)
        XCTAssertEqual(bareBack.itemsView, .full)

        // `itemsView` decodes upstream's three canonical values.
        for raw in ["notLoaded", "summary", "full"] {
            let json = "{\"id\":\"t\",\"items\":[],\"status\":\"inProgress\",\"itemsView\":\"\(raw)\"}"
            let decoded = try JSONDecoder().decode(
                TurnObject.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.itemsView.rawValue, raw,
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
        // The engine's internal `StreamError` reason has no upstream analogue
        // and collapses to the bare camelCase `"other"` CodexErrorInfo variant.
        XCTAssertEqual(params?["error"]?["codexErrorInfo"]?.stringValue, "other")

        // Pre-turn / supervisor case: no active turn, will_retry=false.
        // Upstream `ErrorNotification` (notification.rs:46-47) declares
        // `thread_id`/`turn_id` as REQUIRED `String` (not Option), so both keys
        // are ALWAYS present on the wire as strings — a `nil` engine turnId is
        // emitted as an empty string, never omitted nor null.
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
        XCTAssertEqual(pparams?["turnId"]?.stringValue, "",
                       "turnId always present as a string (empty when nil)")
        if case .bool(let b)? = pparams?["willRetry"] { XCTAssertFalse(b) }
        else { XCTFail("willRetry should serialize as JSON bool") }
    }

    /// `CodexErrorInfo` wire fidelity (upstream
    /// app-server-protocol/src/protocol/v2/shared.rs:68-112): unit variants
    /// serialize as a bare camelCase string; data variants serialize as a
    /// single-key object. Mirrors serde's externally-tagged
    /// `#[serde(rename_all = "camelCase")]` enum.
    func testCodexErrorInfoExternalTaggingWireShape() throws {
        func enc(_ v: CodexErrorInfo) throws -> JSONValue {
            let data = try JSONEncoder().encode(v)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
        // Unit variants → bare camelCase strings.
        XCTAssertEqual(try enc(.contextWindowExceeded).stringValue, "contextWindowExceeded")
        XCTAssertEqual(try enc(.usageLimitExceeded).stringValue, "usageLimitExceeded")
        XCTAssertEqual(try enc(.serverOverloaded).stringValue, "serverOverloaded")
        XCTAssertEqual(try enc(.cyberPolicy).stringValue, "cyberPolicy")
        XCTAssertEqual(try enc(.internalServerError).stringValue, "internalServerError")
        XCTAssertEqual(try enc(.unauthorized).stringValue, "unauthorized")
        XCTAssertEqual(try enc(.badRequest).stringValue, "badRequest")
        XCTAssertEqual(try enc(.threadRollbackFailed).stringValue, "threadRollbackFailed")
        XCTAssertEqual(try enc(.sandboxError).stringValue, "sandboxError")
        XCTAssertEqual(try enc(.other).stringValue, "other")

        // Data variants → single-key objects with camelCase payload.
        let http = try enc(.httpConnectionFailed(httpStatusCode: 503))
        XCTAssertEqual(http["httpConnectionFailed"]?["httpStatusCode"]?.intValue, 503)
        let disc = try enc(.responseStreamDisconnected(httpStatusCode: nil))
        XCTAssertNotNil(disc["responseStreamDisconnected"])
        // `httpStatusCode: Option<u16>` with no skip → explicit null when absent.
        if case .null? = disc["responseStreamDisconnected"]?["httpStatusCode"] {} else {
            XCTFail("absent httpStatusCode should serialize as null")
        }

        // activeTurnNotSteerable carries the required `turnKind` (review|compact).
        let steerReview = try enc(.activeTurnNotSteerable(turnKind: .review))
        XCTAssertEqual(steerReview["activeTurnNotSteerable"]?["turnKind"]?.stringValue, "review")
        let steerCompact = try enc(.activeTurnNotSteerable(turnKind: .compact))
        XCTAssertEqual(steerCompact["activeTurnNotSteerable"]?["turnKind"]?.stringValue, "compact")

        // Round-trips: encode → decode is lossless for each variant.
        for v: CodexErrorInfo in [.contextWindowExceeded, .serverOverloaded, .other,
                                  .httpConnectionFailed(httpStatusCode: 429),
                                  .responseStreamDisconnected(httpStatusCode: nil),
                                  .activeTurnNotSteerable(turnKind: .compact)] {
            let data = try JSONEncoder().encode(v)
            let back = try JSONDecoder().decode(CodexErrorInfo.self, from: data)
            XCTAssertEqual(back, v)
        }
    }

    /// `CodexErrorInfo.from(reason:)` collapses the engine's fine-grained
    /// internal reason tags onto the closest upstream variant; anything without
    /// an analogue becomes `.other` (parity with upstream's `Other` fallthrough).
    func testCodexErrorInfoReasonMapping() {
        XCTAssertEqual(CodexErrorInfo.from(reason: "ContextWindowExceeded"), .contextWindowExceeded)
        XCTAssertEqual(CodexErrorInfo.from(reason: "ContextLimit"), .contextWindowExceeded)
        XCTAssertEqual(CodexErrorInfo.from(reason: "Overloaded"), .serverOverloaded)
        XCTAssertEqual(CodexErrorInfo.from(reason: "ResourceGovernorTerminal"), .serverOverloaded)
        XCTAssertEqual(CodexErrorInfo.from(reason: "WorkerWatchdogTerminal"), .serverOverloaded)
        XCTAssertEqual(CodexErrorInfo.from(reason: "SandboxError"), .sandboxError)
        // No upstream analogue → `.other`.
        for tag in ["StreamError", "ModelError", "LoopGuard", "DeadlineExceeded",
                    "HookBlocked", "DurabilityError", "PersistenceError", "Interrupted"] {
            XCTAssertEqual(CodexErrorInfo.from(reason: tag), .other, "\(tag) should map to .other")
        }
        XCTAssertNil(CodexErrorInfo.from(reason: nil))
    }

    /// `ErrorBody` keeps a non-serialized fine-grained `reason` and a
    /// wire-facing `codexErrorInfo` derived from it; the wire always carries the
    /// collapsed enum + an explicit null `additionalDetails` (upstream
    /// `TurnError` serializes both fields always, no skip_serializing_if).
    func testErrorBodyWireSeparatesReasonFromCodexErrorInfo() throws {
        let body = ErrorBody(message: "boom", codexErrorInfo: "StreamError")
        XCTAssertEqual(body.reason, "StreamError")
        XCTAssertEqual(body.codexErrorInfo, .other)
        let json = try JSONDecoder().decode(JSONValue.self,
                                            from: JSONEncoder().encode(body))
        XCTAssertEqual(json["message"]?.stringValue, "boom")
        // Internal `reason` is NOT on the wire.
        XCTAssertNil(json["reason"])
        XCTAssertEqual(json["codexErrorInfo"]?.stringValue, "other")
        // `additionalDetails` always serialized (null when absent).
        if case .null? = json["additionalDetails"] {} else {
            XCTFail("additionalDetails should be explicit null when absent")
        }

        // Explicit wireInfo override (activeTurnNotSteerable carries turnKind).
        let steer = ErrorBody(message: "busy", codexErrorInfo: "ActiveTurnNotSteerable",
                              wireInfo: .activeTurnNotSteerable(turnKind: .review))
        XCTAssertEqual(steer.reason, "ActiveTurnNotSteerable")
        let sjson = try JSONDecoder().decode(JSONValue.self,
                                             from: JSONEncoder().encode(steer))
        XCTAssertEqual(sjson["codexErrorInfo"]?["activeTurnNotSteerable"]?["turnKind"]?.stringValue,
                       "review")
    }

    /// Wire fidelity for `turn/diff/updated` (upstream
    /// `TurnDiffUpdatedNotification { threadId, turnId, diff }`, camelCase,
    /// all three fields required).
    func testTurnDiffUpdatedWireShape() throws {
        let diff = """
        diff --git a/a.txt b/a.txt
        new file mode 100644
        index 0000000000000000000000000000000000000000..3bd1f0e2
        --- /dev/null
        +++ b/a.txt
        @@ -0,0 +1,2 @@
        +foo
        +bar

        """
        let n = ServerNotification.turnDiffUpdated(
            threadId: ThreadId("thr_99"), turnId: TurnId("turn_7"), diff: diff)
        XCTAssertEqual(n.method, "turn/diff/updated")
        guard case .notification(let msg) = n.toMessage() else {
            return XCTFail("expected notification frame")
        }
        XCTAssertEqual(msg.method, "turn/diff/updated")
        XCTAssertEqual(msg.params?["threadId"]?.stringValue, "thr_99")
        XCTAssertEqual(msg.params?["turnId"]?.stringValue, "turn_7")
        XCTAssertEqual(msg.params?["diff"]?.stringValue, diff)
    }

    func testServerRequestDecisionDecode() throws {
        let sr = ServerRequest.commandApproval(.int(9), .init(
            threadId: ThreadId("t"), turnId: TurnId("tn"), itemId: ItemId("i"),
            startedAtMs: 1_716_500_000_000, reason: "danger",
            command: "rm -rf /", cwd: "/"))
        guard case .request(let m) = sr.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "item/commandExecution/requestApproval")
        XCTAssertEqual(m.params?["command"]?.stringValue, "rm -rf /")
        XCTAssertEqual(m.params?["startedAtMs"]?.intValue, Int64(1_716_500_000_000))
        let dec = try ServerRequest.decodeDecision(.object(["decision": .string("decline")]))
        XCTAssertEqual(dec, .decline)
    }

    // Finding 1 (protocol-wire-types): the four bare-string decisions decode as
    // serde externally-tagged unit variants.
    func testApprovalDecisionBareStringVariantsDecode() throws {
        for (s, expected): (String, ApprovalDecision) in [
            ("accept", .accept), ("acceptForSession", .acceptForSession),
            ("decline", .decline), ("cancel", .cancel),
        ] {
            let d = try ServerRequest.decodeDecision(.object(["decision": .string(s)]))
            XCTAssertEqual(d, expected, "string decision \(s)")
            XCTAssertEqual(d.isAccept, s == "accept" || s == "acceptForSession")
        }
    }

    // Finding 1 (sandbox-safety-policy): the two data-carrying CommandExecution
    // approval decisions are externally-tagged serde STRUCT variants. The wire
    // shape is `{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":[...]}}`
    // — note the snake_case INNER field key (the variant struct fields are NOT
    // camelCased). The amendment value is wrapped in that inner object, not
    // bare. Confirmed by CommandExecutionRequestApprovalResponse.json:20-66.
    func testApprovalDecisionExecpolicyAmendmentDecodes() throws {
        let payload: JSONValue = .object(["decision": .object([
            "acceptWithExecpolicyAmendment": .object([
                "execpolicy_amendment": .array([.string("git"), .string("status")])
            ])
        ])])
        let d = try ServerRequest.decodeDecision(payload)
        guard case .acceptWithExecpolicyAmendment(let amendment) = d else {
            return XCTFail("expected acceptWithExecpolicyAmendment, got \(d)")
        }
        XCTAssertEqual(amendment.command, ["git", "status"])
        XCTAssertTrue(d.isAccept)
    }

    func testApprovalDecisionNetworkPolicyAmendmentDecodes() throws {
        let payload: JSONValue = .object(["decision": .object([
            "applyNetworkPolicyAmendment": .object([
                "network_policy_amendment": .object([
                    "host": .string("example.com"),
                    "action": .string("allow"),
                ])
            ])
        ])])
        let d = try ServerRequest.decodeDecision(payload)
        guard case .applyNetworkPolicyAmendment(let amendment) = d else {
            return XCTFail("expected applyNetworkPolicyAmendment, got \(d)")
        }
        XCTAssertEqual(amendment.host, "example.com")
        XCTAssertEqual(amendment.action, .allow)
        XCTAssertTrue(d.isAccept)
    }

    // The bare-array form (the pre-fix WRONG shape) must NOT decode — it should
    // throw, since the payload must be the inner struct-field object.
    func testApprovalDecisionExecpolicyAmendmentBareArrayRejected() throws {
        let payload: JSONValue = .object(["decision": .object([
            "acceptWithExecpolicyAmendment": .array([.string("git"), .string("status")])
        ])])
        XCTAssertThrowsError(try ServerRequest.decodeDecision(payload))
    }

    // Finding 1: round-trip — the amendment variants re-encode to the exact
    // externally-tagged serde STRUCT-variant wire shape (inner snake_case key).
    func testApprovalDecisionAmendmentVariantsRoundTrip() throws {
        let exec = ApprovalDecision.acceptWithExecpolicyAmendment(
            ExecPolicyAmendment(command: ["npm", "test"]))
        let execWire = try JSONBridge.value(exec)
        XCTAssertEqual(execWire,
            .object(["acceptWithExecpolicyAmendment":
                .object(["execpolicy_amendment":
                    .array([.string("npm"), .string("test")])])]))
        XCTAssertEqual(try JSONBridge.decode(ApprovalDecision.self, from: execWire), exec)

        let net = ApprovalDecision.applyNetworkPolicyAmendment(
            NetworkPolicyAmendment(host: "api.local", action: .deny))
        let netWire = try JSONBridge.value(net)
        XCTAssertEqual(netWire,
            .object(["applyNetworkPolicyAmendment":
                .object(["network_policy_amendment":
                    .object(["host": .string("api.local"), "action": .string("deny")])])]))
        XCTAssertEqual(try JSONBridge.decode(ApprovalDecision.self, from: netWire), net)

        // Bare-string variants round-trip to plain strings.
        XCTAssertEqual(try JSONBridge.value(ApprovalDecision.accept), .string("accept"))
        XCTAssertEqual(try JSONBridge.value(ApprovalDecision.cancel), .string("cancel"))
    }

    // Finding 2/6: CommandApprovalParams gains optional proposed-amendment,
    // command-actions, network-context and available-decisions fields. All are
    // skip-if-nil; when nil they must be absent from the wire (parity with
    // serde `skip_serializing_if = Option::is_none`).
    func testCommandApprovalParamsAmendmentFieldsOmittedWhenNil() throws {
        let p = CommandApprovalParams(
            threadId: ThreadId("t"), turnId: TurnId("u"), itemId: ItemId("i"),
            startedAtMs: 5, command: "ls", cwd: "/tmp")
        let wire = try JSONBridge.value(p)
        guard case .object(let obj) = wire else { return XCTFail("not object") }
        XCTAssertNil(obj["proposedExecpolicyAmendment"])
        XCTAssertNil(obj["proposedNetworkPolicyAmendments"])
        XCTAssertNil(obj["commandActions"])
        XCTAssertNil(obj["availableDecisions"])
        XCTAssertNil(obj["networkApprovalContext"])
        XCTAssertNil(obj["additionalPermissions"])
    }

    func testCommandApprovalParamsAmendmentFieldsEncodeWhenPresent() throws {
        let p = CommandApprovalParams(
            threadId: ThreadId("t"), turnId: TurnId("u"), itemId: ItemId("i"),
            startedAtMs: 5, command: "rm -rf build", cwd: "/tmp",
            proposedExecpolicyAmendment: ExecPolicyAmendment(command: ["rm", "-rf"]),
            proposedNetworkPolicyAmendments: [
                NetworkPolicyAmendment(host: "x.test", action: .deny)],
            availableDecisions: [.accept, .decline])
        let wire = try JSONBridge.value(p)
        guard case .object(let obj) = wire else { return XCTFail("not object") }
        XCTAssertEqual(obj["proposedExecpolicyAmendment"],
                       .array([.string("rm"), .string("-rf")]))
        XCTAssertEqual(obj["proposedNetworkPolicyAmendments"],
                       .array([.object(["host": .string("x.test"),
                                        "action": .string("deny")])]))
        XCTAssertEqual(obj["availableDecisions"],
                       .array([.string("accept"), .string("decline")]))
        // Round-trips back to the same struct.
        XCTAssertEqual(try JSONBridge.decode(CommandApprovalParams.self, from: wire), p)
    }

    // Finding 3 (protocol-wire-types): upstream v1::ClientInfo.version is a
    // required field, but the port documents a deliberate decode-laxness
    // divergence (the missing-version handshake is tolerated, not fatal, so the
    // minimal in-tree probe clients keep working). Pin BOTH behaviours so the
    // divergence is intentional and observable: version decodes when present,
    // and is `nil` (tolerated) when omitted.
    func testClientInfoVersionPresentAndTolerantWhenMissing() throws {
        guard case .initialize(_, let withV) = try ClientRequest.parse(req("initialize", .object([
            "clientInfo": .object(["name": .string("c"), "version": .string("9.9")]),
        ]))) else { return XCTFail("expected initialize") }
        XCTAssertEqual(withV.clientInfo.version, "9.9")

        guard case .initialize(_, let noV) = try ClientRequest.parse(req("initialize", .object([
            "clientInfo": .object(["name": .string("c")]),
        ]))) else { return XCTFail("expected initialize even without version") }
        XCTAssertEqual(noV.clientInfo.name, "c")
        XCTAssertNil(noV.clientInfo.version)
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

    /// Plan update wire shape — upstream `turn/plan/updated`
    /// (`TurnPlanUpdatedNotification`): `{threadId, turnId, plan: [{step,
    /// status}], explanation?}`. The v2 step `status` is camelCase
    /// (`inProgress`), distinct from the snake_case tool-argument `StepStatus`.
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
        XCTAssertEqual(msg.method, "turn/plan/updated")
        XCTAssertEqual(msg.params?["threadId"]?.stringValue, "thr_p")
        XCTAssertEqual(msg.params?["turnId"]?.stringValue, "turn_p")
        XCTAssertEqual(msg.params?["explanation"]?.stringValue, "do work")
        guard case .array(let items)? = msg.params?["plan"] else {
            return XCTFail("plan should serialise as a JSON array")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["step"]?.stringValue, "draft")
        XCTAssertEqual(items[0]["status"]?.stringValue, "inProgress")
        XCTAssertEqual(items[1]["status"]?.stringValue, "pending")

        // Upstream `TurnPlanUpdatedNotification.explanation` is `Option<String>`
        // with NO `skip_serializing_if`, so it serialises as `"explanation": null`
        // when absent — the key is PRESENT with a null value, NOT omitted.
        let bare = ServerNotification.planUpdate(
            threadId: ThreadId("thr_p"), turnId: TurnId("turn_p"),
            explanation: nil, plan: [])
        guard case .notification(let bm) = bare.toMessage() else { return XCTFail() }
        guard case .null? = bm.params?["explanation"] else {
            return XCTFail("explanation must be present as JSON null when nil, not omitted")
        }
    }

    /// Upstream [EXPERIMENTAL] `PlanDeltaNotification` (common.rs:1478,
    /// event_mapping.rs:355-360): method `item/plan/delta`, payload
    /// `{threadId, turnId, itemId, delta}` — same envelope as the other
    /// `*/delta` notifications.
    func testPlanDeltaWireShape() throws {
        let n = ServerNotification.planDelta(
            threadId: ThreadId("thr_pd"), turnId: TurnId("turn_pd"),
            itemId: ItemId("item_pd"), delta: "step 1: ")
        guard case .notification(let m) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "item/plan/delta")
        XCTAssertEqual(m.params?["threadId"]?.stringValue, "thr_pd")
        XCTAssertEqual(m.params?["turnId"]?.stringValue, "turn_pd")
        XCTAssertEqual(m.params?["itemId"]?.stringValue, "item_pd")
        XCTAssertEqual(m.params?["delta"]?.stringValue, "step 1: ")
    }

    /// Upstream `RawResponseItemCompletedNotification` (common.rs:1475,
    /// v2/item.rs:1145-1149): method `rawResponseItem/completed`, payload
    /// `{threadId, turnId, item}` where `item` is the raw `ResponseItem` JSON
    /// carried verbatim.
    func testRawResponseItemCompletedWireShape() throws {
        let item: JSONValue = .object([
            "type": .string("message"),
            "role": .string("assistant"),
            "content": .array([.object([
                "type": .string("output_text"),
                "text": .string("hi"),
            ])]),
        ])
        let n = ServerNotification.rawResponseItemCompleted(
            threadId: ThreadId("thr_rr"), turnId: TurnId("turn_rr"), item: item)
        guard case .notification(let m) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "rawResponseItem/completed")
        XCTAssertEqual(m.params?["threadId"]?.stringValue, "thr_rr")
        XCTAssertEqual(m.params?["turnId"]?.stringValue, "turn_rr")
        // The raw item is forwarded verbatim (no re-shaping).
        XCTAssertEqual(m.params?["item"]?["type"]?.stringValue, "message")
        XCTAssertEqual(m.params?["item"]?["role"]?.stringValue, "assistant")
        let content = try XCTUnwrap(m.params?["item"]?["content"]?.arrayValue)
        XCTAssertEqual(content.first?["text"]?.stringValue, "hi")
    }

    /// Upstream `McpToolCallProgressNotification` (common.rs:1493,
    /// v2/mcp.rs:199-207): method `item/mcpToolCall/progress`, payload the four
    /// required camelCase fields `{threadId, turnId, itemId, message}` with no
    /// `skip_serializing_if`. The wire shape is modeled and emittable; the
    /// emit path is deferred until MCP per-call progress-streaming is wired
    /// into `McpToolProxy.run` (app-server-events finding 3). This test locks
    /// the wire shape so a future emit site is byte-correct on day one.
    func testMcpToolCallProgressWireShape() throws {
        let n = ServerNotification.mcpToolCallProgress(
            threadId: ThreadId("thr_mp"), turnId: TurnId("turn_mp"),
            itemId: ItemId("item_mp"), message: "indexing files 3/10")
        guard case .notification(let m) = n.toMessage() else { return XCTFail() }
        XCTAssertEqual(m.method, "item/mcpToolCall/progress")
        XCTAssertEqual(m.params?["threadId"]?.stringValue, "thr_mp")
        XCTAssertEqual(m.params?["turnId"]?.stringValue, "turn_mp")
        XCTAssertEqual(m.params?["itemId"]?.stringValue, "item_mp")
        XCTAssertEqual(m.params?["message"]?.stringValue, "indexing files 3/10")
        // All four fields are required (no skip_serializing_if): exactly four keys.
        XCTAssertEqual(m.params?.objectValue?.count, 4)
    }

    /// Finding: `item/started` / `item/completed` must carry the TRUE
    /// lifecycle instant threaded from the producing site (upstream
    /// event_mapping.rs:391-400 carries `started_at_ms`/`completed_at_ms`
    /// from the originating core event), not a serialize-time clock read.
    /// When a caller passes an explicit timestamp it is serialized verbatim.
    func testItemLifecycleTimestampsAreThreadedNotSerializeTime() throws {
        let started = ServerNotification.itemStarted(
            threadId: ThreadId("thr_t"), turnId: TurnId("turn_t"),
            item: .agentMessage(id: ItemId("i1"), text: "x"),
            startedAtMs: 1_716_500_000_000)
        guard case .notification(let sm) = started.toMessage() else { return XCTFail() }
        XCTAssertEqual(sm.method, "item/started")
        XCTAssertEqual(sm.params?["startedAtMs"]?.intValue, Int64(1_716_500_000_000))

        let completed = ServerNotification.itemCompleted(
            threadId: ThreadId("thr_t"), turnId: TurnId("turn_t"),
            item: .agentMessage(id: ItemId("i1"), text: "x"),
            completedAtMs: 1_716_500_005_000)
        guard case .notification(let cm) = completed.toMessage() else { return XCTFail() }
        XCTAssertEqual(cm.method, "item/completed")
        XCTAssertEqual(cm.params?["completedAtMs"]?.intValue, Int64(1_716_500_005_000))
    }

    /// Backward-compat: when no explicit lifecycle timestamp is supplied the
    /// envelope still emits a plausible `startedAtMs`/`completedAtMs` (the
    /// serialize-time fallback), so legacy callers and the wire schema's
    /// required field are preserved.
    func testItemLifecycleTimestampFallsBackToNowWhenNil() throws {
        let started = ServerNotification.itemStarted(
            threadId: ThreadId("thr_t"), turnId: TurnId("turn_t"),
            item: .agentMessage(id: ItemId("i1"), text: "x"))
        guard case .notification(let sm) = started.toMessage() else { return XCTFail() }
        XCTAssertNotNil(sm.params?["startedAtMs"]?.intValue,
                        "startedAtMs must always be present on the wire")

        let completed = ServerNotification.itemCompleted(
            threadId: ThreadId("thr_t"), turnId: TurnId("turn_t"),
            item: .agentMessage(id: ItemId("i1"), text: "x"))
        guard case .notification(let cm) = completed.toMessage() else { return XCTFail() }
        XCTAssertNotNil(cm.params?["completedAtMs"]?.intValue,
                        "completedAtMs must always be present on the wire")
    }

    /// User-input / permission prompts are upstream SERVER REQUESTS, NOT
    /// notifications. There is no `item/requestUserInput` /
    /// `item/requestPermissions` notification method anywhere in upstream
    /// `server_notification_definitions!` — those fabricated `ServerNotification`
    /// cases were removed for wire fidelity (the real flow uses `ServerRequest`,
    /// covered by `testServerRequest*` below). This test guards that no
    /// `ServerNotification` ever emits those non-upstream method strings.
    func testNoFabricatedRequestNotificationMethods() throws {
        // The `RequestUserInputQuestion` wire shape is still a public type used
        // by the ServerRequest param surface; verify it round-trips camelCase.
        let q = RequestUserInputQuestion(
            id: "db_password", header: "DB pwd",
            question: "What is the database password?",
            isOther: true, isSecret: true,
            options: [RequestUserInputQuestionOption(
                label: "Use stored", description: "from keychain")])
        let data = try JSONEncoder().encode(q)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, "db_password")
        XCTAssertEqual(obj["isOther"] as? Bool, true)
        XCTAssertEqual(obj["isSecret"] as? Bool, true)

        // No ServerNotification maps to the removed fabricated method strings.
        let methods = [
            ServerNotification.planUpdate(threadId: ThreadId("t"), turnId: TurnId("u"),
                                          explanation: nil, plan: []).method,
            ServerNotification.warning(threadId: nil, message: "x").method,
        ]
        XCTAssertFalse(methods.contains("item/requestUserInput"))
        XCTAssertFalse(methods.contains("item/requestPermissions"))
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

    // MARK: - ThreadStatus tagged activeFlags (upstream thread.rs:955-976)

    /// `ThreadStatus` is an internally-tagged enum. The three unit variants emit
    /// `{"type":"<tag>"}` with NO `activeFlags` key; only `active` carries the
    /// camelCase `activeFlags` array.
    func testThreadStatusUnitVariantsWireShape() throws {
        for (status, tag) in [
            (ThreadStatus.notLoaded, "notLoaded"),
            (ThreadStatus.idle, "idle"),
            (ThreadStatus.systemError, "systemError"),
        ] {
            let data = try JSONEncoder().encode(status)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(obj["type"] as? String, tag)
            XCTAssertNil(obj["activeFlags"],
                         "unit variants must NOT emit activeFlags (never null)")
            XCTAssertEqual(obj.count, 1, "only the type discriminator is present")
            XCTAssertEqual(try JSONDecoder().decode(ThreadStatus.self, from: data), status)
        }
    }

    /// The `active` variant emits `{"type":"active","activeFlags":[...]}` with
    /// the two camelCase flag values, in order.
    func testThreadStatusActiveWithFlagsWireShape() throws {
        let status = ThreadStatus.active(activeFlags: [.waitingOnApproval, .waitingOnUserInput])
        let data = try JSONEncoder().encode(status)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "active")
        XCTAssertEqual(obj["activeFlags"] as? [String],
                       ["waitingOnApproval", "waitingOnUserInput"])
        XCTAssertEqual(try JSONDecoder().decode(ThreadStatus.self, from: data), status)
    }

    /// An `active` status with no flags still emits an (empty) `activeFlags`
    /// array — upstream `Vec<ThreadActiveFlag>` is required on the variant.
    func testThreadStatusActiveEmptyFlags() throws {
        let data = try JSONEncoder().encode(ThreadStatus.active(activeFlags: []))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "active")
        XCTAssertEqual(obj["activeFlags"] as? [String], [])
    }

    /// `thread/status/changed` carries the tagged `ThreadStatus` object under
    /// `status` alongside `threadId`.
    func testThreadStatusChangedNotificationWireShape() throws {
        let n = ServerNotification.threadStatusChanged(
            threadId: ThreadId("thr_7"),
            status: .active(activeFlags: [.waitingOnApproval]))
        XCTAssertEqual(n.method, "thread/status/changed")
        guard case .notification(let note) = n.toMessage() else { return XCTFail() }
        let data = try JSONEncoder().encode(note.params)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["threadId"] as? String, "thr_7")
        let status = try XCTUnwrap(obj["status"] as? [String: Any])
        XCTAssertEqual(status["type"] as? String, "active")
        XCTAssertEqual(status["activeFlags"] as? [String], ["waitingOnApproval"])
    }

    // MARK: - CommandAction tagged set (upstream item.rs:102-124)

    /// Each `CommandAction` variant emits its exact internally-tagged shape with
    /// camelCase `type`; optional fields are omitted when nil.
    func testCommandActionVariantsWireShape() throws {
        let read = CommandAction.read(command: "cat foo.txt", name: "foo.txt", path: "/abs/foo.txt")
        let ro = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(read)) as? [String: Any])
        XCTAssertEqual(ro["type"] as? String, "read")
        XCTAssertEqual(ro["command"] as? String, "cat foo.txt")
        XCTAssertEqual(ro["name"] as? String, "foo.txt")
        XCTAssertEqual(ro["path"] as? String, "/abs/foo.txt")

        let list = CommandAction.listFiles(command: "ls", path: nil)
        let lo = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(list)) as? [String: Any])
        XCTAssertEqual(lo["type"] as? String, "listFiles")
        XCTAssertEqual(lo["command"] as? String, "ls")
        XCTAssertNil(lo["path"], "nil path is omitted, not null")

        let search = CommandAction.search(command: "rg foo", query: "foo", path: "src")
        let so = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(search)) as? [String: Any])
        XCTAssertEqual(so["type"] as? String, "search")
        XCTAssertEqual(so["query"] as? String, "foo")
        XCTAssertEqual(so["path"] as? String, "src")

        let unknown = CommandAction.unknown(command: "weird | thing")
        let uo = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(unknown)) as? [String: Any])
        XCTAssertEqual(uo["type"] as? String, "unknown")
        XCTAssertEqual(uo["command"] as? String, "weird | thing")

        for action in [read, list, search, unknown] {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(CommandAction.self, from: data), action)
        }
    }

    /// A `commandExecution` ThreadItem now carries the required `commandActions`
    /// array on the wire (present even when empty) and round-trips it.
    func testCommandExecutionItemCarriesCommandActions() throws {
        let item: ThreadItem = .commandExecution(
            id: ItemId("c9"), command: ["grep -n foo src"], cwd: "/repo",
            status: .completed,
            commandActions: [.search(command: "grep -n foo src", query: "foo", path: "src")],
            aggregatedOutput: "match", exitCode: 0)
        let data = try JSONEncoder().encode(item)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "commandExecution")
        let actions = try XCTUnwrap(obj["commandActions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0]["type"] as? String, "search")
        XCTAssertEqual(actions[0]["query"] as? String, "foo")
        XCTAssertEqual(try JSONDecoder().decode(ThreadItem.self, from: data), item)
    }

    /// Decoding a legacy `commandExecution` payload WITHOUT `commandActions`
    /// must tolerate the absence and default to an empty list. `source` must
    /// default to `.agent` (upstream `#[serde(default)]`).
    func testCommandExecutionDecodesMissingCommandActions() throws {
        let json = """
        {"type":"commandExecution","id":"c1","command":"ls","cwd":"/w","status":"completed"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(ThreadItem.self, from: json)
        guard case .commandExecution(_, _, _, _, let actions, _, _, _, let source, _) = item else {
            return XCTFail("expected commandExecution")
        }
        XCTAssertEqual(actions, [])
        XCTAssertEqual(source, .agent, "source defaults to .agent when absent")
    }

    /// Finding 5: `commandExecution` carries upstream `processId`, `source`
    /// (`#[serde(default)]`, always serialized as "agent"), and `durationMs`
    /// (`number | null`). Field presence and round-trip are asserted.
    func testCommandExecutionCarriesProcessIdSourceDurationMs() throws {
        // Fully-populated with a non-default source.
        let item: ThreadItem = .commandExecution(
            id: ItemId("c10"), command: ["sleep 1"], cwd: "/repo",
            status: .completed, commandActions: [],
            aggregatedOutput: "", exitCode: 0,
            processId: "4242", source: .unifiedExecStartup, durationMs: 1_005)
        let data = try JSONEncoder().encode(item)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["processId"] as? String, "4242")
        XCTAssertEqual(obj["source"] as? String, "unifiedExecStartup")
        XCTAssertEqual(obj["durationMs"] as? Int, 1_005)
        XCTAssertEqual(try JSONDecoder().decode(ThreadItem.self, from: data), item)

        // Defaulted: source is always serialized as "agent"; processId/durationMs
        // are Option with NO skip_serializing_if upstream (v2/item.rs:248-270),
        // so they are emitted as explicit JSON null when nil — NOT omitted
        // (v9 app-server-events finding 2 corrected the prior omit behavior).
        let bare: ThreadItem = .commandExecution(
            id: ItemId("c11"), command: ["echo hi"], cwd: "/repo",
            status: .inProgress, commandActions: [],
            aggregatedOutput: nil, exitCode: nil)
        let bdata = try JSONEncoder().encode(bare)
        let bobj = try XCTUnwrap(JSONSerialization.jsonObject(with: bdata) as? [String: Any])
        XCTAssertEqual(bobj["source"] as? String, "agent",
                       "source always serialized, defaulting to agent")
        XCTAssertTrue(bobj.keys.contains("processId") && bobj["processId"] is NSNull,
                      "processId emitted as explicit null when nil")
        XCTAssertTrue(bobj.keys.contains("durationMs") && bobj["durationMs"] is NSNull,
                      "durationMs emitted as explicit null when nil")
        XCTAssertTrue(bobj.keys.contains("aggregatedOutput") && bobj["aggregatedOutput"] is NSNull,
                      "aggregatedOutput emitted as explicit null when nil")
        XCTAssertTrue(bobj.keys.contains("exitCode") && bobj["exitCode"] is NSNull,
                      "exitCode emitted as explicit null when nil")
    }

    /// Finding 6 (corrected): although `plugin/installed` is not in the upstream
    /// app-server contract, it is a DELIBERATE port marketplace extension with a
    /// real handler (RequestRouter + GenericResponses) that the marketplace
    /// round-trip flow depends on, so it MUST stay a known method (removing it
    /// regressed `testMarketplaceAddInstallUpgradeUninstallRemoveRoundTrip`).
    /// This mirrors the port's other intentional non-upstream methods
    /// (fuzzyFileSearch / remoteControl / realtime / goal).
    func testPluginInstalledIsAKnownPortExtensionMethod() {
        XCTAssertTrue(Method.isKnown("plugin/installed"),
                      "plugin/installed is a load-bearing port marketplace extension")
        // Sanity: real plugin methods remain known.
        XCTAssertTrue(Method.isKnown("plugin/list"))
        XCTAssertTrue(Method.isKnown("plugin/install"))
    }

    /// Finding 7: deprecated legacy v1 approval server-requests
    /// (`applyPatchApproval` / `execCommandApproval`) are modeled and reconstruct
    /// from the wire (used only for the legacy SendUserTurn / SendUserMessage path).
    func testLegacyV1ApprovalServerRequestsRoundTrip() throws {
        let patch = ServerRequest.applyPatchApproval(
            .int(7),
            LegacyApplyPatchApprovalParams(
                conversationId: ThreadId("conv_1"), callId: "call_a",
                fileChanges: ["/repo/a.txt": .object(["add": .object(["content": .string("x")])])],
                reason: "needs write", grantRoot: "/repo"))
        XCTAssertEqual(patch.method, "applyPatchApproval")
        guard case .request(let pm) = patch.toMessage() else { return XCTFail() }
        XCTAssertEqual(pm.method, "applyPatchApproval")
        XCTAssertEqual(pm.params?["conversationId"]?.stringValue, "conv_1")
        XCTAssertEqual(pm.params?["callId"]?.stringValue, "call_a")
        XCTAssertEqual(pm.params?["reason"]?.stringValue, "needs write")
        XCTAssertEqual(pm.params?["grantRoot"]?.stringValue, "/repo")
        // reconstruct() rebuilds the typed request from the wire.
        let rp = ServerRequest.reconstruct(method: "applyPatchApproval",
                                           id: .int(7), params: pm.params ?? .null)
        guard case .applyPatchApproval(_, let rpp)? = rp else {
            return XCTFail("applyPatchApproval should reconstruct")
        }
        XCTAssertEqual(rpp.callId, "call_a")

        let exec = ServerRequest.execCommandApproval(
            .string("rid_e"),
            LegacyExecCommandApprovalParams(
                conversationId: ThreadId("conv_2"), callId: "call_b",
                approvalId: "appr_1", command: ["ls", "-la"], cwd: "/repo",
                reason: nil, parsedCmd: []))
        XCTAssertEqual(exec.method, "execCommandApproval")
        guard case .request(let em) = exec.toMessage() else { return XCTFail() }
        // v1 `command` is an argv ARRAY (distinct from the v2 joined string).
        guard case .array(let argv)? = em.params?["command"] else {
            return XCTFail("v1 command must be an array")
        }
        XCTAssertEqual(argv.map { $0.stringValue }, ["ls", "-la"])
        XCTAssertEqual(em.params?["approvalId"]?.stringValue, "appr_1")
        XCTAssertNil(em.params?["reason"], "reason omitted when nil")
        let re = ServerRequest.reconstruct(method: "execCommandApproval",
                                           id: .string("rid_e"), params: em.params ?? .null)
        guard case .execCommandApproval(_, let rep)? = re else {
            return XCTFail("execCommandApproval should reconstruct")
        }
        XCTAssertEqual(rep.command, ["ls", "-la"])
        XCTAssertEqual(rep.cwd, "/repo")
    }

    /// Finding 2: `TokenUsageBody.modelContextWindow` is `Option` with no skip
    /// upstream → emitted as explicit JSON `null` when absent (not omitted).
    func testTokenUsageModelContextWindowEmittedAsNullWhenNil() throws {
        let n = ServerNotification.tokenUsageUpdated(
            threadId: ThreadId("t"), turnId: TurnId("u"),
            total: .zero, last: .zero, modelContextWindow: nil)
        guard case .notification(let msg) = n.toMessage() else { return XCTFail() }
        let data = try JSONEncoder().encode(msg.params)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let usage = try XCTUnwrap(obj["tokenUsage"] as? [String: Any])
        XCTAssertTrue(usage["modelContextWindow"] is NSNull,
                      "modelContextWindow emitted as null when nil")
    }

    /// Phase 4e: the trust-report read methods parse to their cases (parameterless,
    /// like wiki/status) and round-trip back to their wire names.
    func testWikiTrustReportMethodsParseAndRoundTrip() throws {
        guard case .wikiLibrarianReport = try ClientRequest.parse(req("wiki/librarian/report", nil)) else {
            return XCTFail("wiki/librarian/report should parse to .wikiLibrarianReport")
        }
        guard case .wikiAuditReport = try ClientRequest.parse(req("wiki/audit/report", nil)) else {
            return XCTFail("wiki/audit/report should parse to .wikiAuditReport")
        }
        XCTAssertEqual(ClientRequest.wikiLibrarianReport(.int(1)).method, "wiki/librarian/report")
        XCTAssertEqual(ClientRequest.wikiAuditReport(.int(1)).method, "wiki/audit/report")
        XCTAssertTrue(ClientRequest.typedMethods.contains("wiki/librarian/report"))
        XCTAssertTrue(ClientRequest.typedMethods.contains("wiki/audit/report"))
    }

    /// Phase 5 curation reads parse + round-trip to their wire names.
    func testWikiCurationReadMethodsParseAndRoundTrip() throws {
        guard case .wikiInventoryList = try ClientRequest.parse(req("wiki/inventory/list", nil)) else { return XCTFail("inventory/list") }
        guard case .wikiDatasetList = try ClientRequest.parse(req("wiki/dataset/list", nil)) else { return XCTFail("dataset/list") }
        guard case .wikiCollectList = try ClientRequest.parse(req("wiki/collect/list", nil)) else { return XCTFail("collect/list") }
        XCTAssertEqual(ClientRequest.wikiInventoryList(.int(1)).method, "wiki/inventory/list")
        XCTAssertEqual(ClientRequest.wikiDatasetList(.int(1)).method, "wiki/dataset/list")
        XCTAssertEqual(ClientRequest.wikiCollectList(.int(1)).method, "wiki/collect/list")
        for m in ["wiki/inventory/list", "wiki/dataset/list", "wiki/collect/list"] {
            XCTAssertTrue(ClientRequest.typedMethods.contains(m), m)
        }
    }

    /// Research-session history read parses + round-trips to its wire name.
    func testWikiSessionsListMethodParsesAndRoundTrips() throws {
        guard case .wikiSessionsList = try ClientRequest.parse(req("wiki/sessions/list", nil)) else { return XCTFail("sessions/list") }
        XCTAssertEqual(ClientRequest.wikiSessionsList(.int(1)).method, "wiki/sessions/list")
        XCTAssertTrue(ClientRequest.typedMethods.contains("wiki/sessions/list"))
    }
}
