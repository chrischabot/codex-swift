import XCTest
import Foundation
@testable import Tools

/// Faithful port of codex-rs `core/src/turn_diff_tracker_tests.rs`. Each case
/// applies a real `apply_patch` envelope against a temp dir (exercising the
/// `PatchedFile -> AppliedPatchDelta` conversion), folds the committed delta
/// into a `TurnDiffTracker`, and asserts the aggregated Git-format unified diff
/// byte-for-byte against the expected upstream output.
final class TurnDiffTrackerTests: XCTestCase {
    private let zeroOID = "0000000000000000000000000000000000000000"
    private let devNull = "/dev/null"
    private let regularFileMode = "100644"

    private func tmpDir() -> String {
        let p = NSTemporaryDirectory() + "turn-diff-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func oid(_ s: String) -> String { TurnDiffTracker.gitBlobOID(s) }

    /// Apply the patch and return the committed delta (parity with upstream
    /// `apply_verified_patch`).
    private func applyDelta(_ root: String, _ patch: String) throws -> AppliedPatchDelta {
        try ApplyPatch().apply(patch, root: root).appliedPatchDelta()
    }

    func testAccumulatesAddThenUpdateAsSingleAdd() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var tracker = TurnDiffTracker.withDisplayRoot(dir)

        tracker.trackDelta(try applyDelta(dir,
            "*** Begin Patch\n*** Add File: a.txt\n+foo\n*** End Patch"))
        tracker.trackDelta(try applyDelta(dir,
            "*** Begin Patch\n*** Update File: a.txt\n@@\n foo\n+bar\n*** End Patch"))

        let rightOID = oid("foo\nbar\n")
        let expected = """
        diff --git a/a.txt b/a.txt
        new file mode \(regularFileMode)
        index \(zeroOID)..\(rightOID)
        --- \(devNull)
        +++ b/a.txt
        @@ -0,0 +1,2 @@
        +foo
        +bar

        """
        XCTAssertEqual(tracker.getUnifiedDiff(), expected)
    }

    func testInvalidatedTrackerSuppressesExistingDiff() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var tracker = TurnDiffTracker.withDisplayRoot(dir)
        tracker.trackDelta(try applyDelta(dir,
            "*** Begin Patch\n*** Add File: a.txt\n+foo\n*** End Patch"))
        tracker.invalidate()
        XCTAssertNil(tracker.getUnifiedDiff())
    }

    func testAccumulatesDelete() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try "x\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)

        var tracker = TurnDiffTracker.withDisplayRoot(dir)
        tracker.trackDelta(try applyDelta(dir,
            "*** Begin Patch\n*** Delete File: b.txt\n*** End Patch"))

        let leftOID = oid("x\n")
        let expected = """
        diff --git a/b.txt b/b.txt
        deleted file mode \(regularFileMode)
        index \(leftOID)..\(zeroOID)
        --- a/b.txt
        +++ \(devNull)
        @@ -1 +0,0 @@
        -x

        """
        XCTAssertEqual(tracker.getUnifiedDiff(), expected)
    }

    func testAccumulatesMoveAndUpdate() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try "line\n".write(toFile: dir + "/src.txt", atomically: true, encoding: .utf8)

        var tracker = TurnDiffTracker.withDisplayRoot(dir)
        tracker.trackDelta(try applyDelta(dir,
            "*** Begin Patch\n*** Update File: src.txt\n*** Move to: dst.txt\n@@\n-line\n+line2\n*** End Patch"))

        let leftOID = oid("line\n")
        let rightOID = oid("line2\n")
        let expected = """
        diff --git a/src.txt b/dst.txt
        index \(leftOID)..\(rightOID)
        --- a/src.txt
        +++ b/dst.txt
        @@ -1 +1 @@
        -line
        +line2

        """
        XCTAssertEqual(tracker.getUnifiedDiff(), expected)
    }

    func testPureRenameYieldsNoDiff() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try "same\n".write(toFile: dir + "/old.txt", atomically: true, encoding: .utf8)

        var tracker = TurnDiffTracker.withDisplayRoot(dir)
        tracker.trackDelta(try applyDelta(dir,
            "*** Begin Patch\n*** Update File: old.txt\n*** Move to: new.txt\n@@\n same\n*** End Patch"))
        XCTAssertNil(tracker.getUnifiedDiff())
    }

    func testDeleteThenReaddSamePathBecomesUpdate() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try "before\n".write(toFile: dir + "/cycle.txt", atomically: true, encoding: .utf8)

        var tracker = TurnDiffTracker.withDisplayRoot(dir)
        tracker.trackDelta(try applyDelta(dir,
            "*** Begin Patch\n*** Delete File: cycle.txt\n*** End Patch"))
        tracker.trackDelta(try applyDelta(dir,
            "*** Begin Patch\n*** Add File: cycle.txt\n+after\n*** End Patch"))

        let leftOID = oid("before\n")
        let rightOID = oid("after\n")
        let expected = """
        diff --git a/cycle.txt b/cycle.txt
        index \(leftOID)..\(rightOID)
        --- a/cycle.txt
        +++ b/cycle.txt
        @@ -1 +1 @@
        -before
        +after

        """
        XCTAssertEqual(tracker.getUnifiedDiff(), expected)
    }

    /// The per-file Update `diff` carried by the `fileChange` thread item /
    /// `item/fileChange/patchUpdated` notification must use context radius 1,
    /// matching upstream `unified_diff_from_chunks` →
    /// `unified_diff_from_chunks_with_context(..., /*context*/ 1, ...)`
    /// (apply-patch/src/lib.rs:820-841) whose diff `format_file_change_diff`
    /// copies verbatim into `FileUpdateChange.diff`. A file with several
    /// unchanged lines surrounding a single edit distinguishes context 1
    /// (one line of surround per side) from the general-purpose default of 3.
    func testFileUpdateChangeDiffUsesContextRadiusOne() throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try "a\nb\nc\nd\ne\nf\ng\n".write(
            toFile: dir + "/ctx.txt", atomically: true, encoding: .utf8)

        let delta = try applyDelta(dir,
            "*** Begin Patch\n*** Update File: ctx.txt\n@@\n c\n-d\n+D\n e\n*** End Patch")
        let changes = delta.toFileUpdateChanges()
        XCTAssertEqual(changes.count, 1)

        // context 1 ⇒ exactly one surrounding line (c / e), hunk header @@ -3,3 +3,3 @@.
        let expected = """
        --- ctx.txt
        +++ ctx.txt
        @@ -3,3 +3,3 @@
         c
        -d
        +D
         e

        """
        XCTAssertEqual(changes[0].diff, expected)
    }

    func testGitBlobOIDMatchesGit() {
        // `git hash-object` of "foo\nbar\n" is a known constant.
        XCTAssertEqual(TurnDiffTracker.gitBlobOID("foo\nbar\n"),
                       "3bd1f0e29744a1f32b08d5650e62e2e62afb177c")
    }

    func testEmptyTrackerHasNoDiff() {
        let tracker = TurnDiffTracker()
        XCTAssertNil(tracker.getUnifiedDiff())
    }
}
