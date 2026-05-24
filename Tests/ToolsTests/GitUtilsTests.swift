import XCTest
import Foundation
@testable import Tools
@testable import InfraPrimitives

final class GitUtilsTests: XCTestCase {

    private func gitAvailable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "--version"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "git-utils-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    private func makeRepo() async throws -> String {
        let dir = try makeTempDir()
        _ = await GitRunner.run(["init", "-q"], cwd: dir)
        _ = await GitRunner.run(["config", "user.email", "t@e"], cwd: dir)
        _ = await GitRunner.run(["config", "user.name", "t"], cwd: dir)
        try "one\n".write(toFile: dir + "/a.txt",
                          atomically: true, encoding: .utf8)
        _ = await GitRunner.run(["add", "a.txt"], cwd: dir)
        _ = await GitRunner.run(["commit", "-q", "-m", "c1"], cwd: dir)
        return dir
    }

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func jsonArgs(_ obj: [String: String]) -> String {
        let d = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: - Pure

    func testCanonicalizeRemoteURL() {
        XCTAssertEqual(
            GitUtils.canonicalizeRemoteURL("git@github.com:Owner/Repo.git"),
            "https://github.com/Owner/Repo")
        XCTAssertEqual(
            GitUtils.canonicalizeRemoteURL("https://user@github.com/Owner/Repo.git"),
            "https://github.com/Owner/Repo")
        XCTAssertEqual(
            GitUtils.canonicalizeRemoteURL("https://GitHub.com/O/R"),
            "https://github.com/O/R")
        XCTAssertEqual(
            GitUtils.canonicalizeRemoteURL("  not-a-url  "),
            "not-a-url")
    }

    // MARK: - Repo identity

    func testIsRepoAndRoot() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let g = GitUtils(cwd: dir)
        let isRepo = await g.isGitRepo()
        XCTAssertTrue(isRepo)
        let root = await g.repoRoot()
        XCTAssertEqual(root.map { self.resolved($0) }, resolved(dir))

        let nonRepo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: nonRepo) }
        let ng = GitUtils(cwd: nonRepo)
        let nIsRepo = await ng.isGitRepo()
        XCTAssertFalse(nIsRepo)
        let nRoot = await ng.repoRoot()
        XCTAssertNil(nRoot)
    }

    // MARK: - Diffs

    func testWorkingAndStagedDiff() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "one\ntwo\n".write(toFile: dir + "/a.txt",
                               atomically: true, encoding: .utf8)
        let g = GitUtils(cwd: dir)
        let wd = await g.workingDiff()
        XCTAssertTrue(wd.contains("+two"), "working diff was:\n\(wd)")

        _ = await GitRunner.run(["add", "a.txt"], cwd: dir)
        let sd = await g.stagedDiff()
        XCTAssertTrue(sd.contains("+two"), "staged diff was:\n\(sd)")
    }

    func testUntrackedAppearsInWorkingDiff() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "new\n".write(toFile: dir + "/b.txt",
                          atomically: true, encoding: .utf8)
        let g = GitUtils(cwd: dir)
        let wd = await g.workingDiff()
        XCTAssertTrue(wd.contains("b.txt"), "working diff was:\n\(wd)")
    }

    func testMergeBaseAndDiffToRemote() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let firstShaR = await GitRunner.run(["rev-parse", "HEAD"], cwd: dir)
        let firstSha = firstShaR.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        _ = await GitRunner.run(
            ["update-ref", "refs/remotes/origin/main", "HEAD"], cwd: dir)

        try "one\nchange\n".write(toFile: dir + "/a.txt",
                                  atomically: true, encoding: .utf8)
        _ = await GitRunner.run(["add", "a.txt"], cwd: dir)
        _ = await GitRunner.run(["commit", "-q", "-m", "c2"], cwd: dir)

        let g = GitUtils(cwd: dir)
        let ref = await g.defaultRemoteRef()
        XCTAssertEqual(ref, "origin/main")

        let mb = await g.mergeBaseWithHead("origin/main")
        XCTAssertEqual(mb, firstSha)

        let dr = await g.diffToRemote()
        XCTAssertTrue(dr.contains("change"), "diffToRemote was:\n\(dr)")
    }

    // MARK: - Ghost commit

    func testGhostCommitDoesNotMutateState() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "one\nedited\n".write(toFile: dir + "/a.txt",
                                  atomically: true, encoding: .utf8)
        try "ghosted\n".write(toFile: dir + "/c.txt",
                              atomically: true, encoding: .utf8)

        let headBeforeR = await GitRunner.run(["rev-parse", "HEAD"], cwd: dir)
        let headBefore = headBeforeR.stdout
        let statusBeforeR = await GitRunner.run(
            ["status", "--porcelain"], cwd: dir)
        let statusBefore = statusBeforeR.stdout

        let g = GitUtils(cwd: dir)
        let ghost = await g.ghostCommit()
        let unwrapped = try XCTUnwrap(ghost)
        XCTAssertEqual(unwrapped.treeSha.count, 40)
        XCTAssertEqual(unwrapped.commitSha.count, 40)
        XCTAssertTrue(unwrapped.treeSha.allSatisfy { $0.isHexDigit })
        XCTAssertTrue(unwrapped.commitSha.allSatisfy { $0.isHexDigit })

        let lsTree = await GitRunner.run(
            ["ls-tree", "-r", unwrapped.treeSha], cwd: dir)
        let treeListing = lsTree.stdout
        XCTAssertTrue(treeListing.contains("a.txt"),
                      "ls-tree was:\n\(treeListing)")
        XCTAssertTrue(treeListing.contains("c.txt"),
                      "ls-tree was:\n\(treeListing)")

        let headAfterR = await GitRunner.run(["rev-parse", "HEAD"], cwd: dir)
        let headAfter = headAfterR.stdout
        let statusAfterR = await GitRunner.run(
            ["status", "--porcelain"], cwd: dir)
        let statusAfter = statusAfterR.stdout

        XCTAssertEqual(headBefore, headAfter)
        XCTAssertEqual(statusBefore, statusAfter)
    }

    // MARK: - Tool through router

    func testGitDiffToolThroughRouter() async throws {
        try XCTSkipUnless(gitAvailable())
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "one\ntwo\n".write(toFile: dir + "/a.txt",
                               atomically: true, encoding: .utf8)

        let router = ToolRouter(limits: Limits())
        await router.register(GitDiffTool())

        let call = ToolCall(callId: "1", name: "git_diff",
                            argumentsJSON: jsonArgs(["mode": "working",
                                                     "cwd": dir]))
        let res = await router.dispatch(call, cwd: dir,
                                        deadline: Deadline.fromNow(.seconds(30)))
        XCTAssertTrue(res.success)
        XCTAssertTrue(res.output.contains("+two"),
                      "git_diff output was:\n\(res.output)")

        let nonRepo = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: nonRepo) }
        let call2 = ToolCall(callId: "2", name: "git_diff",
                             argumentsJSON: jsonArgs(["cwd": nonRepo]))
        let res2 = await router.dispatch(call2, cwd: nonRepo,
                                         deadline: Deadline.fromNow(.seconds(30)))
        XCTAssertFalse(res2.success)
        XCTAssertEqual(res2.output, "(not a git repository)")
    }
}