import XCTest
import Foundation
@testable import HarnessCore
@testable import Sandbox
@testable import ProtocolModel
@testable import Tools

/// Port of upstream `core/src/turn_metadata_tests.rs` (the subset that the Swift
/// port reproduces: the per-turn `x-codex-turn-metadata` header value carrying
/// session/thread/turn ids + sandbox tag, ASCII-only JSON, and git enrichment).
final class TurnMetadataTests: XCTestCase {

    private func git(_ args: [String], cwd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    private func makeRepo() -> String {
        let base = NSTemporaryDirectory() + "tmeta-" + UUID().uuidString
        // Include a non-ASCII path segment to exercise the ASCII escaping.
        let repo = (base as NSString).appendingPathComponent("repo-東京")
        try? FileManager.default.createDirectory(atPath: repo,
                                                 withIntermediateDirectories: true)
        git(["init"], cwd: repo)
        git(["config", "user.name", "Test User"], cwd: repo)
        git(["config", "user.email", "test@example.com"], cwd: repo)
        FileManager.default.createFile(atPath: (repo as NSString)
            .appendingPathComponent("README.md"), contents: Data("hello".utf8))
        git(["add", "."], cwd: repo)
        git(["commit", "-m", "initial"], cwd: repo)
        return repo
    }

    // MARK: build_turn_metadata_header (free function)

    func testBuildTurnMetadataHeaderIncludesHasChangesForCleanRepo() async throws {
        let repo = makeRepo()
        defer { try? FileManager.default.removeItem(atPath: (repo as NSString)
            .deletingLastPathComponent) }
        guard let header = await buildTurnMetadataHeader(cwd: repo, sandbox: "none") else {
            throw XCTSkip("git unavailable on host")
        }
        // ASCII-only: the 東京 path must be \u-escaped, not raw.
        XCTAssertTrue(header.allSatisfy { $0.isASCII }, "header must be ASCII-only")
        XCTAssertFalse(header.contains("東京"))
        let json = try JSONSerialization.jsonObject(with: Data(header.utf8)) as! [String: Any]
        let workspaces = json["workspaces"] as! [String: Any]
        // Repo root key resolves to the (symlink-resolved) repo path.
        XCTAssertEqual(workspaces.count, 1)
        let ws = workspaces.values.first as! [String: Any]
        XCTAssertEqual(ws["has_changes"] as? Bool, false,
                       "clean repo → has_changes == false")
        XCTAssertEqual(json["sandbox"] as? String, "none")
    }

    func testBuildTurnMetadataHeaderReturnsNilWhenNoGitNoSandbox() async {
        // A non-git temp dir with no sandbox tag → nil (upstream early return).
        let dir = NSTemporaryDirectory() + "tmeta-nogit-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let header = await buildTurnMetadataHeader(cwd: dir, sandbox: nil)
        XCTAssertNil(header)
    }

    // MARK: TurnMetadataState base header (turn_metadata_state_uses_*)

    func testTurnMetadataStateCarriesIdsAndSandboxTag() async {
        let dir = NSTemporaryDirectory()
        let state = TurnMetadataState(
            sessionId: "session-a",
            threadId: "thread-a",
            threadSource: "user",
            turnId: "turn-a",
            cwd: dir,
            sandboxMode: .readOnly)
        let header = await state.currentHeaderValue()
        XCTAssertNotNil(header)
        let json = try! JSONSerialization.jsonObject(with: Data(header!.utf8)) as! [String: Any]
        XCTAssertEqual(json["session_id"] as? String, "session-a")
        XCTAssertEqual(json["thread_id"] as? String, "thread-a")
        XCTAssertEqual(json["thread_source"] as? String, "user")
        XCTAssertEqual(json["turn_id"] as? String, "turn-a")
        // sandbox tag matches the helper for the same mode.
        let expected = TurnMetadataSandboxTag.tag(mode: .readOnly)
        XCTAssertEqual(json["sandbox"] as? String, expected)
        XCTAssertNil(json["session_source"])
    }

    func testTurnMetadataStateSubagentThreadSource() async {
        let state = TurnMetadataState(
            sessionId: "session-a", threadId: "thread-a",
            threadSource: "subagent", turnId: "turn-a",
            cwd: NSTemporaryDirectory(), sandboxMode: .readOnly)
        let header = await state.currentHeaderValue()!
        let json = try! JSONSerialization.jsonObject(with: Data(header.utf8)) as! [String: Any]
        XCTAssertEqual(json["thread_source"] as? String, "subagent")
    }

    func testTurnMetadataStateDangerFullAccessSandboxNone() async {
        let state = TurnMetadataState(
            sessionId: "s", threadId: "t", threadSource: nil, turnId: "u",
            cwd: NSTemporaryDirectory(), sandboxMode: .dangerFullAccess)
        let header = await state.currentHeaderValue()!
        let json = try! JSONSerialization.jsonObject(with: Data(header.utf8)) as! [String: Any]
        XCTAssertEqual(json["sandbox"] as? String, "none")
        XCTAssertNil(json["thread_source"], "nil thread_source is omitted")
    }

    // MARK: ASCII JSON emission (to_ascii_json_string parity)

    func testAsciiJSONEscapesNonAscii() {
        let lit = TurnMetadataJSON.stringLiteral("東京/a\"b\\c")
        XCTAssertTrue(lit.allSatisfy { $0.isASCII })
        XCTAssertEqual(lit, "\"\\u6771\\u4eac/a\\\"b\\\\c\"")
    }

    func testAsciiJSONSurrogatePair() {
        // U+1F600 GRINNING FACE → surrogate pair 😀.
        let lit = TurnMetadataJSON.stringLiteral("\u{1F600}")
        XCTAssertEqual(lit, "\"\\ud83d\\ude00\"")
    }

    // MARK: workspace ordering / skip_serializing_if

    func testBagOmitsEmptyWorkspacesAndNilFields() {
        let bag = buildTurnMetadataBag(
            sessionId: "s", threadId: nil, threadSource: nil, turnId: nil,
            sandbox: nil, repoRoot: nil, workspaceGitMetadata: nil)
        let header = bag.toHeaderValue()!
        XCTAssertEqual(header, "{\"session_id\":\"s\"}",
                       "nil fields and empty workspaces are omitted")
    }

    func testWorkspaceRemoteUrlsSortedByName() {
        let ws = WorkspaceGitMetadata(
            associatedRemoteURLs: ["zeta": "z", "alpha": "a"],
            latestGitCommitHash: "deadbeef", hasChanges: true)
        let bag = buildTurnMetadataBag(
            sessionId: nil, threadId: nil, threadSource: nil, turnId: nil,
            sandbox: nil, repoRoot: "/repo", workspaceGitMetadata: ws)
        let header = bag.toHeaderValue()!
        // alpha must precede zeta (BTreeMap sorted), keys appear in serde order.
        let alphaIdx = header.range(of: "\"alpha\"")!.lowerBound
        let zetaIdx = header.range(of: "\"zeta\"")!.lowerBound
        XCTAssertLessThan(alphaIdx, zetaIdx)
        XCTAssertTrue(header.contains("\"has_changes\":true"))
        XCTAssertTrue(header.contains("\"latest_git_commit_hash\":\"deadbeef\""))
    }
}
