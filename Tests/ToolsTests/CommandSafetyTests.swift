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
            "which swift", "realpath .", "diff a b", "sort f", "true",
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
}