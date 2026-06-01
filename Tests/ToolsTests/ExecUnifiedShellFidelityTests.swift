import XCTest
import Foundation
@testable import Tools

/// Wire/behavior-fidelity tests for the `exec-unified-shell` audit unit.
/// Each test pins a specific upstream divergence fix.
final class ExecUnifiedShellFidelityTests: XCTestCase {

    // MARK: Finding 2 — exit-code and session-id lines are INDEPENDENT.
    // Upstream `response_text` (core/src/tools/context.rs:410-416) emits the
    // exit-code line whenever exit_code.is_some() and the session-id line
    // whenever process_id.is_some(); a still-alive process (ProcessStatus::Alive,
    // process_manager.rs:509-516) carries both, so both lines appear together.

    func testRenderEmitsBothExitAndSessionWhenAliveWithExitCode() throws {
        // Alive (exited == false) but an exit_code is already recorded.
        let out = renderExecJSON(
            sessionId: 7,
            output: "hi",
            exited: false,
            exitCode: 0,
            wallTimeSeconds: 0.0,
            chunkId: "abc123",
            originalBytes: 2,
            truncated: false)
        XCTAssertTrue(out.contains("Process exited with code 0"),
                      "exit-code line must appear whenever exitCode != nil: \(out)")
        XCTAssertTrue(out.contains("Process running with session ID 7"),
                      "session-id line must appear for a live process: \(out)")
    }

    func testRenderExitOnlyWhenExitedNoSession() throws {
        // Fully exited: process_id is None upstream, so no session line.
        let out = renderExecJSON(
            sessionId: nil,
            output: "done",
            exited: true,
            exitCode: 3,
            wallTimeSeconds: 1.0,
            chunkId: "",
            originalBytes: 4,
            truncated: false)
        XCTAssertTrue(out.contains("Process exited with code 3"), out)
        XCTAssertFalse(out.contains("session ID"), out)
        // No chunk id when empty (context.rs:403-404).
        XCTAssertFalse(out.contains("Chunk ID"), out)
    }

    func testRenderSessionOnlyWhenAliveNoExitCode() throws {
        let out = renderExecJSON(
            sessionId: 12,
            output: "",
            exited: false,
            exitCode: nil,
            wallTimeSeconds: 0.5,
            chunkId: "z9",
            originalBytes: 0,
            truncated: false)
        XCTAssertFalse(out.contains("exited with code"), out)
        XCTAssertTrue(out.contains("Process running with session ID 12"), out)
        XCTAssertTrue(out.contains("Chunk ID: z9"), out)
        // Empty output yields 0 tokens (ceil-div with no min-of-1).
        XCTAssertTrue(out.contains("Original token count: 0"), out)
    }

    // MARK: Finding 3 — non-POSIX shells get the correct argv conventions.
    // Mirrors upstream `Shell::derive_exec_args` (core/src/shell.rs:43-70) with
    // shell type from `detect_shell_type` (shell_detect.rs:5-24).

    #if DEBUG
    func testPosixShellUsesDashC() throws {
        XCTAssertEqual(
            ExecCommandTool._testDeriveArgv(line: "echo hi", shell: "/bin/bash",
                                            useLoginShell: false),
            ["/bin/bash", "-c", "echo hi"])
        XCTAssertEqual(
            ExecCommandTool._testDeriveArgv(line: "echo hi", shell: "/bin/zsh",
                                            useLoginShell: true),
            ["/bin/zsh", "-lc", "echo hi"])
        XCTAssertEqual(
            ExecCommandTool._testDeriveArgv(line: "ls", shell: "/bin/sh",
                                            useLoginShell: false),
            ["/bin/sh", "-c", "ls"])
    }

    func testPowerShellUsesCommandFlagAndNoProfile() throws {
        // Non-login: -NoProfile precedes -Command.
        XCTAssertEqual(
            ExecCommandTool._testDeriveArgv(line: "Get-ChildItem", shell: "pwsh",
                                            useLoginShell: false),
            ["pwsh", "-NoProfile", "-Command", "Get-ChildItem"])
        // Login: drop -NoProfile.
        XCTAssertEqual(
            ExecCommandTool._testDeriveArgv(line: "Get-ChildItem", shell: "pwsh",
                                            useLoginShell: true),
            ["pwsh", "-Command", "Get-ChildItem"])
        // `powershell` alias + unix-style path + .exe extension are recognised
        // (basename stem stripped, case-insensitive).
        XCTAssertEqual(
            ExecCommandTool._testDeriveArgv(
                line: "echo", shell: "/usr/local/bin/PowerShell.exe",
                useLoginShell: false),
            ["/usr/local/bin/PowerShell.exe", "-NoProfile", "-Command", "echo"])
    }

    func testCmdUsesSlashC() throws {
        XCTAssertEqual(
            ExecCommandTool._testDeriveArgv(line: "dir", shell: "cmd",
                                            useLoginShell: false),
            ["cmd", "/c", "dir"])
        // login flag is ignored for cmd (no login concept upstream); .exe and
        // unix-style path prefix are both handled.
        XCTAssertEqual(
            ExecCommandTool._testDeriveArgv(line: "dir", shell: "/opt/cmd.exe",
                                            useLoginShell: true),
            ["/opt/cmd.exe", "/c", "dir"])
    }
    #endif

    // MARK: Finding 1 — remote free-form command uses non-login `-c`, not `-lc`.
    // Parity with the local UnifiedExec/ShellTool default and upstream
    // `get_command` (allow_login_shell defaults false). Avoids re-introducing the
    // login-init secret side-channel the local port removed.

    #if DEBUG
    func testRemoteLineUsesNonLoginShell() throws {
        XCTAssertEqual(
            RemoteExecServerUnifiedExecTool._testLineArgv("echo hi"),
            ["/bin/sh", "-c", "echo hi"])
    }
    #endif

    // MARK: Finding 4 — remote WriteStatus rejections surface as errors.
    // Upstream `WriteStatus` (exec-server/src/protocol.rs:133-146).

    func testWriteStatusAcceptedIsSuccess() throws {
        XCTAssertNil(
            RemoteExecServerUnifiedExecTool.writeStatusRejection("accepted",
                                                                 remoteProcessId: "p1"))
        // A missing status field is treated as accepted at the call site; verify
        // the classifier itself only blesses the explicit "accepted" token.
    }

    func testWriteStatusRejectionsSurfaceErrors() throws {
        let closed = RemoteExecServerUnifiedExecTool.writeStatusRejection(
            "stdinClosed", remoteProcessId: "p1")
        XCTAssertNotNil(closed)
        XCTAssertTrue(closed!.contains("stdin is closed"), closed!)

        let unknown = RemoteExecServerUnifiedExecTool.writeStatusRejection(
            "unknownProcess", remoteProcessId: "p2")
        XCTAssertNotNil(unknown)
        XCTAssertTrue(unknown!.contains("unknown process"), unknown!)

        let starting = RemoteExecServerUnifiedExecTool.writeStatusRejection(
            "starting", remoteProcessId: "p3")
        XCTAssertNotNil(starting)
        XCTAssertTrue(starting!.contains("still"), starting!)

        // Any unrecognized status is still a rejection (fail-closed).
        let other = RemoteExecServerUnifiedExecTool.writeStatusRejection(
            "bogus", remoteProcessId: "p4")
        XCTAssertNotNil(other)
        XCTAssertTrue(other!.contains("bogus"), other!)
    }
}
