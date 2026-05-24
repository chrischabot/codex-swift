import Foundation

public enum ApplyPatchError: Error, Sendable, Equatable {
    case malformed(String)
    case contextMismatch(String)
    case targetMissing(String)
    case targetExists(String)
    case unsafePath(String)
}

public struct PatchedFile: Sendable, Equatable {
    public enum Kind: String, Sendable { case add, update, delete }
    public var path: String
    public var kind: Kind
    public var movePath: String?
    public var newContents: String?   // nil for delete
    public var unifiedDiff: String

    public init(path: String, kind: Kind, movePath: String? = nil,
                newContents: String?, unifiedDiff: String) {
        self.path = path
        self.kind = kind
        self.movePath = movePath
        self.newContents = newContents
        self.unifiedDiff = unifiedDiff
    }
}

/// Pure parser/applier for the Codex `apply_patch` envelope, ported faithfully
/// from codex-rs `apply-patch` (parser.rs + seek_sequence.rs + lib.rs).
///
/// No instance state — `parse`/`apply` are pure and the type is `Sendable`.
/// Repeated `*** Update File:` sections for the same path are merged (their
/// chunks applied in order against the evolving file). Target paths are
/// validated to stay within `root` (path-traversal + symlink-escape guards).
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

    public func apply(_ patch: String, root: String) throws -> [PatchedFile] {
        let parsed = try parseInternal(patch)
        let fm = FileManager.default
        var applied: [PatchedFile] = []
        for f in parsed.files {
            try Self.validateRelativePath(f.path)
            let full = (root as NSString).appendingPathComponent(f.path)
            try Self.assertContained(root: root, target: full)

            switch f.kind {
            case .add:
                if fm.fileExists(atPath: full) {
                    throw ApplyPatchError.targetExists(f.path)
                }
                try fm.createDirectory(
                    atPath: (full as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                let contents = f.addContents ?? ""
                try contents.write(toFile: full, atomically: true, encoding: .utf8)
                applied.append(PatchedFile(
                    path: f.path, kind: .add, movePath: nil,
                    newContents: contents,
                    unifiedDiff: Self.makeUnifiedDiff(
                        old: "", new: contents, path: f.path,
                        movePath: nil, kind: .add)))

            case .delete:
                guard fm.fileExists(atPath: full) else {
                    throw ApplyPatchError.targetMissing(f.path)
                }
                let original = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
                try fm.removeItem(atPath: full)
                applied.append(PatchedFile(
                    path: f.path, kind: .delete, movePath: nil,
                    newContents: nil,
                    unifiedDiff: Self.makeUnifiedDiff(
                        old: original, new: "", path: f.path,
                        movePath: nil, kind: .delete)))

            case .update:
                guard let original = try? String(contentsOfFile: full, encoding: .utf8) else {
                    throw ApplyPatchError.targetMissing(f.path)
                }
                let updated = try Self.deriveNewContents(
                    original: original, chunks: f.chunks, path: f.path)

                if let move = f.movePath {
                    try Self.validateRelativePath(move)
                    let moveFull = (root as NSString).appendingPathComponent(move)
                    try Self.assertContained(root: root, target: moveFull)
                    if fm.fileExists(atPath: moveFull) {
                        throw ApplyPatchError.targetExists(move)
                    }
                    try fm.createDirectory(
                        atPath: (moveFull as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true)
                    try updated.write(toFile: moveFull, atomically: true, encoding: .utf8)
                    if fm.fileExists(atPath: full) {
                        try fm.removeItem(atPath: full)
                    }
                } else {
                    try updated.write(toFile: full, atomically: true, encoding: .utf8)
                }

                applied.append(PatchedFile(
                    path: f.path, kind: .update, movePath: f.movePath,
                    newContents: updated,
                    unifiedDiff: Self.makeUnifiedDiff(
                        old: original, new: updated, path: f.path,
                        movePath: f.movePath, kind: .update)))
            }
        }
        return applied
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

        func boundariesOK(_ ls: [String]) -> Bool {
            guard let f = ls.first, let l = ls.last else { return false }
            return f.trimmingCharacters(in: .whitespaces) == "*** Begin Patch"
                && l.trimmingCharacters(in: .whitespaces) == "*** End Patch"
        }

        if !boundariesOK(lines) {
            if lines.count >= 4,
               let f = lines.first, let l = lines.last,
               (f == "<<EOF" || f == "<<'EOF'" || f == "<<\"EOF\""),
               l.hasSuffix("EOF") {
                let inner = Array(lines[1..<(lines.count - 1)])
                if boundariesOK(inner) {
                    lines = inner
                } else {
                    throw ApplyPatchError.malformed("invalid patch")
                }
            } else {
                throw ApplyPatchError.malformed(
                    "The first line of the patch must be '*** Begin Patch'")
            }
        }

        let body = Array(lines[1..<(lines.count - 1)])

        var environmentId: String?
        var i = 0

        if i < body.count {
            let raw = body[i]
            let ls = String(raw.drop(while: { $0 == " " || $0 == "\t" }))
            if let rest = Self.afterPrefix(ls, "*** Environment ID:") {
                let id = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                if id.isEmpty { throw ApplyPatchError.malformed("invalid patch") }
                environmentId = id
                i += 1
            }
        }

        var files: [ParsedFile] = []
        var updateIndexByPath: [String: Int] = [:]

        while i < body.count {
            let line = body[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if let path = Self.afterPrefix(trimmed, "*** Add File: ") {
                try Self.validateRelativePath(path)
                i += 1
                var added: [String] = []
                while i < body.count, body[i].hasPrefix("+") {
                    added.append(String(body[i].dropFirst()))
                    i += 1
                }
                // Grammar conceptually appends '\n' per added line; the
                // on-disk Add content joins with '\n' and adds NO forced
                // trailing newline (keeps `line1\nline2` test green).
                let disk = added.joined(separator: "\n")
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
                    let mt = body[i].trimmingCharacters(in: .whitespaces)
                    if let mp = Self.afterPrefix(mt, "*** Move to: ") {
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
                    if raw.hasPrefix("*")
                        || raw.trimmingCharacters(in: .whitespaces).hasPrefix("*** ") { break }
                    let chunk = try Self.parseChunk(
                        body, &i,
                        allowMissingContext: sectionChunks.isEmpty,
                        path: path)
                    sectionChunks.append(chunk)
                }

                if sectionChunks.isEmpty {
                    throw ApplyPatchError.malformed(
                        "Update file hunk for path '\(path)' is empty")
                }

                if let idx = updateIndexByPath[path] {
                    files[idx].chunks.append(contentsOf: sectionChunks)
                    if let mp = movePath { files[idx].movePath = mp }
                } else {
                    updateIndexByPath[path] = files.count
                    files.append(ParsedFile(
                        path: path, kind: .update, movePath: movePath,
                        addContents: nil, chunks: sectionChunks))
                }

            } else {
                throw ApplyPatchError.malformed("unexpected line: \(line)")
            }
        }

        if files.isEmpty {
            throw ApplyPatchError.malformed("patch contains no hunks")
        }

        return ParsedPatch(files: files, environmentId: environmentId)
    }

    private static func parseChunk(_ b: [String], _ i: inout Int,
                                   allowMissingContext: Bool,
                                   path: String) throws -> UpdateChunk {
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
                throw ApplyPatchError.malformed(
                    "Expected update hunk to start with a @@ context marker, got: '\(line)'")
            }
        } else if !allowMissingContext {
            throw ApplyPatchError.malformed(
                "Expected update hunk to start with a @@ context marker, got: ''")
        }

        if i >= b.count {
            throw ApplyPatchError.malformed("Update hunk does not contain any lines")
        }

        var oldLines: [String] = []
        var newLines: [String] = []
        var isEOF = false
        var parsedAny = false

        while i < b.count {
            let line = b[i]
            if line == "*** End of File" {
                if !parsedAny {
                    throw ApplyPatchError.malformed("Update hunk does not contain any lines")
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
                    throw ApplyPatchError.malformed(
                        "Unexpected line found in update hunk: '\(line)'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)")
                }
                break  // start of next hunk — do NOT consume
            }
        }

        return UpdateChunk(changeContext: ctx, oldLines: oldLines,
                           newLines: newLines, isEndOfFile: isEOF)
    }

    // MARK: - seek_sequence.rs

    private static func trimEnd(_ s: String) -> String {
        var v = s.unicodeScalars
        while let last = v.last, CharacterSet.whitespaces.contains(last) {
            v.removeLast()
        }
        return String(v)
    }

    private static func fullTrim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalise(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
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
        var lines = original
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var lineIndex = 0

        for chunk in chunks {
            if let ctx = chunk.changeContext {
                guard let ci = seekSequence(lines, [ctx], lineIndex, false) else {
                    throw ApplyPatchError.contextMismatch("\(path): hunk context not found")
                }
                lineIndex = ci + 1
            }

            let pattern = chunk.oldLines
            var matchLen = pattern.count
            var found = seekSequence(lines, pattern, lineIndex, chunk.isEndOfFile)

            if found == nil, let last = pattern.last, last == "" {
                let p2 = Array(pattern.dropLast())
                if let f2 = seekSequence(lines, p2, lineIndex, chunk.isEndOfFile) {
                    found = f2
                    matchLen = p2.count
                }
            }

            guard let at = found else {
                throw ApplyPatchError.contextMismatch("\(path): hunk context not found")
            }

            lines.replaceSubrange(at ..< (at + matchLen), with: chunk.newLines)
            lineIndex = at + chunk.newLines.count
        }

        return lines.joined(separator: "\n")
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

    private static func diffBody(old: String, new: String) -> String {
        let a = splitForDiff(old)
        let b = splitForDiff(new)
        if a == b { return "" }

        let ops = lcsOps(a, b)
        let N = ops.count
        if N == 0 { return "" }

        let context = 3
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
                                kind: PatchedFile.Kind) -> String {
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
        return "--- \(minus)\n+++ \(plus)\n" + diffBody(old: old, new: new)
    }
}