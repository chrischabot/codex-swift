import Foundation
import CryptoKit
import InfraPrimitives

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors surfaced by the git plumbing layer. Callers generally degrade
/// gracefully (nil/empty) rather than propagate these.
public enum GitError: Error, Sendable, Equatable {
    case notARepo
    case gitFailed(String)
    case timeout
}

/// Captured result of a single `git` invocation.
public struct GitResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool
    public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
        self.stdout = stdout; self.stderr = stderr
        self.exitCode = exitCode; self.timedOut = timedOut
    }
}

/// Holds the Process + its three pipes across the timeout Task and the
/// async drain logic without tripping Swift 6 Sendable checks (the underlying
/// Foundation types are not Sendable but our access is disciplined).
private final class GitProcBox: @unchecked Sendable {
    let process: Process
    let out: Pipe
    let err: Pipe
    let inp: Pipe
    init(process: Process, out: Pipe, err: Pipe, inp: Pipe) {
        self.process = process; self.out = out; self.err = err; self.inp = inp
    }
}

/// Single-resume bridge between async drains, the timeout Task, and the
/// awaiting continuation. NSLock-guarded so the first resume wins; later
/// resumes are no-ops (never trap).
private final class GitResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<GitResult, Never>?
    private var done = false
    func set(_ c: CheckedContinuation<GitResult, Never>) {
        lock.lock(); cont = c; lock.unlock()
    }
    func resume(_ r: GitResult) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: r)
    }
}

/// Thread-safe accumulator for `DispatchIO`-streamed pipe data. Bounded to
/// `maxBytes`; extra bytes are dropped at the tail.
private final class BoundedSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maxBytes: Int
    init(maxBytes: Int) { self.maxBytes = maxBytes }
    func append(_ chunk: DispatchData) {
        lock.lock(); defer { lock.unlock() }
        let remaining = maxBytes - data.count
        if remaining <= 0 { return }
        if chunk.count <= remaining {
            chunk.enumerateBytes { region, _, _ in
                data.append(contentsOf: region)
            }
        } else {
            // Truncate.
            let prefix = chunk.subdata(in: 0..<remaining)
            prefix.enumerateBytes { region, _, _ in
                data.append(contentsOf: region)
            }
        }
    }
    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Spawns `git` via `/usr/bin/env`, drains stdout+stderr concurrently via
/// `DispatchIO` so neither pipe can deadlock the other, and arms a timeout
/// Task that force-reaps the descendant tree on overrun. Output is bound to
/// 1 MiB per stream. Never traps on hostile output.
public enum GitRunner {

    /// Read-only git invocations that should be insulated from a concurrent
    /// IDE's index/lock activity. The flags here go BEFORE the subcommand
    /// (they're `git`-level, not subcommand-level).
    private static let readOnlyPrefix: [String] = [
        "-c", "core.fsmonitor=false",
        "--no-optional-locks",
    ]

    private static let readOnlyVerbs: Set<String> = [
        "diff", "ls-files", "ls-tree", "show", "rev-parse", "status",
        "merge-base", "symbolic-ref", "remote", "cat-file",
    ]

    /// Inject read-only safety flags (`--no-optional-locks` and
    /// `core.fsmonitor=false`) for read-only verbs so a parallel IDE's git
    /// activity doesn't race our index reads. We only apply them when the
    /// first non-`-c` argument is a recognised read-only verb (so write paths
    /// like `add`/`commit-tree` are untouched, and a caller-supplied `-c`
    /// already at the front is preserved).
    private static func decorate(_ args: [String]) -> [String] {
        guard let verb = firstSubcommand(args), readOnlyVerbs.contains(verb) else {
            return args
        }
        return readOnlyPrefix + args
    }

    private static func firstSubcommand(_ args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-c" { i += 2; continue }
            if a.hasPrefix("-") { i += 1; continue }
            return a
        }
        return nil
    }

    static func run(_ args: [String],
                    cwd: String,
                    env extra: [String: String] = [:],
                    timeout: Duration = .seconds(30)) async -> GitResult {
        let decorated = decorate(args)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + decorated
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in extra { environment[k] = v }
        proc.environment = environment

        let outPipe = Pipe(); let errPipe = Pipe(); let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        do {
            try proc.run()
        } catch {
            return GitResult(stdout: "",
                             stderr: "failed to spawn git: \(error)",
                             exitCode: -1, timedOut: false)
        }
        // We never write to git's stdin; close it so commands that might read
        // (rare) see EOF instead of hanging.
        try? inPipe.fileHandleForWriting.close()

        let box = GitProcBox(process: proc, out: outPipe, err: errPipe, inp: inPipe)
        let resumer = GitResumer()

        return await withCheckedContinuation { (cont: CheckedContinuation<GitResult, Never>) in
            resumer.set(cont)

            let maxBytes = 1024 * 1024
            let outSink = BoundedSink(maxBytes: maxBytes)
            let errSink = BoundedSink(maxBytes: maxBytes)

            let queue = DispatchQueue(label: "git-runner.io",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

            // We need to wait for BOTH pipes to hit EOF AND the process to
            // exit before resuming. `pending` starts at 3 (out, err, exit);
            // each completion decrements and the last one resumes.
            let pendingLock = NSLock()
            nonisolated(unsafe) var pending = 3
            let decrementAndMaybeResume: @Sendable () -> Void = {
                pendingLock.lock()
                pending -= 1
                let done = pending == 0
                pendingLock.unlock()
                if done {
                    let code = box.process.terminationStatus
                    resumer.resume(GitResult(stdout: outSink.snapshot(),
                                             stderr: errSink.snapshot(),
                                             exitCode: code,
                                             timedOut: false))
                }
            }

            // Drain stdout via DispatchIO.
            let outFD = dup(box.out.fileHandleForReading.fileDescriptor)
            let outIO = DispatchIO(type: .stream, fileDescriptor: outFD,
                                   queue: queue) { _ in
                close(outFD)
            }
            outIO.setLimit(lowWater: 1)
            outIO.read(offset: 0, length: .max, queue: queue) { done, data, _ in
                if let data, !data.isEmpty { outSink.append(data) }
                if done { outIO.close(); decrementAndMaybeResume() }
            }

            // Drain stderr via DispatchIO.
            let errFD = dup(box.err.fileHandleForReading.fileDescriptor)
            let errIO = DispatchIO(type: .stream, fileDescriptor: errFD,
                                   queue: queue) { _ in
                close(errFD)
            }
            errIO.setLimit(lowWater: 1)
            errIO.read(offset: 0, length: .max, queue: queue) { done, data, _ in
                if let data, !data.isEmpty { errSink.append(data) }
                if done { errIO.close(); decrementAndMaybeResume() }
            }

            // Wait for the process to exit on a background queue.
            box.process.terminationHandler = { _ in
                // Close our copies of the pipe read-ends so the DispatchIO
                // readers see EOF if they haven't already.
                try? box.out.fileHandleForReading.close()
                try? box.err.fileHandleForReading.close()
                decrementAndMaybeResume()
            }

            // Timeout: reap, then let the DispatchIO/termination path finish.
            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                if Task.isCancelled { return }
                if box.process.isRunning {
                    reapProcessTree(box.process.processIdentifier)
                    box.process.terminate()
                }
                // Resume early with a synthetic timeout result — the
                // DispatchIO/termination handlers will still fire but
                // resumer.resume is idempotent.
                resumer.resume(GitResult(stdout: "",
                                         stderr: "git timed out",
                                         exitCode: -1, timedOut: true))
            }
            _ = timeoutTask  // keep alive until parent continuation resumes
        }
    }
}

/// Actor wrapper over the git plumbing the agent needs (codex `git-utils`).
public actor GitUtils {
    public let cwd: String
    public init(cwd: String) { self.cwd = cwd }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHex40(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy { $0.isHexDigit }
    }

    public func isGitRepo() async -> Bool {
        let r = await GitRunner.run(["rev-parse", "--is-inside-work-tree"], cwd: cwd)
        return r.exitCode == 0 && Self.trim(r.stdout) == "true"
    }

    public func repoRoot() async -> String? {
        let r = await GitRunner.run(["rev-parse", "--show-toplevel"], cwd: cwd)
        guard r.exitCode == 0 else { return nil }
        let t = Self.trim(r.stdout)
        return t.isEmpty ? nil : t
    }

    public func currentBranch() async -> String? {
        let r = await GitRunner.run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
        guard r.exitCode == 0 else { return nil }
        let t = Self.trim(r.stdout)
        if t.isEmpty || t == "HEAD" { return nil }   // detached HEAD
        return t
    }

    public func headSha() async -> String? {
        let r = await GitRunner.run(["rev-parse", "HEAD"], cwd: cwd)
        guard r.exitCode == 0 else { return nil }
        let t = Self.trim(r.stdout)
        return Self.isHex40(t) ? t : nil
    }

    public func remoteURLs() async -> [String] {
        let r = await GitRunner.run(["remote", "-v"], cwd: cwd)
        guard r.exitCode == 0 else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for line in r.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            // Format: name<TAB>url (fetch|push)
            let s = String(line)
            guard s.hasSuffix("(fetch)") else { continue }
            let parts = s.split(whereSeparator: { $0 == "\t" || $0 == " " })
                .map(String.init)
            guard parts.count >= 2 else { continue }
            let url = parts[1]
            if seen.insert(url).inserted { ordered.append(url) }
        }
        return ordered
    }

    /// `^[^@/]+@([^:/]+):(.+)$`. Compiled once, reused across calls.
    private static let scpRegex: NSRegularExpression = {
        // The literal is well-formed; force-try is fine here.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "^[^@/]+@([^:/]+):(.+)$")
    }()

    private static func matchSCP(_ s: String) -> (host: String, path: String)? {
        let r = NSRange(s.startIndex..., in: s)
        guard let m = scpRegex.firstMatch(in: s, range: r),
              m.numberOfRanges == 3,
              let hr = Range(m.range(at: 1), in: s),
              let pr = Range(m.range(at: 2), in: s) else { return nil }
        return (String(s[hr]), String(s[pr]))
    }

    /// codex `canonicalize_git_remote_url`: scp→https, strip userinfo, drop a
    /// single trailing `.git`, lowercase ONLY the host. Pure/deterministic.
    public nonisolated static func canonicalizeRemoteURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let m = matchSCP(s) {
            s = "https://\(m.host)/\(m.path)"
        }

        if s.hasPrefix("https://") {
            let rest = String(s.dropFirst("https://".count))
            if let at = rest.firstIndex(of: "@") {
                let slash = rest.firstIndex(of: "/")
                if slash == nil || at < slash! {
                    s = "https://" + String(rest[rest.index(after: at)...])
                }
            }
        }

        if s.hasSuffix(".git") {
            s = String(s.dropLast(4))
        }

        if s.hasPrefix("https://") {
            let rest = String(s.dropFirst("https://".count))
            if let slash = rest.firstIndex(of: "/") {
                let host = rest[..<slash].lowercased()
                let path = rest[slash...]
                s = "https://" + host + path
            } else {
                s = "https://" + rest.lowercased()
            }
        }
        return s
    }

    public func defaultRemoteRef() async -> String? {
        let up = await GitRunner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cwd: cwd)
        if up.exitCode == 0 {
            let t = Self.trim(up.stdout)
            if !t.isEmpty { return t }
        }
        let sym = await GitRunner.run(
            ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], cwd: cwd)
        if sym.exitCode == 0 {
            var t = Self.trim(sym.stdout)
            if t.hasPrefix("refs/remotes/") {
                t = String(t.dropFirst("refs/remotes/".count))
            }
            if !t.isEmpty { return t }
        }
        for cand in ["origin/main", "origin/master"] {
            let v = await GitRunner.run(
                ["rev-parse", "--verify", "--quiet", cand], cwd: cwd)
            if v.exitCode == 0 { return cand }
        }
        return nil
    }

    public func mergeBaseWithHead(_ ref: String) async -> String? {
        let r = await GitRunner.run(["merge-base", "HEAD", ref], cwd: cwd)
        guard r.exitCode == 0 else { return nil }
        let t = Self.trim(r.stdout)
        return Self.isHex40(t) ? t : nil
    }

    /// Best-effort new-file patches for untracked, non-ignored files.
    ///
    /// We don't shell out one git-per-file; instead we synthesize the diff in
    /// process so it matches `git diff --no-index /dev/null <path>` byte-for-
    /// byte. This collapses N spawns into a single `ls-files` plus a parallel
    /// in-process diff fan-out (bounded to 8 concurrent file reads).
    private func untrackedDiffs() async -> String {
        let ls = await GitRunner.run(
            ["ls-files", "--others", "--exclude-standard"], cwd: cwd)
        guard ls.exitCode == 0 else { return "" }

        let paths = ls.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        if paths.isEmpty { return "" }

        let root = cwd
        // Indexed fan-out with bounded concurrency, preserving `ls-files`
        // order in the concatenated output.
        let concurrency = min(8, paths.count)
        let parts: [String] = await withTaskGroup(of: (Int, String).self) { group in
            var out = Array(repeating: "", count: paths.count)
            var next = 0
            var inflight = 0
            let total = paths.count

            // Prime up to `concurrency` workers.
            while next < total && inflight < concurrency {
                let i = next; let p = paths[i]
                group.addTask { (i, GitUtils.synthUntrackedDiff(repoRoot: root, relPath: p)) }
                next += 1; inflight += 1
            }
            // As each completes, schedule the next.
            while let (i, s) = await group.next() {
                out[i] = s
                inflight -= 1
                if next < total {
                    let j = next; let p = paths[j]
                    group.addTask { (j, GitUtils.synthUntrackedDiff(repoRoot: root, relPath: p)) }
                    next += 1; inflight += 1
                }
            }
            return out
        }
        return parts.joined()
    }

    // MARK: - Synthetic `git diff --no-index /dev/null <file>`

    /// Encodes a path the way `git diff` does in its header lines.
    ///
    /// Match `git`'s behaviour with `core.quotePath=true` (the default):
    ///   * If the path contains ANY byte that needs escaping (control chars,
    ///     `"`, `\`, or high-bit non-ASCII), git wraps the whole thing in
    ///     double quotes and C-escapes the contents: control bytes become
    ///     `\a \b \t \n \v \f \r`, `"` becomes `\"`, `\\` stays as `\\`, and
    ///     any other byte with value < 0x20 or >= 0x80 becomes `\NNN` (3-
    ///     digit octal).
    ///   * Otherwise the path is rendered verbatim.
    ///
    /// Returns `(rendered, wasQuoted)`. The caller needs `wasQuoted` because
    /// the `+++ b/path` line's "trailing tab to disambiguate spaces" trick is
    /// only applied when the path is NOT quoted (when quoted the trailing
    /// `"` already terminates the path).
    nonisolated static func gitQuotePath(_ path: String) -> (rendered: String, quoted: Bool) {
        let bytes = Array(path.utf8)
        var needsQuote = false
        for b in bytes {
            if b < 0x20 || b >= 0x80 || b == 0x22 /* " */ || b == 0x5C /* \ */ {
                needsQuote = true; break
            }
        }
        if !needsQuote { return (path, false) }

        var out = ""
        out.reserveCapacity(bytes.count + 4)
        out.append("\"")
        for b in bytes {
            switch b {
            case 0x07: out.append("\\a")
            case 0x08: out.append("\\b")
            case 0x09: out.append("\\t")
            case 0x0A: out.append("\\n")
            case 0x0B: out.append("\\v")
            case 0x0C: out.append("\\f")
            case 0x0D: out.append("\\r")
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x20...0x7E:
                // Printable ASCII (other than " and \) — emit as-is.
                out.append(Character(UnicodeScalar(b)))
            default:
                // Control char or high-bit byte → \NNN three-digit octal.
                out.append(String(format: "\\%03o", b))
            }
        }
        out.append("\"")
        return (out, true)
    }

    /// Render the `--- a/<path>` / `+++ b/<path>` / `diff --git a/p b/p`
    /// header lines exactly as `git diff` would.
    ///
    /// Rules:
    ///   * `diff --git ...` line uses the (possibly-quoted) form on both
    ///     sides.
    ///   * The `--- /dev/null` line is fixed (we're synthesising a new file).
    ///   * The `+++ b/<path>` line gets a trailing `\t` IF the rendered path
    ///     contains a space AND the path was NOT quoted. (When quoted, the
    ///     closing `"` already terminates the path; when there's no space,
    ///     no disambiguator is needed.)
    private nonisolated static func renderDiffGitLine(_ relPath: String) -> String {
        let (q, _) = gitQuotePath(relPath)
        // The `a/` and `b/` prefixes go INSIDE the quotes when the path is
        // quoted; git renders `"a/<escaped>"` not `a/"<escaped>"`.
        let (qa, _) = gitQuotePath("a/" + relPath)
        let (qb, _) = gitQuotePath("b/" + relPath)
        _ = q
        return "diff --git \(qa) \(qb)\n"
    }

    private nonisolated static func renderPlusPlusLine(_ relPath: String) -> String {
        let (qb, wasQuoted) = gitQuotePath("b/" + relPath)
        // Trailing tab only when path has a space AND we did not quote.
        if !wasQuoted && relPath.contains(" ") {
            return "+++ \(qb)\t\n"
        }
        return "+++ \(qb)\n"
    }

    /// Pure helper (nonisolated) so the TaskGroup workers can call it
    /// concurrently without bouncing back into the actor.
    nonisolated static func synthUntrackedDiff(repoRoot: String, relPath: String) -> String {
        let absPath = (relPath as NSString).isAbsolutePath
            ? relPath
            : (repoRoot as NSString).appendingPathComponent(relPath)

        // Stat with lstat so we see the symlink itself rather than its target.
        var st = stat()
        guard lstat(absPath, &st) == 0 else {
            // File vanished between ls-files and read — race. Surface a
            // best-effort marker that mirrors what `git diff --no-index`
            // would emit ("error: ...") and move on.
            return diffHeaderOnly(path: relPath, mode: "100644",
                                  sha: "0000000")
                + "error: open(\"\(relPath)\"): No such file or directory\n"
        }

        let mode = st.st_mode
        let isReg = (mode & S_IFMT) == S_IFREG
        let isLink = (mode & S_IFMT) == S_IFLNK

        if isLink {
            // Symlink: content is the link target string (no trailing \n),
            // mode is 120000. git hashes the target text.
            let target = readlinkText(absPath) ?? ""
            let bytes = Array(target.utf8)
            let sha = blobSHA1(bytes)
            let shortSha = String(sha.prefix(7))
            var out = ""
            out += renderDiffGitLine(relPath)
            out += "new file mode 120000\n"
            out += "index 0000000..\(shortSha)\n"
            out += "--- /dev/null\n"
            out += renderPlusPlusLine(relPath)
            // Symlink target is never empty in practice; emit as single line
            // without trailing newline.
            if !bytes.isEmpty {
                out += "@@ -0,0 +1 @@\n"
                out += "+\(target)\n"
                out += "\\ No newline at end of file\n"
            }
            return out
        }

        guard isReg else {
            // FIFO, socket, device, etc. `git ls-files` already filters these
            // out, but defend in depth: skip with no diff text.
            return ""
        }

        // Regular file: read fully. Files can be huge — but `git diff --no-
        // index` reads them fully too, so behaviour is preserved. The caller
        // (HeadTailBuffer) bounds the *output*, not the input.
        let exec = (mode & S_IXUSR) != 0
        let fileMode = exec ? "100755" : "100644"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: absPath),
                                   options: [.mappedIfSafe]) else {
            return diffHeaderOnly(path: relPath, mode: fileMode, sha: "0000000")
                + "error: open(\"\(relPath)\"): cannot read\n"
        }
        let bytes = [UInt8](data)
        let sha = blobSHA1(bytes)
        let shortSha = String(sha.prefix(7))

        // Empty file: header through index line only, no `---`/`+++`/hunk.
        if bytes.isEmpty {
            var out = ""
            out += renderDiffGitLine(relPath)
            out += "new file mode \(fileMode)\n"
            out += "index 0000000..\(shortSha)\n"
            return out
        }

        // Binary detection: NUL in first 8000 bytes — same heuristic as git's
        // `buffer_is_binary`.
        let scanLen = min(bytes.count, 8000)
        let isBinary = bytes.prefix(scanLen).contains(0)
        if isBinary {
            // Binary files line uses the QUOTED path inside the message too
            // (e.g. `Binary files /dev/null and "b/résumé.txt" differ`).
            let (qb, _) = gitQuotePath("b/" + relPath)
            var out = ""
            out += renderDiffGitLine(relPath)
            out += "new file mode \(fileMode)\n"
            out += "index 0000000..\(shortSha)\n"
            out += "Binary files /dev/null and \(qb) differ\n"
            return out
        }

        // Text: emit `--- /dev/null`, `+++ b/path`, single all-additions hunk.
        // Line count = number of '\n' OR (lines without trailing newline = 1
        // extra). Match git's hunk-count semantics:
        //   - if file ends with \n: hunk count = number of newlines
        //   - else: hunk count = number of newlines + 1
        let endsWithNL = bytes.last == 0x0A
        var newlines = 0
        for b in bytes where b == 0x0A { newlines += 1 }
        let lineCount = endsWithNL ? newlines : (newlines + 1)

        var out = ""
        out += renderDiffGitLine(relPath)
        out += "new file mode \(fileMode)\n"
        out += "index 0000000..\(shortSha)\n"
        out += "--- /dev/null\n"
        out += renderPlusPlusLine(relPath)
        // git emits "@@ -0,0 +1 @@" for single-line files, "@@ -0,0 +1,N @@"
        // for N>=2.
        if lineCount == 1 {
            out += "@@ -0,0 +1 @@\n"
        } else {
            out += "@@ -0,0 +1,\(lineCount) @@\n"
        }
        // Emit each line prefixed with '+'. We preserve original byte
        // sequence (incl. CRLF) by splitting on '\n' only.
        var i = 0
        while i < bytes.count {
            var j = i
            while j < bytes.count && bytes[j] != 0x0A { j += 1 }
            // [i..<j) is the line content, bytes[j] (if in range) is '\n'.
            let lineSlice = bytes[i..<j]
            // The content might be invalid UTF-8 for some text-ish files
            // (e.g. Latin-1). git emits raw bytes; we decode lossy.
            let lineStr = String(decoding: lineSlice, as: UTF8.self)
            out += "+"
            out += lineStr
            out += "\n"
            if j < bytes.count {
                i = j + 1
            } else {
                // No trailing newline at EOF — emit git's marker.
                out += "\\ No newline at end of file\n"
                break
            }
        }
        return out
    }

    /// Header-only diff (used for I/O errors).
    private nonisolated static func diffHeaderOnly(path: String,
                                                   mode: String,
                                                   sha: String) -> String {
        var out = ""
        out += renderDiffGitLine(path)
        out += "new file mode \(mode)\n"
        out += "index 0000000..\(sha)\n"
        return out
    }

    /// Git blob hash: SHA1("blob <size>\0<content>").
    private nonisolated static func blobSHA1(_ bytes: [UInt8]) -> String {
        var h = Insecure.SHA1()
        let header = "blob \(bytes.count)\0"
        h.update(data: Data(header.utf8))
        h.update(data: Data(bytes))
        let digest = h.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Read a symlink's target. Returns nil on failure.
    private nonisolated static func readlinkText(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = path.withCString { cpath in
            readlink(cpath, &buf, buf.count - 1)
        }
        if n < 0 { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    public func workingDiff() async -> String {
        let r = await GitRunner.run(["diff", "HEAD"], cwd: cwd)
        let base = r.exitCode == 0 ? r.stdout : ""
        return base + (await untrackedDiffs())
    }

    public func stagedDiff() async -> String {
        let r = await GitRunner.run(["diff", "--cached"], cwd: cwd)
        return r.exitCode == 0 ? r.stdout : ""
    }

    public func diffToRemote() async -> String {
        guard let ref = await defaultRemoteRef(),
              let mb = await mergeBaseWithHead(ref) else {
            return await workingDiff()
        }
        let r = await GitRunner.run(["diff", mb], cwd: cwd)
        let base = r.exitCode == 0 ? r.stdout : ""
        return base + (await untrackedDiffs())
    }

    public struct DiffToRemoteState: Sendable, Equatable {
        public var sha: String
        public var diff: String
        public init(sha: String, diff: String) {
            self.sha = sha
            self.diff = diff
        }
    }

    public func diffToRemoteState() async -> DiffToRemoteState? {
        guard await isGitRepo(),
              let ref = await defaultRemoteRef(),
              let mb = await mergeBaseWithHead(ref) else {
            return nil
        }
        let r = await GitRunner.run(["diff", mb], cwd: cwd)
        guard r.exitCode == 0 else { return nil }
        return DiffToRemoteState(sha: mb, diff: r.stdout + (await untrackedDiffs()))
    }

    public struct GhostCommit: Sendable, Equatable {
        public var treeSha: String
        public var commitSha: String
        public init(treeSha: String, commitSha: String) {
            self.treeSha = treeSha; self.commitSha = commitSha
        }
    }

    /// codex baseline/ghost commit: capture the FULL working tree (incl.
    /// untracked) into a throwaway index via `GIT_INDEX_FILE`, write-tree,
    /// commit-tree (parented on HEAD if any). The real index/HEAD/working
    /// tree are never touched; the temp index is always deleted.
    public func ghostCommit(message: String = "codex ghost commit") async -> GhostCommit? {
        let tmpIndex = NSTemporaryDirectory() + "codex-ghost-idx-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmpIndex) }
        let env = ["GIT_INDEX_FILE": tmpIndex]

        let add = await GitRunner.run(["add", "-A"], cwd: cwd, env: env)
        guard add.exitCode == 0 else { return nil }

        let wt = await GitRunner.run(["write-tree"], cwd: cwd, env: env)
        let tree = Self.trim(wt.stdout)
        guard wt.exitCode == 0, Self.isHex40(tree) else { return nil }

        var commitArgs = ["commit-tree", tree]
        if let head = await headSha() {
            commitArgs += ["-p", head]
        }
        commitArgs += ["-m", message]

        let ct = await GitRunner.run(commitArgs, cwd: cwd, env: env)
        let commit = Self.trim(ct.stdout)
        guard ct.exitCode == 0, Self.isHex40(commit) else { return nil }

        return GhostCommit(treeSha: tree, commitSha: commit)
    }
}

/// Model-callable `git_diff` tool. Output is head/tail bounded so a huge
/// diff cannot flood the model. Never throws past a clean ToolResult.
public struct GitDiffTool: Tool {
    public let name = "git_diff"
    public let parallelSafe = true
    public var toolDescription: String {
        "Show the git diff of the workspace: mode \"working\" (vs HEAD, default), \"staged\" (index), or \"remote\" (vs merge-base with upstream)."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"mode":{"type":"string","enum":["working","staged","remote"]},"cwd":{"type":"string"}},"additionalProperties":false}"#
    }
    private let maxBytes: Int
    public init(limits: Limits = Limits()) {
        self.maxBytes = limits.clamped().maxToolOutputBytes
    }

    private struct Args: Decodable {
        var mode: String?
        var cwd: String?
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        var mode = "working"
        var dir = cwd
        if let data = call.argumentsJSON.data(using: .utf8),
           let a = try? JSONDecoder().decode(Args.self, from: data) {
            if let m = a.mode { mode = m }
            if let c = a.cwd { dir = c }
        }

        let g = GitUtils(cwd: dir)
        let isRepo = await g.isGitRepo()
        if !isRepo {
            return ToolResult(callId: call.callId,
                              output: "(not a git repository)",
                              success: false, truncated: false)
        }

        let diff: String
        switch mode {
        case "staged": diff = await g.stagedDiff()
        case "remote": diff = await g.diffToRemote()
        default:       diff = await g.workingDiff()
        }

        if diff.isEmpty {
            return ToolResult(callId: call.callId,
                              output: "(no changes)",
                              success: true, truncated: false)
        }

        var ring = HeadTailBuffer(maxBytes: maxBytes)
        ring.append(diff)
        return ToolResult(callId: call.callId,
                          output: ring.rendered(),
                          success: true,
                          truncated: ring.didTruncate)
    }
}
