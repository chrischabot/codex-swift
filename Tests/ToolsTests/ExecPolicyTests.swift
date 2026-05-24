import XCTest
import Foundation
@testable import Tools

final class ExecPolicyTests: XCTestCase {

    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "execpol-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func testDefaultDelegatesToCommandSafety() {
        let ep = ExecPolicy()
        XCTAssertEqual(ep.classify(argv: ["git", "status"]), .safe)
        XCTAssertEqual(ep.classify(argv: ["ls", "-la"]), .safe)
        XCTAssertEqual(ep.classify(argv: ["rm", "-rf", "/tmp/x"]), .needsApproval)
        XCTAssertEqual(ep.classify(argv: []), .needsApproval)
    }

    func testAllowRuleMakesSafe() {
        let ep = ExecPolicy(rules: .init(forbidden: [], allow: [["rm", "-rf"]]))
        // Default would be needsApproval; the allow prefix rule overrides it.
        XCTAssertEqual(ep.classify(argv: ["rm", "-rf", "/tmp/x"]), .safe)
        // Non-matching argv still uses the default classifier.
        XCTAssertEqual(ep.classify(argv: ["mkdir", "x"]), .needsApproval)
    }

    func testForbiddenWinsOverAllowAndDefault() {
        let ep = ExecPolicy(rules: .init(
            forbidden: [["curl"]],
            allow: [["curl"]]))
        XCTAssertEqual(ep.classify(argv: ["curl", "http://x"]), .forbidden,
                       "forbidden takes precedence over allow")
        // A safe default command not covered by rules stays safe.
        XCTAssertEqual(ep.classify(argv: ["git", "status"]), .safe)
    }

    func testArgvPrefixSemantics() {
        let ep = ExecPolicy(rules: .init(forbidden: [["git", "push"]], allow: []))
        XCTAssertEqual(ep.classify(argv: ["git", "push", "origin"]), .forbidden)
        XCTAssertEqual(ep.classify(argv: ["git", "status"]), .safe,
                       "a different git subcommand is not the forbidden prefix")
    }

    func testClassifyToolArgsJSON() {
        let ep = ExecPolicy(rules: .init(forbidden: [["rm"]], allow: []))
        XCTAssertEqual(ep.classifyToolArgs(#"{"command":"rm -rf /tmp/x"}"#), .forbidden)
        XCTAssertEqual(ep.classifyToolArgs(#"{"command":["git","status"]}"#), .safe)
    }

    func testLoadMissingFileIsDefault() {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let ep = ExecPolicy.load(codexHome: home)
        XCTAssertEqual(ep.rules.forbidden.count, 0)
        XCTAssertEqual(ep.rules.allow.count, 0)
        XCTAssertEqual(ep.classify(argv: ["git", "status"]), .safe)
    }

    func testLoadParsesUserRules() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let json = #"{"forbidden":[["rm","-rf","/"]],"allow":[["cargo","test"]]}"#
        try json.write(toFile: home + "/exec_policy.json",
                       atomically: true, encoding: .utf8)
        let ep = ExecPolicy.load(codexHome: home)
        XCTAssertEqual(ep.classify(argv: ["rm", "-rf", "/"]), .forbidden)
        XCTAssertEqual(ep.classify(argv: ["cargo", "test", "--all"]), .safe)
    }

    func testLoadsPrefixRuleFilesWithAlternativesAndStrictestDecision() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/rules",
                                                withIntermediateDirectories: true)
        let policy = #"""
        prefix_rule(
            pattern = ["git"],
            decision = "prompt",
        )
        prefix_rule(
            pattern = ["git", ["commit", "push"]],
            decision = "forbidden",
            justification = "mutates remote or history",
            match = [["git", "commit", "-m", "hi"], "git push origin main"],
        )
        prefix_rule(
            pattern = [["bash", "sh"], ["-lc", "-c"]],
            decision = "allow",
        )
        """#
        try policy.write(toFile: home + "/rules/default.rules",
                         atomically: true, encoding: .utf8)

        let ep = try ExecPolicy.loadStrict(codexHome: home)
        XCTAssertEqual(ep.classify(argv: ["git", "status"]), .needsApproval)
        XCTAssertEqual(ep.classify(argv: ["git", "commit", "-m", "hi"]), .forbidden)
        XCTAssertEqual(ep.classify(argv: ["git", "push", "origin", "main"]), .forbidden)
        XCTAssertEqual(ep.classify(argv: ["bash", "-lc", "echo hi"]), .safe)
        XCTAssertEqual(ep.classify(argv: ["sh", "-c", "echo hi"]), .safe)
        XCTAssertTrue(ep.allowedPrefixes().contains(["bash", "[-lc|-c]"]))
    }

    func testHostExecutableResolutionMatchesRustSemantics() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let allowedGit = "/usr/bin/git"
        let otherGit = "/opt/homebrew/bin/git"
        let policy = #"""
        prefix_rule(pattern = ["/usr/bin/git"], decision = "allow")
        prefix_rule(pattern = ["git"], decision = "prompt")
        host_executable(name = "git", paths = ["/usr/bin/git"])
        """#
        try policy.write(toFile: home + "/exec_policy.rules",
                         atomically: true, encoding: .utf8)
        let ep = try ExecPolicy.loadStrict(codexHome: home)

        XCTAssertEqual(ep.classify(argv: [allowedGit, "status"]), .safe,
                       "an exact absolute-path rule wins before basename fallback")
        XCTAssertEqual(ep.classify(argv: [otherGit, "status"]), .safe,
                       "host_executable allowlist blocks fallback for unlisted absolute paths")

        let fallbackHome = tmp(); defer { try? FileManager.default.removeItem(atPath: fallbackHome) }
        try #"prefix_rule(pattern = ["git"], decision = "prompt")"#
            .write(toFile: fallbackHome + "/exec_policy.rules",
                   atomically: true, encoding: .utf8)
        let fallback = try ExecPolicy.loadStrict(codexHome: fallbackHome)
        XCTAssertEqual(fallback.classify(argv: [otherGit, "status"]), .needsApproval,
                       "without a host_executable mapping, absolute paths may fall back to basename")
    }

    func testNetworkRulesNormalizeAndCompileDomains() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let policy = #"""
        network_rule(host = "Google.COM.", protocol = "http", decision = "allow")
        network_rule(host = "api.github.com:443", protocol = "https", decision = "allow")
        network_rule(host = "blocked.example.com", protocol = "https", decision = "deny")
        network_rule(host = "prompt-only.example.com", protocol = "https", decision = "prompt")
        """#
        try policy.write(toFile: home + "/exec_policy.rules",
                         atomically: true, encoding: .utf8)
        let ep = try ExecPolicy.loadStrict(codexHome: home)
        let compiled = ep.compiledNetworkDomains()
        XCTAssertEqual(compiled.allowed, ["google.com", "api.github.com"])
        XCTAssertEqual(compiled.denied, ["blocked.example.com"])
    }

    func testInvalidRuleFilesFailClosed() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"network_rule(host = "*", protocol = "http", decision = "allow")"#
            .write(toFile: home + "/exec_policy.rules",
                   atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ExecPolicy.loadStrict(codexHome: home))
        let ep = ExecPolicy.load(codexHome: home)
        XCTAssertEqual(ep.classify(argv: ["git", "status"]), .forbidden)
        XCTAssertEqual(ep.classify(argv: ["rm", "-rf", "/tmp/x"]), .forbidden)
    }

    func testPrefixRuleExampleValidationRejectsBadPolicy() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try #"""
        prefix_rule(
            pattern = ["git", "status"],
            not_match = [["git", "status"]],
        )
        """#.write(toFile: home + "/exec_policy.rules",
                   atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ExecPolicy.loadStrict(codexHome: home))
    }

    func testApprovedRuleStorePersistsAcrossInstances() async {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let s1 = ApprovedRuleStore(codexHome: home)
        let pre = await s1.contains("git push")
        XCTAssertFalse(pre)
        await s1.insert("git push")
        await s1.insert("apply_patch")
        let has = await s1.contains("git push")
        XCTAssertTrue(has)
        // A fresh instance over the same codexHome reloads the persisted set.
        let s2 = ApprovedRuleStore(codexHome: home)
        let reloaded = await s2.contains("git push")
        let reloaded2 = await s2.contains("apply_patch")
        XCTAssertTrue(reloaded, "approved prefix survived a process restart")
        XCTAssertTrue(reloaded2)
        let all = await s2.all()
        XCTAssertEqual(all, ["apply_patch", "git push"], "sorted, deduplicated")
    }

    func testApprovedRuleStoreInsertIsIdempotent() async {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let s = ApprovedRuleStore(codexHome: home)
        await s.insert("x")
        await s.insert("x")
        let all = await s.all()
        XCTAssertEqual(all, ["x"])
    }

    // MARK: - Canonical .rules persistence (Codex prefix_rule parity, H-22)

    /// Codex `ApprovedExecpolicyAmendment`: when the user opts to permanently
    /// allow a command prefix, the engine must persist it to
    /// `$CODEX_HOME/rules/default.rules` in upstream's canonical format
    /// (`prefix_rule(pattern=[…], decision="allow")`) so the Rust codex CLI
    /// and any other client picks up the same approval list.
    func testApprovedPrefixWritesCanonicalRulesFile() async throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let s = ApprovedRuleStore(codexHome: home)
        await s.insertArgv(["git", "status"])

        let path = home + "/rules/default.rules"
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "canonical rules file should be created")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents,
                       "prefix_rule(pattern=[\"git\", \"status\"], decision=\"allow\")\n",
                       "matches codex_execpolicy::blocking_append_allow_prefix_rule output")

        // Legacy JSON store is also populated (back-compat).
        let json = home + "/approved_commands.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: json))
        let all = await s.all()
        XCTAssertEqual(all, ["git status"])

        // Idempotent: a second insert of the same argv does not duplicate the
        // line in default.rules.
        await s.insertArgv(["git", "status"])
        let contents2 = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents2, contents, "duplicate rule lines must be deduped")
    }

    /// Codex parity: a pre-existing `default.rules` file must be loaded on
    /// session start so previously approved prefixes are honoured (no prompt).
    func testRulesFileLoadedOnStartup() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(
            atPath: home + "/rules", withIntermediateDirectories: true)
        // Pre-seed the canonical rules file as if a prior session wrote it.
        let seeded = "prefix_rule(pattern=[\"git\", \"status\"], decision=\"allow\")\n"
        try seeded.write(toFile: home + "/rules/default.rules",
                         atomically: true, encoding: .utf8)

        let ep = ExecPolicy.load(codexHome: home)
        XCTAssertEqual(ep.classify(argv: ["git", "status"]), .safe,
                       "previously approved prefix is recognised on startup")
        XCTAssertEqual(ep.classify(argv: ["git", "status", "-s"]), .safe,
                       "prefix matches longer argvs too")
        XCTAssertTrue(ep.allowedPrefixes().contains(["git", "status"]),
                      "allowedPrefixes() reflects the loaded rule")
    }

    /// Codex `NetworkPolicyAmendment`: when the user approves a specific host
    /// for network access, the engine must persist it to `default.rules` as a
    /// `network_rule(host=…, protocol=…, decision="allow")` line — the same
    /// format `blocking_append_network_rule` produces.
    func testNetworkRuleAmendmentWritesCanonicalForm() async throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let s = ApprovedRuleStore(codexHome: home)
        try await s.insertNetworkRule(
            host: "Api.GitHub.com", proto: .https, decision: .safe,
            justification: "Allow https_connect access to api.github.com")

        let path = home + "/rules/default.rules"
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents,
                       "network_rule(host=\"api.github.com\", protocol=\"https\", decision=\"allow\", justification=\"Allow https_connect access to api.github.com\")\n",
                       "matches codex_execpolicy::blocking_append_network_rule output")

        // Loading the file must surface the rule in compiledNetworkDomains().
        let ep = ExecPolicy.load(codexHome: home)
        let domains = ep.compiledNetworkDomains()
        XCTAssertTrue(domains.allowed.contains("api.github.com"))
        XCTAssertTrue(domains.denied.isEmpty)
    }

    /// Edge cases for the canonical line writer.
    func testRulesStoreRejectsEmptyPrefixAndWildcardHost() {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertThrowsError(
            try RulesStore.appendAllowPrefixRule(codexHome: home, prefix: []))
        XCTAssertThrowsError(
            try RulesStore.appendNetworkRule(
                codexHome: home, host: "*.example.com",
                proto: .https, decision: .safe))
    }

    /// JSON encoding of tokens with embedded quotes/backslashes must produce
    /// the same output as `serde_json::to_string` so the file round-trips
    /// across the Rust and Swift writers.
    func testRulesStoreEscapesEmbeddedQuotesInPrefixTokens() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try RulesStore.appendAllowPrefixRule(
            codexHome: home, prefix: ["echo", "Hello, \"world\"!"])
        let contents = try String(
            contentsOfFile: home + "/rules/default.rules", encoding: .utf8)
        XCTAssertEqual(contents,
                       "prefix_rule(pattern=[\"echo\", \"Hello, \\\"world\\\"!\"], decision=\"allow\")\n")
    }

    /// A pre-existing file without a trailing newline is gracefully handled
    /// (matches upstream `append_locked_line` behaviour).
    func testRulesStoreAppendsNewlineWhenMissing() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(
            atPath: home + "/rules", withIntermediateDirectories: true)
        let path = home + "/rules/default.rules"
        try "prefix_rule(pattern=[\"ls\"], decision=\"allow\")"
            .write(toFile: path, atomically: true, encoding: .utf8)
        try RulesStore.appendAllowPrefixRule(
            codexHome: home, prefix: ["echo", "hi"])
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents,
                       """
                       prefix_rule(pattern=["ls"], decision="allow")
                       prefix_rule(pattern=["echo", "hi"], decision="allow")

                       """)
    }

    /// P4.2: concurrent read against an in-flight writer. A Python helper
    /// takes an exclusive `flock(LOCK_EX)` on `default.rules`, sleeps long
    /// enough for the Swift reader to start, then writes a marker line and
    /// releases the lock. The Swift reader (`RulesStore.readLocked`) must
    /// take `LOCK_SH` and therefore block until the writer's release, at
    /// which point it must observe the full post-write contents — never the
    /// pre-write "in flight" state. This is the upstream `file.lock()`
    /// TOCTOU contract from `codex-rs/execpolicy/src/amend.rs`.
    func testRulesStoreReadLockedBlocksUntilWriterCompletes() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let rulesDir = home + "/rules"
        try FileManager.default.createDirectory(
            atPath: rulesDir, withIntermediateDirectories: true)
        let path = rulesDir + "/default.rules"
        // Seed with one existing rule so the file exists for O_RDONLY.
        try "prefix_rule(pattern=[\"ls\"], decision=\"allow\")\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        // Python helper: open the file, take LOCK_EX, sleep, append a new
        // line, then release. We can't use ObjC/Swift in a separate process,
        // so Python's `fcntl.flock` plays the role of "another process" that
        // holds the exclusive lock — exactly the multi-process TOCTOU
        // scenario upstream's `file.lock()` is designed to handle.
        let script = """
        import fcntl, os, sys, time
        path = sys.argv[1]
        hold = float(sys.argv[2])
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX)
        # Hold the lock; the reader's flock(LOCK_SH) must block here.
        time.sleep(hold)
        # Append a marker line while still holding the lock so a non-locked
        # reader would observe the half-written state.
        os.lseek(fd, 0, os.SEEK_END)
        os.write(fd, b'prefix_rule(pattern=["echo"], decision="allow")\\n')
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", script, path, "0.8"]
        let stderr = Pipe()
        proc.standardError = stderr
        try proc.run()

        // Give the Python helper a head start so it definitely owns the
        // exclusive lock before we try LOCK_SH.
        Thread.sleep(forTimeInterval: 0.15)
        let t0 = Date()
        let contents = try RulesStore.readLocked(path: path)
        let elapsed = Date().timeIntervalSince(t0)

        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0,
                       "python helper exit \(proc.terminationStatus): " +
                       (String(data: stderr.fileHandleForReading.availableData,
                               encoding: .utf8) ?? ""))

        // The reader must have blocked behind the writer — total wait
        // ≥ (hold − head_start). Use a conservative lower bound.
        XCTAssertGreaterThan(elapsed, 0.4,
            "reader returned in \(elapsed)s — shared lock did not wait for " +
            "the writer's exclusive lock (possible missing flock(LOCK_SH))")
        // We must see the writer's appended line — not the pre-write state.
        XCTAssertTrue(contents.contains("prefix_rule(pattern=[\"echo\"], decision=\"allow\")"),
            "reader observed pre-write state — \(contents)")
        XCTAssertTrue(contents.contains("prefix_rule(pattern=[\"ls\"], decision=\"allow\")"),
            "reader lost the pre-existing seed line — \(contents)")
    }
}
