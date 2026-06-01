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
        // Non-matching, non-dangerous, unmatched argv under the default policy
        // (`.prompt` = OnRequest, restricted sandbox, no override) is ALLOWED
        // and relies on the sandbox — see
        // `render_decision_for_unmatched_command` lines 715-731.
        XCTAssertEqual(ep.classify(argv: ["mkdir", "x"]), .safe)
        // But when the model requests a sandbox override, the same unmatched
        // command must PROMPT (upstream line 727-728).
        XCTAssertEqual(
            ep.classify(argv: ["mkdir", "x"],
                        approvalPolicy: .init(kind: .onRequest,
                                              sandboxKind: .restricted,
                                              requestsSandboxOverride: true)),
            .needsApproval)
    }

    // MARK: - Unmatched dangerous-command gate (render_decision_for_unmatched_command)

    /// Under `.never`, a dangerous unmatched command must be FORBIDDEN (not run
    /// in the sandbox), unless the sandbox is explicitly disabled — in which
    /// case it is allowed. Mirrors upstream lines 684-696.
    func testDangerousCommandUnmatchedNeverPolicy() {
        let ep = ExecPolicy()
        XCTAssertEqual(
            ep.classify(argv: ["rm", "-rf", "/"], approvalPolicy: .never),
            .forbidden, "dangerous unmatched command is forbidden under .never")
        XCTAssertEqual(
            ep.classify(argv: ["sudo", "rm", "-rf", "/"], approvalPolicy: .never),
            .forbidden)
        XCTAssertEqual(
            ep.classify(argv: ["bash", "-lc", "rm -rf /"], approvalPolicy: .never),
            .forbidden, "dangerous inner command in a shell wrapper is forbidden")
        // Benign command stays safe even under .never.
        XCTAssertEqual(
            ep.classify(argv: ["git", "status"], approvalPolicy: .never), .safe)
        // A non-dangerous unmatched command under `.never` is ALLOWED (relying
        // on the sandbox), NOT escalated to a prompt or forbidden — upstream
        // `render_decision_for_unmatched_command` lines 704-708 return
        // `Decision::Allow` for Never/OnFailure.
        XCTAssertEqual(
            ep.classify(argv: ["mkdir", "x"], approvalPolicy: .never), .safe)
    }

    /// Full unmatched-command truth table parity for the non-dangerous tail
    /// (upstream `render_decision_for_unmatched_command` lines 704-749).
    func testNonDangerousUnmatchedTruthTable() {
        let ep = ExecPolicy()
        let cmd = ["mkdir", "x"]   // non-dangerous, unmatched, not known-safe

        func policy(_ kind: ExecPolicy.UnmatchedApprovalPolicy.Kind,
                    _ sandbox: ExecPolicy.UnmatchedApprovalPolicy.SandboxKind,
                    override: Bool = false) -> ExecPolicy.UnmatchedApprovalPolicy {
            .init(kind: kind, sandboxKind: sandbox, requestsSandboxOverride: override)
        }

        // Never / OnFailure → Allow regardless of sandbox kind.
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.never, .restricted)), .safe)
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.onFailure, .restricted)), .safe)
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.onFailure, .unrestricted)), .safe)

        // UnlessTrusted → Prompt for a non-known-safe command…
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.unlessTrusted, .restricted)), .needsApproval)
        // …but a known-safe command is ALLOWED under UnlessTrusted (short-circuit).
        XCTAssertEqual(ep.classify(argv: ["git", "status"], approvalPolicy: policy(.unlessTrusted, .restricted)), .safe)

        // OnRequest / Granular: unrestricted → Allow; restricted → Allow unless
        // the model requested a sandbox override (then Prompt).
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.onRequest, .unrestricted)), .safe)
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.onRequest, .restricted)), .safe)
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.onRequest, .restricted, override: true)), .needsApproval)
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.granular, .unrestricted)), .safe)
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.granular, .restricted)), .safe)
        XCTAssertEqual(ep.classify(argv: cmd, approvalPolicy: policy(.granular, .restricted, override: true)), .needsApproval)
    }

    /// When the sandbox is explicitly disabled, even under `.never` a dangerous
    /// unmatched command is allowed to run (upstream lines 686-692).
    func testDangerousCommandNeverWithSandboxDisabledAllows() {
        let ep = ExecPolicy()
        XCTAssertEqual(
            ep.classify(argv: ["rm", "-rf", "/"], approvalPolicy: .never,
                        sandboxExplicitlyDisabled: true),
            .safe)
    }

    /// Under any non-never policy a dangerous unmatched command PROMPTS
    /// (needsApproval) rather than running silently (upstream lines 697-701).
    func testDangerousCommandUnmatchedOtherPolicies() {
        let ep = ExecPolicy()
        // .prompt is the default approvalPolicy.
        XCTAssertEqual(ep.classify(argv: ["rm", "-rf", "/"]), .needsApproval)
        XCTAssertEqual(
            ep.classify(argv: ["rm", "-rf", "/"], approvalPolicy: .prompt),
            .needsApproval)
        XCTAssertEqual(
            ep.classify(argv: ["bash", "-lc", "sudo rm -rf /"], approvalPolicy: .prompt),
            .needsApproval)
    }

    /// A dangerous command matched by an explicit allow rule is NOT affected by
    /// the unmatched dangerous gate (upstream applies the gate only to
    /// unmatched commands).
    func testAllowRuleBypassesDangerousGateUnderNever() {
        let ep = ExecPolicy(rules: .init(forbidden: [], allow: [["rm", "-rf"]]))
        XCTAssertEqual(
            ep.classify(argv: ["rm", "-rf", "/tmp/x"], approvalPolicy: .never),
            .safe, "an explicit allow rule wins over the dangerous gate")
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
        // Parity: rules live only in `$CODEX_HOME/rules/*.rules` (upstream
        // collect_policy_files). Express forbidden/allow prefixes as
        // prefix_rule lines.
        try FileManager.default.createDirectory(atPath: home + "/rules",
                                                withIntermediateDirectories: true)
        let policy = #"""
        prefix_rule(pattern = ["rm", "-rf", "/"], decision = "forbidden")
        prefix_rule(pattern = ["cargo", "test"], decision = "allow")
        """#
        try policy.write(toFile: home + "/rules/default.rules",
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
        try FileManager.default.createDirectory(atPath: home + "/rules",
                                                withIntermediateDirectories: true)
        try policy.write(toFile: home + "/rules/default.rules",
                         atomically: true, encoding: .utf8)
        let ep = try ExecPolicy.loadStrict(codexHome: home)

        XCTAssertEqual(ep.classify(argv: [allowedGit, "status"]), .safe,
                       "an exact absolute-path rule wins before basename fallback")
        XCTAssertEqual(ep.classify(argv: [otherGit, "status"]), .safe,
                       "host_executable allowlist blocks fallback for unlisted absolute paths")

        let fallbackHome = tmp(); defer { try? FileManager.default.removeItem(atPath: fallbackHome) }
        try FileManager.default.createDirectory(atPath: fallbackHome + "/rules",
                                                withIntermediateDirectories: true)
        try #"prefix_rule(pattern = ["git"], decision = "prompt")"#
            .write(toFile: fallbackHome + "/rules/default.rules",
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
        try FileManager.default.createDirectory(atPath: home + "/rules",
                                                withIntermediateDirectories: true)
        try policy.write(toFile: home + "/rules/default.rules",
                         atomically: true, encoding: .utf8)
        let ep = try ExecPolicy.loadStrict(codexHome: home)
        let compiled = ep.compiledNetworkDomains()
        XCTAssertEqual(compiled.allowed, ["google.com", "api.github.com"])
        XCTAssertEqual(compiled.denied, ["blocked.example.com"])
    }

    func testInvalidRuleFilesFailClosed() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/rules",
                                                withIntermediateDirectories: true)
        try #"network_rule(host = "*", protocol = "http", decision = "allow")"#
            .write(toFile: home + "/rules/default.rules",
                   atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ExecPolicy.loadStrict(codexHome: home))
        let ep = ExecPolicy.load(codexHome: home)
        XCTAssertEqual(ep.classify(argv: ["git", "status"]), .forbidden)
        XCTAssertEqual(ep.classify(argv: ["rm", "-rf", "/tmp/x"]), .forbidden)
    }

    func testPrefixRuleExampleValidationRejectsBadPolicy() throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/rules",
                                                withIntermediateDirectories: true)
        try #"""
        prefix_rule(
            pattern = ["git", "status"],
            not_match = [["git", "status"]],
        )
        """#.write(toFile: home + "/rules/default.rules",
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

    // MARK: - canonicalizeCommandForApproval (command_canonicalization.rs parity)

    /// Ports upstream `canonicalizes_word_only_shell_scripts_to_inner_command`
    /// (command_canonicalization_tests.rs): a plain word-only `shell -lc`
    /// invocation collapses to the inner argv, and wrapper-path / whitespace
    /// variations produce the same canonical key.
    func testCanonicalizeWordOnlyShellScriptCollapsesToInnerCommand() {
        let a = CommandSafety.canonicalizeCommandForApproval(
            ["/bin/bash", "-lc", "cargo test -p codex-core"])
        XCTAssertEqual(a, ["cargo", "test", "-p", "codex-core"])
        let b = CommandSafety.canonicalizeCommandForApproval(
            ["bash", "-lc", "cargo   test   -p codex-core"])
        XCTAssertEqual(a, b, "wrapper-path + whitespace variations canonicalize identically")
    }

    /// Ports upstream `canonicalizes_heredoc_scripts_to_stable_script_key`:
    /// a complex (here-doc) script collapses to
    /// ["__codex_shell_script__", <shell_mode>, <script>] and is stable across
    /// the wrapper-path spelling.
    func testCanonicalizeHeredocScriptUsesStableScriptKey() {
        let script = "python3 <<'PY'\nprint('hello')\nPY"
        let a = CommandSafety.canonicalizeCommandForApproval(
            ["/bin/zsh", "-lc", script])
        XCTAssertEqual(a, ["__codex_shell_script__", "-lc", script])
        let b = CommandSafety.canonicalizeCommandForApproval(
            ["zsh", "-lc", script])
        XCTAssertEqual(a, b, "wrapper-path variations canonicalize identically")
        XCTAssertTrue(CommandSafety.isCanonicalScriptKey(a))
    }

    /// Ports upstream `canonicalizes_powershell_wrappers_to_stable_script_key`.
    func testCanonicalizePowershellWrapperUsesStableScriptKey() {
        let script = "Write-Host hi"
        let a = CommandSafety.canonicalizeCommandForApproval(
            ["powershell.exe", "-NoProfile", "-Command", script])
        XCTAssertEqual(a, ["__codex_powershell_script__", script])
        let b = CommandSafety.canonicalizeCommandForApproval(
            ["powershell", "-Command", script])
        XCTAssertEqual(a, b, "wrapper-path / extra-flag variations canonicalize identically")
        XCTAssertTrue(CommandSafety.isCanonicalScriptKey(a))
    }

    /// Ports upstream `preserves_non_shell_commands`: a plain non-shell argv is
    /// returned verbatim and is NOT treated as a synthetic script key.
    func testCanonicalizePreservesNonShellCommands() {
        let cmd = ["cargo", "fmt"]
        XCTAssertEqual(CommandSafety.canonicalizeCommandForApproval(cmd), cmd)
        XCTAssertFalse(CommandSafety.isCanonicalScriptKey(cmd))
    }

    /// The in-memory approval cache + persisted prefix rule both key on the
    /// canonicalized command: a `bash -lc "<plain cmd>"` approval matches the
    /// same command spelled via a different wrapper path, and the persisted
    /// `default.rules` line is the precise inner-command prefix (NOT the
    /// over-broad ["bash", "-lc"] form, and NOT a synthetic token).
    func testInsertArgvCanonicalizesPlainShellWrapper() async throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let s = ApprovedRuleStore(codexHome: home)
        await s.insertArgv(["/bin/bash", "-lc", "cargo test -p codex-core"])

        // In-memory cache key is the canonical inner argv joined by spaces.
        let hasCanonical = await s.contains("cargo test -p codex-core")
        XCTAssertTrue(hasCanonical, "approval cache keys on the canonical inner command")
        // The over-broad wrapper-prefix key must NOT be what we stored.
        let hasWrapperKey = await s.contains("bash -lc")
        XCTAssertFalse(hasWrapperKey, "must not key on the over-broad [bash,-lc] prefix")

        // Persisted prefix_rule uses the precise inner-command prefix.
        let path = home + "/rules/default.rules"
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(
            contents,
            "prefix_rule(pattern=[\"cargo\", \"test\", \"-p\", \"codex-core\"], decision=\"allow\")\n",
            "persisted rule must be the canonical inner-command argv, not the shell wrapper")
    }

    /// For a complex (here-doc) script the in-memory key is the synthetic
    /// __codex_shell_script__ form, but the persisted `default.rules` line must
    /// fall back to a REAL argv prefix (never the synthetic token, which could
    /// never match a future real command).
    func testInsertArgvComplexScriptDoesNotPersistSyntheticToken() async throws {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let s = ApprovedRuleStore(codexHome: home)
        let script = "python3 <<'PY'\nprint('hi')\nPY"
        await s.insertArgv(["bash", "-lc", script])

        // In-memory cache uses the stable synthetic script key.
        let key = "__codex_shell_script__ -lc \(script)"
        let hasKey = await s.contains(key)
        XCTAssertTrue(hasKey, "complex script keys on the synthetic __codex_shell_script__ form")

        // Persisted rule must NOT contain the synthetic token.
        let path = home + "/rules/default.rules"
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(contents.contains("__codex_shell_script__"),
                       "synthetic cache token must never be persisted as a prefix_rule")
        XCTAssertEqual(
            contents,
            "prefix_rule(pattern=[\"bash\", \"-lc\"], decision=\"allow\")\n",
            "persisted rule falls back to the real argv prefix for complex scripts")
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

    // MARK: - classifyDetailed (Findings 3/4/5)

    private func writePolicy(_ body: String) throws -> ExecPolicy {
        let home = tmp()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/rules",
                                                withIntermediateDirectories: true)
        try body.write(toFile: home + "/rules/default.rules",
                       atomically: true, encoding: .utf8)
        return try ExecPolicy.loadStrict(codexHome: home)
    }

    // Finding 4: an explicit allow-RULE sets bypass_sandbox=true; an
    // allowed-by-heuristic-fallback command does NOT bypass the sandbox.
    func testAllowRuleSetsBypassSandbox() throws {
        let ep = try writePolicy(#"""
        prefix_rule(pattern = ["cargo", "test"], decision = "allow")
        """#)
        let allowed = ep.classifyDetailed(argv: ["cargo", "test", "--all"])
        XCTAssertEqual(allowed.decision, .safe)
        XCTAssertTrue(allowed.bypassSandbox, "explicit allow-rule must bypass sandbox")
        XCTAssertEqual(allowed.matchKind, .policyRule)

        // A known-safe command not covered by any rule is .safe but must NOT
        // bypass the sandbox (heuristic fallback, not an allow-rule).
        let heuristic = ExecPolicy().classifyDetailed(argv: ["git", "status"])
        XCTAssertEqual(heuristic.decision, .safe)
        XCTAssertFalse(heuristic.bypassSandbox)
        XCTAssertEqual(heuristic.matchKind, .heuristic)
    }

    // Finding 4: a shell wrapper whose inner commands are not ALL allow-ruled
    // must not bypass the sandbox.
    func testBypassSandboxRequiresEveryCommandAllowed() throws {
        let ep = try writePolicy(#"""
        prefix_rule(pattern = ["echo"], decision = "allow")
        """#)
        // `echo hi && ls` — echo is allowed, ls is fallback-safe (not a rule).
        let cls = ep.classifyDetailed(argv: ["bash", "-lc", "echo hi && ls"])
        XCTAssertEqual(cls.decision, .safe)
        XCTAssertFalse(cls.bypassSandbox,
            "bypass requires EVERY segment matched by an allow-rule")
    }

    // Finding 3: a policy 'prompt' RULE is matchKind == .policyRule with a
    // needsApproval decision, so the SessionEngine can reject it under Never.
    func testPromptRuleIsPolicyRule() throws {
        let ep = try writePolicy(#"""
        prefix_rule(pattern = ["deploy"], decision = "prompt")
        """#)
        let cls = ep.classifyDetailed(argv: ["deploy", "prod"])
        XCTAssertEqual(cls.decision, .needsApproval)
        XCTAssertEqual(cls.matchKind, .policyRule)
    }

    // A sandbox/escalation prompt (no policy rule matched) is matchKind
    // .heuristic so it is gated by sandbox_approval, not rules.
    func testHeuristicPromptIsNotPolicyRule() {
        let policy = ExecPolicy.UnmatchedApprovalPolicy(
            kind: .onRequest, sandboxKind: .restricted, requestsSandboxOverride: true)
        let cls = ExecPolicy().classifyDetailed(argv: ["mkdir", "x"],
                                                approvalPolicy: policy)
        XCTAssertEqual(cls.decision, .needsApproval)
        XCTAssertEqual(cls.matchKind, .heuristic)
    }

    // Finding 5: derive_forbidden_reason — justification, prefix, and blanket
    // variants (exec_policy.rs:964-991).
    func testForbiddenReasonDerivation() throws {
        let ep = try writePolicy(#"""
        prefix_rule(
            pattern = ["git", "push"],
            decision = "forbidden",
            justification = "use the PR workflow instead",
        )
        prefix_rule(pattern = ["scp"], decision = "forbidden")
        """#)
        let withJust = ep.classifyDetailed(argv: ["git", "push", "origin"])
        XCTAssertEqual(withJust.forbiddenReason(command: ["git", "push", "origin"]),
            "`git push origin` rejected: use the PR workflow instead")

        let noJust = ep.classifyDetailed(argv: ["scp", "a", "b"])
        XCTAssertEqual(noJust.forbiddenReason(command: ["scp", "a", "b"]),
            "`scp a b` rejected: policy forbids commands starting with `scp`")

        // No matched forbidden rule → blanket reason.
        let blanket = ExecClassification(decision: .forbidden, matchKind: .heuristic,
                                         bypassSandbox: false, matchedRules: [])
        XCTAssertEqual(blanket.forbiddenReason(command: ["x"]),
            "`x` rejected: blocked by policy")
    }

    // Finding 5: derive_prompt_reason — justification vs by-policy
    // (exec_policy.rs:929-955).
    func testPromptReasonDerivation() throws {
        let ep = try writePolicy(#"""
        prefix_rule(
            pattern = ["terraform", "apply"],
            decision = "prompt",
            justification = "review the plan first",
        )
        prefix_rule(pattern = ["kubectl"], decision = "prompt")
        """#)
        let withJust = ep.classifyDetailed(argv: ["terraform", "apply", "-auto"])
        XCTAssertEqual(withJust.promptReason(command: ["terraform", "apply", "-auto"]),
            "`terraform apply -auto` requires approval: review the plan first")

        let noJust = ep.classifyDetailed(argv: ["kubectl", "delete", "pod"])
        XCTAssertEqual(noJust.promptReason(command: ["kubectl", "delete", "pod"]),
            "`kubectl delete pod` requires approval by policy")

        // A heuristic prompt (no policy rule) has no policy-author reason.
        let heuristic = ExecClassification(decision: .needsApproval,
                                           matchKind: .heuristic,
                                           bypassSandbox: false, matchedRules: [])
        XCTAssertNil(heuristic.promptReason(command: ["x"]))
    }

    // Finding 5: shlex quoting in reason strings — words with spaces/quotes are
    // shell-quoted (render_shlex_command, exec_policy.rs:957).
    func testReasonShlexQuoting() throws {
        let ep = try writePolicy(#"""
        prefix_rule(pattern = ["rm"], decision = "forbidden")
        """#)
        let cls = ep.classifyDetailed(argv: ["rm", "a b", "c'd"])
        let reason = cls.forbiddenReason(command: ["rm", "a b", "c'd"])
        XCTAssertEqual(reason,
            "`rm 'a b' 'c'\\''d'` rejected: policy forbids commands starting with `rm`")
    }

    // MARK: - Finding 5 (dup): proposed-execpolicy-amendment derivation
    // (try_derive_execpolicy_amendment_for_{prompt,allow}_rules,
    // BANNED_PREFIX_SUGGESTIONS, derive_requested_execpolicy_amendment_from_prefix_rule,
    // prefix_rule_would_approve_all_commands — exec_policy.rs:52-99, 822-926).

    // A heuristic PROMPT (no policy rule) yields a proposed amendment equal to
    // the heuristic-Prompt segment (try_derive_execpolicy_amendment_for_prompt_rules
    // first HeuristicsRuleMatch{decision: Prompt}, exec_policy.rs:832-840).
    func testPromptAmendmentFromHeuristicPrompt() {
        let policy = ExecPolicy.UnmatchedApprovalPolicy(
            kind: .onRequest, sandboxKind: .restricted, requestsSandboxOverride: true)
        let cls = ExecPolicy().classifyDetailed(argv: ["mydeploy", "--prod"],
                                                approvalPolicy: policy)
        XCTAssertEqual(cls.decision, .needsApproval)
        XCTAssertEqual(cls.matchKind, .heuristic)
        XCTAssertEqual(cls.proposedAmendmentForPromptRules(), ["mydeploy", "--prod"])
    }

    // A policy PROMPT rule suppresses the amendment: amending execpolicy would
    // not skip the policy requirement (exec_policy.rs:825-830).
    func testPromptAmendmentSuppressedByPolicyPromptRule() throws {
        let ep = try writePolicy(#"""
        prefix_rule(pattern = ["deploy"], decision = "prompt")
        """#)
        let cls = ep.classifyDetailed(argv: ["deploy", "prod"])
        XCTAssertEqual(cls.decision, .needsApproval)
        XCTAssertEqual(cls.matchKind, .policyRule)
        XCTAssertNil(cls.proposedAmendmentForPromptRules())
    }

    // The complex (here-doc) decomposition path disables auto-derived amendments
    // (auto_amendment_allowed = !used_complex_parsing, exec_policy.rs:294).
    func testPromptAmendmentSuppressedByComplexParsing() {
        // A bash heredoc that can only be decomposed by the single-command-prefix
        // (complex) path: usedComplexParsing == true, so no amendment.
        let policy = ExecPolicy.UnmatchedApprovalPolicy(
            kind: .onRequest, sandboxKind: .restricted, requestsSandboxOverride: true)
        let cls = ExecPolicy().classifyDetailed(
            argv: ["bash", "-lc", "mytool <<'EOF'\nsome input\nEOF"],
            approvalPolicy: policy)
        if cls.usedComplexParsing {
            XCTAssertNil(cls.proposedAmendmentForPromptRules(),
                "complex parsing must disable auto-derived amendments")
        }
    }

    // The allow-rule amendment derives the heuristic-Allow segment for the
    // sandbox-failure re-run prompt (try_derive_execpolicy_amendment_for_allow_rules,
    // exec_policy.rs:853-861).
    func testAllowAmendmentFromHeuristicAllow() {
        // Under Never, an unmatched non-dangerous command is allowed by heuristic
        // (render_decision_for_unmatched_command tail).
        let policy = ExecPolicy.UnmatchedApprovalPolicy(kind: .never)
        let cls = ExecPolicy().classifyDetailed(argv: ["mytool", "run"],
                                                approvalPolicy: policy)
        XCTAssertEqual(cls.decision, .safe)
        XCTAssertEqual(cls.matchKind, .heuristic)
        XCTAssertEqual(cls.proposedAmendmentForAllowRules(), ["mytool", "run"])
    }

    // A policy match (even an allow-rule) suppresses the allow-amendment: we
    // would already run unsandboxed via the rule (exec_policy.rs:849-851).
    func testAllowAmendmentSuppressedByPolicyMatch() throws {
        let ep = try writePolicy(#"""
        prefix_rule(pattern = ["cargo", "test"], decision = "allow")
        """#)
        let cls = ep.classifyDetailed(argv: ["cargo", "test", "--all"])
        XCTAssertEqual(cls.decision, .safe)
        XCTAssertEqual(cls.matchKind, .policyRule)
        XCTAssertNil(cls.proposedAmendmentForAllowRules())
    }

    // BANNED_PREFIX_SUGGESTIONS: exact-match interpreter/shell/privilege prefixes
    // are never suggested (exec_policy.rs:52-99, 876-884).
    func testBannedPrefixSuggestions() {
        XCTAssertTrue(ExecPolicyAmendmentDerivation.isBannedPrefix(["python3"]))
        XCTAssertTrue(ExecPolicyAmendmentDerivation.isBannedPrefix(["bash", "-lc"]))
        XCTAssertTrue(ExecPolicyAmendmentDerivation.isBannedPrefix(["sudo"]))
        XCTAssertTrue(ExecPolicyAmendmentDerivation.isBannedPrefix(["osascript"]))
        XCTAssertTrue(ExecPolicyAmendmentDerivation.isBannedPrefix(["powershell.exe", "-Command"]))
        // A longer prefix that merely starts with a banned word is NOT banned
        // (upstream requires exact length-and-element equality).
        XCTAssertFalse(ExecPolicyAmendmentDerivation.isBannedPrefix(["python3", "myscript.py"]))
        XCTAssertFalse(ExecPolicyAmendmentDerivation.isBannedPrefix(["git", "pull"]))
        XCTAssertFalse(ExecPolicyAmendmentDerivation.isBannedPrefix(["pytest"]))
    }

    // derive_requested_execpolicy_amendment_from_prefix_rule full truth table
    // (exec_policy.rs:864-903) + prefix_rule_would_approve_all_commands (:905-926).
    func testRequestedAmendmentFromPrefixRule() {
        let cmds = [["uv", "run", "pytest"]]
        // Happy path: non-empty, non-banned, no policy match, would approve all.
        XCTAssertEqual(
            ExecPolicyAmendmentDerivation.requestedAmendmentFromPrefixRule(
                prefixRule: ["uv", "run"], autoAmendmentAllowed: true,
                anyPolicyMatch: false, commands: cmds,
                wouldApprove: { prefix, all in all.allSatisfy { Array($0.prefix(prefix.count)) == prefix } }),
            ["uv", "run"])
        // nil prefix → nil.
        XCTAssertNil(ExecPolicyAmendmentDerivation.requestedAmendmentFromPrefixRule(
            prefixRule: nil, autoAmendmentAllowed: true, anyPolicyMatch: false,
            commands: cmds, wouldApprove: { _, _ in true }))
        // empty prefix → nil.
        XCTAssertNil(ExecPolicyAmendmentDerivation.requestedAmendmentFromPrefixRule(
            prefixRule: [], autoAmendmentAllowed: true, anyPolicyMatch: false,
            commands: cmds, wouldApprove: { _, _ in true }))
        // banned prefix → nil.
        XCTAssertNil(ExecPolicyAmendmentDerivation.requestedAmendmentFromPrefixRule(
            prefixRule: ["bash"], autoAmendmentAllowed: true, anyPolicyMatch: false,
            commands: cmds, wouldApprove: { _, _ in true }))
        // any policy match → nil.
        XCTAssertNil(ExecPolicyAmendmentDerivation.requestedAmendmentFromPrefixRule(
            prefixRule: ["uv", "run"], autoAmendmentAllowed: true, anyPolicyMatch: true,
            commands: cmds, wouldApprove: { _, _ in true }))
        // would NOT approve all → nil.
        XCTAssertNil(ExecPolicyAmendmentDerivation.requestedAmendmentFromPrefixRule(
            prefixRule: ["uv", "run"], autoAmendmentAllowed: true, anyPolicyMatch: false,
            commands: cmds, wouldApprove: { _, _ in false }))
        // auto-amendment gated off (complex parsing) → nil.
        XCTAssertNil(ExecPolicyAmendmentDerivation.requestedAmendmentFromPrefixRule(
            prefixRule: ["uv", "run"], autoAmendmentAllowed: false, anyPolicyMatch: false,
            commands: cmds, wouldApprove: { _, _ in true }))
    }
}
