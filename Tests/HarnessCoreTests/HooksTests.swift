import XCTest
import Foundation
@testable import Observability
@testable import HarnessCore
@testable import Tools
@testable import ProtocolModel
@testable import WireProtocol
@testable import ModelClient
@testable import Persistence
@testable import InfraPrimitives

final class HooksTests: XCTestCase {

    // MARK: - HookDefinition decode

    func testHookDefinitionDecodeKebabAndCamel() throws {
        let dec = JSONDecoder()
        let a = try dec.decode(HookDefinition.self, from: Data(
            #"{"event":"pre-tool-use","matcher":"shell","command":"echo","timeout":5}"#.utf8))
        XCTAssertEqual(a.eventName, .preToolUse)
        XCTAssertEqual(a.matcher, "shell")
        XCTAssertEqual(a.command, "echo")
        XCTAssertEqual(a.timeoutSec, 5)

        let b = try dec.decode(HookDefinition.self, from: Data(
            #"{"eventName":"postToolUse","command":"x"}"#.utf8))
        XCTAssertEqual(b.eventName, .postToolUse)
        XCTAssertNil(b.matcher)
        XCTAssertEqual(b.command, "x")
        // Default matches upstream (`HookHandlerConfig::Command.timeout_sec
        // .unwrap_or(600)`). Previously 60s; see P4.7 / H-31.
        XCTAssertEqual(b.timeoutSec, 600)
    }

    // MARK: - timeout defaults (P4.7 / H-31)

    func testDefaultHookTimeoutMatchesUpstream() {
        XCTAssertEqual(HookDefinition.defaultTimeoutSec, 600,
                       "default hook timeout must match codex-rs (600s)")
        XCTAssertEqual(HookDefinition.defaultTimeoutMillis, 600_000)
        let def = HookDefinition(eventName: .preToolUse, command: "echo")
        XCTAssertEqual(def.timeoutSec, 600)
    }

    // MARK: - trust hash (P4.7 / H-30)

    /// Locked-in fixtures: computed from the upstream Rust binary
    /// `cargo run -p codex-config --example hookhash`, which round-trips the
    /// `NormalizedHookIdentity` through `toml::Value::try_from` and
    /// `codex_config::version_for_toml`. Any drift in our canonical-JSON
    /// hasher will trip this test.
    func testHookTrustHashMatchesUpstreamFormat() {
        let fixture1 = HookDefinition(
            eventName: .preToolUse, matcher: "Bash",
            command: "echo hi", timeoutSec: 60)
        XCTAssertEqual(
            HookEngine.currentHookHash(fixture1),
            "sha256:d5030d2a3c704b4a75fe25c5c7a47a1010ada427d56d9bb6c83aa830ce07ce90")

        let fixture2 = HookDefinition(
            eventName: .sessionStart, matcher: nil,
            command: "a", timeoutSec: 60)
        XCTAssertEqual(
            HookEngine.currentHookHash(fixture2),
            "sha256:e5e616cbaede3a46f84e7c45123309343cfa00f149ec622ac64785799b23b54c")
    }

    /// TOML normalization means two hooks.json entries that differ only by
    /// key whitespace, key order, or use of the camelCase vs snake_case event
    /// alias produce the same trust hash — which is the whole point of
    /// using a normalized identity instead of hashing the raw bytes.
    func testHookTrustHashRoundTripsViaNormalization() throws {
        func parseHook(_ json: String) throws -> [String: JSONValue] {
            let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            return v.objectValue!
        }
        // Differ in: key order, event spelling (kebab vs camel), spacing.
        let a = try parseHook(
            #"{"event":"pre-tool-use","matcher":"Bash","command":"x","timeout":60}"#)
        let b = try parseHook(
            #"{ "command" : "x" , "timeout":60, "eventName":"preToolUse" , "matcher":"Bash" }"#)
        let c = try parseHook(
            #"{"timeout":60,"matcher":"Bash","command":"x","event_name":"pre_tool_use"}"#)
        let h1 = HookEngine.currentHookHash(a)
        let h2 = HookEngine.currentHookHash(b)
        let h3 = HookEngine.currentHookHash(c)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h2, h3)
        XCTAssertTrue(h1.hasPrefix("sha256:"))
    }

    /// Trust state written by older Swift builds used the FNV-64 algorithm.
    /// Upgrading must not silently un-trust existing hooks: the engine must
    /// accept *either* the new SHA-256 hash or the legacy `fnv64:` hash.
    func testLoadAcceptsLegacyFnv64TrustHashForBackwardCompat() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "hkfnv-\(UUID().uuidString)"
        let cwd = NSTemporaryDirectory() + "hkfnvcwd-\(UUID().uuidString)"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cwd + "/.codex",
                               withIntermediateDirectories: true)
        let legacyHookJSON =
            #"{"event":"session-start","command":"legacy-trusted"}"#
        try #"{"hooks":[\#(legacyHookJSON)]}"#
            .write(toFile: home + "/hooks.json", atomically: true, encoding: .utf8)
        let parsed = try JSONDecoder().decode(JSONValue.self,
                                              from: Data(legacyHookJSON.utf8)).objectValue!
        let legacyHash = HookEngine.legacyHookHash(parsed)
        XCTAssertTrue(legacyHash.hasPrefix("fnv64:"))
        let key = home + "/hooks.json:session_start:0:0"
        try """
        [hooks.state."\(key)"]
        trusted_hash = "\(legacyHash)"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let exp = expectation(description: "legacy-fnv")
        Task {
            let engine = HookEngine.load(codexHome: home, cwd: cwd)
            let defs = await engine.definitions()
            XCTAssertEqual(defs.map(\.command), ["legacy-trusted"],
                           "legacy fnv64 trust hash must still load the hook")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    /// And the new SHA-256 path must also work: a hook with the
    /// upstream-format trusted_hash loads correctly.
    func testLoadAcceptsUpstreamSha256TrustHash() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "hksha-\(UUID().uuidString)"
        let cwd = NSTemporaryDirectory() + "hkshacwd-\(UUID().uuidString)"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cwd + "/.codex",
                               withIntermediateDirectories: true)
        let hookJSON = #"{"event":"stop","command":"cross-process"}"#
        try #"{"hooks":[\#(hookJSON)]}"#
            .write(toFile: home + "/hooks.json", atomically: true, encoding: .utf8)
        let parsed = try JSONDecoder().decode(JSONValue.self,
                                              from: Data(hookJSON.utf8)).objectValue!
        let upstreamHash = HookEngine.currentHookHash(parsed)
        XCTAssertTrue(upstreamHash.hasPrefix("sha256:"))
        let key = home + "/hooks.json:stop:0:0"
        try """
        [hooks.state."\(key)"]
        trusted_hash = "\(upstreamHash)"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let exp = expectation(description: "sha256")
        Task {
            let engine = HookEngine.load(codexHome: home, cwd: cwd)
            let defs = await engine.definitions()
            XCTAssertEqual(defs.map(\.command), ["cross-process"],
                           "upstream-compatible sha256 trust hash must load")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    // MARK: - load + merge

    func testLoadMergesHomeThenCwd() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "hkhome-\(UUID().uuidString)"
        let cwd = NSTemporaryDirectory() + "hkcwd-\(UUID().uuidString)"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cwd + "/.codex",
                               withIntermediateDirectories: true)
        let homeHook = #"{"event":"session-start","command":"a"}"#
        let projectHook = #"{"event":"stop","command":"b"}"#
        try #"{"hooks":[\#(homeHook)]}"#
            .write(toFile: home + "/hooks.json", atomically: true, encoding: .utf8)
        try #"[\#(projectHook)]"#
            .write(toFile: cwd + "/.codex/hooks.json",
                   atomically: true, encoding: .utf8)
        let homeKey = home + "/hooks.json:session_start:0:0"
        let projectKey = cwd + "/.codex/hooks.json:stop:0:0"
        let homeHash = try hookHash(homeHook)
        let projectHash = try hookHash(projectHook)
        try """
        [hooks.state."\(homeKey)"]
        trusted_hash = "\(homeHash)"

        [hooks.state."\(projectKey)"]
        trusted_hash = "\(projectHash)"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let exp = expectation(description: "load")
        Task {
            let engine = HookEngine.load(codexHome: home, cwd: cwd)
            let defs = await engine.definitions()
            XCTAssertEqual(defs.count, 2)
            XCTAssertEqual(defs[0].eventName, .sessionStart)
            XCTAssertEqual(defs[0].command, "a")
            XCTAssertEqual(defs[1].eventName, .stop)
            XCTAssertEqual(defs[1].command, "b")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testLoadSkipsUntrustedModifiedAndDisabledHooks() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "hkhome-\(UUID().uuidString)"
        let cwd = NSTemporaryDirectory() + "hkcwd-\(UUID().uuidString)"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cwd + "/.codex",
                               withIntermediateDirectories: true)
        let trusted = #"{"event":"session-start","command":"trusted"}"#
        let modified = #"{"event":"stop","command":"modified"}"#
        let disabled = #"{"event":"user-prompt-submit","command":"disabled"}"#
        let untrusted = #"{"event":"post-compact","command":"untrusted"}"#
        try #"{"hooks":[\#(trusted),\#(modified),\#(disabled),\#(untrusted)]}"#
            .write(toFile: home + "/hooks.json", atomically: true, encoding: .utf8)
        let path = home + "/hooks.json"
        let trustedKey = "\(path):session_start:0:0"
        let modifiedKey = "\(path):stop:1:0"
        let disabledKey = "\(path):user_prompt_submit:2:0"
        try """
        [hooks.state."\(trustedKey)"]
        trusted_hash = "\(try hookHash(trusted))"

        [hooks.state."\(modifiedKey)"]
        trusted_hash = "fnv64:stale"

        [hooks.state."\(disabledKey)"]
        trusted_hash = "\(try hookHash(disabled))"
        enabled = false
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let exp = expectation(description: "trust-filter")
        Task {
            let engine = HookEngine.load(codexHome: home, cwd: cwd)
            let defs = await engine.definitions()
            XCTAssertEqual(defs.map(\.command), ["trusted"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    private func hookHash(_ json: String) throws -> String {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard let object = value.objectValue else {
            XCTFail("hook test fixture must be an object")
            return ""
        }
        return HookEngine.stableHookHash(object)
    }

    // MARK: - matcher

    func testMatcherRegexNilAndNonMatch() {
        let exp = expectation(description: "matcher")
        Task {
            func fired(_ defs: [HookDefinition], _ tool: String) async -> Int {
                let e = HookEngine(hooks: defs)
                let o = await e.fire(.preToolUse, HookRequest(
                    eventName: .preToolUse, sessionId: "s", cwd: "/",
                    toolName: tool,
                    toolArgumentsJSON: "{}"))
                return o.count
            }
            let rx = HookDefinition(eventName: .preToolUse, matcher: "^sh",
                                    command: #"printf '{"decision":"allow"}'"#,
                                    timeoutSec: 5)
            let s1 = await fired([rx], "shell")
            let s2 = await fired([rx], "python")
            let nilM = HookDefinition(eventName: .preToolUse, matcher: nil,
                                      command: #"printf '{"decision":"allow"}'"#,
                                      timeoutSec: 5)
            let s3 = await fired([nilM], "whatever")
            let bad = HookDefinition(eventName: .preToolUse, matcher: "[",
                                     command: #"printf '{"decision":"allow"}'"#,
                                     timeoutSec: 5)
            let s4 = await fired([bad], "a[b")
            let s5 = await fired([bad], "abc")
            XCTAssertEqual(s1, 1)
            XCTAssertEqual(s2, 0)
            XCTAssertEqual(s3, 1)
            XCTAssertEqual(s4, 1)
            XCTAssertEqual(s5, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 20)
    }

    // MARK: - real /bin/sh hooks

    func testShellHookBlockViaExit2() {
        let exp = expectation(description: "exit2")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: "exit 2", timeoutSec: 5)])
            let o = await e.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: "shell", toolArgumentsJSON: "{}"))
            let agg = await e.aggregate(o)
            let reason = await e.blockingReason(o)
            XCTAssertEqual(o.count, 1)
            XCTAssertEqual(o.first?.decision, .block)
            XCTAssertEqual(agg, .block)
            XCTAssertNotNil(reason)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    /// P4.6 cosmetic parity: a Stop hook that exits with code 2 but writes
    /// nothing to stderr is treated by upstream
    /// (`hooks/src/events/stop.rs:213-220`) as `HookRunStatus::Failed` with
    /// NO block signal — the session is allowed to terminate. The Swift
    /// outcome therefore carries `decision: .allow`, `shouldBlock: false`,
    /// nil continuation, and surfaces the failure via `outputSchemaError`.
    func testStopHookExit2WithEmptyStderrDoesNotBlock() {
        let exp = expectation(description: "stop-exit2-empty")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .stop, matcher: nil,
                // No stderr / stdout — just exit 2.
                command: "exit 2", timeoutSec: 5)])
            let o = await e.fire(.stop, HookRequest(
                eventName: .stop, sessionId: "s", cwd: "/"))
            XCTAssertEqual(o.count, 1)
            let first = o.first
            XCTAssertEqual(first?.decision, .allow,
                           "Stop+exit2 with empty stderr must not block")
            XCTAssertFalse(first?.shouldBlock ?? true,
                           "shouldBlock must be false (matches upstream Failed status)")
            XCTAssertFalse(first?.shouldStop ?? true,
                           "shouldStop must be false")
            XCTAssertNil(first?.continuationPrompt,
                         "continuationPrompt must be nil (no prompt injected)")
            XCTAssertNotNil(first?.outputSchemaError,
                            "outputSchemaError must carry the divergence signal")
            // Aggregated Stop result reflects "no block, no stop".
            let agg = await e.aggregateStop(o)
            XCTAssertFalse(agg.shouldBlock)
            XCTAssertFalse(agg.shouldStop)
            XCTAssertNil(agg.continuationPrompt)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    func testShellHookBlockViaJSON() {
        let exp = expectation(description: "jsonblock")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: #"printf '{"decision":"block","reason":"nope"}'"#,
                timeoutSec: 5)])
            let o = await e.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: "shell", toolArgumentsJSON: "{}"))
            XCTAssertEqual(o.first?.decision, .block)
            XCTAssertEqual(o.first?.reason, "nope")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    func testShellHookAllowAndContextPassedOnStdin() {
        let exp = expectation(description: "allowctx")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: "cat", timeoutSec: 5)])
            let o = await e.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "sid", cwd: "/tmp",
                toolName: "shelltool", toolArgumentsJSON: "{}"))
            let first = o.first
            XCTAssertEqual(first?.decision, .allow)
            let raw = first?.raw ?? ""
            XCTAssertTrue(raw.contains(#""hook_event_name":"PreToolUse""#))
            XCTAssertTrue(raw.contains("shelltool"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    func testSlowHookTimesOutToAllow() {
        let exp = expectation(description: "timeout")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: "sleep 5", timeoutSec: 1)])
            let start = Date()
            let o = await e.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: "shell", toolArgumentsJSON: "{}"))
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(o.first?.decision, .allow)
            XCTAssertTrue((o.first?.reason ?? "").lowercased().contains("timed out"))
            XCTAssertLessThan(elapsed, 4)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }

    func testAggregate() {
        let e = HookEngine()
        let exp = expectation(description: "agg")
        Task {
            let allowOnly = await e.aggregate([
                HookOutcome(decision: .allow), HookOutcome(decision: .allow)])
            let withBlock = await e.aggregate([
                HookOutcome(decision: .allow), HookOutcome(decision: .block)])
            XCTAssertEqual(allowOnly, .allow)
            XCTAssertEqual(withBlock, .block)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testLegacyNotifyPayloadMatchesRustAfterAgentShape() throws {
        let json = try HookEngine.legacyNotifyJSON(.init(
            threadId: "b5f6c1c2-1111-2222-3333-444455556666",
            turnId: "12345",
            cwd: "/Users/example/project",
            client: "codex-tui",
            inputMessages: ["Rename `foo` to `bar` and update the callsites."],
            lastAssistantMessage: "Rename complete and verified `cargo build` succeeds."))
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(value?["type"] as? String, "agent-turn-complete")
        XCTAssertEqual(value?["thread-id"] as? String,
                       "b5f6c1c2-1111-2222-3333-444455556666")
        XCTAssertEqual(value?["turn-id"] as? String, "12345")
        XCTAssertEqual(value?["cwd"] as? String, "/Users/example/project")
        XCTAssertEqual(value?["client"] as? String, "codex-tui")
        XCTAssertEqual(value?["input-messages"] as? [String],
                       ["Rename `foo` to `bar` and update the callsites."])
        XCTAssertEqual(value?["last-assistant-message"] as? String,
                       "Rename complete and verified `cargo build` succeeds.")
    }

    func testSessionEngineFiresLegacyNotifyAfterCompletedAgentTurn() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        let out = home + "/notify.json"
        let script = #"printf '%s' "$1" > "\#(out)""#
        let cfg = SessionConfig(threadId: tid, cwd: "/w",
                                notify: ["/bin/sh", "-c", script, "notify"])
        _ = try await store.create(cfg)
        let engine = SessionEngine(
            config: cfg,
            model: MockModelClient([.hello("notify done")]),
            store: store,
            router: ToolRouter(limits: Limits()),
            limits: Limits())

        let notes = await driveAndCollect(engine)
        XCTAssertTrue(notes.contains {
            if case .turnCompleted(_, let turn) = $0 {
                return turn.status == .completed
            }
            return false
        })

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: out), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let text = try String(contentsOfFile: out, encoding: .utf8)
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(payload?["type"] as? String, "agent-turn-complete")
        XCTAssertEqual(payload?["thread-id"] as? String, tid.raw)
        XCTAssertEqual(payload?["cwd"] as? String, "/w")
        XCTAssertEqual(payload?["input-messages"] as? [String], ["go"])
        XCTAssertEqual(payload?["last-assistant-message"] as? String, "notify done")
        XCTAssertNotNil(payload?["turn-id"] as? String)
    }

    // MARK: - SessionEngine integration

    private final class RanFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        func mark() { lock.lock(); v = true; lock.unlock() }
        func value() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    private struct StubTool: Tool {
        let name = "stub"
        let parallelSafe = true
        let flag: RanFlag
        func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
            flag.mark()
            return ToolResult(callId: call.callId, output: "stub ran",
                              success: true, truncated: false)
        }
    }

    private func makeStore() throws -> (ThreadStore, String) {
        let home = NSTemporaryDirectory() + "hkstore-\(UUID().uuidString)"
        return (try ThreadStore(codexHome: home, limits: Limits()), home)
    }

    private func toolThenDoneModel() -> MockModelClient {
        MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "stub", argumentsJSON: "{}"),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "r2", tokens: 1)]),
        ])
    }

    private func driveAndCollect(_ engine: SessionEngine) async -> [ServerNotification] {
        var notes: [ServerNotification] = []
        let stream = await engine.events()
        let collector = Task { () -> [ServerNotification] in
            var acc: [ServerNotification] = []
            for await n in stream {
                acc.append(n)
                if case .turnCompleted = n { break }
            }
            return acc
        }
        await engine.start()
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil))
        notes = await collector.value
        return notes
    }

    func testSessionEnginePreToolHookBlocksTool() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let flag = RanFlag()
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let router = ToolRouter(limits: Limits())
        await router.register(StubTool(flag: flag))
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: toolThenDoneModel(), store: store, router: router,
            limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: "exit 2", timeoutSec: 5)]))

        let notes = await driveAndCollect(engine)

        var sawDeclined = false
        for n in notes {
            if case .itemCompleted(_, _, let item) = n,
               case .commandExecution(_, _, _, let status, let out, _) = item,
               status == .declined,
               (out ?? "").contains("blocked by hook") {
                sawDeclined = true
            }
        }
        XCTAssertTrue(sawDeclined, "tool call should be declined by the hook")
        XCTAssertFalse(flag.value(), "stub tool must not have run")
    }

    func testSessionEngineNoHooksUnchanged() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let flag = RanFlag()
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let router = ToolRouter(limits: Limits())
        await router.register(StubTool(flag: flag))
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: toolThenDoneModel(), store: store, router: router,
            limits: Limits())

        let notes = await driveAndCollect(engine)

        var sawCompleted = false
        for n in notes {
            if case .itemCompleted(_, _, let item) = n,
               case .commandExecution(_, _, _, let status, _, _) = item,
               status == .completed {
                sawCompleted = true
            }
        }
        XCTAssertTrue(sawCompleted, "stub tool should run normally with no hooks")
        XCTAssertTrue(flag.value(), "stub tool side effect must occur")
    }

    // MARK: - P4.5 / C10: PreCompact / PostCompact wiring

    /// Compaction model: a single scenario that streams a tiny summary and
    /// completes. Used by the manual `/compact` tests below.
    private func compactionModel() -> MockModelClient {
        MockModelClient([
            MockScenario([
                .created,
                .agentDone(itemId: "compact-1", "summary"),
                .completeEndTurn(responseId: "rc", tokens: 1),
            ]),
        ])
    }

    private func driveCompact(_ engine: SessionEngine) async -> [ServerNotification] {
        // Mirrors `driveAndCollect` but issues `.compactNow` instead of
        // `.startTurn`. The stream is obtained BEFORE the submit so the
        // collector Task captures only the stream (Sendable), not the engine.
        let stream = await engine.events()
        let collector = Task { () -> [ServerNotification] in
            var acc: [ServerNotification] = []
            for await n in stream {
                acc.append(n)
                if case .turnCompleted = n { break }
            }
            return acc
        }
        await engine.start()
        await engine.submit(.compactNow)
        return await collector.value
    }

    func testPreCompactHookFires() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let marker = home + "/precompact.touch"
        // The hook writes a marker file when it fires so the test can observe
        // the side effect without coupling to internal hook plumbing.
        let cmd = #"printf '{"hookSpecificOutput":{"hookEventName":"PreCompact","additionalContext":""}}' && touch '\#(marker)'"#
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: compactionModel(), store: store,
            router: ToolRouter(limits: Limits()),
            limits: Limits(),
            autoCompactTokens: 10_000,
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .preCompact, matcher: nil,
                command: cmd, timeoutSec: 5)]))
        _ = await driveCompact(engine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker),
                      "PreCompact hook should fire before the model call")
    }

    func testPreCompactHookBlocksCompaction() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // exit 2 → block decision (mirrors upstream PreCompact short-circuit).
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: compactionModel(), store: store,
            router: ToolRouter(limits: Limits()),
            limits: Limits(),
            autoCompactTokens: 10_000,
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .preCompact, matcher: nil,
                command: "exit 2", timeoutSec: 5)]))
        let events = await driveCompact(engine)
        let aborted = events.contains { ev in
            if case .turnCompleted(_, let turn) = ev {
                return turn.status == .failed
            }
            return false
        }
        XCTAssertTrue(aborted,
                      "PreCompact hook returning block must abort compaction; events=\(events.map(\.method))")
    }

    /// P4.5 / F2 — PreCompact may also block via the structured wire form
    /// `{"continue":false,"stopReason":"..."}` (exit 0). This is the
    /// upstream-canonical block path; the prior `exit 2` test exercises the
    /// legacy short-circuit. Both must abort compaction identically.
    func testPreCompactHookBlocksViaContinueFalse() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: compactionModel(), store: store,
            router: ToolRouter(limits: Limits()),
            limits: Limits(),
            autoCompactTokens: 10_000,
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .preCompact, matcher: nil,
                command: #"printf '{"continue":false,"stopReason":"compaction-blocked-by-policy"}'"#,
                timeoutSec: 5)]))
        let events = await driveCompact(engine)
        let aborted = events.contains { ev in
            if case .turnCompleted(_, let turn) = ev {
                return turn.status == .failed
            }
            return false
        }
        XCTAssertTrue(aborted,
                      "PreCompact hook returning {continue:false} must abort compaction; events=\(events.map(\.method))")
    }

    func testPostCompactHookFires() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let marker = home + "/postcompact.touch"
        let cmd = "touch '\(marker)' && printf '{}'"
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: compactionModel(), store: store,
            router: ToolRouter(limits: Limits()),
            limits: Limits(),
            autoCompactTokens: 10_000,
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .postCompact, matcher: nil,
                command: cmd, timeoutSec: 5)]))
        let events = await driveCompact(engine)
        let completed = events.contains { ev in
            if case .turnCompleted(_, let turn) = ev {
                return turn.status == .completed
            }
            return false
        }
        XCTAssertTrue(completed, "compaction must complete; events=\(events.map(\.method))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker),
                      "PostCompact hook should fire after compaction completes")
    }

    // MARK: - P4.5 / C10: PermissionRequest hook wiring

    func testPermissionRequestHookCanAutoApprove() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let flag = RanFlag()
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let router = ToolRouter(limits: Limits())
        // Register a gated tool ("shell" is .command in ApprovalPolicyEngine).
        // We use a custom tool name not in the gated list AND verify the
        // PermissionRequest hook can still allow a gated tool. Use the actual
        // `shell` gated-tool path: but since approvals is nil + isAutoReview
        // is off, the existing guard skips approval entirely. To exercise the
        // PermissionRequest allow path we need approvals coordinator set OR
        // the gated path to be hit. Use a recording stub coordinator that
        // ALWAYS denies; the hook's allow must short-circuit before it runs.
        struct AlwaysDenyCoordinator: ApprovalCoordinator {
            func requestApproval(_ request: ServerRequest) async -> ApprovalDecision {
                .decline
            }
        }
        await router.register(StubGatedTool(flag: flag))
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w",
                                  approvalPolicy: .onRequest),
            model: gatedToolThenDoneModel(),
            store: store, router: router, limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .permissionRequest, matcher: nil,
                command: #"printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'"#,
                timeoutSec: 5)]))
        await engine.setApprovalCoordinator(AlwaysDenyCoordinator())
        let notes = await driveAndCollect(engine)
        var sawCompleted = false
        for n in notes {
            if case .itemCompleted(_, _, let item) = n,
               case .commandExecution(_, _, _, let status, _, _) = item,
               status == .completed {
                sawCompleted = true
            }
        }
        XCTAssertTrue(sawCompleted,
                      "PermissionRequest hook allow must short-circuit user approval and run the tool")
        XCTAssertTrue(flag.value(),
                      "stub gated tool must have run after PermissionRequest hook allowed it")
    }

    func testPermissionRequestHookCanDeny() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let flag = RanFlag()
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let router = ToolRouter(limits: Limits())
        await router.register(StubGatedTool(flag: flag))
        struct AcceptAllCoordinator: ApprovalCoordinator {
            func requestApproval(_ request: ServerRequest) async -> ApprovalDecision {
                .accept
            }
        }
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w",
                                  approvalPolicy: .onRequest),
            model: gatedToolThenDoneModel(),
            store: store, router: router, limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .permissionRequest, matcher: nil,
                command: #"printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"hook said no"}}}'"#,
                timeoutSec: 5)]))
        await engine.setApprovalCoordinator(AcceptAllCoordinator())
        let notes = await driveAndCollect(engine)
        var sawDeclined = false
        for n in notes {
            if case .itemCompleted(_, _, let item) = n,
               case .commandExecution(_, _, _, let status, let out, _) = item,
               status == .declined, (out ?? "").contains("hook said no") {
                sawDeclined = true
            }
        }
        XCTAssertTrue(sawDeclined,
                      "PermissionRequest hook deny must short-circuit the approval coordinator")
        XCTAssertFalse(flag.value(),
                       "stub gated tool must not have run when the hook denies")
    }

    // MARK: - P4.5 / C11: hookSpecificOutput parsing

    func testHookSpecificOutputUpdatedInputRewritesToolArgs() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recorder = ArgsRecorder()
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let router = ToolRouter(limits: Limits())
        await router.register(RecordingTool(recorder: recorder))
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: recordingToolThenDoneModel(),
            store: store, router: router, limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: #"printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"value":"rewritten"}}}'"#,
                timeoutSec: 5)]))
        _ = await driveAndCollect(engine)
        let observed = recorder.value()
        XCTAssertEqual(observed,
                       #"{"value":"rewritten"}"#,
                       "PreToolUse hook permissionDecision:allow + updatedInput must rewrite the tool args; got: \(observed ?? "nil")")
    }

    func testHookSpecificOutputAdditionalContextSurfacedOnPreToolUseAllow() async throws {
        // Sanity: a hook returning permissionDecision:allow without
        // updatedInput must NOT block and must NOT modify the args. The
        // additionalContext field is currently captured into the outcome but
        // not injected at SessionEngine level; this test pins the contract so
        // a future regression that drops `additionalContext` from the parser
        // is caught.
        let req = HookRequest(eventName: .preToolUse, sessionId: "s",
                              cwd: "/", toolName: "shell",
                              toolArgumentsJSON: "{}")
        let engine = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"please be careful"}}'"#,
            timeoutSec: 5)])
        let outcomes = await engine.fire(.preToolUse, req)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.decision, .allow)
        XCTAssertEqual(outcomes.first?.additionalContext,
                       "please be careful")
        XCTAssertEqual(outcomes.first?.hookSpecificOutput?.additionalContext,
                       "please be careful")
    }

    func testLegacyFlatKeysStillWork() async throws {
        // Hook returning the legacy `decision:block` + `reason` shape (no
        // hookSpecificOutput) must keep blocking. P4.5 must NOT regress this.
        let engine = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"decision":"block","reason":"legacy nope"}'"#,
            timeoutSec: 5)])
        let outcomes = await engine.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        XCTAssertEqual(outcomes.first?.decision, .block)
        XCTAssertEqual(outcomes.first?.reason, "legacy nope")

        // And the legacy `additionalContext` (flat) on a PostToolUse hook
        // still flows through to the outcome.
        let post = HookEngine(hooks: [HookDefinition(
            eventName: .postToolUse, matcher: nil,
            command: #"printf '{"additionalContext":"legacy ctx"}'"#,
            timeoutSec: 5)])
        let postOutcomes = await post.fire(.postToolUse, HookRequest(
            eventName: .postToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        XCTAssertEqual(postOutcomes.first?.additionalContext, "legacy ctx")
    }

    // MARK: - Stubs for permission/rewrite integration

    private final class ArgsRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: String?
        func record(_ s: String) { lock.lock(); seen = s; lock.unlock() }
        func value() -> String? { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private struct RecordingTool: Tool {
        let name = "recorder"
        let parallelSafe = true
        let recorder: ArgsRecorder
        func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
            recorder.record(call.argumentsJSON)
            return ToolResult(callId: call.callId, output: "ok",
                              success: true, truncated: false)
        }
    }

    private struct StubGatedTool: Tool {
        // Approval policy gates tools by hard-coded name list. We override
        // tool name to "shell" so ApprovalPolicyEngine.op(forTool:) returns
        // .command, exercising the PermissionRequest gating path.
        let name = "shell"
        let parallelSafe = false
        let flag: RanFlag
        func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
            flag.mark()
            return ToolResult(callId: call.callId, output: "shell ran",
                              success: true, truncated: false)
        }
    }

    private func gatedToolThenDoneModel() -> MockModelClient {
        MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "g1", name: "shell",
                                    argumentsJSON: #"{"command":["echo","hi"]}"#),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "r2", tokens: 1)]),
        ])
    }

    private func recordingToolThenDoneModel() -> MockModelClient {
        MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "r1", name: "recorder",
                                    argumentsJSON: #"{"value":"original"}"#),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "r2", tokens: 1)]),
        ])
    }

    // MARK: - P4.6 / H-27, H-28, H-29, H-40

    /// Drop the hook's stdin to a temp file and return the parsed JSON. The
    /// hook command is `cat > <file>` so the entire payload is preserved. We
    /// also `printf '{"continue":true}'` afterwards so the hook returns
    /// `.allow` and the engine surfaces the run as a normal allow outcome.
    private func captureHookStdin(eventName: HookEventName,
                                  request: HookRequest) async throws
        -> [String: Any] {
        let path = NSTemporaryDirectory() + "hkstdin-\(UUID().uuidString).json"
        let cmd = #"cat > '\#(path)' && printf '{"continue":true}'"#
        let engine = HookEngine(hooks: [HookDefinition(
            eventName: eventName, matcher: nil,
            command: cmd, timeoutSec: 5)])
        _ = await engine.fire(eventName, request)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("hook stdin not a JSON object")
            return [:]
        }
        return obj
    }

    // MARK: - P4.5 / F3, F4 — warning-log paths (allow without updatedInput,
    //         deny without permissionDecisionReason)

    /// F3: permissionDecision:allow without updatedInput logs a warning but
    /// must NOT block and must NOT modify the tool args (the allow is
    /// effectively a no-op pass-through).
    func testPreToolUseAllowWithoutUpdatedInputDoesNotBlock() async throws {
        FeedbackLogStore.shared.clear()
        let req = HookRequest(eventName: .preToolUse, sessionId: "s",
                              cwd: "/", toolName: "shell",
                              toolArgumentsJSON: #"{"command":"ls"}"#)
        let engine = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'"#,
            timeoutSec: 5)])
        let outcomes = await engine.fire(.preToolUse, req)
        XCTAssertEqual(outcomes.count, 1)
        // No block — the invalid allow is treated as a pass-through.
        XCTAssertEqual(outcomes.first?.decision, .allow,
                       "F3: allow without updatedInput must not block")
        // No updatedInput propagated.
        XCTAssertNil(outcomes.first?.hookSpecificOutput?.updatedInputJSON,
                     "F3: no updatedInputJSON expected when updatedInput is absent")
        // F3: the warning itself must have been emitted (the whole point of
        // this fix). Upstream raises `unsupported_pre_tool_use_hook_specific_output`
        // with the exact string "PreToolUse hook returned unsupported
        // permissionDecision:allow"; we match byte-for-byte.
        let warned = FeedbackLogStore.shared.snapshot().contains { entry in
            entry.level == .warn && entry.category == "HookEngine"
                && entry.message
                    == "PreToolUse hook returned unsupported permissionDecision:allow"
        }
        XCTAssertTrue(warned,
                      "F3: a warn-level HookEngine log matching upstream's exact string must be emitted")
        // The outcome must also carry the schema-error signal so callers can
        // mirror upstream's `HookRunStatus::Failed` if they want to.
        XCTAssertEqual(
            outcomes.first?.outputSchemaError,
            "PreToolUse hook returned unsupported permissionDecision:allow",
            "F3: outputSchemaError must mirror upstream's HookRunStatus::Failed message")
    }

    /// F4: permissionDecision:deny without permissionDecisionReason logs a
    /// warning. The deny should still take effect (fall back to the generic
    /// deny path — upstream also marks this invalid but the deny still
    /// propagates through the hook outcome).
    func testPreToolUseDenyWithoutReasonStillDenies() async throws {
        FeedbackLogStore.shared.clear()
        let req = HookRequest(eventName: .preToolUse, sessionId: "s",
                              cwd: "/", toolName: "shell",
                              toolArgumentsJSON: #"{"command":"ls"}"#)
        let engine = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}'"#,
            timeoutSec: 5)])
        let outcomes = await engine.fire(.preToolUse, req)
        XCTAssertEqual(outcomes.count, 1)
        // The deny decision is captured in hookSpecificOutput even though no
        // permissionDecisionReason was supplied. The warning fires, but the
        // deny is still surfaced so SessionEngine can act on it.
        XCTAssertEqual(outcomes.first?.hookSpecificOutput?.permissionDecision, .deny,
                       "F4: deny without permissionDecisionReason must still be captured as deny")
        // F4: the warning itself must have been emitted. Upstream raises
        // `invalid_pre_tool_use_reason_message` — the Swift warn must match.
        let warned = FeedbackLogStore.shared.snapshot().contains { entry in
            entry.level == .warn && entry.category == "HookEngine"
                && entry.message.contains("permissionDecision:deny")
                && entry.message.contains("permissionDecisionReason")
        }
        XCTAssertTrue(warned,
                      "F4: a warn-level HookEngine log mentioning permissionDecision:deny + permissionDecisionReason must be emitted")
    }

    func testHookStdinUsesPascalCaseEventName() async throws {
        // Every hook event must emit `hook_event_name` in PascalCase
        // (`PreToolUse`, `Stop`, …) on stdin — see upstream
        // `codex_hooks::schema::HookEventNameWire`. Pre-P4.6 we sent the
        // kebab-case form, breaking hooks that branched on this field.
        let cases: [(HookEventName, String)] = [
            (.preToolUse, "PreToolUse"),
            (.permissionRequest, "PermissionRequest"),
            (.postToolUse, "PostToolUse"),
            (.preCompact, "PreCompact"),
            (.postCompact, "PostCompact"),
            (.sessionStart, "SessionStart"),
            (.userPromptSubmit, "UserPromptSubmit"),
            (.stop, "Stop"),
        ]
        for (ev, expected) in cases {
            let stdin = try await captureHookStdin(
                eventName: ev,
                request: HookRequest(eventName: ev, sessionId: "s",
                                     cwd: "/", model: "gpt-x",
                                     permissionMode: "default"))
            XCTAssertEqual(stdin["hook_event_name"] as? String, expected,
                           "expected PascalCase \(expected) on stdin for \(ev)")
        }
    }

    func testHookStdinIncludesTurnIdModelPermissionMode() async throws {
        // Every turn-scoped hook event sends `turn_id`, `model`,
        // `permission_mode`, and `transcript_path` on stdin (P4.6 / H-28).
        let req = HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/cwd",
            toolName: "shell", toolArgumentsJSON: #"{"command":"x"}"#,
            turnId: "t-42", model: "gpt-5.1-codex",
            permissionMode: "default",
            transcriptPath: "/codex/sessions/s.rollout.jsonl")
        let stdin = try await captureHookStdin(eventName: .preToolUse, request: req)
        XCTAssertEqual(stdin["turn_id"] as? String, "t-42")
        XCTAssertEqual(stdin["model"] as? String, "gpt-5.1-codex")
        XCTAssertEqual(stdin["permission_mode"] as? String, "default")
        XCTAssertEqual(stdin["transcript_path"] as? String,
                       "/codex/sessions/s.rollout.jsonl")
        XCTAssertEqual(stdin["tool_name"] as? String, "shell")
        let toolInput = stdin["tool_input"] as? [String: Any]
        XCTAssertEqual(toolInput?["command"] as? String, "x")
    }

    func testHookStdinSessionStartIncludesSource() async throws {
        // SessionStart sends `source` ("startup"/"resume"/"clear") and OMITS
        // `turn_id` (upstream `SessionStartCommandInput` has no turn_id).
        let req = HookRequest(eventName: .sessionStart, sessionId: "s",
                              cwd: "/", model: "m", permissionMode: "default",
                              source: "startup")
        let stdin = try await captureHookStdin(eventName: .sessionStart, request: req)
        XCTAssertEqual(stdin["source"] as? String, "startup")
        XCTAssertNil(stdin["turn_id"],
                     "SessionStart must NOT include turn_id (upstream parity)")

        let req2 = HookRequest(eventName: .sessionStart, sessionId: "s",
                               cwd: "/", model: "m", permissionMode: "default",
                               source: "resume")
        let stdin2 = try await captureHookStdin(eventName: .sessionStart, request: req2)
        XCTAssertEqual(stdin2["source"] as? String, "resume")
    }

    func testHookStdinStopIncludesStopHookActiveAndLastMessage() async throws {
        // Stop sends `stop_hook_active` (bool) and `last_assistant_message`
        // (nullable). Upstream `StopCommandInput`.
        let reqNoMsg = HookRequest(eventName: .stop, sessionId: "s",
                                    cwd: "/", turnId: "t-1", model: "m",
                                    permissionMode: "default",
                                    stopHookActive: false,
                                    lastAssistantMessage: nil)
        let stdinNoMsg = try await captureHookStdin(eventName: .stop, request: reqNoMsg)
        XCTAssertEqual(stdinNoMsg["stop_hook_active"] as? Bool, false)
        XCTAssertTrue(stdinNoMsg["last_assistant_message"] is NSNull)

        let reqMsg = HookRequest(eventName: .stop, sessionId: "s",
                                  cwd: "/", turnId: "t-1", model: "m",
                                  permissionMode: "default",
                                  stopHookActive: true,
                                  lastAssistantMessage: "we are done")
        let stdinMsg = try await captureHookStdin(eventName: .stop, request: reqMsg)
        XCTAssertEqual(stdinMsg["stop_hook_active"] as? Bool, true)
        XCTAssertEqual(stdinMsg["last_assistant_message"] as? String,
                       "we are done")
    }

    func testPostToolUseUsesToolResponseNotToolOutput() async throws {
        // Upstream `PostToolUseCommandInput.tool_response`. Pre-P4.6 we
        // emitted `tool_output`.
        let req = HookRequest(
            eventName: .postToolUse, sessionId: "s", cwd: "/",
            toolName: "shell",
            toolArgumentsJSON: "{}",
            toolOutput: #"{"ok":true,"data":42}"#,
            turnId: "t-3", model: "m", permissionMode: "default")
        let stdin = try await captureHookStdin(eventName: .postToolUse, request: req)
        XCTAssertNil(stdin["tool_output"],
                     "PostToolUse must NOT carry the legacy tool_output key")
        let toolResponse = stdin["tool_response"] as? [String: Any]
        XCTAssertNotNil(toolResponse,
                        "PostToolUse must carry the tool_response key")
        XCTAssertEqual(toolResponse?["ok"] as? Bool, true)
        XCTAssertEqual(toolResponse?["data"] as? Int, 42)
    }

    func testStopHookContinueFalseTerminatesSession() async throws {
        // `continue: false` in a Stop hook output must terminate the session
        // (upstream `events/stop.rs::aggregate_results.should_stop`). It must
        // NOT inject a continuation prompt, and the regular-turn loop must
        // see a single completed turn (no re-entry).
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: MockModelClient([.hello("done")]),
            store: store,
            router: ToolRouter(limits: Limits()),
            limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .stop, matcher: nil,
                command: #"printf '{"continue":false,"stopReason":"early stop"}'"#,
                timeoutSec: 5)]))

        let notes = await driveAndCollect(engine)
        var sawCompleted = false
        var userMessageCount = 0
        for n in notes {
            if case .turnCompleted(_, let turn) = n {
                XCTAssertEqual(turn.status, .completed,
                               "continue:false must complete (not fail) the turn")
                sawCompleted = true
            }
            if case .itemStarted(_, _, let item) = n,
               case .userMessage = item {
                userMessageCount += 1
            }
        }
        XCTAssertTrue(sawCompleted, "must see a single completed turn")
        // One user message for the initial input, no continuation injected.
        XCTAssertEqual(userMessageCount, 1,
                       "continue:false must NOT inject a continuation prompt; got \(userMessageCount) user messages")
    }

    func testStopHookDecisionBlockInjectsContinuationPrompt() async throws {
        // `decision:"block"` + non-empty `reason` must inject the reason as a
        // user-role message and re-enter sampling (upstream
        // `session/turn.rs:554-564`).
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // First Stop call: block + reason "please continue". Second Stop call:
        // allow (so the second iteration terminates cleanly without an
        // infinite loop). The Stop hook script switches behaviour using a
        // marker file: first call exits with block, second call sees the
        // marker and exits with allow.
        let marker = home + "/stopblock.marker"
        let cmd = """
        if [ -f '\(marker)' ]; then
          printf '{"continue":true}'
        else
          touch '\(marker)'
          printf '{"decision":"block","reason":"please continue"}'
        fi
        """
        // Two model scenarios so the second sampling iteration (after
        // continuation prompt is injected) has a model response queued.
        let model = MockModelClient([
            MockScenario([.created,
                          .agentDone(itemId: "m1", "first answer"),
                          .completeEndTurn(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "m2", "second answer"),
                          .completeEndTurn(responseId: "r2", tokens: 1)]),
        ])
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: model, store: store,
            router: ToolRouter(limits: Limits()),
            limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .stop, matcher: nil,
                command: cmd, timeoutSec: 5)]))

        let notes = await driveAndCollect(engine)
        var userMessageTexts: [String] = []
        var completedTurns = 0
        for n in notes {
            if case .itemStarted(_, _, let item) = n,
               case .userMessage(_, let content) = item {
                userMessageTexts.append(content.first?.text ?? "")
            }
            if case .turnCompleted = n { completedTurns += 1 }
        }
        XCTAssertEqual(completedTurns, 1, "expected single completed turn")
        // Initial "go" + injected "please continue" → 2 user-message items.
        XCTAssertEqual(userMessageTexts.count, 2,
                       "Stop hook decision:block must inject a continuation user message; got: \(userMessageTexts)")
        XCTAssertEqual(userMessageTexts.last, "please continue",
                       "injected continuation prompt must match the hook reason")
    }
}
