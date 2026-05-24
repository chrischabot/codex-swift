import XCTest
@testable import Sandbox

/// Parity H-23 — Sandbox profile must protect `.git`, `.codex`, `.agents`
/// even when located inside a writable root, and `/tmp` must not be writable
/// in `readOnly` mode. These tests pin the deny rules + bwrap argv shape so
/// regressions are immediate.
final class SandboxProfileTests: XCTestCase {

    // MARK: Seatbelt profile (parity H-23)

    func testSeatbeltProfileExcludesGitHooks() throws {
        // Workspace-write profile with cwd = writable root must include a deny
        // rule covering `<root>/.git` (and anything underneath, e.g. .git/hooks).
        let root = "/tmp/codex-swift-h23-git"
        let policy = SandboxPolicy(mode: .workspaceWrite,
                                   writableRoots: [root],
                                   networkAllowed: false)
        let profile = WorkspaceSandbox.buildSeatbeltProfile(policy: policy, cwd: root)
        XCTAssertTrue(profile.contains("(allow file-write* (subpath"),
                      "writable root should still allow writes:\n\(profile)")

        // The deny rule must use an anchored regex so `<root>/.git` and any
        // descendent (e.g. `<root>/.git/hooks/pre-commit`) match. The exact
        // regex string follows upstream `seatbelt_protected_metadata_name_regex`.
        let expectedRegex = WorkspaceSandbox.protectedMetadataRegex(root: root, name: ".git")
        XCTAssertTrue(expectedRegex.contains("\\.git"),
                      "regex must escape the leading dot in .git: \(expectedRegex)")
        XCTAssertTrue(expectedRegex.hasSuffix("(/.*)?$"),
                      "regex must allow trailing path segments (hooks/, config, …): \(expectedRegex)")

        let denyClause = "(deny file-write* (regex #\"\(WorkspaceSandbox.sbplRegexLiteral(expectedRegex))\"))"
        XCTAssertTrue(profile.contains(denyClause),
                      "expected deny clause for .git not found.\nexpected: \(denyClause)\nprofile:\n\(profile)")

        // Sanity: the deny must apply specifically to .git/hooks/pre-commit —
        // simulate by running the regex against a candidate path.
        let candidate = "\(root)/.git/hooks/pre-commit"
        let nsRange = NSRange(candidate.startIndex..., in: candidate)
        let re = try NSRegularExpression(pattern: expectedRegex)
        XCTAssertNotNil(re.firstMatch(in: candidate, range: nsRange),
                        ".git regex must match \(candidate)")
    }

    func testSeatbeltProfileExcludesCodexDir() throws {
        let root = "/tmp/codex-swift-h23-codex"
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: [root])
        let profile = WorkspaceSandbox.buildSeatbeltProfile(policy: policy, cwd: root)

        let regex = WorkspaceSandbox.protectedMetadataRegex(root: root, name: ".codex")
        let denyClause = "(deny file-write* (regex #\"\(WorkspaceSandbox.sbplRegexLiteral(regex))\"))"
        XCTAssertTrue(profile.contains(denyClause),
                      "expected deny clause for .codex not found.\nprofile:\n\(profile)")

        // `.codex/config.toml` must match.
        let candidate = "\(root)/.codex/config.toml"
        let re = try NSRegularExpression(pattern: regex)
        let nsRange = NSRange(candidate.startIndex..., in: candidate)
        XCTAssertNotNil(re.firstMatch(in: candidate, range: nsRange),
                        ".codex regex must match \(candidate)")
    }

    func testSeatbeltProfileExcludesAgentsDir() throws {
        let root = "/tmp/codex-swift-h23-agents"
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: [root])
        let profile = WorkspaceSandbox.buildSeatbeltProfile(policy: policy, cwd: root)

        let regex = WorkspaceSandbox.protectedMetadataRegex(root: root, name: ".agents")
        let denyClause = "(deny file-write* (regex #\"\(WorkspaceSandbox.sbplRegexLiteral(regex))\"))"
        XCTAssertTrue(profile.contains(denyClause),
                      "expected deny clause for .agents not found.\nprofile:\n\(profile)")
    }

    func testSeatbeltProfileReadOnlyEmitsNoWritableAllows() {
        let policy = SandboxPolicy(mode: .readOnly,
                                   writableRoots: ["/tmp/should-not-appear"])
        let profile = WorkspaceSandbox.buildSeatbeltProfile(policy: policy, cwd: "/tmp/should-not-appear")
        XCTAssertFalse(profile.contains("(allow file-write*"),
                       "readOnly profile must not allow any file-write*:\n\(profile)")
        XCTAssertFalse(profile.contains("(deny file-write* (regex"),
                       "readOnly profile shouldn't emit per-root deny regexes (nothing writable to deny):\n\(profile)")
    }

    func testSeatbeltProfileDangerFullAccessSkipsMetadataDenies() {
        // dangerFullAccess intentionally bypasses protection — the user has
        // opted into unrestricted writes. Matches upstream
        // `DangerFullAccess` semantics.
        let policy = SandboxPolicy(mode: .dangerFullAccess,
                                   writableRoots: ["/tmp/full"])
        let profile = WorkspaceSandbox.buildSeatbeltProfile(policy: policy, cwd: "/tmp/full")
        XCTAssertFalse(profile.contains("(deny file-write* (regex"),
                       "dangerFullAccess must not insert metadata denies:\n\(profile)")
    }

    // MARK: bwrap argv (parity H-23 / audit F-3)

    func testBwrapReadOnlyDoesNotAllowTmpWrites() {
        let cwd = "/tmp/codex-swift-h23-ro"
        let policy = SandboxPolicy(mode: .readOnly,
                                   writableRoots: [],
                                   networkAllowed: false)
        let argv = WorkspaceSandbox.buildBwrapArgv(bwrap: "/usr/bin/bwrap",
                                                   policy: policy,
                                                   argv: ["/bin/echo", "hello"],
                                                   cwd: cwd)

        // No `--tmpfs /tmp` — that would shadow the read-only root mount with
        // a writable in-memory FS, defeating readOnly mode.
        for i in 0..<argv.count - 1 {
            XCTAssertFalse(argv[i] == "--tmpfs" && argv[i + 1] == "/tmp",
                           "readOnly bwrap must NOT mount /tmp as tmpfs (sandbox escape). argv: \(argv)")
        }

        // No `--bind /tmp /tmp` writable bind either.
        for i in 0..<argv.count - 2 {
            XCTAssertFalse(argv[i] == "--bind" && argv[i + 1] == "/tmp" && argv[i + 2] == "/tmp",
                           "readOnly bwrap must NOT writable-bind /tmp. argv: \(argv)")
        }

        // The base read-only root mount must be present so /tmp is reachable
        // (read-only).
        XCTAssertTrue(argv.contains("--ro-bind"),
                      "readOnly bwrap must mount / read-only. argv: \(argv)")

        // Network must be unshared by default.
        XCTAssertTrue(argv.contains("--unshare-net"),
                      "readOnly bwrap with networkAllowed=false must unshare net. argv: \(argv)")
    }

    func testBwrapWorkspaceWriteAllowsTmp() {
        let cwd = "/tmp/codex-swift-h23-ww"
        let policy = SandboxPolicy(mode: .workspaceWrite,
                                   writableRoots: [cwd],
                                   networkAllowed: false)
        let argv = WorkspaceSandbox.buildBwrapArgv(bwrap: "/usr/bin/bwrap",
                                                   policy: policy,
                                                   argv: ["/bin/echo", "ok"],
                                                   cwd: cwd)

        // `/tmp` must be a writable tmpfs in workspaceWrite mode.
        var foundTmpTmpfs = false
        for i in 0..<argv.count - 1 {
            if argv[i] == "--tmpfs" && argv[i + 1] == "/tmp" {
                foundTmpTmpfs = true
                break
            }
        }
        XCTAssertTrue(foundTmpTmpfs,
                      "workspaceWrite bwrap should mount /tmp as tmpfs. argv: \(argv)")

        // Writable bind for cwd must be present.
        var foundCwdBind = false
        for i in 0..<argv.count - 2 {
            if argv[i] == "--bind" && argv[i + 1] == cwd && argv[i + 2] == cwd {
                foundCwdBind = true
                break
            }
        }
        XCTAssertTrue(foundCwdBind,
                      "workspaceWrite bwrap should bind cwd. argv: \(argv)")
    }

    func testBwrapWorkspaceWriteShadowsProtectedMetadataDirs() {
        // Parity H-23: even inside a writable bind, .git/.codex/.agents must
        // be masked. The overlay must be READ-ONLY (upstream uses
        // `--perms 555 --tmpfs <path> --remount-ro <path>`); a plain
        // `--tmpfs <path>` is writable by default and lets the sandboxed
        // process write `<cwd>/.git/hooks/pre-commit` in the ephemeral
        // tmpfs, enabling intra-session hook injection if `git commit`
        // runs later in the same session.
        let cwd = "/tmp/codex-swift-h23-protected"
        let policy = SandboxPolicy(mode: .workspaceWrite, writableRoots: [cwd])
        let argv = WorkspaceSandbox.buildBwrapArgv(bwrap: "/usr/bin/bwrap",
                                                   policy: policy,
                                                   argv: ["/bin/true"],
                                                   cwd: cwd)
        for name in [".git", ".codex", ".agents"] {
            let target = "\(cwd)/\(name)"

            // Assert the full 6-element sequence:
            //   --perms 555 --tmpfs <path> --remount-ro <path>
            var foundFullSequence = false
            if argv.count >= 6 {
                for i in 0...(argv.count - 6) {
                    if argv[i] == "--perms"
                        && argv[i + 1] == "555"
                        && argv[i + 2] == "--tmpfs"
                        && argv[i + 3] == target
                        && argv[i + 4] == "--remount-ro"
                        && argv[i + 5] == target {
                        foundFullSequence = true
                        break
                    }
                }
            }
            XCTAssertTrue(foundFullSequence,
                          "bwrap must shadow \(target) with the upstream read-only pattern " +
                          "`--perms 555 --tmpfs <path> --remount-ro <path>`. argv: \(argv)")

            // Defence-in-depth: assert each individual flag is present even
            // if some future refactor changes the ordering.
            XCTAssertTrue(argv.contains("--perms"),
                          "argv must contain --perms for read-only metadata overlay: \(argv)")
            XCTAssertTrue(argv.contains("555"),
                          "argv must contain 555 perm bits for read-only metadata overlay: \(argv)")
            XCTAssertTrue(argv.contains("--tmpfs"),
                          "argv must contain --tmpfs for metadata overlay: \(argv)")
            XCTAssertTrue(argv.contains("--remount-ro"),
                          "argv must contain --remount-ro to make the tmpfs read-only: \(argv)")
            XCTAssertTrue(argv.contains(target),
                          "argv must reference \(target) as overlay target: \(argv)")
        }
    }

    // MARK: regression — sbplStringLiteral must hex-escape `"` (DEFECT #1)

    /// SBPL plain `"..."` string literals do NOT support `\"` as an escape —
    /// the `"` after `\` closes the string. Any cwd or writable root path
    /// containing a `"` character therefore produces an unparseable profile
    /// when emitted via `(subpath "...")`. The fix is to use a hex escape
    /// (`\x22`) for `"` inside `sbplStringLiteral`, matching the same
    /// approach `sbplRegexLiteral` uses inside `#"..."#`.
    func testSbplStringLiteralEscapesQuoteAsHex() {
        let raw = "/path/with\"quote/inside"
        let lit = WorkspaceSandbox.sbplStringLiteral(raw)
        XCTAssertTrue(lit.contains("\\x22"),
                      "sbplStringLiteral must hex-escape \" as \\x22, got: \(lit)")
        XCTAssertFalse(lit.contains("\\\""),
                       "sbplStringLiteral must NOT emit \\\" (SBPL does not recognize it as an escape), got: \(lit)")
        // Sanity: literal still starts/ends with `"` and the interior
        // `"` is gone (replaced by the hex escape).
        XCTAssertTrue(lit.hasPrefix("\""))
        XCTAssertTrue(lit.hasSuffix("\""))
        // Exactly two `"` characters in the literal — the outer pair.
        XCTAssertEqual(lit.filter { $0 == "\"" }.count, 2,
                       "expected exactly the outer pair of quotes, got: \(lit)")
    }

    func testBwrapReadOnlyHasNoMetadataTmpfsOverlays() {
        // In readOnly mode there's no writable root, so no need to overlay
        // the protected metadata dirs — the entire root is already read-only.
        let cwd = "/tmp/codex-swift-h23-ro2"
        let policy = SandboxPolicy(mode: .readOnly, writableRoots: [])
        let argv = WorkspaceSandbox.buildBwrapArgv(bwrap: "/usr/bin/bwrap",
                                                   policy: policy,
                                                   argv: ["/bin/true"],
                                                   cwd: cwd)
        XCTAssertFalse(argv.contains("--tmpfs"),
                       "readOnly mode must not insert ANY --tmpfs mounts. argv: \(argv)")
    }

    // MARK: regex escaping

    func testProtectedMetadataRegexEscapesDotsAndSlashes() {
        // The root path's `/` are escaped via regexEscape (defensive: many
        // regex flavours treat `/` as a delimiter); the literal `/` between
        // root and name comes from string interpolation, so it is unescaped.
        // The basename's leading `.` MUST be escaped, otherwise `.git` would
        // also match `xgit`.
        let regex = WorkspaceSandbox.protectedMetadataRegex(root: "/Users/me/proj", name: ".git")
        XCTAssertEqual(regex, "^\\/Users\\/me\\/proj/\\.git(/.*)?$")
    }

    func testProtectedMetadataRegexAtFilesystemRoot() {
        let regex = WorkspaceSandbox.protectedMetadataRegex(root: "/", name: ".codex")
        XCTAssertEqual(regex, "^/\\.codex(/.*)?$")
    }

    // MARK: regression — generated Seatbelt profile must parse

    /// Parity H-23 regression: when the writable root contains characters that
    /// are syntactically significant in SBPL (`)`, `(`, `"`, newline), the
    /// regex literal we emit inside `(deny file-write* (regex #"…"))` must
    /// still be a well-formed SBPL extended-string literal. `\n` inside the
    /// literal breaks the lexer; we encode it as `\xNN`.
    func testSeatbeltProfileWithUnsafeRootStillParses() throws {
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("sandbox-exec not available")
        }
        let temp = NSTemporaryDirectory() + "codex-swift-h23-unsafe-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        // Mirror the existing ToolsTests injection vector: a path containing
        // `"`, `)`, newline, and `(`.
        let unsafe = temp + "/quote\")\n(allow network*)\n(path"
        try FileManager.default.createDirectory(atPath: unsafe,
                                                withIntermediateDirectories: true)
        let policy = SandboxPolicy(mode: .workspaceWrite,
                                   writableRoots: [unsafe],
                                   networkAllowed: false)
        let profile = WorkspaceSandbox.buildSeatbeltProfile(policy: policy, cwd: unsafe)

        // Profile must not have a literal newline inside any `#"..."` regex
        // literal. Newlines outside the literal (between top-level clauses)
        // are fine, but a `#"` opener must be followed by a closing `"` on
        // the same line — otherwise the SBPL lexer reads the next line's
        // content as part of the regex pattern, which usually explodes
        // during parsing.
        for line in profile.split(separator: "\n") {
            let opens = line.components(separatedBy: "#\"").count - 1
            // Every `#"` opens a literal which needs a `"` closer on the
            // same physical line. Count plain `"` (excluding the opener
            // `#"` instances which themselves contribute one `"`).
            let totalQuotes = line.components(separatedBy: "\"").count - 1
            // closers = totalQuotes - opens (each opener `#"` contributes one
            // quote of its own to totalQuotes).
            let closers = totalQuotes - opens
            XCTAssertGreaterThanOrEqual(closers, opens,
                "regex literal split across newlines (opener without closer on same line): \(line)\nprofile:\n\(profile)")
        }

        // Profile must parse under sandbox-exec.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile, "/bin/echo", "ok"]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0,
                       "Seatbelt profile with unsafe root must still parse:\n\(profile)")
        #endif
    }
}
