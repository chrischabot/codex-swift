import XCTest
import Foundation
@testable import Tools
@testable import Sandbox
@testable import ProtocolModel
@testable import InfraPrimitives

private func ftTmp() -> String {
    let p = NSTemporaryDirectory() + "ft-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

final class FileToolsTests: XCTestCase {

    private func seed(_ root: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root + "/src/utils", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/.git/objects", withIntermediateDirectories: true)
        try? "fn add".write(toFile: root + "/src/calculator.swift", atomically: true, encoding: .utf8)
        try? "helpers".write(toFile: root + "/src/utils/helper.swift", atomically: true, encoding: .utf8)
        try? "# Readme".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        try? "junk".write(toFile: root + "/.git/objects/deadbeef", atomically: true, encoding: .utf8)
    }

    func testFileSearchRanksAndSkipsHeavyDirs() async throws {
        let root = ftTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        seed(root)
        let r = try await FileSearchTool().run(
            ToolCall(callId: "1", name: "file_search",
                     argumentsJSON: #"{"query":"calc"}"#), cwd: root)
        XCTAssertTrue(r.success)
        let lines = r.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "src/calculator.swift",
                       "best fuzzy match ranks first")
        XCTAssertFalse(r.output.contains("deadbeef"),
                       ".git is skipped during traversal")
        let none = try await FileSearchTool().run(
            ToolCall(callId: "2", name: "file_search",
                     argumentsJSON: #"{"query":"zzznomatch"}"#), cwd: root)
        XCTAssertEqual(none.output, "(no matches)")
    }

    func testReadFileFullOffsetLimitAndGuards() async throws {
        let root = ftTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "L1\nL2\nL3\nL4\nL5".write(toFile: root + "/f.txt",
                                       atomically: true, encoding: .utf8)
        let tool = ReadFileTool(limits: Limits())
        let full = try await tool.run(
            ToolCall(callId: "1", name: "read_file", argumentsJSON: #"{"path":"f.txt"}"#),
            cwd: root)
        XCTAssertEqual(full.output, "L1\nL2\nL3\nL4\nL5")
        let win = try await tool.run(
            ToolCall(callId: "2", name: "read_file",
                     argumentsJSON: #"{"path":"f.txt","offset":2,"limit":2}"#), cwd: root)
        XCTAssertEqual(win.output, "L2\nL3")
        let trav = try await tool.run(
            ToolCall(callId: "3", name: "read_file",
                     argumentsJSON: #"{"path":"../../../etc/passwd"}"#), cwd: root)
        XCTAssertFalse(trav.success)
        XCTAssertTrue(trav.output.contains("traversal"))
        let abs = try await tool.run(
            ToolCall(callId: "4", name: "read_file",
                     argumentsJSON: #"{"path":"/etc/passwd"}"#), cwd: root)
        XCTAssertFalse(abs.success)
        XCTAssertTrue(abs.output.contains("absolute"))
        let missing = try await tool.run(
            ToolCall(callId: "5", name: "read_file", argumentsJSON: #"{"path":"nope.txt"}"#),
            cwd: root)
        XCTAssertFalse(missing.success)
        XCTAssertTrue(missing.output.contains("file not found"))
    }

    func testWriteFileSandboxGated() async throws {
        let root = ftTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let allow = WriteFileTool(sandbox: WorkspaceSandbox(
            SandboxPolicy(mode: .workspaceWrite, writableRoots: [root])))
        let w = try await allow.run(
            ToolCall(callId: "1", name: "write_file",
                     argumentsJSON: #"{"path":"out/new.txt","content":"hello"}"#),
            cwd: root)
        XCTAssertTrue(w.success, w.output)
        XCTAssertEqual(try String(contentsOfFile: root + "/out/new.txt", encoding: .utf8),
                       "hello")
        let deny = WriteFileTool(sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        let d = try await deny.run(
            ToolCall(callId: "2", name: "write_file",
                     argumentsJSON: #"{"path":"x.txt","content":"y"}"#), cwd: root)
        XCTAssertFalse(d.success)
        XCTAssertTrue(d.output.contains("sandbox denied write"))
        let trav = try await allow.run(
            ToolCall(callId: "3", name: "write_file",
                     argumentsJSON: #"{"path":"../escape.txt","content":"z"}"#), cwd: root)
        XCTAssertFalse(trav.success)
        XCTAssertTrue(trav.output.contains("traversal"))
    }

    func testFileToolsSymlinkEscapesAreBlocked() async throws {
        let root = ftTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = ftTmp(); defer { try? FileManager.default.removeItem(atPath: outside) }
        try "SECRET".write(toFile: outside + "/secret.txt",
                           atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/outside", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/secret-link.txt", withDestinationPath: outside + "/secret.txt")

        let read = try await ReadFileTool().run(
            ToolCall(callId: "r", name: "read_file",
                     argumentsJSON: #"{"path":"secret-link.txt"}"#),
            cwd: root)
        XCTAssertFalse(read.success)
        XCTAssertTrue(read.output.contains("symlink"), read.output)
        XCTAssertFalse(read.output.contains("SECRET"))

        let list = try await ListDirTool().run(
            ToolCall(callId: "l", name: "list_dir",
                     argumentsJSON: #"{"path":"outside"}"#),
            cwd: root)
        XCTAssertFalse(list.success)
        XCTAssertTrue(list.output.contains("symlink"), list.output)

        let allow = WriteFileTool(sandbox: WorkspaceSandbox(
            SandboxPolicy(mode: .workspaceWrite, writableRoots: [root])))
        let write = try await allow.run(
            ToolCall(callId: "w", name: "write_file",
                     argumentsJSON: #"{"path":"outside/pwned.txt","content":"PWNED"}"#),
            cwd: root)
        XCTAssertFalse(write.success)
        XCTAssertTrue(write.output.contains("symlink"), write.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/pwned.txt"))

        let search = try await FileSearchTool().run(
            ToolCall(callId: "s", name: "file_search",
                     argumentsJSON: #"{"query":"secret"}"#),
            cwd: root)
        XCTAssertTrue(search.success)
        XCTAssertFalse(search.output.contains("secret.txt"),
                       "file_search must not traverse symlinked dirs outside the workspace")

        try FileManager.default.createDirectory(atPath: root + "/inside",
                                                withIntermediateDirectories: true)
        try "SAFE".write(toFile: root + "/inside/safe.txt",
                         atomically: true, encoding: .utf8)
        let safe = try await ReadFileTool().run(
            ToolCall(callId: "safe", name: "read_file",
                     argumentsJSON: #"{"path":"inside/safe.txt"}"#),
            cwd: root)
        XCTAssertTrue(safe.success)
        XCTAssertEqual(safe.output, "SAFE")
    }

    func testListDir() async throws {
        let root = ftTmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        seed(root)
        let r = try await ListDirTool().run(
            ToolCall(callId: "1", name: "list_dir", argumentsJSON: #"{"path":"src"}"#),
            cwd: root)
        XCTAssertTrue(r.success)
        let entries = Set(r.output.split(separator: "\n").map(String.init))
        XCTAssertTrue(entries.contains("calculator.swift"))
        XCTAssertTrue(entries.contains("utils/"), "directories get a trailing slash")
        let bad = try await ListDirTool().run(
            ToolCall(callId: "2", name: "list_dir", argumentsJSON: #"{"path":".."}"#),
            cwd: root)
        XCTAssertFalse(bad.success)
    }

    func testListDirOnSymlinkedWorkspaceRootSucceeds() async throws {
        // Regression: when the workspace root sits under a symlinked path
        // (e.g. macOS's `/var/folders/...` → `/private/var/folders/...`),
        // `list_dir(.)` previously walked up to the workspace's parent dir
        // when checking realpath containment, and that parent — by
        // definition outside the workspace — tripped the symlink check.
        // The model could self-correct, but real codex sessions launched
        // from `mkdtemp` would lose their first 1-2 exploration turns.
        let parent = NSTemporaryDirectory() + "ft-symlinked-root-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: parent,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: parent) }
        let root = parent + "/workspace"
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
        try "PAYLOAD".write(toFile: root + "/README.md",
                            atomically: true, encoding: .utf8)
        // Resolve to realpath to mirror what macOS tempdirs look like (the
        // codex driver hits the same shape when the cwd it passes goes
        // through `/var/folders/...`).
        let resolved = URL(fileURLWithPath: root)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let r = try await ListDirTool().run(
            ToolCall(callId: "1", name: "list_dir", argumentsJSON: #"{"path":""}"#),
            cwd: resolved)
        XCTAssertTrue(r.success,
                      "list_dir on workspace root must not trip the realpath check: \(r.output)")
        XCTAssertTrue(r.output.contains("README.md"), r.output)

        // Also exercise the unresolved variant — clients may pass the
        // unresolved tempdir path; both should work.
        let r2 = try await ListDirTool().run(
            ToolCall(callId: "2", name: "list_dir", argumentsJSON: #"{"path":""}"#),
            cwd: root)
        XCTAssertTrue(r2.success,
                      "list_dir on unresolved workspace root must work: \(r2.output)")
        XCTAssertTrue(r2.output.contains("README.md"), r2.output)
    }

    func testWebSearchDisabledAndCustomBackend() async throws {
        let off = try await WebSearchTool().run(
            ToolCall(callId: "1", name: "web_search", argumentsJSON: #"{"query":"swift"}"#),
            cwd: "/tmp")
        XCTAssertFalse(off.success)
        XCTAssertTrue(off.output.contains("not configured"))

        struct Stub: WebSearchBackend {
            func search(_ q: String) async -> Result<String, ToolError> {
                .success("RESULT for \(q)")
            }
        }
        let on = try await WebSearchTool(backend: Stub()).run(
            ToolCall(callId: "2", name: "web_search", argumentsJSON: #"{"query":"swift"}"#),
            cwd: "/tmp")
        XCTAssertTrue(on.success)
        XCTAssertEqual(on.output, "RESULT for swift")
    }

    func testDefaultToolsRegistersFullInventory() async {
        let router = ToolRouter(limits: Limits())
        await DefaultTools.register(on: router,
                                    sandbox: WorkspaceSandbox(SandboxPolicy(mode: .readOnly)))
        let names = Set((await router.specs()).map { $0.name })
        // Default registration uses `shell_type: shell_command` (the value every
        // shipped model declares), which upstream `spec_plan.rs` resolves to a
        // model-visible `shell_command` ONLY. The `exec_command`/`write_stdin`
        // PTY pair is reserved for `ConfigShellToolType::UnifiedExec` and must
        // NOT be advertised simultaneously (see ExecCommandWriteStdinTests).
        for expected in ["apply_patch", "shell_command",
                         "file_search", "read_file", "write_file", "list_dir",
                         "web_search", "exec", "wait"] {
            XCTAssertTrue(names.contains(expected),
                          "DefaultTools must register \(expected)")
        }
        XCTAssertFalse(names.contains("exec_command"),
                       "ShellCommand mode must NOT expose `exec_command` alongside `shell_command`")
        XCTAssertFalse(names.contains("write_stdin"),
                       "ShellCommand mode must NOT expose `write_stdin` alongside `shell_command`")
        // `unified_exec` has no model-visible ToolSpec upstream — it must be
        // CALLABLE (hidden registry) but absent from specs().
        XCTAssertFalse(names.contains("unified_exec"),
                       "unified_exec must NOT be model-visible (upstream parity)")
        let ux = await router.dispatch(
            ToolCall(callId: "ux-hidden", name: "unified_exec", argumentsJSON: "{}"),
            cwd: NSTemporaryDirectory(), deadline: .fromNow(.seconds(5)))
        XCTAssertFalse(ux.output.hasPrefix("unsupported call:"),
                       "unified_exec stays callable via the hidden registry: \(ux.output)")
    }
}
