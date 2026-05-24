import XCTest
@testable import Tools

/// Parity coverage for upstream
/// `codex-rs/shell-command/src/command_safety/is_safe_command.rs`:
/// rg option allowlist, git global-option rejection (`-C`, `-c`,
/// `--exec-path`), recursive `bash -lc "..."` shell-string parsing,
/// and `base64 -o` rejection.
final class CommandSafetyParityTests: XCTestCase {

    // MARK: ripgrep ----------------------------------------------------------

    func testRgOptionAllowlistAcceptsKnownSafeOptions() {
        // Known-safe flags should leave the command safe.
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "pattern", "-n"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "--type", "swift",
                                                      "pattern"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "--no-config",
                                                      "pattern"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "Cargo.toml", "-n"]),
                       .safe)
    }

    func testRgOptionAllowlistRejectsUnknownOptions() {
        // `--pre` and `--hostname-bin` (both with and without `=`) run code.
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "--pre", "pwned",
                                                      "files"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "--pre=pwned",
                                                      "files"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "--hostname-bin",
                                                      "pwned", "files"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "--hostname-bin=p",
                                                      "files"]),
                       .needsApproval)
        // `-z` / `--search-zip` delegate to external decompressors.
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "-z", "files"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["rg", "--search-zip",
                                                      "files"]),
                       .needsApproval)
    }

    // MARK: git global options ------------------------------------------------

    func testGitGlobalOptionRejectsDashCapitalC() {
        // `git -C <dir> status` MUST require approval — `-C` overrides cwd.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "-C", "/other",
                                                      "status"]),
                       .needsApproval)
        // Short-with-inline-value form (`-C.` / `-C/other`).
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "-C.", "status"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "-C/tmp/evil",
                                                      "status"]),
                       .needsApproval)
    }

    func testGitGlobalOptionRejectsDashLowercaseC() {
        // `git -c key=val log` (config injection) MUST require approval.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "-c",
                                                      "core.pager=cat", "log"]),
                       .needsApproval)
        // Short-with-inline-value form (`-ckey=val`).
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "-ccore.pager=cat",
                                                      "status"]),
                       .needsApproval)
    }

    func testGitExecPathRejected() {
        // `git --exec-path <dir>` overrides the git helper search path.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "--exec-path",
                                                      ".git/helpers", "show",
                                                      "HEAD"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git",
                                                      "--exec-path=.git/helpers",
                                                      "show", "HEAD"]),
                       .needsApproval)
        // Other namespace / work-tree / git-dir / paginate overrides too.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "--git-dir",
                                                      ".evil-git", "diff",
                                                      "HEAD"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "--work-tree", ".",
                                                      "status"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "--paginate", "log",
                                                      "-1"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "-p", "log", "-1"]),
                       .needsApproval)
    }

    // MARK: bash -lc recursive evaluation -------------------------------------

    func testBashDashLcRecursivelyEvaluates() {
        // `bash -lc "echo hi"` should reach the inner `echo` and be safe.
        XCTAssertEqual(CommandSafety.classify(argv: ["bash", "-lc", "echo hi"]),
                       .safe)
        // Composite of safe inner commands.
        XCTAssertEqual(CommandSafety.classify(argv: ["bash", "-lc",
                                                      "ls && pwd"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["bash", "-lc",
                                                      "git status"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["zsh", "-lc", "ls"]),
                       .safe)
    }

    func testBashDashLcRecursivelyRejectsUnsafeInner() {
        // `bash -lc "rm -rf /"` MUST be unsafe via recursive eval.
        XCTAssertEqual(CommandSafety.classify(argv: ["bash", "-lc",
                                                      "rm -rf /"]),
                       .needsApproval)
        // Mix of safe + unsafe.
        XCTAssertEqual(CommandSafety.classify(argv: ["bash", "-lc",
                                                      "ls && rm -rf /"]),
                       .needsApproval)
        // Unsafe git global option inside bash -lc.
        XCTAssertEqual(CommandSafety.classify(argv: ["bash", "-lc",
                                                      "git -C /other status"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["bash", "-lc",
                                                      "git --paginate log -1"]),
                       .needsApproval)
        // Four-arg "bash -lc git status" is NOT the recursive form (script
        // must be a single string).
        XCTAssertEqual(CommandSafety.classify(argv: ["bash", "-lc", "git",
                                                      "status"]),
                       .needsApproval)
    }

    // MARK: base64 ------------------------------------------------------------

    func testBase64DashODotRejected() {
        // Any output-redirection variant of base64 must require approval.
        XCTAssertEqual(CommandSafety.classify(argv: ["base64", "-o",
                                                      "/tmp/x"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["base64", "--output",
                                                      "/tmp/x"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["base64",
                                                      "--output=/tmp/x"]),
                       .needsApproval)
        // Short-with-inline-value form `-o<file>` (e.g. `-ob64.txt`).
        XCTAssertEqual(CommandSafety.classify(argv: ["base64", "-ob64.txt"]),
                       .needsApproval)
    }

    func testBase64ReadOnlyIsSafe() {
        // Plain base64 (read input, write stdout) is safe.
        XCTAssertEqual(CommandSafety.classify(argv: ["base64"]), .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["base64", "input.bin"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["base64", "-d",
                                                      "input.txt"]),
                       .safe)
    }

    // MARK: additional smoke (find, sed -n, git branch) -----------------------

    func testFindRejectsUnsafeOptions() {
        for unsafe: [String] in [
            ["find", ".", "-name", "x", "-exec", "rm", "{}", ";"],
            ["find", ".", "-execdir", "python3", "{}", ";"],
            ["find", ".", "-delete", "-name", "x"],
            ["find", ".", "-fprint", "/etc/passwd"],
        ] {
            XCTAssertEqual(CommandSafety.classify(argv: unsafe),
                           .needsApproval,
                           "expected unsafe: \(unsafe)")
        }
        // Plain find without unsafe options is safe.
        XCTAssertEqual(CommandSafety.classify(argv: ["find", ".", "-name",
                                                      "x"]),
                       .safe)
    }

    func testSedNumericPagePatternSafe() {
        XCTAssertEqual(CommandSafety.classify(argv: ["sed", "-n", "1,5p",
                                                      "file.txt"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["sed", "-n", "10p",
                                                      "file.txt"]),
                       .safe)
        // Invalid pattern → unsafe.
        XCTAssertEqual(CommandSafety.classify(argv: ["sed", "-n", "xp",
                                                      "file.txt"]),
                       .needsApproval)
    }

    func testGitBranchReadOnlySafe() {
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "branch"]), .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "branch",
                                                      "--show-current"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "branch", "-a"]),
                       .safe)
        // Mutating forms.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "branch", "-d",
                                                      "feature"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "branch",
                                                      "new-branch"]),
                       .needsApproval)
    }

    func testGitOutputFlagsRejected() {
        // `--output` / `--ext-diff` / `--textconv` cause writes / code exec.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "log", "--output",
                                                      "/tmp/x"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "diff",
                                                      "--output=/tmp/x"]),
                       .needsApproval)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "diff",
                                                      "--ext-diff"]),
                       .needsApproval)
    }

    func testGitFirstPositionalIsTheSubcommand() {
        // `git checkout status` MUST NOT be auto-approved by mis-reading
        // `status` as the subcommand.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "checkout",
                                                      "status"]),
                       .needsApproval)
    }

    // MARK: REV P4.4 — extended-subcommand bypass remediation ----------------
    //
    // The original implementation extended `safeGitSubcommands` to 24
    // subcommands (config, stash, tag, remote, reflog, ...). The reviewer
    // found this admits mutating operations that `UNSAFE_GIT_SUBCOMMAND_OPTIONS`
    // does not catch. The fix collapses the allowlist to upstream's exact
    // 5 (status, log, diff, show, branch). These tests pin that decision
    // and would have caught the original bypass.

    func testGitConfigHooksPathIsUnsafe() {
        // The flagship bypass: `git config --local core.hooksPath /evil`
        // sets the per-repo hook directory, enabling arbitrary code execution
        // on the next git operation in that repo.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "config", "--local",
                                                      "core.hooksPath",
                                                      "/evil"]),
                       .needsApproval)
        // Plain global config write must also be unsafe.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "config", "--global",
                                                      "user.name", "attacker"]),
                       .needsApproval)
        // Even a read-only `git config --get` is now unsafe (we are matching
        // upstream's allowlist verbatim; upstream does not accept `config`).
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "config", "--get",
                                                      "user.name"]),
                       .needsApproval)
    }

    func testGitStashDropIsUnsafe() {
        // `git stash drop` permanently deletes a stash entry.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "stash", "drop"]),
                       .needsApproval)
        // `git stash clear` deletes ALL stash entries.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "stash", "clear"]),
                       .needsApproval)
        // `git stash pop` mutates the working tree.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "stash", "pop"]),
                       .needsApproval)
        // Even bare `git stash` (which would push a new stash) is unsafe.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "stash"]),
                       .needsApproval)
    }

    func testGitTagDeleteIsUnsafe() {
        // `git tag -d v1.0` destroys a tag.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "tag", "-d",
                                                      "v1.0"]),
                       .needsApproval)
        // `git tag -f v1.0 HEAD` force-moves a tag.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "tag", "-f",
                                                      "v1.0", "HEAD"]),
                       .needsApproval)
        // Plain `git tag` (list) — also unsafe under the upstream allowlist
        // since `tag` is not an accepted subcommand at all.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "tag"]),
                       .needsApproval)
    }

    func testGitRemoteSetUrlIsUnsafe() {
        // `git remote set-url origin evil.com` redirects pushes/fetches to
        // an attacker-controlled URL.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "remote", "set-url",
                                                      "origin",
                                                      "https://evil.com/x"]),
                       .needsApproval)
        // `git remote add` introduces a new remote.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "remote", "add",
                                                      "evil",
                                                      "https://evil.com/x"]),
                       .needsApproval)
        // Even read-only `git remote -v` is unsafe under the upstream allowlist.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "remote", "-v"]),
                       .needsApproval)
    }

    func testGitReflogExpireIsUnsafe() {
        // `git reflog expire --expire=now --all` silently rewrites history.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "reflog", "expire",
                                                      "--expire=now", "--all"]),
                       .needsApproval)
        // `git reflog delete HEAD@{0}` removes a reflog entry.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "reflog", "delete",
                                                      "HEAD@{0}"]),
                       .needsApproval)
        // Even read-only `git reflog` is unsafe under the upstream allowlist.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "reflog"]),
                       .needsApproval)
    }

    func testExtendedGitSubcommandsAreNotAutoApproved() {
        // Any git subcommand outside upstream's {status, log, diff, show,
        // branch} requires approval. This is the catch-all regression test
        // for REV P4.4: the original implementation auto-approved all of
        // these.
        for unsafe: [String] in [
            ["git", "rev-parse", "HEAD"],
            ["git", "ls-files"],
            ["git", "ls-tree", "HEAD"],
            ["git", "describe"],
            ["git", "blame", "file.txt"],
            ["git", "shortlog"],
            ["git", "cat-file", "-p", "HEAD"],
            ["git", "for-each-ref"],
            ["git", "symbolic-ref", "HEAD"],
            ["git", "name-rev", "HEAD"],
            ["git", "whatchanged"],
            ["git", "show-ref"],
            ["git", "var", "GIT_EDITOR"],
            ["git", "help"],
            ["git", "version"],
            ["git", "merge-base", "a", "b"],
            ["git", "rev-list", "HEAD"],
        ] {
            XCTAssertEqual(CommandSafety.classify(argv: unsafe),
                           .needsApproval,
                           "expected unsafe (not in upstream 5): \(unsafe)")
        }
        // Upstream's exact 5 remain safe.
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "status"]), .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "log",
                                                      "--oneline"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "diff"]), .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "show", "HEAD"]),
                       .safe)
        XCTAssertEqual(CommandSafety.classify(argv: ["git", "branch", "-a"]),
                       .safe)
    }
}
