import Foundation
import InfraPrimitives

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

/// Holds the Process + its three pipes across the dedicated reader thread and
/// the timeout Task without tripping Swift 6 Sendable checks (the underlying
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

/// Single-resume bridge between the blocking reader thread / timeout Task and
/// the awaiting continuation. NSLock-guarded so the first resume wins and a
/// late second resume is a no-op (never traps).
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

/// Spawns `git` via `/usr/bin/env`, captures stdout+stderr fully on a
/// dedicated thread (so no cooperative thread blocks), and arms a timeout
/// Task that force-reaps the descendant tree on overrun. Output is bound to
/// 1 MiB per stream. Never traps on hostile output.
public enum GitRunner {
    static func run(_ args: [String],
                    cwd: String,
                    env extra: [String: String] = [:],
                    timeout: Duration = .seconds(30)) async -> GitResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + args
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

            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                if Task.isCancelled { return }
                if box.process.isRunning {
                    reapProcessTree(box.process.processIdentifier)
                    box.process.terminate()
                }
                resumer.resume(GitResult(stdout: "",
                                         stderr: "git timed out",
                                         exitCode: -1, timedOut: true))
            }

            let reader = Thread {
                let maxBytes = 1024 * 1024
                let outData = (try? box.out.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? box.err.fileHandleForReading.readToEnd()) ?? Data()
                box.process.waitUntilExit()
                let code = box.process.terminationStatus
                func bound(_ d: Data) -> String {
                    let slice = d.count > maxBytes ? d.prefix(maxBytes) : d[...]
                    return String(decoding: slice, as: UTF8.self)
                }
                timeoutTask.cancel()
                resumer.resume(GitResult(stdout: bound(outData),
                                         stderr: bound(errData),
                                         exitCode: code,
                                         timedOut: false))
            }
            reader.stackSize = 1 << 20
            reader.start()
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

    private static func matchSCP(_ s: String) -> (host: String, path: String)? {
        // ^[^@/]+@([^:/]+):(.+)$
        guard let re = try? NSRegularExpression(pattern: "^[^@/]+@([^:/]+):(.+)$")
        else { return nil }
        let r = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: r), m.numberOfRanges == 3,
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
    private func untrackedDiffs() async -> String {
        let ls = await GitRunner.run(
            ["ls-files", "--others", "--exclude-standard"], cwd: cwd)
        guard ls.exitCode == 0 else { return "" }
        var out = ""
        for line in ls.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = String(line)
            let d = await GitRunner.run(
                ["diff", "--no-index", "/dev/null", f], cwd: cwd)
            // `git diff --no-index` exits 1 when there ARE differences.
            if d.exitCode == 0 || d.exitCode == 1 {
                out += d.stdout
            }
        }
        return out
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
