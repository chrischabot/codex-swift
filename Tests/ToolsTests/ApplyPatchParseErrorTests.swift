import XCTest
import Foundation
@testable import Tools

/// Parser/applier error-message parity with upstream `codex-rs/apply-patch`.
/// Each test pins the model-facing message (via `ApplyPatchError.formatted`,
/// which reproduces the upstream `ParseError`/anyhow Display strings). Ported
/// from `apply-patch/src/parser.rs` test cases and the `parse_one_hunk`/
/// `parse_update_file_chunk` line-number expectations.
final class ApplyPatchParseErrorTests: XCTestCase {

    private func tmpDir() -> String {
        let d = NSTemporaryDirectory() + "ap-err-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d,
                                                 withIntermediateDirectories: true)
        return d
    }

    private func parseError(_ patch: String) -> ApplyPatchError? {
        do {
            _ = try ApplyPatch().parse(patch)
            return nil
        } catch let e as ApplyPatchError {
            return e
        } catch {
            return nil
        }
    }

    // MARK: - Finding 1 + 2: invalid hunk header text, line number, Display prefix

    func testInvalidHunkHeaderTextAndLineNumber() {
        // Body line "bad" is the first hunk header at absolute line 2.
        let patch = "*** Begin Patch\nbad line\n*** End Patch\n"
        guard let e = parseError(patch) else { return XCTFail("expected error") }
        XCTAssertEqual(
            e.formatted,
            "invalid hunk at line 2, 'bad line' is not a valid hunk header. "
                + "Valid hunk headers: '*** Add File: {path}', "
                + "'*** Delete File: {path}', '*** Update File: {path}'")
    }

    func testInvalidHunkHeaderLineNumberAdvancesPastFirstHunk() {
        // First hunk (Add File: foo + one added line) consumes 2 body lines
        // (lines 2 and 3); the bad header lands on absolute line 4.
        let patch = "*** Begin Patch\n*** Add File: foo\n+hi\nbogus\n*** End Patch\n"
        guard let e = parseError(patch) else { return XCTFail("expected error") }
        XCTAssertTrue(e.formatted.hasPrefix("invalid hunk at line 4, 'bogus' is not a valid hunk header."),
                      "got: \(e.formatted)")
    }

    // MARK: - Finding 2: empty Update hunk carries "invalid hunk at line N"

    func testEmptyUpdateHunkLineNumber() {
        // Mirrors parser.rs:611-622 (line_number: 2).
        let patch = "*** Begin Patch\n*** Update File: test.py\n*** End Patch\n"
        guard let e = parseError(patch) else { return XCTFail("expected error") }
        XCTAssertEqual(e.formatted,
                       "invalid hunk at line 2, Update file hunk for path 'test.py' is empty")
    }

    // MARK: - Finding 3: wrong-boundary distinction (last line vs first line)

    func testFirstLineWrongGivesFirstLineMessage() {
        // No '*** Begin Patch' first line.
        let patch = "garbage\n*** End Patch\n"
        guard let e = parseError(patch) else { return XCTFail("expected error") }
        XCTAssertEqual(e.formatted,
                       "invalid patch: The first line of the patch must be '*** Begin Patch'")
    }

    func testLastLineWrongGivesLastLineMessage() {
        // Mirrors parser.rs:586-591: "*** Begin Patch\nbad" → last-line message.
        let patch = "*** Begin Patch\nbad"
        guard let e = parseError(patch) else { return XCTFail("expected error") }
        XCTAssertEqual(e.formatted,
                       "invalid patch: The last line of the patch must be '*** End Patch'")
    }

    // MARK: - Finding 4: empty Environment ID specific message

    func testEmptyEnvironmentId() {
        // Mirrors parser.rs:941-953.
        let patch = "*** Begin Patch\n*** Environment ID:   \n*** Add File: foo\n+hi\n*** End Patch\n"
        guard let e = parseError(patch) else { return XCTFail("expected error") }
        XCTAssertEqual(e.formatted,
                       "invalid patch: apply_patch environment_id cannot be empty")
    }

    // MARK: - Finding 5: heredoc inner-boundary mismatch surfaces the real boundary error

    func testHeredocInnerBoundaryMismatch() {
        // Heredoc markers match, but inner body's last line is not '*** End Patch'.
        // Upstream (parser.rs:905-916) returns the inner strict boundary error.
        let patch = "<<'EOF'\n*** Begin Patch\n*** Add File: foo\n+hi\nEOF\n"
        guard let e = parseError(patch) else { return XCTFail("expected error") }
        XCTAssertEqual(e.formatted,
                       "invalid patch: The last line of the patch must be '*** End Patch'")
    }

    func testHeredocInnerBoundaryValidStillParses() throws {
        let patch = "<<'EOF'\n*** Begin Patch\n*** Add File: foo\n+hi\n*** End Patch\nEOF\n"
        let files = try ApplyPatch().parse(patch)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "foo")
        XCTAssertEqual(files[0].kind, .add)
    }

    // MARK: - Finding 6: missing-target Delete/Update use upstream text + absolute path

    func testDeleteMissingTargetMessage() {
        let root = tmpDir()
        let patch = "*** Begin Patch\n*** Delete File: gone.txt\n*** End Patch\n"
        do {
            _ = try ApplyPatch().apply(patch, root: root)
            XCTFail("expected error")
        } catch let e as ApplyPatchError {
            // On the production handler path a missing delete target fails in
            // the verify pass (invocation.rs:188-198) as IoError with context
            // "Failed to read {abs}" and Display "{context}: {source}"
            // (lib.rs:81). The prefix is byte-identical; the OS-error suffix is
            // environment-dependent (errno text), so we assert its shape.
            let abs = (root as NSString).appendingPathComponent("gone.txt")
            XCTAssertTrue(e.formatted.hasPrefix("Failed to read \(abs): "),
                          "got: \(e.formatted)")
            XCTAssertTrue(e.formatted.contains("(os error "),
                          "missing os-error suffix; got: \(e.formatted)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testUpdateMissingTargetMessage() {
        let root = tmpDir()
        let patch = "*** Begin Patch\n*** Update File: gone.txt\n@@\n-old\n+new\n*** End Patch\n"
        do {
            _ = try ApplyPatch().apply(patch, root: root)
            XCTFail("expected error")
        } catch let e as ApplyPatchError {
            // derive_new_contents_from_chunks maps the read failure to IoError
            // with context "Failed to read file to update {abs}" and Display
            // appends ": {source}" (lib.rs:663-668, :81). Prefix is exact; the
            // OS-error suffix is environment-dependent.
            let abs = (root as NSString).appendingPathComponent("gone.txt")
            XCTAssertTrue(e.formatted.hasPrefix("Failed to read file to update \(abs): "),
                          "got: \(e.formatted)")
            XCTAssertTrue(e.formatted.contains("(os error "),
                          "missing os-error suffix; got: \(e.formatted)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - "invalid patch:" prefix on a generic parse error

    func testEmptyPatchParsesAndAppliesWithBareMessage() throws {
        // Upstream `parse_patch` returns Ok with empty hunks for a boundary-valid
        // empty patch (parser.rs:623-632); "No files were modified." is an
        // apply-time bail (lib.rs:371-373) surfaced as a BARE stderr line — no
        // `invalid patch:` / `verification failed:` prefix.
        let patch = "*** Begin Patch\n*** End Patch\n"
        XCTAssertNil(parseError(patch), "empty patch must not be a parse error")
        XCTAssertEqual(try ApplyPatch().parse(patch).count, 0)

        let root = tmpDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertThrowsError(try ApplyPatch().apply(patch, root: root)) {
            guard case let ApplyPatchError.emptyPatch(msg) = $0 else {
                return XCTFail("expected emptyPatch, got \($0)")
            }
            XCTAssertEqual(msg, "No files were modified.")
            XCTAssertEqual(($0 as? ApplyPatchError)?.formatted, "No files were modified.")
        }
    }

    // MARK: - v9 Finding 1: blank line between top-level hunks is rejected

    func testBlankLineBetweenHunksIsRejected() {
        // Upstream's top-level loop (parser.rs:186-191) does NOT skip blank
        // lines between hunks; a blank line at a hunk-header position reaches
        // `parse_one_hunk` with `lines[0] == ""` and errors as
        // "'' is not a valid hunk header. …" (parser.rs:286,368-373).
        // Add hunk (Add File: a + one added line) consumes body lines 2-3; the
        // blank lands on absolute line 4.
        let patch = "*** Begin Patch\n*** Add File: a\n+hi\n\n*** Update File: b\n@@\n-old\n+new\n*** End Patch\n"
        guard let e = parseError(patch) else { return XCTFail("expected error") }
        XCTAssertEqual(
            e.formatted,
            "invalid hunk at line 4, '' is not a valid hunk header. "
                + "Valid hunk headers: '*** Add File: {path}', "
                + "'*** Delete File: {path}', '*** Update File: {path}'")
    }

    // MARK: - v9 Finding 2: fully empty / whitespace-only patch boundary message

    func testEmptyPatchYieldsLastLineMessage() {
        // Upstream: an empty trimmed input produces zero `.lines()`, matching
        // `[] => (None, None)` in check_patch_boundaries_strict (parser.rs:227),
        // which falls to the final arm → "The last line of the patch must be …"
        // (parser.rs:278-281).
        for patch in ["", "   ", "\n\n", "  \n \t\n"] {
            guard let e = parseError(patch) else {
                return XCTFail("expected error for \(patch.debugDescription)")
            }
            XCTAssertEqual(
                e.formatted,
                "invalid patch: The last line of the patch must be '*** End Patch'",
                "for input \(patch.debugDescription)")
        }
    }

    // MARK: - v9 Finding 3: Environment ID marker requires a trailing space

    func testEnvironmentIdWithoutSpaceIsNotStripped() {
        // Upstream ENVIRONMENT_ID_MARKER is "*** Environment ID: " WITH a
        // trailing space (parser.rs:36). "*** Environment ID:remote" (no space)
        // does NOT strip and is treated as a hunk header → unrecognised-header
        // error at the preamble position (absolute line 2).
        let patch = "*** Begin Patch\n*** Environment ID:remote\n*** End Patch\n"
        guard let e = parseError(patch) else { return XCTFail("expected error") }
        XCTAssertTrue(
            e.formatted.hasPrefix(
                "invalid hunk at line 2, '*** Environment ID:remote' is not a valid hunk header."),
            "got: \(e.formatted)")
    }

    func testEnvironmentIdWithSpaceStillParses() throws {
        // The well-formed (space) form is still accepted.
        let patch = "*** Begin Patch\n*** Environment ID: remote\n*** Add File: foo\n+hi\n*** End Patch\n"
        let files = try ApplyPatch().parse(patch)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "foo")
    }

    // MARK: - v10 Finding 1: apply is all-or-nothing across a multi-file patch

    func testMultiFilePatchIsAllOrNothingOnLaterFailure() throws {
        // A multi-file patch where the FIRST file's hunk is valid but the
        // SECOND file's context cannot be matched must leave the workspace
        // untouched (upstream verifies all hunks before any write,
        // invocation.rs:161-233). A pre-fix Swift applier would have already
        // written the first file before throwing on the second.
        let root = tmpDir()
        let fm = FileManager.default
        // First file exists with known content (a valid Update target).
        let firstPath = (root as NSString).appendingPathComponent("first.txt")
        try "alpha\n".write(toFile: firstPath, atomically: true, encoding: .utf8)
        // Second file exists but its hunk's old-lines will NOT match.
        let secondPath = (root as NSString).appendingPathComponent("second.txt")
        try "totally different\n".write(toFile: secondPath, atomically: true, encoding: .utf8)

        let patch = """
        *** Begin Patch
        *** Update File: first.txt
        @@
        -alpha
        +ALPHA
        *** Update File: second.txt
        @@
        -nonexistent context line
        +replacement
        *** End Patch

        """
        do {
            _ = try ApplyPatch().apply(patch, root: root)
            XCTFail("expected context-mismatch error")
        } catch let e as ApplyPatchError {
            XCTAssertTrue(e.formatted.hasPrefix("Failed to find expected lines in "),
                          "got: \(e.formatted)")
        }
        // CRITICAL: first.txt must be UNCHANGED — no partial application.
        XCTAssertEqual(try String(contentsOfFile: firstPath, encoding: .utf8), "alpha\n")
        XCTAssertEqual(try String(contentsOfFile: secondPath, encoding: .utf8),
                       "totally different\n")
        // And no stray files were created.
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: root).sorted(),
            ["first.txt", "second.txt"])
    }

    func testMultiFilePatchAddIsRolledBackOnLaterUpdateFailure() throws {
        // An Add hunk that precedes a failing Update must NOT leave the added
        // file on disk (verify pass catches the Update mismatch before any
        // write).
        let root = tmpDir()
        let fm = FileManager.default
        let existing = (root as NSString).appendingPathComponent("exists.txt")
        try "keep\n".write(toFile: existing, atomically: true, encoding: .utf8)

        let patch = """
        *** Begin Patch
        *** Add File: brand_new.txt
        +created
        *** Update File: exists.txt
        @@
        -does not match
        +x
        *** End Patch

        """
        XCTAssertThrowsError(try ApplyPatch().apply(patch, root: root))
        XCTAssertFalse(fm.fileExists(atPath:
            (root as NSString).appendingPathComponent("brand_new.txt")),
            "the added file must not survive a later-hunk verify failure")
        XCTAssertEqual(try String(contentsOfFile: existing, encoding: .utf8), "keep\n")
    }

    func testSingleFileAndMoveStillApplyAfterVerifySplit() throws {
        // Guard against regressions in the verify/apply split for the common
        // single-file Update, Add-over-existing, and Update-with-move cases.
        let root = tmpDir()
        let fm = FileManager.default

        // Single-file update.
        let up = (root as NSString).appendingPathComponent("u.txt")
        try "one\ntwo\n".write(toFile: up, atomically: true, encoding: .utf8)
        _ = try ApplyPatch().apply(
            "*** Begin Patch\n*** Update File: u.txt\n@@\n-two\n+TWO\n*** End Patch\n",
            root: root)
        XCTAssertEqual(try String(contentsOfFile: up, encoding: .utf8), "one\nTWO\n")

        // Add-over-existing overwrites.
        let ov = (root as NSString).appendingPathComponent("ov.txt")
        try "old\n".write(toFile: ov, atomically: true, encoding: .utf8)
        _ = try ApplyPatch().apply(
            "*** Begin Patch\n*** Add File: ov.txt\n+fresh\n*** End Patch\n", root: root)
        XCTAssertEqual(try String(contentsOfFile: ov, encoding: .utf8), "fresh\n")

        // Update with move: source removed, destination written.
        let src = (root as NSString).appendingPathComponent("src.txt")
        try "a\nb\n".write(toFile: src, atomically: true, encoding: .utf8)
        _ = try ApplyPatch().apply(
            "*** Begin Patch\n*** Update File: src.txt\n*** Move to: dst.txt\n@@\n-b\n+B\n*** End Patch\n",
            root: root)
        XCTAssertFalse(fm.fileExists(atPath: src))
        XCTAssertEqual(
            try String(contentsOfFile:
                (root as NSString).appendingPathComponent("dst.txt"), encoding: .utf8),
            "a\nB\n")
    }

    // MARK: - v10 Finding 4: fuzzy errors render the ABSOLUTE path

    func testFuzzyContextMismatchErrorUsesAbsolutePath() throws {
        // "Failed to find expected lines in {path}" must use the absolute
        // resolved path (lib.rs:678,771-775), not the relative patch path.
        let root = tmpDir()
        let target = (root as NSString).appendingPathComponent("f.txt")
        try "real content\n".write(toFile: target, atomically: true, encoding: .utf8)
        let patch = "*** Begin Patch\n*** Update File: f.txt\n@@\n-missing line\n+x\n*** End Patch\n"
        do {
            _ = try ApplyPatch().apply(patch, root: root)
            XCTFail("expected context-mismatch error")
        } catch let e as ApplyPatchError {
            XCTAssertTrue(e.formatted.hasPrefix("Failed to find expected lines in \(target):"),
                          "expected absolute path; got: \(e.formatted)")
            XCTAssertFalse(e.formatted.hasPrefix("Failed to find expected lines in f.txt"),
                           "should not use the relative path")
        }
    }

    func testFuzzyChangeContextMismatchUsesAbsolutePath() throws {
        // "Failed to find context '{ctx}' in {path}" must also use the absolute
        // path (lib.rs:714-718).
        let root = tmpDir()
        let target = (root as NSString).appendingPathComponent("g.txt")
        try "line one\nline two\n".write(toFile: target, atomically: true, encoding: .utf8)
        let patch = "*** Begin Patch\n*** Update File: g.txt\n@@ no such context\n-line two\n+x\n*** End Patch\n"
        do {
            _ = try ApplyPatch().apply(patch, root: root)
            XCTFail("expected context error")
        } catch let e as ApplyPatchError {
            XCTAssertTrue(e.formatted.contains("in \(target)"),
                          "expected absolute path; got: \(e.formatted)")
        }
    }
}
