import XCTest
@testable import Tools

final class CommandSafetyTests: XCTestCase {

    func testSafeReadCommands() {
        let safe = [
            "ls -la", "pwd", "cat README.md", "head -n 20 f", "tail -f f",
            "wc -l f", "grep -n foo f", "rg pattern .", "git status",
            "git diff", "git log --oneline -20", "git show abc",
            "git branch", "find . -name foo.swift",
            "sed -n '1,5p' f", "stat f", "uname -a", "echo hello world",
            "which swift", "uniq f", "true",
        ]
        for c in safe {
            XCTAssertEqual(CommandSafety.classify(shell: c), .safe,
                           "expected safe: \(c)")
        }
    }

    func testUnsafeCommandsNeedApproval() {
        let unsafe = [
            "rm -rf /tmp/x", "mkdir -p /tmp/x", "mv a b", "cp a b",
            "python3 -c 'import os'", "bash -c 'rm -rf /'", "sh script.sh",
            "node app.js", "git push", "git commit -m x", "git reset --hard",
            "sed -i s/a/b/ f", "find . -delete", "find . -exec rm {} ;",
            "tee out.txt", "echo hi > f", "cat f | tee g", "FOO=1 ls",
            "echo $(whoami)", "echo `id`", "ls *.swift", "curl http://x",
            "ls && rm x", "ls; rm x", "true || rm x",
            // Parity: these are NOT in upstream `is_safe_to_call_with_exec`,
            // so they must fall through to the approval prompt rather than be
            // auto-trusted (the codex-swift extension allowlist was removed).
            "realpath .", "diff a b", "sort f", "printf hi", "less f",
            "more f", "ps aux", "du -sh .", "df -h", "tree .", "date",
            "file x", "printenv", "hostname",
        ]
        for c in unsafe {
            XCTAssertEqual(CommandSafety.classify(shell: c), .needsApproval,
                           "expected needsApproval: \(c)")
        }
    }

    func testArgvClassification() {
        XCTAssertEqual(CommandSafety.classify(argv: ["ls", "-la"]), .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "status"]), .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "push"]), .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["rm", "-rf", "/"]), .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: []), .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["/bin/ls"]), .safe)
    }

    func testToolArgsJSONHelpers() {
        let strForm = #"{"command":"git status"}"#
        XCTAssertEqual(CommandSafety.argv(fromToolArgsJSON: strForm), ["git", "status"])
        XCTAssertEqual(CommandSafety.classifyToolArgs(strForm), .safe)

        let argvForm = #"{"command":["rm","-rf","/x"]}"#
        XCTAssertEqual(CommandSafety.argv(fromToolArgsJSON: argvForm), ["rm", "-rf", "/x"])
        XCTAssertEqual(CommandSafety.classifyToolArgs(argvForm), .needsApproval)

        XCTAssertTrue(CommandSafety.requiresEscalated(
            fromToolArgsJSON: #"{"command":"ls","sandbox_permissions":"require_escalated"}"#))
        XCTAssertFalse(CommandSafety.requiresEscalated(
            fromToolArgsJSON: #"{"command":"ls"}"#))
    }

    func testSegmentationIsQuoteAware() {
        // An operator inside quotes does not split the command.
        XCTAssertEqual(CommandSafety.classify(shell: "echo 'a && b'"), .safe)
        // A real operator does split → second segment unknown → needsApproval.
        XCTAssertEqual(CommandSafety.classify(shell: "echo hi && rm x"), .needsApproval)
    }

    // MARK: - Dangerous-command heuristic (command_might_be_dangerous parity)

    /// Base case: `rm -f` / `rm -rf` are dangerous; other `rm` forms and
    /// benign commands are not. Mirrors upstream `is_dangerous_to_call_with_exec`
    /// (`is_dangerous_command.rs:145-157`) and the `rm_rf_is_dangerous` /
    /// `rm_f_is_dangerous` upstream tests.
    func testDangerousCommandDetection() {
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["rm", "-f", "/"]))
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["rm", "-rf", "/"]))
        // Only the exact -f / -rf flags trip the heuristic.
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["rm", "-i", "/"]))
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["rm", "--force", "/"]))
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["rm", "-fd", "/"]))
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["rm"]))
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["ls"]))
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: []))
    }

    /// `sudo <cmd>` recurses on `<cmd>` (upstream lines 151-152), including
    /// multi-level unwrapping.
    func testDangerousCommandRecursiveSudoUnwrap() {
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["sudo", "rm", "-rf", "/"]))
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["sudo", "rm", "-f", "/etc/hosts"]))
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["sudo", "sudo", "rm", "-rf", "/"]))
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["sudo", "git", "status"]))
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["sudo"]))
    }

    /// `bash -lc "<script>"` / `sh -c` / `zsh -lc` decomposition: ANY inner
    /// command being dangerous flags the whole wrapper (upstream lines 19-26).
    func testDangerousCommandRecursiveBashUnwrap() {
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["bash", "-lc", "rm -rf /"]))
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["sh", "-c", "rm -rf /"]))
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["zsh", "-lc", "rm -f /etc/hosts"]))
        // ANY inner command (not just the first) being dangerous trips it.
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["bash", "-lc", "ls && rm -rf /"]))
        // sudo + rm unwrap together inside the script.
        XCTAssertTrue(CommandSafety.isDangerousCommand(argv: ["bash", "-lc", "sudo rm -rf /"]))
        // Benign script is not dangerous.
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["bash", "-lc", "echo hi"]))
        XCTAssertFalse(CommandSafety.isDangerousCommand(argv: ["bash", "-lc", "ls && echo hi"]))
    }
}