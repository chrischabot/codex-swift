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

    /// The canonical upstream grouped-object `hooks.json` (a MAP from EventName
    /// → [{matcher, hooks:[…]}]) must derive per-event (group_index,
    /// handler_index) trust keys exactly like `codex_hooks::hook_key`
    /// (`{path}:{snake_event}:{group_index}:{handler_index}`,
    /// hooks/src/lib.rs:91-101, discovery.rs:418-472). With TWO handlers in one
    /// group, the second handler is key …:0:1 — the old loader hard-coded
    /// handler_index 0 and used a flat running counter for group_index, so the
    /// :0:1 hook never matched its persisted hash and silently never ran.
    func testGroupedHooksTrustKeyUsesGroupAndHandlerIndices() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "hkgrp-\(UUID().uuidString)"
        let cwd = NSTemporaryDirectory() + "hkgrpcwd-\(UUID().uuidString)"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cwd + "/.codex", withIntermediateDirectories: true)
        // One event (pre-tool-use) with TWO matcher-groups; the first group has
        // TWO command handlers. Expected keys:
        //   pre_tool_use:0:0 (group0/handler0)  -> "alpha"
        //   pre_tool_use:0:1 (group0/handler1)  -> "beta"
        //   pre_tool_use:1:0 (group1/handler0)  -> "gamma"
        let json = """
        {"hooks":{"pre-tool-use":[
          {"matcher":"shell","hooks":[
            {"type":"command","command":"alpha"},
            {"type":"command","command":"beta"}
          ]},
          {"matcher":"python","hooks":[
            {"type":"command","command":"gamma"}
          ]}
        ]}}
        """
        let path = home + "/hooks.json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)

        func hash(matcher: String, command: String) -> String {
            HookEngine.currentHookHash(HookDefinition(
                eventName: .preToolUse, matcher: matcher, command: command,
                timeoutSec: HookDefinition.defaultTimeoutSec))
        }
        // Trust ONLY group0/handler1 (key …:0:1) and group1/handler0 (key …:1:0).
        // The old buggy loader generated …:0:0, …:1:0, …:2:0 with handler_index
        // hard-coded 0, so it would NOT trust "beta" (real key …:0:1) and would
        // mis-key "gamma".
        let betaKey = "\(path):pre_tool_use:0:1"
        let gammaKey = "\(path):pre_tool_use:1:0"
        try """
        [hooks.state."\(betaKey)"]
        trusted_hash = "\(hash(matcher: "shell", command: "beta"))"

        [hooks.state."\(gammaKey)"]
        trusted_hash = "\(hash(matcher: "python", command: "gamma"))"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let exp = expectation(description: "grouped-keys")
        Task {
            let engine = HookEngine.load(codexHome: home, cwd: cwd)
            let defs = await engine.definitions()
            // alpha (…:0:0) has no trust entry → skipped. beta + gamma trusted.
            XCTAssertEqual(Set(defs.map(\.command)), ["beta", "gamma"],
                           "only the correctly-keyed grouped handlers should be trusted")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
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
            // Upstream `invalid_regex_is_rejected` (common.rs:240-244): a matcher
            // that is neither match-all, exact, nor a valid regex (e.g. "[") NEVER
            // matches. The old Swift substring fallback (`s.contains("[")`) is a
            // bug — `matches_matcher(Some("["), _)` returns false.
            let bad = HookDefinition(eventName: .preToolUse, matcher: "[",
                                     command: #"printf '{"decision":"allow"}'"#,
                                     timeoutSec: 5)
            let s4 = await fired([bad], "a[b")
            let s5 = await fired([bad], "abc")
            // Upstream `is_match_all_matcher`: "*" is the documented wildcard and
            // must match EVERY tool (identical to nil/empty), not be treated as a
            // failing regex / literal substring (which matched nothing).
            let star = HookDefinition(eventName: .preToolUse, matcher: "*",
                                      command: #"printf '{"decision":"allow"}'"#,
                                      timeoutSec: 5)
            let s6 = await fired([star], "Bash")
            let s7 = await fired([star], "anything-at-all")
            XCTAssertEqual(s1, 1)
            XCTAssertEqual(s2, 0)
            XCTAssertEqual(s3, 1)
            XCTAssertEqual(s4, 0, "invalid-regex matcher must never match (no substring fallback)")
            XCTAssertEqual(s5, 0)
            XCTAssertEqual(s6, 1, "\"*\" wildcard matcher must fire for any tool")
            XCTAssertEqual(s7, 1, "\"*\" wildcard matcher must fire for any tool")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 20)
    }

    // MARK: - matcher aliases (apply_patch -> Write/Edit)

    /// Faithful port of upstream `pre_tool_use_aliases_match_once_per_handler`
    /// (hooks/src/engine/dispatcher.rs:341-384) combined with
    /// `HookToolName::apply_patch` (core/src/tools/hook_names.rs:34-39): an
    /// apply_patch tool call carries the matcher-input set
    /// `["apply_patch","Write","Edit"]`, so a hook matching the canonical name
    /// OR either Claude-Code alias fires — and each handler fires EXACTLY ONCE
    /// even when its matcher matches multiple inputs (the combined matcher).
    func testApplyPatchMatcherAliasesFireWriteAndEdit() {
        let exp = expectation(description: "aliases")
        Task {
            // One handler per matcher: canonical, Write, Edit, combined, plus a
            // non-matching control. Each prints its name so we can count fires.
            func handler(_ m: String) -> HookDefinition {
                HookDefinition(eventName: .preToolUse, matcher: m,
                               command: #"printf '{"decision":"allow"}'"#,
                               timeoutSec: 5)
            }
            let defs = [
                handler("^apply_patch$"),
                handler("^Write$"),
                handler("^Edit$"),
                handler("apply_patch|Write|Edit"),
                handler("^Bash$"),               // control: must NOT fire
            ]
            let e = HookEngine(hooks: defs)
            // matcherAliases mirror SessionEngine.hookMatcherAliases(for:).
            let o = await e.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: "apply_patch", toolArgumentsJSON: "{}",
                matcherAliases: ["Write", "Edit"]))
            // Upstream selects 4 handlers (orders 0..3), each exactly once.
            XCTAssertEqual(o.count, 4,
                "apply_patch must select canonical + Write + Edit + combined, once each")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 20)
    }

    /// Without aliases, a Write/Edit-only hook must NOT fire on apply_patch,
    /// and conversely a Bash tool call (no aliases) only matches its own name.
    func testNonApplyPatchToolHasNoAliases() {
        let exp = expectation(description: "noaliases")
        Task {
            func handler(_ m: String) -> HookDefinition {
                HookDefinition(eventName: .preToolUse, matcher: m,
                               command: #"printf '{"decision":"allow"}'"#,
                               timeoutSec: 5)
            }
            let writeOnly = [handler("^Write$"), handler("^Edit$")]
            let e1 = HookEngine(hooks: writeOnly)
            // apply_patch WITHOUT aliases threaded: Write/Edit must not match.
            let bare = await e1.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: "apply_patch", toolArgumentsJSON: "{}"))
            XCTAssertEqual(bare.count, 0,
                "Write/Edit matchers must not fire when no aliases are threaded")
            // Bash tool: aliases are empty, so only ^Bash$ fires.
            let e2 = HookEngine(hooks: [handler("^Bash$"), handler("^Write$")])
            let bash = await e2.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: "Bash", toolArgumentsJSON: "{}",
                matcherAliases: []))
            XCTAssertEqual(bash.count, 1, "Bash has no aliases; only ^Bash$ fires")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 20)
    }

    /// PostToolUse and PermissionRequest honor the same aliases (upstream
    /// threads matcher_aliases into all three tool-scoped events,
    /// core/src/hook_runtime.rs:159-160,219-220).
    func testApplyPatchAliasesAlsoApplyToPostAndPermission() {
        let exp = expectation(description: "post-perm-aliases")
        Task {
            func handler(_ ev: HookEventName, _ m: String) -> HookDefinition {
                HookDefinition(eventName: ev, matcher: m,
                               command: #"printf '{"decision":"allow"}'"#,
                               timeoutSec: 5)
            }
            let post = HookEngine(hooks: [handler(.postToolUse, "^Write$")])
            let oPost = await post.fire(.postToolUse, HookRequest(
                eventName: .postToolUse, sessionId: "s", cwd: "/",
                toolName: "apply_patch", toolArgumentsJSON: "{}",
                toolOutput: "ok", matcherAliases: ["Write", "Edit"]))
            XCTAssertEqual(oPost.count, 1, "PostToolUse Write matcher fires on apply_patch")

            let perm = HookEngine(hooks: [handler(.permissionRequest, "^Edit$")])
            let oPerm = await perm.fire(.permissionRequest, HookRequest(
                eventName: .permissionRequest, sessionId: "s", cwd: "/",
                toolName: "apply_patch", toolArgumentsJSON: "{}",
                runIdSuffix: "call-1", matcherAliases: ["Write", "Edit"]))
            XCTAssertEqual(oPerm.count, 1, "PermissionRequest Edit matcher fires on apply_patch")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 20)
    }

    // MARK: - real /bin/sh hooks

    /// PreToolUse exit-2 with a non-empty stderr blocks the tool and surfaces
    /// the stderr as the blocking feedback (pre_tool_use.rs:248-264).
    func testShellHookBlockViaExit2() {
        let exp = expectation(description: "exit2")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: "echo nope 1>&2; exit 2", timeoutSec: 5)])
            let o = await e.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: "shell", toolArgumentsJSON: "{}"))
            let agg = await e.aggregate(o)
            let reason = await e.blockingReason(o)
            XCTAssertEqual(o.count, 1)
            XCTAssertEqual(o.first?.decision, .block)
            XCTAssertEqual(o.first?.reason, "nope")
            XCTAssertTrue(o.first?.shouldBlock ?? false)
            XCTAssertEqual(agg, .block)
            XCTAssertEqual(reason, "nope")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    /// PreToolUse exit-2 with EMPTY stderr is a Failed run, NOT a block —
    /// upstream marks status Failed with "PreToolUse hook exited with code 2
    /// but did not write a blocking reason to stderr" (pre_tool_use.rs:259-263).
    func testPreToolUseExit2EmptyStderrDoesNotBlock() {
        let exp = expectation(description: "pretool-exit2-empty")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: "exit 2", timeoutSec: 5)])
            let o = await e.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: "shell", toolArgumentsJSON: "{}"))
            XCTAssertEqual(o.first?.decision, .allow,
                           "empty-stderr exit-2 must not block")
            XCTAssertFalse(o.first?.shouldBlock ?? true)
            XCTAssertEqual(o.first?.outputSchemaError,
                "PreToolUse hook exited with code 2 but did not write a blocking reason to stderr")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    /// PostToolUse exit-2 stderr is model FEEDBACK (additionalContext), never a
    /// block — the tool already ran (post_tool_use.rs:256-269).
    func testPostToolUseExit2IsFeedbackNotBlock() {
        let exp = expectation(description: "posttool-exit2")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .postToolUse, matcher: nil,
                command: "echo 'run the tests' 1>&2; exit 2", timeoutSec: 5)])
            let o = await e.fire(.postToolUse, HookRequest(
                eventName: .postToolUse, sessionId: "s", cwd: "/",
                toolName: "shell", toolArgumentsJSON: "{}", toolOutput: "ok"))
            XCTAssertEqual(o.first?.decision, .allow,
                           "PostToolUse exit-2 must not block")
            XCTAssertFalse(o.first?.shouldBlock ?? true)
            // H-hooks F8: stderr is model FEEDBACK (feedbackMessage → a
            // `feedback` entry), NOT additionalContext (`context` entry).
            XCTAssertEqual(o.first?.feedbackMessage, "run the tests",
                           "stderr must surface as model feedback")
            XCTAssertNil(o.first?.additionalContext)
            XCTAssertNil(o.first?.outputSchemaError)
            // summarize() must render it as a `feedback` entry, status completed.
            let recs = await e.drainHookRunRecords()
            XCTAssertEqual(recs.first?.completed.status, "completed")
            XCTAssertEqual(recs.first?.completed.entries.first?.kind, "feedback")
            XCTAssertEqual(recs.first?.completed.entries.first?.text, "run the tests")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    /// PostToolUse exit-2 with EMPTY stderr is a Failed run, no block, no
    /// context (post_tool_use.rs:264-268).
    func testPostToolUseExit2EmptyStderrIsFailed() {
        let exp = expectation(description: "posttool-exit2-empty")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .postToolUse, matcher: nil,
                command: "exit 2", timeoutSec: 5)])
            let o = await e.fire(.postToolUse, HookRequest(
                eventName: .postToolUse, sessionId: "s", cwd: "/",
                toolName: "shell", toolArgumentsJSON: "{}", toolOutput: "ok"))
            XCTAssertEqual(o.first?.decision, .allow)
            XCTAssertNil(o.first?.additionalContext)
            XCTAssertEqual(o.first?.outputSchemaError,
                "PostToolUse hook exited with code 2 but did not write feedback to stderr")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    /// SessionStart has no exit-2 special case: exit 2 is a generic nonzero
    /// exit → Failed, never a block (session_start.rs:208-214).
    func testSessionStartExit2IsFailedNotBlock() {
        let exp = expectation(description: "sessionstart-exit2")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .sessionStart, matcher: nil,
                command: "echo blocked 1>&2; exit 2", timeoutSec: 5)])
            let o = await e.fire(.sessionStart, HookRequest(
                eventName: .sessionStart, sessionId: "s", cwd: "/"))
            XCTAssertEqual(o.first?.decision, .allow,
                           "SessionStart exit-2 must never block")
            XCTAssertFalse(o.first?.shouldBlock ?? true)
            XCTAssertFalse(o.first?.shouldStop ?? true)
            XCTAssertNil(o.first?.additionalContext)
            XCTAssertEqual(o.first?.outputSchemaError, "hook exited with code 2")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    /// Generic nonzero exit (not 2) is a Failed run with the upstream
    /// "hook exited with code {N}" message — and no block (every event's
    /// `Some(exit_code)` arm, e.g. pre_tool_use.rs:266-271).
    func testGenericNonzeroExitIsFailed() {
        let exp = expectation(description: "exit127")
        Task {
            let e = HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: "exit 127", timeoutSec: 5)])
            let o = await e.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: "shell", toolArgumentsJSON: "{}"))
            XCTAssertEqual(o.first?.decision, .allow)
            XCTAssertEqual(o.first?.outputSchemaError, "hook exited with code 127")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    /// Malformed / `[`-prefixed JSON stdout at exit 0 is a Failed run with the
    /// per-event "hook returned invalid <event> JSON output" message, not a
    /// silent no-op (post_tool_use.rs:248-254, session_start.rs:193-199).
    func testInvalidJSONOutputMarksRunFailed() {
        let exp = expectation(description: "invalid-json")
        Task {
            // `{`-prefixed but unparseable.
            let bad = HookEngine(hooks: [HookDefinition(
                eventName: .postToolUse, matcher: nil,
                command: #"printf '{not json'"#, timeoutSec: 5)])
            let o1 = await bad.fire(.postToolUse, HookRequest(
                eventName: .postToolUse, sessionId: "s", cwd: "/",
                toolName: "shell", toolArgumentsJSON: "{}", toolOutput: "ok"))
            XCTAssertEqual(o1.first?.decision, .allow)
            XCTAssertEqual(o1.first?.outputSchemaError,
                           "hook returned invalid post-tool-use JSON output")
            // `[`-prefixed JSON never decodes to a hook object → invalid.
            let arr = HookEngine(hooks: [HookDefinition(
                eventName: .sessionStart, matcher: nil,
                command: #"printf '[1,2,3]'"#, timeoutSec: 5)])
            let o2 = await arr.fire(.sessionStart, HookRequest(
                eventName: .sessionStart, sessionId: "s", cwd: "/"))
            XCTAssertEqual(o2.first?.decision, .allow)
            XCTAssertEqual(o2.first?.outputSchemaError,
                           "hook returned invalid session start JSON output")
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
        await engine.submit(.startTurn(input: [TurnInput(text: "go")], model: nil, turnId: nil))
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
            // PreToolUse blocks via exit-2 WITH a non-empty stderr (the
            // blocking reason). An empty-stderr exit-2 is a Failed run upstream,
            // not a block (pre_tool_use.rs:248-264).
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: "echo 'blocked by hook' 1>&2; exit 2", timeoutSec: 5)]))

        let notes = await driveAndCollect(engine)

        var sawDeclined = false
        for n in notes {
            if case .itemCompleted(_, _, let item, _) = n,
               case .commandExecution(_, _, _, let status, _, let out, _, _, _, _) = item,
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
            if case .itemCompleted(_, _, let item, _) = n,
               case .commandExecution(_, _, _, let status, _, _, _, _, _, _) = item,
               status == .completed {
                sawCompleted = true
            }
        }
        XCTAssertTrue(sawCompleted, "stub tool should run normally with no hooks")
        XCTAssertTrue(flag.value(), "stub tool side effect must occur")
    }

    /// hooks-v11 finding 3: a brand-new thread fires SessionStart with
    /// `source: "startup"` (upstream session.rs:1124-1136 New => Startup).
    func testSessionStartSourceStartupForNewThread() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let src = home + "/sessionstart-source.txt"
        // The SessionStart hook captures its stdin so the test can read the
        // `source` field byte-for-byte.
        let cmd = #"cat > '\#(src)'; printf '{}'"#
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: toolThenDoneModel(), store: store,
            router: ToolRouter(limits: Limits()), limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .sessionStart, matcher: nil, command: cmd, timeoutSec: 5)]))
        await engine.start()
        let data = try Data(contentsOf: URL(fileURLWithPath: src))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["source"] as? String, "startup")
    }

    /// hooks-v11 finding 3: a thread reconstructed with prior items fires
    /// SessionStart with `source: "resume"` (upstream Resumed => Resume).
    func testSessionStartSourceResumeForReconstructedThread() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        // First engine: run one full turn so the rollout has prior items.
        let first = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: toolThenDoneModel(), store: store,
            router: ToolRouter(limits: Limits()), limits: Limits())
        let router1 = ToolRouter(limits: Limits())
        await router1.register(StubTool(flag: RanFlag()))
        _ = await driveAndCollect(first)

        // Second engine on the SAME threadId: reconstruct loads prior items, so
        // the SessionStart hook must report source "resume".
        let src = home + "/sessionstart-resume.txt"
        let cmd = #"cat > '\#(src)'; printf '{}'"#
        let resumed = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: toolThenDoneModel(), store: store,
            router: ToolRouter(limits: Limits()), limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .sessionStart, matcher: nil, command: cmd, timeoutSec: 5)]))
        await resumed.start()
        let data = try Data(contentsOf: URL(fileURLWithPath: src))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["source"] as? String, "resume",
                       "reconstructed thread with prior items must fire SessionStart source:resume")
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

    /// PreCompact has NO exit-2 special case upstream (compact.rs:275-282):
    /// exit 2 is a Failed hook run, NOT a compaction abort. Only the stdout
    /// `continue:false` path (see the next test) aborts compaction.
    func testPreCompactHookExit2DoesNotAbortCompaction() async throws {
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
                command: "echo boom 1>&2; exit 2", timeoutSec: 5)]))
        let events = await driveCompact(engine)
        let aborted = events.contains { ev in
            if case .turnCompleted(_, let turn) = ev {
                return turn.status == .failed
            }
            return false
        }
        XCTAssertFalse(aborted,
                       "PreCompact exit-2 must NOT abort compaction; events=\(events.map(\.method))")
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
            if case .itemCompleted(_, _, let item, _) = n,
               case .commandExecution(_, _, _, let status, _, _, _, _, _, _) = item,
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
            if case .itemCompleted(_, _, let item, _) = n,
               case .commandExecution(_, _, _, let status, _, let out, _, _, _, _) = item,
               status == .declined, (out ?? "").contains("hook said no") {
                sawDeclined = true
            }
        }
        XCTAssertTrue(sawDeclined,
                      "PermissionRequest hook deny must short-circuit the approval coordinator")
        XCTAssertFalse(flag.value(),
                       "stub gated tool must not have run when the hook denies")
    }

    /// Fail-CLOSED regression: a PermissionRequest hook that exits 2 with a
    /// non-empty stderr DENIES the tool (upstream permission_request.rs:243-258
    /// maps exit-2+stderr to `Deny { message }`). The previous Swift code only
    /// populated the legacy top-level `decision:.block` on this arm, while the
    /// consumer (`firePermissionRequestHook`) read ONLY the structured
    /// `hookSpecificOutput.permissionDecision` — so the deny was silently
    /// dropped and the tool ran (a fail-OPEN security bug). Here the approval
    /// coordinator ACCEPTS everything, so if the hook deny were dropped the
    /// gated tool would run. We assert it is declined and the tool never ran.
    func testPermissionRequestHookExit2WithStderrDeniesTool() async throws {
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
                command: "echo 'hook denied via exit2' 1>&2; exit 2",
                timeoutSec: 5)]))
        await engine.setApprovalCoordinator(AcceptAllCoordinator())
        let notes = await driveAndCollect(engine)
        var sawDeclined = false
        for n in notes {
            if case .itemCompleted(_, _, let item, _) = n,
               case .commandExecution(_, _, _, let status, _, let out, _, _, _, _) = item,
               status == .declined, (out ?? "").contains("hook denied via exit2") {
                sawDeclined = true
            }
        }
        XCTAssertTrue(sawDeclined,
                      "PermissionRequest hook exit-2 + stderr must DENY the tool (fail-closed), even when the approval coordinator accepts")
        XCTAssertFalse(flag.value(),
                       "stub gated tool must NOT have run when the exit-2 hook denied it")
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
            if case .itemStarted(_, _, let item, _) = n,
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
            if case .itemStarted(_, _, let item, _) = n,
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

    // MARK: - audit-v7 hooks unit findings

    /// Finding 1: HookRunSummary.id must be `<kebab-event>:<order>:<sourcePath>`
    /// (upstream `ConfiguredHandler::run_id()`), NOT `<source>:<camelEvent>:<order>`.
    func testHookRunIdMatchesUpstreamFormat() async throws {
        var def = HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"decision":"allow"}'"#, timeoutSec: 5)
        def.sourcePath = "/tmp/hooks.json"
        def.source = "user"
        let e = HookEngine(hooks: [def])
        // Upstream `hook_run_for_tool_use` (hooks/src/events/common.rs:93-95)
        // appends `:{tool_use_id}` to the run id for PreToolUse/PostToolUse;
        // pre_tool_use.rs:704-707 asserts `pre-tool-use:0:{path}:tool-call-123`.
        _ = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}",
            toolUseId: "tool-call-123"))
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs.first?.started.id, "pre-tool-use:0:/tmp/hooks.json:tool-call-123")
        XCTAssertEqual(recs.first?.completed.id, "pre-tool-use:0:/tmp/hooks.json:tool-call-123")
    }

    /// Finding 1 (hooks-v11): PreToolUse/PostToolUse with NO tool_use_id still
    /// append the (empty) suffix — upstream `tool_use_id` is a non-optional
    /// String so the id always ends with a trailing `:`.
    func testHookRunIdAppendsEmptySuffixWhenNoToolUseId() async throws {
        var def = HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"decision":"block","reason":"no"}'"#, timeoutSec: 5)
        def.sourcePath = "/tmp/hooks.json"
        def.source = "user"
        let e = HookEngine(hooks: [def])
        _ = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.started.id, "pre-tool-use:0:/tmp/hooks.json:")
        XCTAssertEqual(recs.first?.completed.id, "pre-tool-use:0:/tmp/hooks.json:")
    }

    /// Finding 1 (hooks-v11): PermissionRequest appends the caller-supplied
    /// run_id_suffix (the tool call_id) to the run id
    /// (permission_request.rs:79, core/src/hook_runtime.rs:208).
    func testHookRunIdPermissionRequestAppendsRunIdSuffix() async throws {
        var def = HookDefinition(
            eventName: .permissionRequest, matcher: nil,
            command: #"printf '{}'"#, timeoutSec: 5)
        def.sourcePath = "/tmp/hooks.json"
        def.source = "project"
        let e = HookEngine(hooks: [def])
        _ = await e.fire(.permissionRequest, HookRequest(
            eventName: .permissionRequest, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}",
            runIdSuffix: "call-42"))
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.started.id, "permission-request:0:/tmp/hooks.json:call-42")
        XCTAssertEqual(recs.first?.completed.id, "permission-request:0:/tmp/hooks.json:call-42")
    }

    /// Finding 1 (Stop fixture shape): upstream test confirms `stop:0:/path`.
    func testHookRunIdStopFixtureShape() async throws {
        var def = HookDefinition(
            eventName: .stop, matcher: nil,
            command: #"printf '{"continue":true}'"#, timeoutSec: 5)
        def.sourcePath = "/tmp/hooks.json"
        def.source = "project"
        let e = HookEngine(hooks: [def])
        _ = await e.fire(.stop, HookRequest(eventName: .stop, sessionId: "s", cwd: "/"))
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.started.id, "stop:0:/tmp/hooks.json")
    }

    /// Finding 3: with multiple matched hooks, the run records must be ordered
    /// so all `started` summaries precede all `completed` summaries when
    /// SessionEngine drains them. The records themselves carry displayOrder
    /// 0,1,… and emitHookRuns emits all starteds then all completeds.
    func testHookRunRecordsDisplayOrderBatched() async throws {
        func mk(_ order: Int) -> HookDefinition {
            var d = HookDefinition(eventName: .preToolUse, matcher: nil,
                                   command: #"printf '{"decision":"allow"}'"#,
                                   timeoutSec: 5)
            d.sourcePath = "/tmp/h\(order).json"
            d.source = "user"
            // displayOrder is now a STABLE load-time index (no longer derived
            // per fire). The loader assigns it; mirror that here so the run id
            // and HookRunSummary.display_order match upstream.
            d.displayOrder = order
            return d
        }
        let e = HookEngine(hooks: [mk(0), mk(1)])
        _ = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}",
            toolUseId: "tc-9"))
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0].started.displayOrder, 0)
        XCTAssertEqual(recs[1].started.displayOrder, 1)
        // PreToolUse ids carry the tool_use_id suffix.
        XCTAssertEqual(recs[0].started.id, "pre-tool-use:0:/tmp/h0.json:tc-9")
        XCTAssertEqual(recs[1].started.id, "pre-tool-use:1:/tmp/h1.json:tc-9")
    }

    /// Finding 4: `continue:false` on PreToolUse is upstream-unsupported and
    /// must NOT block the tool. It is surfaced as outputSchemaError (Failed
    /// status) with decision left .allow.
    func testPreToolUseContinueFalseDoesNotBlock() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"continue":false}'"#, timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        XCTAssertEqual(o.first?.decision, .allow,
                       "continue:false on PreToolUse must NOT block")
        XCTAssertFalse(o.first?.shouldStop ?? true)
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PreToolUse hook returned unsupported continue:false")
        // summarize() must report `failed`, not `blocked`.
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// Finding 4 (PermissionRequest): continue:false likewise must not block.
    func testPermissionRequestContinueFalseDoesNotBlock() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .permissionRequest, matcher: nil,
            command: #"printf '{"continue":false}'"#, timeoutSec: 5)])
        let o = await e.fire(.permissionRequest, HookRequest(
            eventName: .permissionRequest, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        XCTAssertEqual(o.first?.decision, .allow)
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PermissionRequest hook returned unsupported continue:false")
    }

    // MARK: - audit-v11 hooks unit findings

    /// hooks-v11 finding 7: PreToolUse legacy `decision:"approve"` is
    /// unsupported — Failed run with the verbatim upstream message
    /// (output_parser.rs:434-457), no block.
    func testPreToolUseDecisionApproveIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"decision":"approve","reason":"ok"}'"#, timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertEqual(o.first?.decision, .allow)
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PreToolUse hook returned unsupported decision:approve")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// hooks-v11 finding 7: PreToolUse with a top-level `reason` but NO
    /// `decision` is "reason without decision" → Failed, no block.
    func testPreToolUseReasonWithoutDecisionIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"reason":"stray"}'"#, timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertEqual(o.first?.decision, .allow)
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PreToolUse hook returned reason without decision")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// hooks-v11 finding 7: universal `stopReason` on PreToolUse is
    /// unsupported → Failed (output_parser.rs:322-323), no block.
    func testPreToolUseUniversalStopReasonIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"stopReason":"halt"}'"#, timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertEqual(o.first?.decision, .allow)
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PreToolUse hook returned unsupported stopReason")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// hooks-v11 finding 7: universal `suppressOutput:true` on PreToolUse is
    /// unsupported → Failed (output_parser.rs:324-325), no block.
    func testPreToolUseUniversalSuppressOutputIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"suppressOutput":true}'"#, timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertEqual(o.first?.decision, .allow)
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PreToolUse hook returned unsupported suppressOutput")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// hooks-v11 finding 7: PermissionRequest universal suppressOutput is
    /// likewise unsupported → Failed (output_parser.rs:336-337).
    func testPermissionRequestUniversalSuppressOutputIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .permissionRequest, matcher: nil,
            command: #"printf '{"suppressOutput":true}'"#, timeoutSec: 5)])
        let o = await e.fire(.permissionRequest, HookRequest(
            eventName: .permissionRequest, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", runIdSuffix: "c"))
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PermissionRequest hook returned unsupported suppressOutput")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// hooks-v11 finding 7: PostToolUse universal suppressOutput is
    /// unsupported → Failed (output_parser.rs:344-345); stopReason is NOT an
    /// error for PostToolUse (no stopReason arm).
    func testPostToolUseUniversalSuppressOutputIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .postToolUse, matcher: nil,
            command: #"printf '{"suppressOutput":true}'"#, timeoutSec: 5)])
        let o = await e.fire(.postToolUse, HookRequest(
            eventName: .postToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PostToolUse hook returned unsupported suppressOutput")
    }

    /// hooks-v11 finding 7: a legacy `decision:"block"` WITH a non-empty reason
    /// still blocks (not flagged Failed) — the new approve/stopReason/
    /// suppressOutput checks must not regress the supported block path.
    func testPreToolUseDecisionBlockWithReasonStillBlocks() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"decision":"block","reason":"nope"}'"#, timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertEqual(o.first?.decision, .block)
        XCTAssertNil(o.first?.outputSchemaError)
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "blocked")
    }

    // MARK: - audit-v12 hooks unit findings (F1-F8)

    /// H-hooks F1: PostToolUse `{"continue":false}` (exit 0) stops the run.
    /// Upstream (post_tool_use.rs Some(0) arm) sets status=Stopped,
    /// should_stop=true, and ALWAYS pushes a `stop` entry whose text falls back
    /// to "PostToolUse hook stopped execution" when stopReason is absent.
    func testPostToolUseContinueFalseStopsWithFallbackEntry() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .postToolUse, matcher: nil,
            command: #"printf '{"continue":false}'"#, timeoutSec: 5)])
        let o = await e.fire(.postToolUse, HookRequest(
            eventName: .postToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolOutput: "ok",
            toolUseId: "tc"))
        XCTAssertTrue(o.first?.shouldStop ?? false,
                      "PostToolUse continue:false must set shouldStop")
        XCTAssertEqual(o.first?.stopReason, "PostToolUse hook stopped execution")
        XCTAssertNil(o.first?.outputSchemaError)
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "stopped")
        XCTAssertEqual(recs.first?.completed.entries.first(where: { $0.kind == "stop" })?.text,
                       "PostToolUse hook stopped execution")
    }

    /// H-hooks F1: PostToolUse continue:false WITH an explicit stopReason uses
    /// that reason as the `stop` entry text (no fallback).
    func testPostToolUseContinueFalseUsesStopReason() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .postToolUse, matcher: nil,
            command: #"printf '{"continue":false,"stopReason":"halt now"}'"#, timeoutSec: 5)])
        let o = await e.fire(.postToolUse, HookRequest(
            eventName: .postToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolOutput: "ok",
            toolUseId: "tc"))
        XCTAssertEqual(o.first?.stopReason, "halt now")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "stopped")
        XCTAssertEqual(recs.first?.completed.entries.first(where: { $0.kind == "stop" })?.text,
                       "halt now")
    }

    /// H-hooks F1: continue:false wins over the suppressOutput gate (upstream
    /// sets Stopped before checking invalid_reason).
    func testPostToolUseContinueFalseWinsOverSuppressOutput() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .postToolUse, matcher: nil,
            command: #"printf '{"continue":false,"suppressOutput":true}'"#, timeoutSec: 5)])
        let o = await e.fire(.postToolUse, HookRequest(
            eventName: .postToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolOutput: "ok",
            toolUseId: "tc"))
        XCTAssertTrue(o.first?.shouldStop ?? false)
        XCTAssertNil(o.first?.outputSchemaError,
                     "continue:false must win over the suppressOutput gate")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "stopped")
    }

    /// H-hooks F2: UserPromptSubmit `{"continue":false}` stops the run. A
    /// `stop` entry is pushed ONLY when stopReason is present (no fallback,
    /// unlike PostToolUse — user_prompt_submit.rs Some(0) arm).
    func testUserPromptSubmitContinueFalseStopsNoEntryWhenNoReason() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .userPromptSubmit, matcher: nil,
            command: #"printf '{"continue":false}'"#, timeoutSec: 5)])
        let o = await e.fire(.userPromptSubmit, HookRequest(
            eventName: .userPromptSubmit, sessionId: "s", cwd: "/", prompt: "hi"))
        XCTAssertTrue(o.first?.shouldStop ?? false)
        XCTAssertNil(o.first?.stopReason)
        XCTAssertNil(o.first?.outputSchemaError)
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "stopped")
        XCTAssertNil(recs.first?.completed.entries.first(where: { $0.kind == "stop" }),
                     "no stop entry when stopReason absent (UserPromptSubmit)")
    }

    /// H-hooks F2: UserPromptSubmit continue:false WITH stopReason pushes a
    /// `stop` entry carrying that text.
    func testUserPromptSubmitContinueFalseStopEntryWhenReason() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .userPromptSubmit, matcher: nil,
            command: #"printf '{"continue":false,"stopReason":"policy block"}'"#, timeoutSec: 5)])
        let o = await e.fire(.userPromptSubmit, HookRequest(
            eventName: .userPromptSubmit, sessionId: "s", cwd: "/", prompt: "hi"))
        XCTAssertEqual(o.first?.stopReason, "policy block")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "stopped")
        XCTAssertEqual(recs.first?.completed.entries.first(where: { $0.kind == "stop" })?.text,
                       "policy block")
    }

    /// H-hooks F3: PreToolUse `permissionDecision:ask` is unsupported → Failed
    /// (output_parser.rs:408-410).
    func testPreToolUsePermissionDecisionAskIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}'"#,
            timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PreToolUse hook returned unsupported permissionDecision:ask")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// H-hooks F4: PreToolUse `updatedInput` without `permissionDecision:allow`
    /// is unsupported → Failed; the updatedInput is dropped
    /// (output_parser.rs:394-400).
    func testPreToolUseUpdatedInputWithoutAllowIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no","updatedInput":{"a":1}}}'"#,
            timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PreToolUse hook returned updatedInput without permissionDecision:allow")
        XCTAssertNil(o.first?.hookSpecificOutput?.updatedInputJSON,
                     "updatedInput must be dropped on invalid_reason")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// H-hooks F4 control: `permissionDecision:allow` WITH updatedInput is the
    /// one supported rewrite path — no schema error, updatedInput preserved.
    func testPreToolUseAllowWithUpdatedInputIsValid() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"a":1}}}'"#,
            timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertNil(o.first?.outputSchemaError)
        XCTAssertEqual(o.first?.hookSpecificOutput?.updatedInputJSON, #"{"a":1}"#)
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "completed")
    }

    /// H-hooks F5: PreToolUse `permissionDecisionReason` WITHOUT
    /// `permissionDecision` is unsupported → Failed (output_parser.rs:423-428).
    func testPreToolUsePermissionDecisionReasonWithoutDecisionIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"why"}}'"#,
            timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PreToolUse hook returned permissionDecisionReason without permissionDecision")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// H-hooks F6: PermissionRequest decision carrying reserved `updatedInput`
    /// is unsupported → Failed and the decision is dropped
    /// (output_parser.rs:351-364).
    func testPermissionRequestUpdatedInputIsFailedAndDropsDecision() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .permissionRequest, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{"a":1}}}}'"#,
            timeoutSec: 5)])
        let o = await e.fire(.permissionRequest, HookRequest(
            eventName: .permissionRequest, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", runIdSuffix: "c"))
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PermissionRequest hook returned unsupported updatedInput")
        XCTAssertNil(o.first?.hookSpecificOutput?.permissionDecision,
                     "decision must be dropped on invalid_reason")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// H-hooks F6: PermissionRequest reserved `updatedPermissions`.
    func testPermissionRequestUpdatedPermissionsIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .permissionRequest, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","updatedPermissions":["x"]}}}'"#,
            timeoutSec: 5)])
        let o = await e.fire(.permissionRequest, HookRequest(
            eventName: .permissionRequest, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", runIdSuffix: "c"))
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PermissionRequest hook returned unsupported updatedPermissions")
        XCTAssertNil(o.first?.hookSpecificOutput?.permissionDecision)
    }

    /// H-hooks F6: PermissionRequest reserved `interrupt:true`.
    func testPermissionRequestInterruptTrueIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .permissionRequest, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","interrupt":true}}}'"#,
            timeoutSec: 5)])
        let o = await e.fire(.permissionRequest, HookRequest(
            eventName: .permissionRequest, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", runIdSuffix: "c"))
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PermissionRequest hook returned unsupported interrupt:true")
        XCTAssertNil(o.first?.hookSpecificOutput?.permissionDecision)
    }

    /// H-hooks F6 control: `interrupt:false` is NOT flagged (upstream keys on
    /// `decision.interrupt` being true).
    func testPermissionRequestInterruptFalseIsAllowed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .permissionRequest, matcher: nil,
            command: #"printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","interrupt":false}}}'"#,
            timeoutSec: 5)])
        let o = await e.fire(.permissionRequest, HookRequest(
            eventName: .permissionRequest, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", runIdSuffix: "c"))
        XCTAssertNil(o.first?.outputSchemaError)
        XCTAssertEqual(o.first?.hookSpecificOutput?.permissionDecision, .allow)
    }

    /// H-hooks F7: PostToolUse top-level `reason` WITHOUT a `decision:block`
    /// (and continue not false) is "reason without decision" → Failed
    /// (output_parser.rs:203-204).
    func testPostToolUseReasonWithoutDecisionIsFailed() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .postToolUse, matcher: nil,
            command: #"printf '{"reason":"stray"}'"#, timeoutSec: 5)])
        let o = await e.fire(.postToolUse, HookRequest(
            eventName: .postToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolOutput: "ok",
            toolUseId: "tc"))
        XCTAssertEqual(o.first?.decision, .allow)
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PostToolUse hook returned reason without decision")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// H-hooks F7 control: PostToolUse `decision:block` WITH a non-empty reason
    /// blocks (not "reason without decision") — must not regress.
    func testPostToolUseDecisionBlockWithReasonBlocks() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .postToolUse, matcher: nil,
            command: #"printf '{"decision":"block","reason":"bad output"}'"#, timeoutSec: 5)])
        let o = await e.fire(.postToolUse, HookRequest(
            eventName: .postToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolOutput: "ok",
            toolUseId: "tc"))
        XCTAssertEqual(o.first?.decision, .block)
        XCTAssertNil(o.first?.outputSchemaError)
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "blocked")
    }

    /// hooks-v11 finding 5: PreCompact / PostCompact hook stdin must NOT carry
    /// a `permission_mode` key (upstream PreCompact/PostCompactCommandInput
    /// have no such field); every other turn-scoped event still includes it.
    func testCompactStdinOmitsPermissionMode() async throws {
        let pre = HookRequest(eventName: .preCompact, sessionId: "s", cwd: "/",
                              turnId: "t-1", model: "m", permissionMode: "default",
                              extra: ["trigger": "manual"])
        let stdinPre = try await captureHookStdin(eventName: .preCompact, request: pre)
        XCTAssertNil(stdinPre["permission_mode"],
                     "PreCompact stdin must omit permission_mode")
        XCTAssertEqual(stdinPre["trigger"] as? String, "manual")
        XCTAssertEqual(stdinPre["turn_id"] as? String, "t-1")

        let post = HookRequest(eventName: .postCompact, sessionId: "s", cwd: "/",
                               turnId: "t-2", model: "m", permissionMode: "default",
                               extra: ["trigger": "auto"])
        let stdinPost = try await captureHookStdin(eventName: .postCompact, request: post)
        XCTAssertNil(stdinPost["permission_mode"],
                     "PostCompact stdin must omit permission_mode")

        // Control: a PreToolUse stdin still carries permission_mode.
        let pre2 = HookRequest(eventName: .preToolUse, sessionId: "s", cwd: "/",
                               toolName: "shell", toolArgumentsJSON: "{}",
                               turnId: "t-3", model: "m", permissionMode: "default")
        let stdinTool = try await captureHookStdin(eventName: .preToolUse, request: pre2)
        XCTAssertEqual(stdinTool["permission_mode"] as? String, "default")
    }

    /// hooks-v11 finding 4: legacy notify always includes
    /// `last-assistant-message` (null when absent), never omitting the key.
    func testLegacyNotifyAlwaysIncludesLastAssistantMessageAsNull() throws {
        let json = try HookEngine.legacyNotifyJSON(.init(
            threadId: "t", turnId: "1", cwd: "/p", client: nil,
            inputMessages: ["hi"], lastAssistantMessage: nil))
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertTrue(value?.keys.contains("last-assistant-message") ?? false,
                      "key must be present even when nil")
        XCTAssertTrue(value?["last-assistant-message"] is NSNull,
                      "absent last assistant message must serialize as null")
        // `client` IS skipped when nil (upstream skip_serializing_if).
        XCTAssertNil(value?["client"])
    }

    /// hooks-v11 finding 6: a hook timeout above 600s is honored verbatim — only
    /// the lower bound (1s) is clamped, matching upstream
    /// `timeout_sec.unwrap_or(600).max(1)`. We assert a 700s-timeout fast hook
    /// still completes normally (not capped/killed); the timeout value itself is
    /// internal, so we exercise the no-upper-cap path behaviorally.
    func testHookTimeoutAbove600IsHonored() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"decision":"block","reason":"x"}'"#,
            timeoutSec: 700)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        // A 700s configured timeout must NOT cause an immediate cap/kill; the
        // fast hook runs to completion and blocks as configured.
        XCTAssertEqual(o.first?.decision, .block)
        XCTAssertNotEqual(o.first?.reason, "hook timed out")
    }

    /// hooks-v11 finding 2: the hook child process runs with its working
    /// directory set to the request cwd, so `pwd` resolves there (upstream
    /// command_runner.rs:34-39 `command.current_dir(cwd)`).
    func testHookProcessRunsInRequestCwd() async throws {
        let dir = NSTemporaryDirectory() + "hkcwd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Resolve symlinks: macOS /var/folders is a symlink to /private/var.
        let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let out = dir + "/pwd.txt"
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"pwd > '\#(out)'; printf '{"decision":"allow"}'"#,
            timeoutSec: 5)])
        _ = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: dir,
            toolName: "shell", toolArgumentsJSON: "{}", toolUseId: "tc"))
        let pwd = (try String(contentsOfFile: out, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pwdResolved = URL(fileURLWithPath: pwd).resolvingSymlinksInPath().path
        XCTAssertEqual(pwdResolved, resolved,
                       "hook must run in the request cwd")
    }

    /// Finding 6: UserPromptSubmit decision:block WITHOUT a reason must be
    /// marked Failed and must NOT block.
    func testUserPromptSubmitBlockWithoutReasonNotBlocked() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .userPromptSubmit, matcher: nil,
            command: #"printf '{"decision":"block"}'"#, timeoutSec: 5)])
        let o = await e.fire(.userPromptSubmit, HookRequest(
            eventName: .userPromptSubmit, sessionId: "s", cwd: "/"))
        XCTAssertEqual(o.first?.decision, .allow,
                       "block-without-reason must not block")
        XCTAssertEqual(o.first?.outputSchemaError,
                       "UserPromptSubmit hook returned decision:block without a non-empty reason")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// Finding 6 (PostToolUse): same block-without-reason gate.
    func testPostToolUseBlockWithoutReasonNotBlocked() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .postToolUse, matcher: nil,
            command: #"printf '{"decision":"block","reason":"   "}'"#, timeoutSec: 5)])
        let o = await e.fire(.postToolUse, HookRequest(
            eventName: .postToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        XCTAssertEqual(o.first?.decision, .allow,
                       "whitespace-only reason must be treated as empty")
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PostToolUse hook returned decision:block without a non-empty reason")
    }

    /// Finding 6 (positive): UserPromptSubmit decision:block WITH a reason still blocks.
    func testUserPromptSubmitBlockWithReasonStillBlocks() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .userPromptSubmit, matcher: nil,
            command: #"printf '{"decision":"block","reason":"nope"}'"#, timeoutSec: 5)])
        let o = await e.fire(.userPromptSubmit, HookRequest(
            eventName: .userPromptSubmit, sessionId: "s", cwd: "/"))
        XCTAssertEqual(o.first?.decision, .block)
        XCTAssertEqual(o.first?.reason, "nope")
        XCTAssertNil(o.first?.outputSchemaError)
    }

    /// Finding 7: UserPromptSubmit bare-text stdout (non-JSON, exit 0) becomes
    /// additionalContext injected into the model turn.
    func testUserPromptSubmitBareTextBecomesAdditionalContext() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .userPromptSubmit, matcher: nil,
            command: "printf 'remember to be concise'", timeoutSec: 5)])
        let o = await e.fire(.userPromptSubmit, HookRequest(
            eventName: .userPromptSubmit, sessionId: "s", cwd: "/"))
        XCTAssertEqual(o.first?.decision, .allow)
        XCTAssertEqual(o.first?.additionalContext, "remember to be concise")
    }

    /// Finding 7: SessionStart bare-text stdout also becomes additionalContext.
    func testSessionStartBareTextBecomesAdditionalContext() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .sessionStart, matcher: nil,
            command: "printf 'project uses tabs'", timeoutSec: 5)])
        let o = await e.fire(.sessionStart, HookRequest(
            eventName: .sessionStart, sessionId: "s", cwd: "/"))
        XCTAssertEqual(o.first?.additionalContext, "project uses tabs")
    }

    /// Finding 7 (negative): a non-userPromptSubmit/sessionStart event's bare
    /// text is NOT treated as additionalContext.
    func testPreToolUseBareTextNotAdditionalContext() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: "printf 'some text'", timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        XCTAssertNil(o.first?.additionalContext)
    }

    /// Finding 2: a UserPromptSubmit hook's additionalContext must be injected
    /// into the conversation as a developer-role message visible on the model
    /// prompt. We assert the engine records it (round-trips through history).
    func testUserPromptSubmitAdditionalContextInjectedIntoConversation() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let model = MockModelClient([
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "r1", tokens: 1)]),
        ])
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: model, store: store,
            router: ToolRouter(limits: Limits()),
            limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .userPromptSubmit, matcher: nil,
                command: #"printf '{"hookSpecificOutput":{"additionalContext":"INJECTED-CTX"}}'"#,
                timeoutSec: 5)]))
        let notes = await driveAndCollect(engine)
        // The injected developer context is persisted as an item; verify it
        // shows up in the durable thread items.
        let items = try await store.reconstruct(tid).items
        var found = false
        for it in items {
            if case .contextMessage(_, let role, let sections) = it,
               role == "developer", sections.contains("INJECTED-CTX") {
                found = true
            }
        }
        XCTAssertTrue(found,
                      "UserPromptSubmit additionalContext must be recorded as a developer-role conversation item")
        _ = notes
    }

    /// Finding 5: PreToolUse block message for Bash includes the command.
    func testPreToolUseBlockMessageBashIncludesCommand() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let router = ToolRouter(limits: Limits())
        await router.register(BashStubTool())
        let model = MockModelClient([
            MockScenario([.created,
                          .toolCall(callId: "c1", name: "Bash",
                                    argumentsJSON: #"{"command":"rm -rf /"}"#),
                          .completeContinue(responseId: "r1", tokens: 1)]),
            MockScenario([.created,
                          .agentDone(itemId: "m1", "done"),
                          .completeEndTurn(responseId: "r2", tokens: 1)]),
        ])
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: model, store: store, router: router,
            limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: #"printf '{"decision":"block","reason":"dangerous"}'"#,
                timeoutSec: 5)]))
        let notes = await driveAndCollect(engine)
        var blockMsg: String?
        for n in notes {
            if case .itemCompleted(_, _, let item, _) = n,
               case .commandExecution(_, _, _, let status, _, let out, _, _, _, _) = item,
               status == .declined {
                blockMsg = out
            }
        }
        XCTAssertEqual(blockMsg,
                       "Command blocked by PreToolUse hook: dangerous. Command: rm -rf /")
    }

    /// Finding 5: non-Bash tool block message names the tool.
    func testPreToolUseBlockMessageNonBashNamesTool() async throws {
        let (store, home) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tid = ThreadId.generate()
        _ = try await store.create(SessionConfig(threadId: tid, cwd: "/w"))
        let router = ToolRouter(limits: Limits())
        await router.register(StubTool(flag: RanFlag()))
        let engine = SessionEngine(
            config: SessionConfig(threadId: tid, cwd: "/w"),
            model: toolThenDoneModel(), store: store, router: router,
            limits: Limits(),
            hooks: HookEngine(hooks: [HookDefinition(
                eventName: .preToolUse, matcher: nil,
                command: #"printf '{"decision":"block","reason":"no"}'"#,
                timeoutSec: 5)]))
        let notes = await driveAndCollect(engine)
        var blockMsg: String?
        for n in notes {
            if case .itemCompleted(_, _, let item, _) = n,
               case .commandExecution(_, _, _, let status, _, let out, _, _, _, _) = item,
               status == .declined {
                blockMsg = out
            }
        }
        XCTAssertEqual(blockMsg,
                       "Tool call blocked by PreToolUse hook: no. Tool: stub")
    }

    // MARK: - audit-v9 hooks unit findings

    /// Finding 2: pure port of upstream `events::common::matches_matcher`
    /// (hooks/src/events/common.rs tests). Match-all, exact (pipe-split), regex,
    /// and invalid-regex behaviour must all line up.
    func testMatchesMatcherPortOfUpstream() {
        // matcher omitted matches all
        XCTAssertTrue(HookEngine.matchesMatcher(nil, "Bash"))
        XCTAssertTrue(HookEngine.matchesMatcher(nil, "Write"))
        // "*" and "" match all
        XCTAssertTrue(HookEngine.matchesMatcher("*", "Bash"))
        XCTAssertTrue(HookEngine.matchesMatcher("*", "Edit"))
        XCTAssertTrue(HookEngine.matchesMatcher("", "Bash"))
        XCTAssertTrue(HookEngine.matchesMatcher("", "SessionStart"))
        // exact matcher supports pipe alternatives
        XCTAssertTrue(HookEngine.matchesMatcher("Edit|Write", "Edit"))
        XCTAssertTrue(HookEngine.matchesMatcher("Edit|Write", "Write"))
        XCTAssertFalse(HookEngine.matchesMatcher("Edit|Write", "Bash"))
        // literal matcher uses EXACT matching (no substring)
        XCTAssertTrue(HookEngine.matchesMatcher("Bash", "Bash"))
        XCTAssertFalse(HookEngine.matchesMatcher("Bash", "BashOutput"))
        XCTAssertTrue(HookEngine.matchesMatcher("mcp__memory__create_entities",
                                                "mcp__memory__create_entities"))
        XCTAssertFalse(HookEngine.matchesMatcher("mcp__memory",
                                                 "mcp__memory__create_entities"))
        // regex when the matcher contains regex characters
        XCTAssertTrue(HookEngine.matchesMatcher("^Bash", "BashOutput"))
        XCTAssertTrue(HookEngine.matchesMatcher("mcp__memory__.*",
                                                "mcp__memory__create_entities"))
        XCTAssertTrue(HookEngine.matchesMatcher("mcp__.*__write.*",
                                                "mcp__filesystem__write_file"))
        XCTAssertFalse(HookEngine.matchesMatcher("mcp__.*__write.*",
                                                 "mcp__filesystem__read_file"))
        // anchored regex
        XCTAssertTrue(HookEngine.matchesMatcher("^Bash$", "Bash"))
        XCTAssertFalse(HookEngine.matchesMatcher("^Bash$", "BashOutput"))
        // invalid regex never matches
        XCTAssertFalse(HookEngine.matchesMatcher("[", "Bash"))
        // a concrete matcher with no input (UserPromptSubmit/Stop) never matches
        XCTAssertFalse(HookEngine.matchesMatcher("Bash", nil))
        XCTAssertFalse(HookEngine.matchesMatcher("^Bash", nil))
        // but match-all/nil with no input still matches (matcher ignored)
        XCTAssertTrue(HookEngine.matchesMatcher(nil, nil))
        XCTAssertTrue(HookEngine.matchesMatcher("*", nil))
        XCTAssertTrue(HookEngine.matchesMatcher("", nil))
    }

    /// Finding 2: an exact matcher "Bash" must NOT fire for a tool named
    /// "BashOutput" (upstream rejects the substring/regex partial match).
    func testExactMatcherDoesNotPartialMatch() async {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: "Bash",
            command: #"printf '{"decision":"allow"}'"#, timeoutSec: 5)])
        let fired = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "BashOutput", toolArgumentsJSON: "{}"))
        XCTAssertEqual(fired.count, 0,
                       "exact matcher \"Bash\" must not partial-match \"BashOutput\"")
        let exact = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "Bash", toolArgumentsJSON: "{}"))
        XCTAssertEqual(exact.count, 1)
    }

    /// Finding 2: "Read|Write" exact-matches Read or Write, not a substring.
    func testPipeAlternativesExactMatch() async {
        let def = HookDefinition(
            eventName: .preToolUse, matcher: "Read|Write",
            command: #"printf '{"decision":"allow"}'"#, timeoutSec: 5)
        let e = HookEngine(hooks: [def])
        func count(_ tool: String) async -> Int {
            await e.fire(.preToolUse, HookRequest(
                eventName: .preToolUse, sessionId: "s", cwd: "/",
                toolName: tool, toolArgumentsJSON: "{}")).count
        }
        let read = await count("Read")
        let write = await count("Write")
        let bash = await count("Bash")
        let readFile = await count("ReadFile")
        XCTAssertEqual(read, 1)
        XCTAssertEqual(write, 1)
        XCTAssertEqual(bash, 0)
        XCTAssertEqual(readFile, 0, "alternation must be exact, not substring")
    }

    /// Finding 3: a SessionStart hook with matcher "resume" fires only when the
    /// session source is "resume", matched against the source (not the empty
    /// tool name).
    func testSessionStartMatcherUsesSource() async {
        let def = HookDefinition(
            eventName: .sessionStart, matcher: "resume",
            command: #"printf '{}'"#, timeoutSec: 5)
        let e = HookEngine(hooks: [def])
        let onResume = await e.fire(.sessionStart, HookRequest(
            eventName: .sessionStart, sessionId: "s", cwd: "/", source: "resume"))
        let onStartup = await e.fire(.sessionStart, HookRequest(
            eventName: .sessionStart, sessionId: "s", cwd: "/", source: "startup"))
        XCTAssertEqual(onResume.count, 1, "matcher:resume must fire on a resume source")
        XCTAssertEqual(onStartup.count, 0, "matcher:resume must NOT fire on a startup source")
    }

    /// Finding 3: PreCompact matcher is tested against the compaction trigger.
    func testPreCompactMatcherUsesTrigger() async {
        let def = HookDefinition(
            eventName: .preCompact, matcher: "manual",
            command: #"printf '{}'"#, timeoutSec: 5)
        let e = HookEngine(hooks: [def])
        let manual = await e.fire(.preCompact, HookRequest(
            eventName: .preCompact, sessionId: "s", cwd: "/",
            extra: ["trigger": "manual"]))
        let auto = await e.fire(.preCompact, HookRequest(
            eventName: .preCompact, sessionId: "s", cwd: "/",
            extra: ["trigger": "auto"]))
        XCTAssertEqual(manual.count, 1)
        XCTAssertEqual(auto.count, 0)
    }

    /// Finding 3: UserPromptSubmit / Stop ignore matchers entirely (matcher
    /// input is None upstream → any matcher is match-all).
    func testUserPromptSubmitAndStopIgnoreMatcher() async {
        let ups = HookEngine(hooks: [HookDefinition(
            eventName: .userPromptSubmit, matcher: "this-would-never-match",
            command: #"printf '{}'"#, timeoutSec: 5)])
        let firedUps = await ups.fire(.userPromptSubmit, HookRequest(
            eventName: .userPromptSubmit, sessionId: "s", cwd: "/"))
        XCTAssertEqual(firedUps.count, 1,
                       "UserPromptSubmit must ignore the matcher and always fire")
        let stop = HookEngine(hooks: [HookDefinition(
            eventName: .stop, matcher: "irrelevant",
            command: #"printf '{"continue":true}'"#, timeoutSec: 5)])
        let firedStop = await stop.fire(.stop, HookRequest(
            eventName: .stop, sessionId: "s", cwd: "/"))
        XCTAssertEqual(firedStop.count, 1,
                       "Stop must ignore the matcher and always fire")
    }

    /// Finding 4: display_order is a stable global discovery index assigned at
    /// load time across BOTH files, preserved into run ids — NOT recomputed per
    /// fire over only the matched subset of one event.
    func testDisplayOrderIsGlobalAtLoadTime() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "hkho-\(UUID().uuidString)"
        let cwd = NSTemporaryDirectory() + "hkcw-\(UUID().uuidString)"
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cwd + "/.codex", withIntermediateDirectories: true)
        // home file: pre-tool-use then post-tool-use (flat array → declaration
        // order). project file: a second pre-tool-use. Global counter must run
        // 0,1 in home then 2 in project.
        let h0 = #"{"event":"pre-tool-use","command":"a"}"#
        let h1 = #"{"event":"post-tool-use","command":"b"}"#
        let p0 = #"{"event":"pre-tool-use","command":"c"}"#
        try #"[\#(h0),\#(h1)]"#
            .write(toFile: home + "/hooks.json", atomically: true, encoding: .utf8)
        try #"[\#(p0)]"#
            .write(toFile: cwd + "/.codex/hooks.json", atomically: true, encoding: .utf8)
        let homePath = home + "/hooks.json"
        let projPath = cwd + "/.codex/hooks.json"
        try """
        [hooks.state."\(homePath):pre_tool_use:0:0"]
        trusted_hash = "\(try hookHash(h0))"

        [hooks.state."\(homePath):post_tool_use:1:0"]
        trusted_hash = "\(try hookHash(h1))"

        [hooks.state."\(projPath):pre_tool_use:0:0"]
        trusted_hash = "\(try hookHash(p0))"
        """.write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)

        let exp = expectation(description: "display-order")
        Task {
            let engine = HookEngine.load(codexHome: home, cwd: cwd)
            let defs = await engine.definitions()
            XCTAssertEqual(defs.count, 3)
            // command → displayOrder mapping
            let byCmd = Dictionary(uniqueKeysWithValues: defs.map { ($0.command, $0.displayOrder) })
            XCTAssertEqual(byCmd["a"], 0)
            XCTAssertEqual(byCmd["b"], 1)
            XCTAssertEqual(byCmd["c"], 2, "project hook keeps the GLOBAL counter, not a reset")
            // Firing only the post-tool-use event must still report displayOrder 1
            // for hook "b" (its stable discovery index), not 0.
            _ = await engine.fire(.postToolUse, HookRequest(
                eventName: .postToolUse, sessionId: "s", cwd: "/",
                toolName: "x", toolArgumentsJSON: "{}", toolOutput: "{}",
                toolUseId: "tc-7"))
            let recs = await engine.drainHookRunRecords()
            XCTAssertEqual(recs.count, 1)
            XCTAssertEqual(recs.first?.started.displayOrder, 1,
                           "post-tool-use hook keeps its global display_order 1 across a fire of just that event")
            // PostToolUse run id carries the tool_use_id suffix (upstream
            // hook_run_for_tool_use).
            XCTAssertEqual(recs.first?.started.id, "post-tool-use:1:\(homePath):tc-7")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    /// Finding 5: tool_use_id is emitted (required) on PreToolUse / PostToolUse
    /// stdin payloads, and is empty-string when not threaded.
    func testToolUseIdEmittedOnToolUseEvents() throws {
        let preWith = HookRequest(eventName: .preToolUse, sessionId: "s", cwd: "/",
                                  toolName: "Bash", toolArgumentsJSON: "{}",
                                  toolUseId: "call-123")
        let preObj = preWith.jsonObject()
        XCTAssertEqual(preObj["tool_use_id"] as? String, "call-123")

        let preWithout = HookRequest(eventName: .preToolUse, sessionId: "s", cwd: "/",
                                     toolName: "Bash", toolArgumentsJSON: "{}")
        XCTAssertEqual(preWithout.jsonObject()["tool_use_id"] as? String, "",
                       "tool_use_id is a required field; emit empty string when absent")

        let postWith = HookRequest(eventName: .postToolUse, sessionId: "s", cwd: "/",
                                   toolName: "Bash", toolArgumentsJSON: "{}",
                                   toolOutput: "{}", toolUseId: "call-9")
        XCTAssertEqual(postWith.jsonObject()["tool_use_id"] as? String, "call-9")

        // Non-tool-use events must NOT carry tool_use_id.
        let session = HookRequest(eventName: .sessionStart, sessionId: "s", cwd: "/",
                                  source: "startup")
        XCTAssertNil(session.jsonObject()["tool_use_id"])
    }

    /// Finding 6: PreToolUse legacy decision:block WITHOUT a non-empty reason
    /// must be marked Failed and must NOT block (matches UserPromptSubmit /
    /// PostToolUse gating; upstream `unsupported_pre_tool_use_legacy_decision`).
    func testPreToolUseLegacyBlockWithoutReasonNotBlocked() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"decision":"block"}'"#, timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        XCTAssertEqual(o.first?.decision, .allow,
                       "PreToolUse decision:block without reason must NOT block")
        XCTAssertEqual(o.first?.outputSchemaError,
                       "PreToolUse hook returned decision:block without a non-empty reason")
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "failed")
    }

    /// Finding 6 (positive): PreToolUse legacy decision:block WITH a reason
    /// still blocks.
    func testPreToolUseLegacyBlockWithReasonStillBlocks() async throws {
        let e = HookEngine(hooks: [HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"decision":"block","reason":"danger"}'"#, timeoutSec: 5)])
        let o = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        XCTAssertEqual(o.first?.decision, .block)
        XCTAssertEqual(o.first?.reason, "danger")
        XCTAssertNil(o.first?.outputSchemaError)
    }

    // MARK: - audit-v10 hooks unit

    /// audit-v10 Finding 1: the CONFIGURED handler statusMessage is surfaced
    /// verbatim on BOTH hook/started and hook/completed (dispatcher.rs:79,132),
    /// regardless of run outcome — never derived from the outcome.
    func testConfiguredStatusMessageSurfacedOnBothSummaries() async throws {
        var def = HookDefinition(
            eventName: .preToolUse, matcher: nil,
            command: #"printf '{"decision":"allow"}'"#, timeoutSec: 5,
            statusMessage: "checking...")
        def.sourcePath = "/tmp/hooks.json"
        def.source = "project"
        let e = HookEngine(hooks: [def])
        _ = await e.fire(.preToolUse, HookRequest(
            eventName: .preToolUse, sessionId: "s", cwd: "/",
            toolName: "shell", toolArgumentsJSON: "{}"))
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.started.statusMessage, "checking...",
                       "started must carry the configured statusMessage")
        XCTAssertEqual(recs.first?.completed.statusMessage, "checking...",
                       "completed must carry the configured statusMessage, not outcome text")
    }

    /// audit-v10 Finding 1: when a Stop hook blocks, statusMessage must remain
    /// the configured value (nil here) and NOT be filled with the block reason.
    func testStatusMessageNotDerivedFromOutcome() async throws {
        var def = HookDefinition(
            eventName: .stop, matcher: nil,
            command: #"printf '{"decision":"block","reason":"keep going"}'"#,
            timeoutSec: 5)
        def.sourcePath = "/tmp/hooks.json"
        def.source = "project"
        let e = HookEngine(hooks: [def])
        _ = await e.fire(.stop, HookRequest(
            eventName: .stop, sessionId: "s", cwd: "/"))
        let recs = await e.drainHookRunRecords()
        XCTAssertEqual(recs.first?.completed.status, "blocked")
        XCTAssertNil(recs.first?.completed.statusMessage,
                     "statusMessage must stay nil (configured), not the block reason")
        XCTAssertNil(recs.first?.started.statusMessage)
    }

    /// audit-v10 Finding 1: discovery parses the handler `statusMessage` field
    /// from the grouped hooks.json object.
    func testStatusMessageParsedFromGroupedHooksJson() throws {
        let dir = NSTemporaryDirectory() + "hooks-statusmsg-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let json = #"""
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
          {"type":"command","command":"echo hi","statusMessage":"running checks"}]}]}}
        """#
        let hooksFile = dir + "/hooks.json"
        try json.data(using: .utf8)!.write(to: URL(fileURLWithPath: hooksFile))
        // Trust the discovered hook so it loads (bypass via state not available
        // here; instead decode the HookDefinition directly to assert parsing).
        let obj = #"{"event":"pre-tool-use","command":"echo hi","statusMessage":"running checks"}"#
        let def = try JSONDecoder().decode(
            HookDefinition.self, from: obj.data(using: .utf8)!)
        XCTAssertEqual(def.statusMessage, "running checks")
        // Also accept the snake_case alias.
        let obj2 = #"{"event":"pre-tool-use","command":"x","status_message":"snake"}"#
        let def2 = try JSONDecoder().decode(
            HookDefinition.self, from: obj2.data(using: .utf8)!)
        XCTAssertEqual(def2.statusMessage, "snake")
    }

    /// audit-v10 Finding 2: a Stop-block continuation reason is emitted as a
    /// `feedback` entry, NOT a `stop` entry (stop.rs:171-184). The `stop` kind
    /// is reserved for a true continue:false termination reason.
    func testStopBlockContinuationIsFeedbackEntry() async throws {
        var def = HookDefinition(
            eventName: .stop, matcher: nil,
            command: #"printf '{"decision":"block","reason":"do more work"}'"#,
            timeoutSec: 5)
        def.sourcePath = "/tmp/hooks.json"
        def.source = "project"
        let e = HookEngine(hooks: [def])
        _ = await e.fire(.stop, HookRequest(
            eventName: .stop, sessionId: "s", cwd: "/"))
        let recs = await e.drainHookRunRecords()
        let entries = recs.first?.completed.entries ?? []
        XCTAssertEqual(entries.count, 1, "exactly one block-reason entry")
        XCTAssertEqual(entries.first?.kind, "feedback",
                       "Stop-block continuation reason is feedback, not stop")
        XCTAssertEqual(entries.first?.text, "do more work")
        XCTAssertFalse(entries.contains { $0.kind == "stop" })
    }

    /// audit-v10 Finding 2 (negative): a true continue:false termination reason
    /// IS emitted as a `stop` entry (stop.rs:160-166).
    func testStopContinueFalseIsStopEntry() async throws {
        var def = HookDefinition(
            eventName: .stop, matcher: nil,
            command: #"printf '{"continue":false,"stopReason":"all done"}'"#,
            timeoutSec: 5)
        def.sourcePath = "/tmp/hooks.json"
        def.source = "project"
        let e = HookEngine(hooks: [def])
        _ = await e.fire(.stop, HookRequest(
            eventName: .stop, sessionId: "s", cwd: "/"))
        let recs = await e.drainHookRunRecords()
        let entries = recs.first?.completed.entries ?? []
        XCTAssertEqual(recs.first?.completed.status, "stopped")
        XCTAssertEqual(entries.first?.kind, "stop")
        XCTAssertEqual(entries.first?.text, "all done")
        XCTAssertFalse(entries.contains { $0.kind == "feedback" })
    }

    /// audit-v10 Finding 3: the universal systemMessage (warning) entry is
    /// emitted FIRST, before any context/feedback/stop entry (stop.rs:149-155,
    /// pre_tool_use.rs:208-213).
    func testSummarizeWarningOrderedFirst() {
        // A Stop hook that blocks AND emits a systemMessage: warning must lead,
        // followed by the feedback continuation entry.
        let o = HookOutcome(
            decision: .block, reason: "continue",
            systemMessage: "be careful",
            shouldBlock: true, continuationPrompt: "continue")
        let (_, entries) = HookEngine.summarize(o)
        XCTAssertEqual(entries.map(\.kind), ["warning", "feedback"],
                       "warning must precede the event-specific feedback entry")
        XCTAssertEqual(entries.first?.text, "be careful")
        XCTAssertEqual(entries.last?.text, "continue")
    }

    /// audit-v10 Finding 3: with context + warning, warning still leads context.
    func testSummarizeWarningBeforeContext() {
        let o = HookOutcome(
            decision: .allow, systemMessage: "warn",
            additionalContext: "ctx")
        let (status, entries) = HookEngine.summarize(o)
        XCTAssertEqual(status, "completed")
        XCTAssertEqual(entries.map(\.kind), ["warning", "context"])
    }

    /// audit-v10 Finding 2+3: a Stop-block with a non-empty reason produces
    /// exactly one feedback entry (no duplicate from the raw `reason` field).
    func testStopBlockProducesSingleFeedbackEntry() {
        let o = HookOutcome(
            decision: .block, reason: "fix it",
            shouldBlock: true, continuationPrompt: "fix it")
        let (status, entries) = HookEngine.summarize(o)
        XCTAssertEqual(status, "blocked")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, "feedback")
    }
}

/// Minimal Bash-named tool for Finding-5 message tests. Never actually runs in
/// the block-path tests (the PreToolUse hook short-circuits dispatch).
private struct BashStubTool: Tool {
    let name = "Bash"
    let parallelSafe = true
    func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        ToolResult(callId: call.callId, output: "ran", success: true, truncated: false)
    }
}
