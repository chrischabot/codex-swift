import Foundation
import InfraPrimitives
import Sandbox
#if canImport(Darwin)
import Darwin
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Reject absolute paths, `..` traversal, and empty/escaping paths. The tool
/// surface is workspace-relative; the kernel sandbox is an additional, not
/// the only, boundary (defense in depth, Codex parity).
enum ToolPath {
    static func resolve(_ rel: String, under root: String) throws -> String {
        if rel.hasPrefix("/") { throw ToolError(message: "absolute path not allowed: \(rel)") }
        let comps = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.contains("..") { throw ToolError(message: "path traversal not allowed: \(rel)") }
        let trimmed = rel.trimmingCharacters(in: .whitespaces)
        let full = trimmed.isEmpty
            ? (root as NSString).standardizingPath
            : ((root as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
        let r = (root as NSString).standardizingPath
        guard full == r || full.hasPrefix(r.hasSuffix("/") ? r : r + "/") else {
            throw ToolError(message: "path escapes workspace: \(rel)")
        }
        try assertContained(root: root, target: full)
        return full
    }

    /// Realpath containment for symlink defense-in-depth. Lexical checks stop
    /// `..`; this catches symlinked roots, intermediates, and target files.
    ///
    /// When `target` already exists we resolve it directly and require its
    /// canonical path to be the root or under it. When `target` does NOT
    /// exist (e.g. a new file we're about to create) we walk up to the
    /// deepest existing ancestor and check that — but never above the root
    /// itself, since the root's parent is by definition outside the
    /// workspace (this is what caused `list_dir(".")` to trip the check when
    /// the workspace lived under a symlinked path like `/var/folders/...`).
    static func assertContained(root: String, target: String) throws {
        let fm = FileManager.default
        func resolve(_ p: String) -> String {
            URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let realRoot = resolve(root)
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        func requireWithin(_ resolved: String) throws {
            if resolved != realRoot && !resolved.hasPrefix(prefix) {
                throw ToolError(message: "path escapes workspace through symlink")
            }
        }
        if fm.fileExists(atPath: target) {
            try requireWithin(resolve(target))
            return
        }
        // Target does not exist — walk up to find the deepest existing
        // ancestor. Stop at the workspace root: if the deepest existing
        // ancestor IS the root, that's fine; we must not walk into the
        // root's parent and then declare it "escapes workspace".
        var dir = ((target as NSString).standardizingPath as NSString)
            .deletingLastPathComponent
        while !dir.isEmpty && dir != "/" && !fm.fileExists(atPath: dir) {
            dir = (dir as NSString).deletingLastPathComponent
        }
        let resolvedDir = resolve(dir.isEmpty ? "/" : dir)
        if resolvedDir == realRoot || resolvedDir.hasPrefix(prefix) {
            return
        }
        // The deepest existing ancestor sits outside the workspace, meaning
        // the workspace root itself does not yet exist on disk. That's the
        // session bind's responsibility, not the tool's; surface the same
        // error so the caller (apply_patch/write_file) can report cleanly.
        throw ToolError(message: "path escapes workspace through symlink")
    }
}

/// `file_search` — fuzzy filename search rooted at cwd (Codex `file-search`).
/// Case-insensitive subsequence match with contiguity/substring/word-boundary/
/// basename scoring. Traversal is bounded and skips heavy build/VCS dirs so a
/// huge tree cannot exhaust memory or time.
///
/// Implementation note: walks via `FileManager.enumerator(at:URL, …)` so APFS
/// can batch metadata through `getattrlistbulk` — one syscall per page of
/// entries instead of two (`readdir` + `lstat`) per entry. We do one realpath
/// containment check on the workspace root before walking and rely on the
/// kernel/`.skipsPackageDescendants` to enforce that — every entry yielded by
/// the enumerator is guaranteed to live under that real root (we never follow
/// directory symlinks: `.skipsSubdirectoryDescendants` is off but
/// `FileManager` does not traverse symlinks by default for `enumerator(at:)`),
/// so we drop the per-entry `assertContained` (which hit `realpath` 20k
/// times on a 20k-entry tree). Cancellation is honoured every iteration.
public struct FileSearchTool: Tool {
    public let name = "file_search"
    public let parallelSafe = true
    public var toolDescription: String {
        "Fuzzy-search filenames under the workspace. Returns ranked relative paths."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"],"additionalProperties":false}"#
    }
    private let maxEntries: Int
    private let defaultLimit: Int
    public init(maxEntries: Int = 20_000, defaultLimit: Int = 50) {
        self.maxEntries = maxEntries
        self.defaultLimit = defaultLimit
    }

    private struct Args: Decodable { var query: String; var limit: Int? }
    private static let skipDirs: Set<String> = [
        ".git", ".build", "node_modules", ".swiftpm", "DerivedData",
        ".venv", "venv", "__pycache__", ".mypy_cache", "target", "dist",
    ]

    private static func isSubsequence(_ q: [Character], _ s: [Character]) -> Bool {
        if q.isEmpty { return true }
        var qi = 0
        for c in s where qi < q.count && c == q[qi] { qi += 1 }
        return qi == q.count
    }

    private static func isWordBoundary(_ chars: [Character], _ i: Int) -> Bool {
        if i == 0 { return true }
        let prev = chars[i - 1]
        if prev == "/" || prev == "_" || prev == "-" || prev == "." { return true }
        let cur = chars[i]
        if prev.isLowercase && cur.isUppercase { return true }
        return false
    }

    /// Require all query chars as an in-order, case-insensitive subsequence of
    /// the full path (else `nil`). Then add bonuses:
    /// +1000 contiguous substring of basename, +400 contiguous substring of
    /// path, +200 occurrence at a word boundary, +80 basename subsequence,
    /// minus path length (shorter-path tiebreak).
    ///
    /// Hot path: each candidate hits this function once. We compute the
    /// lowercase character array exactly once per candidate (instead of three
    /// times: once for the subsequence test, once for the substring test,
    /// once for the basename test).
    static func score(_ query: String, _ path: String) -> Int? {
        if query.isEmpty { return 0 }
        let chars = Array(path)
        let lower: [Character] = path.lowercased().map { $0 }
        let ql: [Character] = query.lowercased().map { $0 }

        guard isSubsequence(ql, lower) else { return nil }

        var score = 0

        let basenameStart: Int = {
            if let slash = path.lastIndex(of: "/") {
                return path.distance(from: path.startIndex, to: path.index(after: slash))
            }
            return 0
        }()

        // Substring tests: avoid building a `String` round-trip by scanning
        // the cached lowercase character array.
        if !ql.isEmpty {
            let inBase = containsSubsequence(haystack: lower,
                                              start: basenameStart,
                                              needle: ql)
            if inBase {
                score += 1000
            } else if containsSubsequence(haystack: lower, start: 0, needle: ql) {
                score += 400
            }
        }

        // Word-boundary occurrence of the query in the original-cased path.
        if !ql.isEmpty {
            let qn = ql.count
            var wb = false
            if qn <= lower.count {
                var i = 0
                while i + qn <= lower.count {
                    var match = true
                    var k = 0
                    while k < qn {
                        if lower[i + k] != ql[k] { match = false; break }
                        k += 1
                    }
                    if match && isWordBoundary(chars, i) { wb = true; break }
                    i += 1
                }
            }
            if wb { score += 200 }
        }

        if isSubsequence(ql, Array(lower[basenameStart...])) { score += 80 }

        score -= path.count
        return score
    }

    /// Substring scan over a `[Character]` slice from a start index — avoids
    /// the `String.contains(String)` round-trip and its UTF-16/grapheme
    /// machinery (we already canonicalised to lowercase ASCII-ish characters
    /// for ranking; lossy on locales that's parity with the original).
    private static func containsSubsequence(haystack: [Character],
                                            start: Int,
                                            needle: [Character]) -> Bool {
        let n = haystack.count - start
        let m = needle.count
        if m == 0 { return true }
        if m > n { return false }
        var i = 0
        while i + m <= n {
            var k = 0
            while k < m && haystack[start + i + k] == needle[k] { k += 1 }
            if k == m { return true }
            i += 1
        }
        return false
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8),
              let a = try? JSONDecoder().decode(Args.self, from: d) else {
            return ToolResult(callId: call.callId, output: "invalid file_search arguments",
                              success: false, truncated: false)
        }
        let limit = max(1, min(a.limit ?? defaultLimit, 500))
        let rootStd = (cwd as NSString).standardizingPath
        let realRoot = URL(fileURLWithPath: rootStd)
            .resolvingSymlinksInPath().standardizedFileURL.path
        // Single up-front containment check; the enumerator never follows
        // directory symlinks for `enumerator(at:)`, so every entry it yields
        // lives under `rootStd` and (by realpath) under `realRoot`.
        do { try ToolPath.assertContained(root: realRoot, target: rootStd) }
        catch let e as ToolError {
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "\(error)",
                              success: false, truncated: false)
        }

        let rootURL = URL(fileURLWithPath: rootStd, isDirectory: true)
        // Prefetch `isDirectoryKey` so the enumerator drives a single
        // batched `getattrlistbulk` per page on APFS and so `url.hasDirectoryPath`
        // returns the kernel-known value (no extra `stat`).
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }   // best-effort — denied dirs surface as warnings
        ) else {
            return ToolResult(callId: call.callId,
                              output: "(no matches)",
                              success: true, truncated: false)
        }

        var results: [(path: String, score: Int)] = []
        var visited = 0
        let rootPrefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"

        while let any = enumerator.nextObject() {
            // Cancellation: cheap per-iteration check. With `Task.isCancelled`
            // observable in <50ms even on multi-million-entry walks.
            try Task.checkCancellation()
            if visited >= maxEntries { break }
            guard let url = any as? URL else { continue }
            visited += 1

            // `URL.hasDirectoryPath` is populated from the prefetched
            // metadata — no extra syscall. We avoid `resourceValues(...)`
            // entirely (which would allocate a `URLResourceValues` snapshot
            // per entry, ~25% of the walk time on a 50k tree).
            if url.hasDirectoryPath {
                let name = url.lastPathComponent
                if Self.skipDirs.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            // The enumerator yields URLs rooted at `rootURL`; `url.path`
            // is already absolute and under the root. We skip
            // `standardizedFileURL` (allocates a fresh URL) — the path
            // strings the enumerator returns are already canonical for
            // our purposes (no `..`, no double slashes). One up-front
            // realpath check on the root caught any symlinked workspace
            // root, and `enumerator(at:)` does not follow directory
            // symlinks by default, so every entry below is guaranteed
            // to live under the same on-disk root.
            let abs = url.path
            guard abs == rootStd || abs.hasPrefix(rootPrefix) else { continue }
            let rel = String(abs.dropFirst(rootStd.count).drop(while: { $0 == "/" }))
            if let s = Self.score(a.query, rel) {
                results.append((rel, s))
            }
        }

        results.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        let top = results.prefix(limit).map { $0.path }
        return ToolResult(callId: call.callId,
                          output: top.isEmpty ? "(no matches)" : top.joined(separator: "\n"),
                          success: true, truncated: false)
    }
}

/// `read_file` — read a workspace-relative text file with optional 1-based
/// line offset/limit. Output is head/tail bounded (Codex `file-system`).
///
/// Three code paths:
///   1. Whole-file read of a small file → `FileManager.contents(atPath:)`.
///   2. Whole-file read of a >1 MB file → mmap (`Data(contentsOf:options:.mappedIfSafe)`).
///   3. offset/limit OR file >1 MB → `FileHandle` async byte stream, decoded
///      line by line with early termination after `limit` lines. This keeps
///      peak RSS to a single line plus the truncation window even on a
///      500 MB file with `offset=1, limit=10`.
///
/// Refuses binary files via `UTType` (no `public.text` conformance) so that
/// the model isn't shown garbled bytes.
public struct ReadFileTool: Tool {
    public let name = "read_file"
    public let parallelSafe = true
    public var toolDescription: String {
        "Read a workspace-relative text file. Optional 1-based line offset/limit."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"],"additionalProperties":false}"#
    }
    private let maxBytes: Int
    /// Above this size we always stream; below we read the whole file in one
    /// shot (faster for tiny files where syscall overhead dominates).
    private static let streamingThreshold = 1 * 1024 * 1024
    public init(limits: Limits = Limits()) {
        self.maxBytes = limits.clamped().maxToolOutputBytes
    }
    private struct Args: Decodable { var path: String; var offset: Int?; var limit: Int? }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8),
              let a = try? JSONDecoder().decode(Args.self, from: d) else {
            return ToolResult(callId: call.callId, output: "invalid read_file arguments",
                              success: false, truncated: false)
        }
        let full: String
        do { full = try ToolPath.resolve(a.path, under: cwd) }
        catch let e as ToolError {
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        }
        let url = URL(fileURLWithPath: full)
        let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey,
                                                     .isDirectoryKey, .typeIdentifierKey])
        if vals == nil || vals?.isRegularFile != true {
            // Distinguish "missing" from "not a file" with the same message
            // the old code used so callers/tests keep working.
            return ToolResult(callId: call.callId, output: "file not found: \(a.path)",
                              success: false, truncated: false)
        }
        let size = vals?.fileSize ?? 0

        // Binary detection: refuse to read non-text files. We accept files
        // whose UTType conforms to `public.text` OR whose UTType is unknown
        // (extensionless source/config files commonly fall here, and we
        // don't want to false-positive them). We refuse anything that
        // explicitly conforms to a binary type.
        #if canImport(UniformTypeIdentifiers)
        if #available(macOS 11.0, *), let tid = vals?.typeIdentifier,
           let t = UTType(tid) {
            let isText = t.conforms(to: .text) || t.conforms(to: .sourceCode)
                || t.conforms(to: .plainText) || t.conforms(to: .json)
                || t.conforms(to: .xml) || t.conforms(to: .yaml)
                || t.conforms(to: .propertyList) || t.conforms(to: .script)
            let isData = t.conforms(to: .data) && !isText
            // `public.data` is the root of binary types; explicit conformance
            // to `public.image`, `public.movie`, etc. all flow through there.
            // We only refuse when (a) it's a known type, (b) explicitly
            // non-text. Sniff bytes for the unknown/no-extension case below.
            if isData && !isText {
                return ToolResult(callId: call.callId,
                                  output: "binary file refused: \(a.path) (UTI \(tid))",
                                  success: false, truncated: false)
            }
        }
        #endif

        let useStream = (a.offset != nil) || (a.limit != nil) || size > Self.streamingThreshold

        if !useStream {
            // Fast path — whole small file.
            guard let data = FileManager.default.contents(atPath: full) else {
                return ToolResult(callId: call.callId, output: "file not found: \(a.path)",
                                  success: false, truncated: false)
            }
            if Self.looksBinary(data.prefix(4096)) {
                return ToolResult(callId: call.callId,
                                  output: "binary file refused: \(a.path) (NUL bytes detected)",
                                  success: false, truncated: false)
            }
            let text = String(decoding: data, as: UTF8.self)
            var ring = HeadTailBuffer(maxBytes: maxBytes)
            ring.append(text)
            return ToolResult(callId: call.callId, output: ring.rendered(),
                              success: true, truncated: ring.didTruncate)
        }

        // Streaming path. Open with `O_NOFOLLOW` so a symlink swapped in
        // mid-flight cannot redirect us outside the workspace.
        let fd: Int32 = full.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 {
            let err = errno
            // ELOOP means a symlink — surface a clean error.
            let msg = err == ELOOP
                ? "symlink read refused: \(a.path)"
                : "file not found: \(a.path)"
            return ToolResult(callId: call.callId, output: msg,
                              success: false, truncated: false)
        }
        defer { close(fd) }

        // Sniff the first 4 KB for binary content (NUL byte).
        var sniff = [UInt8](repeating: 0, count: 4096)
        let n = sniff.withUnsafeMutableBytes { buf -> Int in
            #if canImport(Darwin)
            return Darwin.read(fd, buf.baseAddress, buf.count)
            #else
            return Glibc.read(fd, buf.baseAddress, buf.count)
            #endif
        }
        if n > 0, Self.looksBinary(Data(sniff.prefix(n))) {
            return ToolResult(callId: call.callId,
                              output: "binary file refused: \(a.path) (NUL bytes detected)",
                              success: false, truncated: false)
        }
        // Rewind for the actual streaming read.
        _ = lseek(fd, 0, SEEK_SET)

        let startLine = max(0, (a.offset ?? 1) - 1)
        let maxLines = a.limit.map { max(0, $0) } ?? Int.max

        // Line-buffered streaming. We pull 64 KB chunks and split on '\n',
        // emitting completed lines into the ring buffer until we hit the
        // window's end. Memory: one chunk (64 KB) + the partial-line tail.
        let chunkSize = 64 * 1024
        var ring = HeadTailBuffer(maxBytes: maxBytes)
        var emitted = 0
        var lineIdx = 0
        var tail = Data()
        var firstEmit = true
        var done = false
        var buf = [UInt8](repeating: 0, count: chunkSize)

        outer: while !done {
            try Task.checkCancellation()
            let r = buf.withUnsafeMutableBytes { p -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, p.baseAddress, p.count)
                #else
                return Glibc.read(fd, p.baseAddress, p.count)
                #endif
            }
            if r <= 0 { break }
            var start = 0
            for i in 0..<r {
                if buf[i] == 0x0A {  // '\n'
                    let lineBytes: Data
                    if tail.isEmpty {
                        lineBytes = Data(buf[start..<i])
                    } else {
                        var d = tail
                        d.append(contentsOf: buf[start..<i])
                        tail = Data()
                        lineBytes = d
                    }
                    if lineIdx >= startLine {
                        if emitted >= maxLines { done = true; break outer }
                        let s = String(decoding: lineBytes, as: UTF8.self)
                        if firstEmit { firstEmit = false } else { ring.append("\n") }
                        ring.append(s)
                        emitted += 1
                    }
                    lineIdx += 1
                    start = i + 1
                }
            }
            if start < r {
                tail.append(contentsOf: buf[start..<r])
                // Cap tail to avoid pathological lines exhausting memory.
                if tail.count > 16 * 1024 * 1024 {
                    // 16 MB single line — treat as binary-ish; bail out.
                    return ToolResult(callId: call.callId,
                                      output: "line too long: \(a.path)",
                                      success: false, truncated: true)
                }
            }
        }
        // Trailing partial line (no terminating '\n').
        if !tail.isEmpty && !done {
            if lineIdx >= startLine && emitted < maxLines {
                let s = String(decoding: tail, as: UTF8.self)
                if firstEmit { firstEmit = false } else { ring.append("\n") }
                ring.append(s)
            }
        }
        return ToolResult(callId: call.callId, output: ring.rendered(),
                          success: true, truncated: ring.didTruncate)
    }

    /// Treat any NUL byte in the first 4 KB as a binary indicator. Same
    /// heuristic git uses (cat-file/diff). False-negatives on UTF-16 files
    /// are fine — UTType already caught the common ones.
    private static func looksBinary(_ data: Data) -> Bool {
        for b in data where b == 0 { return true }
        return false
    }
}

/// `write_file` — create/overwrite a workspace-relative file. Serial (mutates)
/// and gated by the sandbox write policy (Codex `file-system` write path).
///
/// Overwrite behaviour: when the target already exists we preserve extended
/// attributes (notably `com.apple.quarantine`, Finder tags, ACLs) by
/// `copyfile(3)`-ing the metadata from the OLD file onto the temp file
/// before the atomic rename. The temp file is opened with `O_NOFOLLOW` so a
/// symlink races can't redirect the write.
public struct WriteFileTool: Tool {
    public let name = "write_file"
    public let parallelSafe = false
    public var toolDescription: String {
        "Create or overwrite a workspace-relative text file."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#
    }
    private let sandbox: any Sandbox
    public init(sandbox: any Sandbox) { self.sandbox = sandbox }
    private struct Args: Decodable { var path: String; var content: String }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8),
              let a = try? JSONDecoder().decode(Args.self, from: d) else {
            return ToolResult(callId: call.callId, output: "invalid write_file arguments",
                              success: false, truncated: false)
        }
        let full: String
        do { full = try ToolPath.resolve(a.path, under: cwd) }
        catch let e as ToolError {
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        }
        let decision = sandbox.evaluateWrite(path: full)
        if decision.outcome == .deny {
            return ToolResult(callId: call.callId,
                              output: "sandbox denied write: \(decision.reason)",
                              success: false, truncated: false)
        }
        do {
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            let bytes = a.content.utf8.count
            try Self.atomicWritePreservingMetadata(path: full,
                                                   content: a.content)
            return ToolResult(callId: call.callId,
                              output: "wrote \(bytes) bytes to \(a.path)",
                              success: true, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "write failed: \(error)",
                              success: false, truncated: false)
        }
    }

    /// Atomic write that preserves xattrs and ACLs on overwrite. Strategy:
    ///   1. Write content to `<path>.codex-write-<uuid>` opened with
    ///      `O_NOFOLLOW | O_CREAT | O_EXCL | O_WRONLY` — refuses to follow
    ///      a symlink the attacker may have planted at the temp path.
    ///   2. If the destination exists, `copyfile(3)` xattrs+ACL from old
    ///      onto temp (`COPYFILE_XATTR | COPYFILE_ACL`).
    ///   3. `rename(2)` temp over destination — atomic on the same FS.
    static func atomicWritePreservingMetadata(path: String, content: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let tmpName = ".\(base).codex-write-\(UUID().uuidString)"
        let tmpPath = (dir as NSString).appendingPathComponent(tmpName)

        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let mode: mode_t = 0o644
        let fd: Int32 = tmpPath.withCString { open($0, flags, mode) }
        if fd < 0 {
            let e = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "open temp failed: \(String(cString: strerror(e)))"])
        }
        var closed = false
        defer {
            if !closed { close(fd) }
            // Remove temp if rename failed.
            unlink(tmpPath)
        }

        // Write the content.
        var remaining = Array(content.utf8)
        var off = 0
        while off < remaining.count {
            let r = remaining.withUnsafeBytes { p -> Int in
                #if canImport(Darwin)
                return Darwin.write(fd, p.baseAddress!.advanced(by: off),
                                    remaining.count - off)
                #else
                return Glibc.write(fd, p.baseAddress!.advanced(by: off),
                                   remaining.count - off)
                #endif
            }
            if r < 0 {
                let e = errno
                if e == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(e),
                              userInfo: [NSLocalizedDescriptionKey:
                                            "write temp failed: \(String(cString: strerror(e)))"])
            }
            off += r
        }

        // Make sure bytes are on disk before rename.
        #if canImport(Darwin)
        _ = fsync(fd)
        #endif
        close(fd); closed = true

        // If destination exists, carry over xattrs + ACLs.
        if FileManager.default.fileExists(atPath: path) {
            #if canImport(Darwin)
            let copyFlags = copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)
            // `copyfile` from old onto temp. Errors here are non-fatal —
            // the data write succeeded; metadata loss is degraded but
            // not catastrophic. We *do* log to stderr in debug builds.
            let rc = path.withCString { src in
                tmpPath.withCString { dst in
                    copyfile(src, dst, nil, copyFlags)
                }
            }
            if rc != 0 {
                #if DEBUG
                FileHandle.standardError.write(Data(
                    "[write_file] copyfile(xattr|acl) failed: \(String(cString: strerror(errno)))\n".utf8))
                #endif
            }
            #endif
        }

        // Atomic rename. After this, defer's `unlink` is a no-op.
        let rc = tmpPath.withCString { src in
            path.withCString { dst in rename(src, dst) }
        }
        if rc != 0 {
            let e = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e),
                          userInfo: [NSLocalizedDescriptionKey:
                                        "rename failed: \(String(cString: strerror(e)))"])
        }
    }
}

/// `list_dir` — list a workspace-relative directory (name + kind).
///
/// Uses `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)` so
/// the kernel batches the `isDirectoryKey` metadata into the directory read
/// (one `getattrlistbulk` syscall per page on APFS) instead of one extra
/// `stat` per entry.
public struct ListDirTool: Tool {
    public let name = "list_dir"
    public let parallelSafe = true
    public var toolDescription: String { "List a workspace-relative directory." }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"path":{"type":"string"}},"additionalProperties":false}"#
    }
    public init() {}
    private struct Args: Decodable { var path: String? }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        let a = (call.argumentsJSON.data(using: .utf8)).flatMap {
            try? JSONDecoder().decode(Args.self, from: $0)
        } ?? Args(path: nil)
        let full: String
        do { full = try ToolPath.resolve(a.path ?? "", under: cwd) }
        catch let e as ToolError {
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        }
        let url = URL(fileURLWithPath: full, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [])
        } catch {
            return ToolResult(callId: call.callId,
                              output: "not a directory: \(a.path ?? ".")",
                              success: false, truncated: false)
        }
        // Use the prefetched `hasDirectoryPath` rather than a per-entry
        // `resourceValues(forKeys:)` call (which allocates a snapshot
        // struct per entry).
        let lines: [String] = entries
            .map { (u: URL) -> (name: String, isDir: Bool) in
                (u.lastPathComponent, u.hasDirectoryPath)
            }
            .sorted { $0.name < $1.name }
            .map { $0.isDir ? "\($0.name)/" : $0.name }
        return ToolResult(callId: call.callId,
                          output: lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"),
                          success: true, truncated: false)
    }
}

/// Pluggable web-search backend (Codex `web_search` is provider-backed). The
/// default is disabled so the tool is advertised + wired but deterministic
/// offline; a real backend is injected where a provider is configured.
public protocol WebSearchBackend: Sendable {
    var requiredHosts: [String] { get }
    func search(_ query: String) async -> Result<String, ToolError>
}

public extension WebSearchBackend {
    var requiredHosts: [String] { [] }
}

public struct DisabledWebSearch: WebSearchBackend {
    public init() {}
    public func search(_ query: String) async -> Result<String, ToolError> {
        .failure(ToolError(message: "web_search is not configured for this session"))
    }
}

public struct WebSearchTool: Tool {
    public let name = "web_search"
    public let parallelSafe = true
    public var toolDescription: String {
        "Search the web. Returns ranked result snippets when a provider is configured."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#
    }
    private let backend: any WebSearchBackend
    private let sandbox: (any Sandbox)?
    public init(backend: any WebSearchBackend = DisabledWebSearch(),
                sandbox: (any Sandbox)? = nil) {
        self.backend = backend
        self.sandbox = sandbox
    }
    private struct Args: Decodable { var query: String }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        guard let d = call.argumentsJSON.data(using: .utf8),
              let a = try? JSONDecoder().decode(Args.self, from: d) else {
            return ToolResult(callId: call.callId, output: "invalid web_search arguments",
                              success: false, truncated: false)
        }
        if let sandbox {
            for host in backend.requiredHosts {
                if let decision = sandbox.evaluateNetworkDomainRule(host: host),
                   decision.outcome == .deny {
                    return ToolResult(callId: call.callId,
                                      output: "web_search blocked: \(host) \(decision.reason)",
                                      success: false, truncated: false)
                }
            }
        }
        switch await backend.search(a.query) {
        case .success(let text):
            return ToolResult(callId: call.callId, output: text,
                              success: true, truncated: false)
        case .failure(let e):
            return ToolResult(callId: call.callId, output: e.message,
                              success: false, truncated: false)
        }
    }
}
