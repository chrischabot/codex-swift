import Foundation

public enum ApplyPatchError: Error, Sendable, Equatable {
    case malformed(String)
    /// A hunk-class parse error carrying the offending line number, mirroring
    /// upstream `ParseError::InvalidHunkError { message, line_number }`
    /// (apply-patch/src/parser.rs:58-59). Renders via `formatted` as
    /// "invalid hunk at line N, <message>".
    case malformedHunk(String, Int)
    case contextMismatch(String)
    case targetMissing(String)
    case targetExists(String)
    case unsafePath(String)
    /// An empty-but-boundary-valid patch applied with no hunks. Upstream
    /// surfaces this as a bare apply-time `anyhow::bail!("No files were
    /// modified.")` (lib.rs:371-373) written to stderr — NOT a parser
    /// `InvalidPatchError`, so its `formatted` carries NO `invalid patch:`
    /// prefix. The associated value is the literal message.
    case emptyPatch(String)

    /// The model-facing message body, reproducing upstream's error `Display`
    /// implementations so the surfaced text matches codex-rs byte-for-byte:
    ///  - parser `InvalidPatchError(s)` → "invalid patch: {s}" (parser.rs:56)
    ///  - parser `InvalidHunkError { message, line_number }`
    ///    → "invalid hunk at line {line_number}, {message}" (parser.rs:58)
    ///  - apply-time errors (context mismatch, IoError context for
    ///    delete/update) surface their bare message (lib.rs anyhow contexts).
    public var formatted: String {
        switch self {
        case .malformed(let m):
            return "invalid patch: \(m)"
        case .malformedHunk(let m, let line):
            return "invalid hunk at line \(line), \(m)"
        case .contextMismatch(let m), .targetMissing(let m),
             .targetExists(let m), .unsafePath(let m):
            return m
        case .emptyPatch(let m):
            // Bare apply-time stderr text — no `invalid patch:` prefix
            // (lib.rs:371-373 `anyhow::bail!`, surfaced via apply_hunks's
            // writeln at lib.rs:336).
            return m
        }
    }
}

public struct PatchedFile: Sendable, Equatable {
    public enum Kind: String, Sendable { case add, update, delete }
    public var path: String
    public var kind: Kind
    public var movePath: String?
    public var newContents: String?   // nil for delete
    public var unifiedDiff: String
    /// Prior on-disk content of `path` (nil for a clean Add). For Update/Delete
    /// this is the file's text before the change; for an Add that overwrote an
    /// existing file it is the overwritten content. Carried so callers (e.g.
    /// `TurnDiffTracker`) can reconstruct the per-file `AppliedPatchDelta`
    /// without rereading the workspace — parity with upstream
    /// `AppliedPatchFileChange`.
    public var oldContents: String?
    /// Prior on-disk content of the move destination, when an Update with a
    /// `movePath` overwrote an existing file there (upstream
    /// `overwritten_move_content`).
    public var overwrittenMoveContents: String?

    public init(path: String, kind: Kind, movePath: String? = nil,
                newContents: String?, unifiedDiff: String,
                oldContents: String? = nil,
                overwrittenMoveContents: String? = nil) {
        self.path = path
        self.kind = kind
        self.movePath = movePath
        self.newContents = newContents
        self.unifiedDiff = unifiedDiff
        self.oldContents = oldContents
        self.overwrittenMoveContents = overwrittenMoveContents
    }

    /// Convert this applied change into an `AppliedPatchChange` for the
    /// `TurnDiffTracker` (parity with how upstream `apply_patch` records each
    /// committed change). Returns nil only if invariants are violated (never in
    /// practice, since `apply` always populates the relevant content fields).
    public func toAppliedChange() -> AppliedPatchChange? {
        switch kind {
        case .add:
            return AppliedPatchChange(
                path: path,
                change: .add(content: newContents ?? "",
                             overwrittenContent: oldContents))
        case .delete:
            return AppliedPatchChange(
                path: path,
                change: .delete(content: oldContents ?? ""))
        case .update:
            return AppliedPatchChange(
                path: path,
                change: .update(movePath: movePath,
                                oldContent: oldContents ?? "",
                                overwrittenMoveContent: overwrittenMoveContents,
                                newContent: newContents ?? ""))
        }
    }
}

extension Array where Element == PatchedFile {
    /// Build an `AppliedPatchDelta` from a successful `apply` result, preserving
    /// the committed order. `exact` is always true here because the Swift
    /// applier only returns success when every hunk matched; failures throw.
    public func appliedPatchDelta() -> AppliedPatchDelta {
        AppliedPatchDelta(changes: compactMap { $0.toAppliedChange() }, exact: true)
    }
}

/// Pure parser/applier for the Codex `apply_patch` envelope, ported faithfully
/// from codex-rs `apply-patch` (parser.rs + seek_sequence.rs + lib.rs).
///
/// No instance state — `parse`/`apply` are pure and the type is `Sendable`.
/// Repeated `*** Update File:` sections for the same path are NOT merged: each
/// `*** Update File:` block becomes a separate hunk (parity with upstream
/// `parser.rs:314-365`, which emits one `Hunk::UpdateFile` per block) and is
/// applied independently and sequentially against the (possibly already
/// modified) target — `apply()` models the evolving content via an in-memory
/// overlay, matching upstream `apply_hunks_to_files`' per-hunk re-read
/// (lib.rs:393-547). Target paths are validated to stay within `root`
/// (path-traversal + symlink-escape guards).
public struct ApplyPatch: Sendable {
    public init() {}

    // MARK: - Internal model

    private struct UpdateChunk {
        var changeContext: String?
        var oldLines: [String]
        var newLines: [String]
        var isEndOfFile: Bool
    }

    private struct ParsedFile {
        var path: String
        var kind: PatchedFile.Kind
        var movePath: String?
        var addContents: String?      // on-disk content for Add (no forced newline)
        var chunks: [UpdateChunk]     // for Update
    }

    private struct ParsedPatch {
        var files: [ParsedFile]
        var environmentId: String?
    }

    // MARK: - Public surface

    public func parse(_ patch: String) throws -> [PatchedFile] {
        try parseInternal(patch).files.map { Self.toPatchedFile($0) }
    }

    /// A fully-verified change ready to be committed to disk. Computed during
    /// the verify pass (no filesystem mutation), then applied during the second
    /// pass. Mirrors upstream `ApplyPatchFileChange` (invocation.rs:188-233):
    /// every hunk is read + validated in-memory first, and only if EVERY hunk
    /// verifies does any write happen.
    private struct VerifiedChange {
        var file: PatchedFile
        /// Absolute path to write the new contents to (move destination when
        /// the update has a `movePath`, else the original path).
        var writePath: String?         // nil for Delete
        var newContents: String?       // nil for Delete
        /// Original absolute path to remove (Delete, or the source of a move).
        var removePath: String?
    }

    public func apply(_ patch: String, root: String) throws -> [PatchedFile] {
        let parsed = try parseInternal(patch)
        let fm = FileManager.default

        // Mirror upstream `apply_hunks_to_files` (lib.rs:371-373): an empty
        // (boundary-valid) patch with no hunks is an apply-time
        // `anyhow::bail!("No files were modified.")`, surfaced as a bare runtime
        // stderr line — NOT a parser `invalid patch:` error.
        if parsed.files.isEmpty {
            throw ApplyPatchError.emptyPatch("No files were modified.")
        }

        // ---------------------------------------------------------------
        // PHASE 1 — VERIFY (no filesystem mutation).
        //
        // Upstream `verify_apply_patch_args` (invocation.rs:161-233) reads
        // EVERY hunk's target and computes its new contents (Delete →
        // read_file_text; Update → unified_diff_from_chunks →
        // derive_new_contents_from_chunks → compute_replacements) WITHOUT
        // touching the filesystem. Any hunk failure returns a CorrectnessError,
        // so NO file is mutated. We reproduce that all-or-nothing guarantee:
        // build a list of `VerifiedChange`s, surfacing any context-mismatch,
        // missing-target, or path error here BEFORE any write happens.
        // ---------------------------------------------------------------
        var verified: [VerifiedChange] = []

        // In-memory content overlay tracking each absolute path's EVOLVING
        // content across hunks during verification. Upstream
        // `apply_hunks_to_files` (lib.rs:393-547) applies each hunk sequentially
        // and re-reads the file from `fs` for the next hunk, so a second
        // `*** Update File:` block for the same path (or an Add/Update/Delete
        // chain) sees the prior hunk's result, not the original on-disk content.
        // The Swift port keeps its two-phase verify-then-apply (all-or-nothing)
        // design, so we model the same evolving view here: `overlay[abs]` holds
        // the current content (`.some` = present with content, `nil` entry =
        // known-deleted) once a hunk has touched that path; absence from the map
        // means "not yet touched — read from disk".
        var overlay: [String: String?] = [:]
        func currentContent(_ abs: String) -> String? {
            if let entry = overlay[abs] { return entry }
            return try? String(contentsOfFile: abs, encoding: .utf8)
        }
        func currentExists(_ abs: String) -> Bool {
            if let entry = overlay[abs] { return entry != nil }
            return fm.fileExists(atPath: abs)
        }

        for f in parsed.files {
            try Self.validateRelativePath(f.path)
            let full = (root as NSString).appendingPathComponent(f.path)
            try Self.assertContained(root: root, target: full)

            switch f.kind {
            case .add:
                // Upstream `lib.rs:397-417` reads any pre-existing content
                // (`read_optional_file_text_for_delta`) into `overwritten_content`
                // and then writes UNCONDITIONALLY — an `*** Add File:` over an
                // existing path overwrites it rather than erroring.
                let overwrittenContent = currentContent(full)
                let contents = f.addContents ?? ""
                overlay[full] = contents
                verified.append(VerifiedChange(
                    file: PatchedFile(
                        path: f.path, kind: .add, movePath: nil,
                        newContents: contents,
                        unifiedDiff: Self.makeUnifiedDiff(
                            old: overwrittenContent ?? "", new: contents, path: f.path,
                            movePath: nil, kind: .add),
                        oldContents: overwrittenContent),
                    writePath: full, newContents: contents, removePath: nil))

            case .delete:
                guard currentExists(full) else {
                    // On the production handler path a missing delete target
                    // fails during VERIFICATION (invocation.rs:188-198):
                    // `read_file_text` errors and is wrapped as
                    // IoError{ context: "Failed to read {abs}", source }. IoError
                    // Display is "{context}: {source}" (lib.rs:81). Reproduce both
                    // the "Failed to read" verb and the trailing OS-error suffix.
                    throw ApplyPatchError.targetMissing(
                        "Failed to read \(full): \(Self.osErrorString(full))")
                }
                let original = currentContent(full) ?? ""
                overlay[full] = String?.none
                verified.append(VerifiedChange(
                    file: PatchedFile(
                        path: f.path, kind: .delete, movePath: nil,
                        newContents: nil,
                        unifiedDiff: Self.makeUnifiedDiff(
                            old: original, new: "", path: f.path,
                            movePath: nil, kind: .delete),
                        oldContents: original),
                    writePath: nil, newContents: nil, removePath: full))

            case .update:
                guard let original = currentContent(full) else {
                    // Upstream wraps the read failure as IoError with context
                    // "Failed to read file to update {abs}" (lib.rs:663-668), and
                    // IoError Display appends ": {source}" (lib.rs:81). Surface the
                    // absolute path AND the trailing OS-error suffix.
                    throw ApplyPatchError.targetMissing(
                        "Failed to read file to update \(full): \(Self.osErrorString(full))")
                }
                // Pass the ABSOLUTE path so fuzzy context-mismatch /
                // expected-lines errors render the resolved path, matching
                // upstream `compute_replacements(&original_lines, path_abs, …)`
                // (lib.rs:678, 714-718, 771-775).
                let updated = try Self.deriveNewContents(
                    original: original, chunks: f.chunks, path: full)

                var overwrittenMoveContent: String?
                var writePath = full
                var removePath: String?
                if let move = f.movePath {
                    try Self.validateRelativePath(move)
                    let moveFull = (root as NSString).appendingPathComponent(move)
                    try Self.assertContained(root: root, target: moveFull)
                    // Upstream `lib.rs:465-486` reads any pre-existing content at
                    // the move destination (`read_optional_file_text_for_delta` →
                    // `overwritten_move_content`) and then writes UNCONDITIONALLY,
                    // overwriting rather than erroring on an existing destination.
                    overwrittenMoveContent = currentContent(moveFull)
                    overlay[moveFull] = updated
                    overlay[full] = String?.none
                    writePath = moveFull
                    removePath = full
                } else {
                    overlay[full] = updated
                }

                verified.append(VerifiedChange(
                    file: PatchedFile(
                        path: f.path, kind: .update, movePath: f.movePath,
                        newContents: updated,
                        unifiedDiff: Self.makeUnifiedDiff(
                            old: original, new: updated, path: f.path,
                            movePath: f.movePath, kind: .update),
                        oldContents: original,
                        overwrittenMoveContents: overwrittenMoveContent),
                    writePath: writePath, newContents: updated, removePath: removePath))
            }
        }

        // ---------------------------------------------------------------
        // PHASE 2 — APPLY (all hunks verified; now mutate the filesystem).
        //
        // Mirrors upstream `apply_hunks_to_files` (lib.rs:393-547): writes the
        // new contents and removes move sources / delete targets. Because every
        // hunk already verified above, a mid-stream failure here can only be a
        // genuine I/O fault (disk full, permission), not a context/missing-target
        // mismatch — so well-formed multi-file patches are all-or-nothing.
        // ---------------------------------------------------------------
        var applied: [PatchedFile] = []
        for change in verified {
            if let writePath = change.writePath, let contents = change.newContents {
                try fm.createDirectory(
                    atPath: (writePath as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try contents.write(toFile: writePath, atomically: true, encoding: .utf8)
            }
            if let removePath = change.removePath,
               // For a move, only remove the source if it still exists and is
               // not the same path we just wrote (matches upstream rename).
               removePath != change.writePath,
               fm.fileExists(atPath: removePath) {
                try fm.removeItem(atPath: removePath)
            }
            applied.append(change.file)
        }
        return applied
    }

    /// Reproduce Rust's `std::io::Error` Display text for the failure of an
    /// operation on `path`, e.g. "No such file or directory (os error 2)".
    /// Used to append the `: {source}` suffix that upstream's `IoError` Display
    /// always emits (lib.rs:81), keeping the model-facing message byte-identical.
    private static func osErrorString(_ path: String) -> String {
        errno = 0
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return "Success (os error 0)" }
        let e = errno
        return "\(String(cString: strerror(e))) (os error \(e))"
    }

    private static func toPatchedFile(_ f: ParsedFile) -> PatchedFile {
        switch f.kind {
        case .add:
            let c = f.addContents ?? ""
            return PatchedFile(
                path: f.path, kind: .add, movePath: nil, newContents: c,
                unifiedDiff: makeUnifiedDiff(old: "", new: c, path: f.path,
                                             movePath: nil, kind: .add))
        case .delete:
            return PatchedFile(
                path: f.path, kind: .delete, movePath: nil, newContents: nil,
                unifiedDiff: makeUnifiedDiff(old: "", new: "", path: f.path,
                                             movePath: nil, kind: .delete))
        case .update:
            let oldStr = f.chunks.flatMap { $0.oldLines }.joined(separator: "\n")
            let newStr = f.chunks.flatMap { $0.newLines }.joined(separator: "\n")
            return PatchedFile(
                path: f.path, kind: .update, movePath: f.movePath,
                newContents: nil,
                unifiedDiff: makeUnifiedDiff(old: oldStr, new: newStr,
                                             path: f.path, movePath: f.movePath,
                                             kind: .update))
        }
    }

    // MARK: - Security guards (PRESERVED EXACTLY)

    /// Reject absolute paths and any `..` component (path-traversal guard for
    /// direct callers; the sandbox is an additional, not the only, boundary).
    ///
    /// INTENTIONAL PORT DIVERGENCE (audit-findings-v9 apply-patch #4): upstream
    /// `parser.rs:288-373` parses Add/Delete/Update/Move paths permissively via
    /// `PathBuf::from` with NO rejection of absolute paths or `..`
    /// (`test_parse_patch_accepts_relative_and_absolute_hunk_paths`,
    /// parser.rs:728-771), and relies on `Hunk::resolve_path` + sandbox
    /// containment as the boundary. The Swift port instead layers a
    /// defense-in-depth containment guard into the parse/apply path. This is an
    /// accepted hardening choice for the macOS server: (1) the sandbox is the
    /// primary boundary, (2) `assertContained` (below) provides redundant
    /// apply-time containment, and (3) models/frontends in this harness always
    /// emit relative paths, so normal traffic is unaffected. Do NOT remove this
    /// guard to "match" upstream — the divergence is deliberate and documented.
    static func validateRelativePath(_ p: String) throws {
        if p.hasPrefix("/") { throw ApplyPatchError.unsafePath("absolute path: \(p)") }
        let comps = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.contains("..") { throw ApplyPatchError.unsafePath("path traversal: \(p)") }
        if p.isEmpty { throw ApplyPatchError.unsafePath("empty path") }
    }

    /// Symlink-escape containment (CWE-59): no Add/Update/Delete may resolve
    /// outside the workspace root through a symlink. `resolvingSymlinksInPath`
    /// only resolves components that exist, so for a not-yet-existing target
    /// we resolve the nearest EXISTING ancestor (catches a symlinked
    /// intermediate directory); if the target itself exists we also resolve it
    /// (catches a symlinked target file). Both must stay within the resolved
    /// root.
    static func assertContained(root: String, target: String) throws {
        let fm = FileManager.default
        func resolve(_ p: String) -> String {
            URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let realRoot = resolve(root)
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        func requireWithin(_ resolved: String) throws {
            if resolved != realRoot && !resolved.hasPrefix(prefix) {
                throw ApplyPatchError.unsafePath("escapes workspace root: \(target)")
            }
        }
        var dir = ((target as NSString).standardizingPath as NSString)
            .deletingLastPathComponent
        while !dir.isEmpty && dir != "/" && !fm.fileExists(atPath: dir) {
            dir = (dir as NSString).deletingLastPathComponent
        }
        try requireWithin(resolve(dir.isEmpty ? "/" : dir))
        if fm.fileExists(atPath: target) {
            try requireWithin(resolve(target))
        }
    }

    // MARK: - Parser (parser.rs)

    private static func afterPrefix(_ s: String, _ pre: String) -> String? {
        s.hasPrefix(pre) ? String(s.dropFirst(pre.count)) : nil
    }

    private func parseInternal(_ patch: String) throws -> ParsedPatch {
        let trimmedWhole = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmedWhole
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { (sub: Substring) -> String in
                var s = String(sub)
                if s.hasSuffix("\r") { s.removeLast() }
                return s
            }

        // Mirror upstream `check_start_and_end_lines_strict` (parser.rs:264-282):
        // distinguish a wrong FIRST line from a wrong LAST line so the model
        // gets the precise boundary error. Returns the matching `ParseError`
        // message (already an `InvalidPatchError` body), or nil when both
        // boundaries are valid.
        func boundaryError(_ ls: [String]) -> String? {
            let first = ls.first?.trimmingCharacters(in: .whitespaces)
            let last = ls.last?.trimmingCharacters(in: .whitespaces)
            if let f = first, let l = last,
               f == "*** Begin Patch", l == "*** End Patch" {
                return nil
            }
            // Mirror upstream `check_start_and_end_lines_strict` (parser.rs:264-282)
            // and the `[] => (None, None)` arm of `check_patch_boundaries_strict`
            // (parser.rs:227): the `(Some(first), _) if first != BEGIN` arm only
            // matches when there IS a first line. A fully empty patch (`first ==
            // nil`, i.e. no lines at all) falls through to the final `_` arm and
            // reports the LAST-line message. Swift's `split` on an empty trimmed
            // string yields `[""]`, so an empty patch surfaces here as
            // `first == ""`; treat that (and the genuinely empty `ls`) as the
            // `(None, None)` case so the model sees the same text as upstream.
            if let f = first, f != "*** Begin Patch", !ls.isEmpty, !(ls.count == 1 && f.isEmpty) {
                return "The first line of the patch must be '*** Begin Patch'"
            }
            return "The last line of the patch must be '*** End Patch'"
        }

        if let strictError = boundaryError(lines) {
            // Lenient mode (`check_patch_boundaries_lenient`, parser.rs:240-262):
            // if the text is heredoc-wrapped, strip the markers and re-run the
            // strict boundary check on the inner lines; if THAT fails, surface
            // its (inner) boundary message — NOT the original outer error.
            if lines.count >= 4,
               let f = lines.first, let l = lines.last,
               (f == "<<EOF" || f == "<<'EOF'" || f == "<<\"EOF\""),
               l.hasSuffix("EOF") {
                let inner = Array(lines[1..<(lines.count - 1)])
                if let innerError = boundaryError(inner) {
                    throw ApplyPatchError.malformed(innerError)
                }
                lines = inner
            } else {
                throw ApplyPatchError.malformed(strictError)
            }
        }

        let body = Array(lines[1..<(lines.count - 1)])

        // Absolute line number of `body[0]` per upstream: the body begins on
        // line 2 (after `*** Begin Patch`), and the environment-id preamble, if
        // present, bumps it to 3 (parser.rs:201-217).
        var bodyStartLine = 2

        var environmentId: String?
        var i = 0

        if i < body.count {
            let raw = body[i]
            let ls = String(raw.drop(while: { $0 == " " || $0 == "\t" }))
            if let rest = Self.afterPrefix(ls, "*** Environment ID: ") {
                let id = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if id.isEmpty {
                    throw ApplyPatchError.malformed(
                        "apply_patch environment_id cannot be empty")
                }
                environmentId = id
                i += 1
                bodyStartLine = 3
            }
        }

        var files: [ParsedFile] = []

        while i < body.count {
            let line = body[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // NOTE: upstream's top-level hunk loop (parser.rs:186-191) does NOT
            // skip blank lines between hunks — only the inside of an Update hunk
            // consumes blanks (parser.rs:328-332, mirrored at lines 433-436
            // below). A blank line at a hunk-header position therefore falls
            // through to `parse_one_hunk`'s final arm (parser.rs:368-373) and
            // errors as "'' is not a valid hunk header. …". Do NOT add a
            // blank-line skip here.

            // Absolute line number of this hunk's header, mirroring upstream's
            // `line_number` accumulator (parser.rs:183-191).
            let hunkLine = bodyStartLine + i

            if let path = Self.afterPrefix(trimmed, "*** Add File: ") {
                try Self.validateRelativePath(path)
                i += 1
                var added: [String] = []
                while i < body.count, body[i].hasPrefix("+") {
                    added.append(String(body[i].dropFirst()))
                    i += 1
                }
                // Upstream `parser.rs:291-299` pushes `line + "\n"` for EVERY
                // added line, so `+line1\n+line2` yields `"line1\nline2\n"`
                // (trailing newline included). `lib.rs:405` writes that content
                // verbatim. Reproduce exactly.
                let disk = added.map { $0 + "\n" }.joined()
                files.append(ParsedFile(
                    path: path, kind: .add, movePath: nil,
                    addContents: disk, chunks: []))

            } else if let path = Self.afterPrefix(trimmed, "*** Delete File: ") {
                try Self.validateRelativePath(path)
                i += 1
                files.append(ParsedFile(
                    path: path, kind: .delete, movePath: nil,
                    addContents: nil, chunks: []))

            } else if let path = Self.afterPrefix(trimmed, "*** Update File: ") {
                try Self.validateRelativePath(path)
                i += 1

                var movePath: String?
                if i < body.count {
                    // Upstream `parser.rs:317-319` tests the move prefix against
                    // the RAW (un-trimmed) line via `x.strip_prefix(MOVE_TO_MARKER)`
                    // — unlike the hunk headers, which are tested against
                    // `first_line.trim()`. An indented "  *** Move to: foo" therefore
                    // does NOT match as a move; it falls into the chunk loop where the
                    // raw `starts_with('*')` break (line 539) also fails for a leading
                    // space, so it is absorbed as a context line. Match exactly: test
                    // the RAW line, not a trimmed copy.
                    if let mp = Self.afterPrefix(body[i], "*** Move to: ") {
                        try Self.validateRelativePath(mp)
                        movePath = mp
                        i += 1
                    }
                }

                var sectionChunks: [UpdateChunk] = []
                while i < body.count {
                    let raw = body[i]
                    if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                        i += 1
                        continue
                    }
                    // Upstream parser.rs:334 tests ONLY the RAW (untrimmed)
                    // line for a literal leading `*`: `remaining_lines[0]
                    // .starts_with('*')`. An indented line such as
                    // "  *** Add File: x" does NOT start with `*`, so upstream
                    // absorbs it as a context line rather than breaking out into
                    // a new hunk. Match that exactly — do not trim first.
                    if raw.hasPrefix("*") { break }
                    // Upstream passes `line_number + parsed_lines` to
                    // `parse_update_file_chunk` (parser.rs:338-342); at this
                    // point `bodyStartLine + i` is exactly that absolute line.
                    let chunk = try Self.parseChunk(
                        body, &i,
                        allowMissingContext: sectionChunks.isEmpty,
                        path: path,
                        lineNumber: bodyStartLine + i)
                    sectionChunks.append(chunk)
                }

                if sectionChunks.isEmpty {
                    throw ApplyPatchError.malformedHunk(
                        "Update file hunk for path '\(path)' is empty", hunkLine)
                }

                // Upstream `parser.rs:314-365` produces one `Hunk::UpdateFile`
                // per `*** Update File:` block with NO merging by path; on the
                // CLI/runtime apply path (`apply_hunks_to_files`, lib.rs:393-547)
                // each UpdateFile hunk is applied independently, re-reading the
                // (possibly already-modified) target each time. Emit a separate
                // ParsedFile per block rather than merging chunks for a repeated
                // path — `apply()` processes them sequentially against fresh reads.
                files.append(ParsedFile(
                    path: path, kind: .update, movePath: movePath,
                    addContents: nil, chunks: sectionChunks))

            } else {
                // Mirror upstream `parse_one_hunk`'s final fallthrough
                // (parser.rs:368-373): on an unrecognised hunk header, tell the
                // model exactly which three header forms are valid, with the
                // offending line number. `{path}` is a literal placeholder
                // upstream (note the doubled braces in the Rust `format!`).
                throw ApplyPatchError.malformedHunk(
                    "'\(trimmed)' is not a valid hunk header. Valid hunk headers: "
                        + "'*** Add File: {path}', '*** Delete File: {path}', "
                        + "'*** Update File: {path}'",
                    hunkLine)
            }
        }

        // NOTE: an empty-but-boundary-valid patch (`*** Begin Patch` /
        // `*** End Patch` with no hunks) is NOT a parse error upstream:
        // `parse_patch` returns `Ok` with `hunks: Vec::new()` (parser.rs:623-632).
        // The "No files were modified." text is an apply-time
        // `anyhow::bail!` from `apply_hunks_to_files` (lib.rs:371-373), surfaced
        // as a bare runtime stderr line — NOT prefixed with `invalid patch:`.
        // Do NOT throw here; let `parse()` return an empty list and let `apply()`
        // raise the apply-time `emptyPatch` error so the model-facing message
        // matches upstream verbatim.
        return ParsedPatch(files: files, environmentId: environmentId)
    }

    private static func parseChunk(_ b: [String], _ i: inout Int,
                                   allowMissingContext: Bool,
                                   path: String,
                                   lineNumber: Int) throws -> UpdateChunk {
        // Upstream `parse_update_file_chunk` (parser.rs:376-465): the empty-input
        // guard and the missing-`@@`-context error use `line_number`; the
        // body-level "does not contain any lines" / unexpected-line errors use
        // `line_number + 1`.
        if i >= b.count {
            throw ApplyPatchError.malformedHunk(
                "Update hunk does not contain any lines", lineNumber)
        }
        var ctx: String?
        if i < b.count {
            let line = b[i]
            if line == "@@" {
                ctx = nil
                i += 1
            } else if line.hasPrefix("@@ ") {
                ctx = String(line.dropFirst(3))
                i += 1
            } else if allowMissingContext {
                ctx = nil
                // do NOT consume
            } else {
                throw ApplyPatchError.malformedHunk(
                    "Expected update hunk to start with a @@ context marker, got: '\(line)'",
                    lineNumber)
            }
        } else if !allowMissingContext {
            throw ApplyPatchError.malformedHunk(
                "Expected update hunk to start with a @@ context marker, got: ''",
                lineNumber)
        }

        if i >= b.count {
            throw ApplyPatchError.malformedHunk(
                "Update hunk does not contain any lines", lineNumber + 1)
        }

        var oldLines: [String] = []
        var newLines: [String] = []
        var isEOF = false
        var parsedAny = false

        while i < b.count {
            let line = b[i]
            if line == "*** End of File" {
                if !parsedAny {
                    throw ApplyPatchError.malformedHunk(
                        "Update hunk does not contain any lines", lineNumber + 1)
                }
                isEOF = true
                i += 1
                break
            }
            if line.isEmpty {
                oldLines.append("")
                newLines.append("")
                parsedAny = true
                i += 1
                continue
            }
            let c = line.first!
            if c == " " {
                let s = String(line.dropFirst())
                oldLines.append(s)
                newLines.append(s)
                parsedAny = true
                i += 1
            } else if c == "+" {
                newLines.append(String(line.dropFirst()))
                parsedAny = true
                i += 1
            } else if c == "-" {
                oldLines.append(String(line.dropFirst()))
                parsedAny = true
                i += 1
            } else {
                if !parsedAny {
                    throw ApplyPatchError.malformedHunk(
                        "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)",
                        lineNumber + 1)
                }
                break  // start of next hunk — do NOT consume
            }
        }

        return UpdateChunk(changeContext: ctx, oldLines: oldLines,
                           newLines: newLines, isEndOfFile: isEOF)
    }

    // MARK: - seek_sequence.rs

    /// Rust's `str::trim_end()` / `str::trim()` (used by seek_sequence's
    /// rstrip/trim passes at seek_sequence.rs:44,57) strip by
    /// `char::is_whitespace()`, i.e. the full Unicode `White_Space` property.
    /// That set is broader than ASCII and broader than what `normalise()`
    /// (seek_sequence.rs:76-94) later maps to space: it ALSO includes
    /// U+0085 (NEL), U+1680 (Ogham space mark), U+2000-U+2001 (en/em quad),
    /// U+2028 (line separator), U+2029 (paragraph separator), U+00A0 (NBSP),
    /// U+2002-U+200A, U+202F, U+205F and U+3000. A context line or file line
    /// whose only trailing/leading difference is one of these exotic scalars
    /// must match here (Rust trims it away before comparing) even though
    /// normalise() would not handle it — so the trim/rstrip predicate must use
    /// the Unicode White_Space property, NOT an ASCII-only set.
    @inline(__always)
    private static func isUnicodeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    private static func trimEnd(_ s: String) -> String {
        var v = s.unicodeScalars
        while let last = v.last, isUnicodeWhitespace(last) {
            v.removeLast()
        }
        return String(v)
    }

    private static func fullTrim(_ s: String) -> String {
        var v = s.unicodeScalars
        while let last = v.last, isUnicodeWhitespace(last) {
            v.removeLast()
        }
        var startIdx = v.startIndex
        while startIdx != v.endIndex, isUnicodeWhitespace(v[startIdx]) {
            startIdx = v.index(after: startIdx)
        }
        return String(v[startIdx...])
    }

    private static func normalise(_ s: String) -> String {
        // Rust's normalise() starts with `s.trim()` — the same
        // `char::is_whitespace()` (Unicode White_Space) trim used above, so
        // route through `fullTrim` rather than `.whitespacesAndNewlines`
        // (which omits some White_Space scalars such as U+0085 NEL).
        let t = fullTrim(s)
        var scalars: [Unicode.Scalar] = []
        for u in t.unicodeScalars {
            let v = u.value
            if (0x2010...0x2015).contains(v) || v == 0x2212 {
                scalars.append(Unicode.Scalar(0x2D)!)            // '-'
            } else if (0x2018...0x201B).contains(v) {
                scalars.append(Unicode.Scalar(0x27)!)            // '\''
            } else if (0x201C...0x201F).contains(v) {
                scalars.append(Unicode.Scalar(0x22)!)            // '"'
            } else if v == 0x00A0 || (0x2002...0x200A).contains(v)
                        || v == 0x202F || v == 0x205F || v == 0x3000 {
                scalars.append(Unicode.Scalar(0x20)!)            // ' '
            } else {
                scalars.append(u)
            }
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func seekSequence(_ lines: [String], _ pattern: [String],
                                     _ start: Int, _ eof: Bool) -> Int? {
        if pattern.isEmpty { return start }
        if pattern.count > lines.count { return nil }

        let searchStart = (eof && lines.count >= pattern.count)
            ? lines.count - pattern.count
            : start
        if searchStart < 0 { return nil }
        let upper = lines.count - pattern.count
        if searchStart > upper { return nil }

        func scan(_ eq: (String, String) -> Bool) -> Int? {
            var i = searchStart
            while i <= upper {
                var ok = true
                var j = 0
                while j < pattern.count {
                    if !eq(lines[i + j], pattern[j]) { ok = false; break }
                    j += 1
                }
                if ok { return i }
                i += 1
            }
            return nil
        }

        if let r = scan({ $0 == $1 }) { return r }
        if let r = scan({ trimEnd($0) == trimEnd($1) }) { return r }
        if let r = scan({ fullTrim($0) == fullTrim($1) }) { return r }
        if let r = scan({ normalise($0) == normalise($1) }) { return r }
        return nil
    }

    // MARK: - Apply flow (lib.rs)

    private static func deriveNewContents(original: String,
                                          chunks: [UpdateChunk],
                                          path: String) throws -> String {
        var originalLines = original
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // Mirror upstream `lib.rs:674-676`: drop the synthetic trailing empty
        // element produced by splitting a newline-terminated file BEFORE
        // matching, so hunk contexts line up against real content lines.
        if originalLines.last == "" { originalLines.removeLast() }

        // Three-phase algorithm matching upstream compute_replacements /
        // apply_replacements (lib.rs:691-810):
        //   (1) compute all replacements against the IMMUTABLE original lines,
        //       advancing a read cursor through the original coordinate space;
        //   (2) sort replacements by start index ascending;
        //   (3) apply them to a mutable copy in DESCENDING order so earlier
        //       replacements don't shift the positions of later ones.
        let replacements = try computeReplacements(originalLines: originalLines,
                                                   chunks: chunks,
                                                   path: path)
        var lines = applyReplacements(originalLines, replacements)

        // Mirror upstream `lib.rs:681-683`: guarantee a trailing newline by
        // re-adding the trailing empty element before re-joining.
        if lines.last != "" { lines.append("") }
        return lines.joined(separator: "\n")
    }

    /// Compute a list of `(startIndex, oldLen, newLines)` replacements needed
    /// to transform `originalLines` per the patch `chunks`. Mirrors upstream
    /// `compute_replacements` (lib.rs:694-782): all indices are against the
    /// immutable `originalLines`; the running `lineIndex` cursor advances in
    /// that same coordinate space.
    private static func computeReplacements(originalLines: [String],
                                            chunks: [UpdateChunk],
                                            path: String) throws -> [(Int, Int, [String])] {
        var replacements: [(Int, Int, [String])] = []
        var lineIndex = 0

        for chunk in chunks {
            // If a chunk has a change_context, seek it then continue from there.
            if let ctx = chunk.changeContext {
                guard let ci = seekSequence(originalLines, [ctx], lineIndex, false) else {
                    // Upstream `lib.rs:714-718` surfaces the offending context line.
                    throw ApplyPatchError.contextMismatch(
                        "Failed to find context '\(ctx)' in \(path)")
                }
                lineIndex = ci + 1
            }

            // Pure addition (no old lines): record an insertion at end of file,
            // before any trailing empty line (lib.rs:722-731).
            if chunk.oldLines.isEmpty {
                let insertionIdx = (originalLines.last == "")
                    ? originalLines.count - 1
                    : originalLines.count
                replacements.append((insertionIdx, 0, chunk.newLines))
                continue
            }

            // Otherwise, locate `old_lines` within the original file. If the
            // verbatim search fails and the pattern ends with an empty string
            // (the terminating-newline sentinel, stripped from originalLines),
            // retry without that final element — and likewise drop the trailing
            // empty from the new slice (lib.rs:745-765).
            var pattern = chunk.oldLines
            var newSlice = chunk.newLines
            var found = seekSequence(originalLines, pattern, lineIndex, chunk.isEndOfFile)

            if found == nil, pattern.last == "" {
                pattern = Array(pattern.dropLast())
                if newSlice.last == "" {
                    newSlice = Array(newSlice.dropLast())
                }
                found = seekSequence(originalLines, pattern, lineIndex, chunk.isEndOfFile)
            }

            guard let startIdx = found else {
                // Upstream `lib.rs:771-775` surfaces the full block of expected
                // (original `old_lines`) so the model can re-author the patch.
                throw ApplyPatchError.contextMismatch(
                    "Failed to find expected lines in \(path):\n"
                        + chunk.oldLines.joined(separator: "\n"))
            }

            replacements.append((startIdx, pattern.count, newSlice))
            lineIndex = startIdx + pattern.count
        }

        replacements.sort { $0.0 < $1.0 }
        return replacements
    }

    /// Apply `(startIndex, oldLen, newSegment)` replacements to `lines` in
    /// descending order so earlier edits don't shift later positions. Mirrors
    /// upstream `apply_replacements` (lib.rs:786-810).
    private static func applyReplacements(_ lines: [String],
                                          _ replacements: [(Int, Int, [String])]) -> [String] {
        var lines = lines
        for (startIdx, oldLen, newSegment) in replacements.reversed() {
            for _ in 0 ..< oldLen where startIdx < lines.count {
                lines.remove(at: startIdx)
            }
            for (offset, newLine) in newSegment.enumerated() {
                lines.insert(newLine, at: startIdx + offset)
            }
        }
        return lines
    }

    // MARK: - Real unified diff (LCS line diff)

    private static func splitForDiff(_ s: String) -> [String] {
        s.isEmpty ? [] : s.components(separatedBy: "\n")
    }

    private static func lcsOps(_ a: [String], _ b: [String]) -> [(Character, String)] {
        let n = a.count, m = b.count
        if n == 0 && m == 0 { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if a[i] == b[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = Swift.max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }
        var out: [(Character, String)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                out.append((" ", a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                out.append(("-", a[i])); i += 1
            } else {
                out.append(("+", b[j])); j += 1
            }
        }
        while i < n { out.append(("-", a[i])); i += 1 }
        while j < m { out.append(("+", b[j])); j += 1 }
        return out
    }

    private static func diffBody(old: String, new: String, context: Int = 3) -> String {
        let a = splitForDiff(old)
        let b = splitForDiff(new)
        if a == b { return "" }

        let ops = lcsOps(a, b)
        let N = ops.count
        if N == 0 { return "" }

        var out = ""
        var idx = 0

        while idx < N {
            while idx < N && ops[idx].0 == " " { idx += 1 }
            if idx >= N { break }

            let changeStart = idx
            var j = idx
            var lastChange = idx
            while j < N {
                if ops[j].0 != " " {
                    lastChange = j
                    j += 1
                } else {
                    var k = j
                    while k < N && ops[k].0 == " " { k += 1 }
                    if k >= N { break }
                    if k - j > 2 * context { break }
                    j = k
                }
            }

            let s = Swift.max(0, changeStart - context)
            let e = Swift.min(N - 1, lastChange + context)

            var oCount = 0, nCount = 0
            for k in s...e {
                if ops[k].0 != "+" { oCount += 1 }
                if ops[k].0 != "-" { nCount += 1 }
            }
            var preO = 0, preN = 0
            if s > 0 {
                for k in 0..<s {
                    if ops[k].0 != "+" { preO += 1 }
                    if ops[k].0 != "-" { preN += 1 }
                }
            }
            let oStart = oCount > 0 ? preO + 1 : preO
            let nStart = nCount > 0 ? preN + 1 : preN

            out += "@@ -\(oStart),\(oCount) +\(nStart),\(nCount) @@\n"
            for k in s...e {
                out += String(ops[k].0) + ops[k].1 + "\n"
            }
            idx = e + 1
        }
        return out
    }

    static func makeUnifiedDiff(old: String, new: String, path: String,
                                movePath: String?,
                                kind: PatchedFile.Kind,
                                context: Int = 3) -> String {
        let minus: String
        let plus: String
        switch kind {
        case .add:
            minus = "/dev/null"; plus = path
        case .delete:
            minus = path; plus = "/dev/null"
        case .update:
            minus = path; plus = movePath ?? path
        }
        return "--- \(minus)\n+++ \(plus)\n" + diffBody(old: old, new: new, context: context)
    }
}