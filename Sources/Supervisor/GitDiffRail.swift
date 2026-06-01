import Foundation

/// Backend for the web UI's diff-rail (Commit / Commit&push / Commit+PR /
/// Revert). Runs `git` (and `gh` for PRs) in the thread's working directory.
/// Lives behind the `git/action` JSON-RPC method + the gateway method gate +
/// per-session auth — it performs real repo writes, so it is intentionally a
/// single, explicit, audited surface (no force-push, no destructive cleans).
enum GitDiffRail {
    struct Outcome: Sendable, Codable, Equatable {
        var ok: Bool
        var output: String
        var branch: String?
    }

    /// Run an executable in `cwd`, returning (exitOK, combined-output).
    static func run(_ exe: String, _ args: [String], cwd: String) async -> (Bool, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            DispatchQueue.global().async {
                let p = Process()
                // Resolve via env so `git`/`gh` come from PATH.
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = [exe] + args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: (false, "failed to launch \(exe): \(error.localizedDescription)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }

    static func currentBranch(cwd: String) async -> String? {
        let (ok, out) = await run("git", ["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
        let b = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ok && !b.isEmpty ? b : nil
    }

    /// action ∈ status | commit | push | commitPush | pr | revert
    static func perform(action: String, cwd: String,
                        message: String?, title: String?, body: String?) async -> Outcome {
        let branch = await currentBranch(cwd: cwd)
        func out(_ ok: Bool, _ s: String) -> Outcome { Outcome(ok: ok, output: s, branch: branch) }

        switch action {
        case "status":
            let (ok, s) = await run("git", ["status", "--porcelain=v1", "-b"], cwd: cwd)
            return out(ok, s)
        case "commit", "commitPush":
            let msg = (message?.isEmpty == false ? message! : "Update from Codex")
            let (addOK, addOut) = await run("git", ["add", "-A"], cwd: cwd)
            guard addOK else { return out(false, addOut) }
            let (cOK, cOut) = await run("git", ["commit", "-m", msg], cwd: cwd)
            if action == "commit" || !cOK { return out(cOK, cOut) }
            let (pOK, pOut) = await run("git", ["push"], cwd: cwd)   // no --force
            return out(pOK, cOut + "\n" + pOut)
        case "push":
            let (ok, s) = await run("git", ["push"], cwd: cwd)
            return out(ok, s)
        case "pr":
            // Requires the `gh` CLI to be authenticated.
            var args = ["pr", "create", "--fill"]
            if let title, !title.isEmpty { args = ["pr", "create", "--title", title, "--body", body ?? ""] }
            let (ok, s) = await run("gh", args, cwd: cwd)
            return out(ok, s)
        case "revert":
            // Discard tracked working-tree changes only (no untracked clean).
            let (ok, s) = await run("git", ["checkout", "--", "."], cwd: cwd)
            return out(ok, s)
        default:
            return out(false, "unknown git action: \(action)")
        }
    }
}
