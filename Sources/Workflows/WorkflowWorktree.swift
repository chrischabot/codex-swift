import Foundation

/// Per-agent git worktree isolation (port of Claude's `opts.isolation:"worktree"`).
/// Creates a throwaway worktree, runs the subagent there, and removes it
/// afterward — but only if the agent left no changes (auto-remove-if-unchanged,
/// matching `KR_`/`c8H`). Worktree creation is serialized by the caller (the
/// runner holds a concurrency-1 semaphore) to match Claude's behaviour.
public enum WorkflowWorktree {

    public struct Handle: Sendable {
        public let path: String
        public let branch: String
        public let baseRepo: String
    }

    /// Create `<repo>/.git/codex-worktrees/<runId>-<idx>` on a detached branch.
    /// Returns nil if `cwd` is not inside a git repo (caller then runs in `cwd`).
    public static func create(runId: String, index: Int, cwd: String) async -> Handle? {
        guard let repoRoot = await gitOutput(["rev-parse", "--show-toplevel"], cwd: cwd) else { return nil }
        let safe = (runId + "-\(index)").replacingOccurrences(of: "/", with: "_")
        let wtPath = repoRoot + "/.git/codex-worktrees/" + safe
        let branch = "codex/wf-" + safe
        // best-effort cleanup of a stale path
        _ = await git(["worktree", "remove", "--force", wtPath], cwd: repoRoot)
        try? FileManager.default.createDirectory(atPath: repoRoot + "/.git/codex-worktrees",
                                                 withIntermediateDirectories: true)
        let r = await git(["worktree", "add", "--detach", wtPath, "HEAD"], cwd: repoRoot)
        guard r.ok else {
            // try with a branch if --detach failed
            let r2 = await git(["worktree", "add", "-b", branch, wtPath], cwd: repoRoot)
            guard r2.ok else { return nil }
            return Handle(path: wtPath, branch: branch, baseRepo: repoRoot)
        }
        return Handle(path: wtPath, branch: branch, baseRepo: repoRoot)
    }

    /// Whether the worktree has any uncommitted changes.
    public static func hasChanges(_ h: Handle) async -> Bool {
        let out = await gitOutput(["status", "--porcelain"], cwd: h.path)
        return !(out ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Remove the worktree (force). Caller decides whether to keep it (changes).
    public static func remove(_ h: Handle) async {
        _ = await git(["worktree", "remove", "--force", h.path], cwd: h.baseRepo)
    }

    /// The isolation notice appended to the subagent prompt.
    public static func isolationNotice(path: String, mainCwd: String) -> String {
        """

        You are running inside an isolated git worktree at \(path). Changes you make here do NOT \
        affect the main working directory (\(mainCwd)). Make edits freely; they will be reviewed \
        and merged separately.
        """
    }

    // MARK: git plumbing

    private struct Res { let out: String; let ok: Bool }

    private static func git(_ args: [String], cwd: String) async -> Res {
        await withCheckedContinuation { (c: CheckedContinuation<Res, Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["git"] + args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let out = Pipe(); let err = Pipe()
                p.standardOutput = out; p.standardError = err
                do { try p.run() } catch { c.resume(returning: Res(out: "", ok: false)); return }
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                c.resume(returning: Res(out: String(data: data, encoding: .utf8) ?? "",
                                        ok: p.terminationStatus == 0))
            }
        }
    }

    private static func gitOutput(_ args: [String], cwd: String) async -> String? {
        let r = await git(args, cwd: cwd)
        guard r.ok else { return nil }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
