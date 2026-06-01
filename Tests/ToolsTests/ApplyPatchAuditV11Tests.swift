import XCTest
import Foundation
@testable import Tools

/// audit-findings-v11 fidelity tests for the `apply-patch` unit.
///
/// Finding 1: seek_sequence's rstrip/trim passes must strip the FULL Unicode
///   White_Space set (Rust `str::trim_end()`/`str::trim()` via
///   `char::is_whitespace()`), not just ASCII whitespace. A context line whose
///   only trailing difference is an exotic White_Space scalar (NEL U+0085,
///   Ogham U+1680, en/em quad U+2000/U+2001, line/paragraph separators
///   U+2028/U+2029, …) must still match — these are NOT all handled by the
///   later `normalise()` pass (seek_sequence.rs:88-90).
///
/// Finding 2: in-hunk next-hunk detection must test ONLY the RAW (untrimmed)
///   line for a leading `*` (parser.rs:334). An indented `"  *** ..."` line is
///   absorbed as a context line, not treated as a new hunk header.
final class ApplyPatchAuditV11Tests: XCTestCase {

    private func tmpDir() -> String {
        let d = NSTemporaryDirectory() + "ap-v11-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d,
                                                 withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    private func write(_ dir: String, _ name: String, _ contents: String) -> String {
        let p = (dir as NSString).appendingPathComponent(name)
        try? contents.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Finding 1: exotic Unicode trailing whitespace still matches (rstrip pass)

    /// The file line carries a trailing exotic White_Space scalar that the
    /// patch context line lacks. Rust's `trim_end()` rstrip pass strips it and
    /// the lines compare equal; the ASCII-only Swift port would have failed.
    /// `normalise()` alone does NOT save these scalars (NEL/quad/separators are
    /// not in its map), so this exercises the broadened trim predicate.
    func testTrailingExoticWhitespaceMatchesViaRstrip() throws {
        let exotics: [(String, UInt32)] = [
            ("NEL", 0x0085),
            ("OghamSpace", 0x1680),
            ("EnQuad", 0x2000),
            ("EmQuad", 0x2001),
            ("LineSep", 0x2028),
            ("ParaSep", 0x2029),
        ]
        for (label, code) in exotics {
            let dir = tmpDir()
            let ws = String(Unicode.Scalar(code)!)
            // File: a context line that ends in the exotic whitespace.
            let original = "alpha\ncontext\(ws)\nbeta\n"
            let path = write(dir, "f.txt", original)
            // Patch context line has NO trailing whitespace; only rstrip can match.
            let patch = """
            *** Begin Patch
            *** Update File: f.txt
             alpha
             context
            -beta
            +gamma
            *** End Patch

            """
            let result = try ApplyPatch().apply(patch, root: dir)
            XCTAssertEqual(result.count, 1, "[\(label)] expected one changed file")
            // The fuzzy rstrip pass LOCATES the region; the replacement then
            // substitutes the patch's text (context line WITHOUT the exotic
            // trailing whitespace). The behavioural signal is that the patch
            // applied at all — pre-fix it failed with a context mismatch.
            XCTAssertEqual(read(path), "alpha\ncontext\ngamma\n",
                           "[\(label)] rstrip pass should have matched the context line")
        }
    }

    // MARK: - Finding 1: exotic leading+trailing whitespace matches (full-trim pass)

    func testLeadingAndTrailingExoticWhitespaceMatchesViaFullTrim() throws {
        let dir = tmpDir()
        let nbsp = "\u{00A0}"      // NBSP (handled by trim AND normalise)
        let nel = "\u{0085}"       // NEL (handled by trim only)
        // File line is padded with exotic whitespace on BOTH sides.
        let original = "head\n\(nel)\(nbsp)payload\(nbsp)\(nel)\ntail\n"
        let path = write(dir, "g.txt", original)
        // Patch context line has the bare token; only the full-trim pass matches.
        let patch = """
        *** Begin Patch
        *** Update File: g.txt
         head
         payload
        -tail
        +done
        *** End Patch

        """
        let result = try ApplyPatch().apply(patch, root: dir)
        XCTAssertEqual(result.count, 1)
        // Full-trim pass locates the padded line; the replacement substitutes
        // the patch's bare "payload" context line. Pre-fix the NEL padding
        // (not in normalise()'s map) caused a context mismatch.
        XCTAssertEqual(read(path), "head\npayload\ndone\n")
    }

    // MARK: - Finding 2: indented "*** " line inside an Update body is context, not a header

    /// Upstream parser.rs:334 breaks only on a RAW leading `*`. A line that is
    /// whitespace-indented before `*** ` does not start with `*`, so it is
    /// consumed as a context line (leading space stripped). The patch here uses
    /// such a line as context and must parse + apply without a hunk-header
    /// error.
    func testIndentedTripleStarLineTreatedAsContext() throws {
        let dir = tmpDir()
        // The file literally contains a line " *** Add File: x" (one leading
        // space) — i.e. the context line below with its leading space stripped.
        let original = "first\n *** Add File: x\nlast\n"
        let path = write(dir, "h.txt", original)
        // The context line in the patch begins with a context-marker space,
        // THEN one more space, THEN "*** Add File: x". The raw line starts with
        // a space (not '*'), so upstream keeps it as hunk content.
        let patch = "*** Begin Patch\n*** Update File: h.txt\n  *** Add File: x\n-last\n+done\n*** End Patch\n"
        let result = try ApplyPatch().apply(patch, root: dir)
        XCTAssertEqual(result.count, 1, "indented *** line must be context, not a new hunk")
        XCTAssertEqual(read(path), "first\n *** Add File: x\ndone\n")
    }

    /// Sanity: a RAW (non-indented) leading `*` still terminates the hunk body —
    /// we did not over-relax the break condition.
    func testRawLeadingStarStillBreaksHunk() throws {
        let dir = tmpDir()
        write(dir, "a.txt", "x\n")
        write(dir, "b.txt", "y\n")
        // Two consecutive Update hunks; the second header (raw leading '*')
        // must terminate the first hunk's body.
        let patch = """
        *** Begin Patch
        *** Update File: a.txt
        -x
        +x2
        *** Update File: b.txt
        -y
        +y2
        *** End Patch

        """
        let result = try ApplyPatch().apply(patch, root: dir)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(read((dir as NSString).appendingPathComponent("a.txt")), "x2\n")
        XCTAssertEqual(read((dir as NSString).appendingPathComponent("b.txt")), "y2\n")
    }

    // MARK: - v12 Finding 1: indented `*** Move to:` is context, not a move

    /// Upstream tests the move-to prefix against the RAW (un-trimmed) line
    /// (`x.strip_prefix(MOVE_TO_MARKER)`, parser.rs:317-319), unlike hunk headers
    /// (trimmed). An indented "  *** Move to: foo" therefore does NOT register as
    /// a rename — the raw `starts_with('*')` break (parser.rs:334) also fails for
    /// a leading space, so the line is absorbed as a CONTEXT line. The Swift port
    /// previously trimmed before matching and wrongly treated it as a move.
    func testIndentedMoveToLineTreatedAsContextNotRename() throws {
        let dir = tmpDir()
        // File literally contains " *** Move to: dst.txt" (one leading space) —
        // i.e. the patch context line below with its leading context-marker space
        // stripped.
        let original = " *** Move to: dst.txt\nbody\n"
        let path = write(dir, "u.txt", original)
        // The Update hunk's first line is " *** Move to: dst.txt" preceded by a
        // context-marker space ("  *** Move to: dst.txt"). The RAW line starts
        // with a space (not '*'), so it is NOT a rename and is kept as context;
        // the change rewrites `body`.
        let patch = "*** Begin Patch\n*** Update File: u.txt\n  *** Move to: dst.txt\n-body\n+changed\n*** End Patch\n"
        let result = try ApplyPatch().apply(patch, root: dir)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.first?.movePath, "indented Move-to must NOT be a rename")
        XCTAssertEqual(read(path), " *** Move to: dst.txt\nchanged\n")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("dst.txt")),
            "no destination file should be created")
    }

    /// Sanity: a RAW (un-indented) `*** Move to:` line IS still a rename.
    func testRawMoveToLineStillRenames() throws {
        let dir = tmpDir()
        let path = write(dir, "src.txt", "hello\n")
        let patch = "*** Begin Patch\n*** Update File: src.txt\n*** Move to: dst.txt\n-hello\n+world\n*** End Patch\n"
        let result = try ApplyPatch().apply(patch, root: dir)
        XCTAssertEqual(result.first?.movePath, "dst.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(read((dir as NSString).appendingPathComponent("dst.txt")), "world\n")
    }

    // MARK: - v12 Finding 2: repeated `*** Update File:` for one path is independent

    /// Upstream emits one `Hunk::UpdateFile` per block (parser.rs:314-365, no
    /// merge by path) and `apply_hunks_to_files` applies each independently,
    /// re-reading the file between hunks (lib.rs:393-547). Two blocks for the
    /// same path must therefore compose sequentially: the SECOND block's context
    /// is matched against the FIRST block's already-applied result. The previous
    /// Swift port merged both blocks' chunks against a SINGLE read, which fails
    /// when the second block's context line was produced by the first block.
    func testRepeatedUpdateBlocksAppliedSequentially() throws {
        let dir = tmpDir()
        let path = write(dir, "f.txt", "one\ntwo\n")
        // Block 1: one -> ONE. Block 2: matches the just-written "ONE" and the
        // unchanged "two", proving block 2 sees block 1's output.
        let patch = """
        *** Begin Patch
        *** Update File: f.txt
        -one
        +ONE
        *** Update File: f.txt
         ONE
        -two
        +TWO
        *** End Patch

        """
        let result = try ApplyPatch().apply(patch, root: dir)
        // Two independent hunks → two PatchedFile entries (not merged into one).
        XCTAssertEqual(result.count, 2, "each *** Update File: block is a separate hunk")
        XCTAssertTrue(result.allSatisfy { $0.kind == .update })
        XCTAssertEqual(read(path), "ONE\nTWO\n")
    }

    /// An add-then-update chain for the same path: the Update must see the
    /// freshly-added content (overlay re-read), matching upstream's per-hunk
    /// `fs` read in `apply_hunks_to_files`.
    func testAddThenUpdateSamePathSeesAddedContent() throws {
        let dir = tmpDir()
        let path = (dir as NSString).appendingPathComponent("new.txt")
        let patch = """
        *** Begin Patch
        *** Add File: new.txt
        +alpha
        +beta
        *** Update File: new.txt
        -beta
        +BETA
        *** End Patch

        """
        let result = try ApplyPatch().apply(patch, root: dir)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.kind, .add)
        XCTAssertEqual(result.last?.kind, .update)
        XCTAssertEqual(read(path), "alpha\nBETA\n")
    }
}
