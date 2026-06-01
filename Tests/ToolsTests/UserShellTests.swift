import XCTest
@testable import Tools

/// Parity tests for audit exec-unified-shell finding 7: `shell_command` /
/// `exec_command` string forms must run under the user's default shell via
/// upstream `Shell::derive_exec_args` semantics, not a hardcoded /bin/sh.
final class UserShellTests: XCTestCase {

    func testExecArgsUsesResolvedShellWithDashC() {
        let argv = UserShell.execArgs(command: "echo hi")
        XCTAssertEqual(argv.count, 3, "argv must be [shell, flag, command]")
        XCTAssertEqual(argv[0], UserShell.path, "argv[0] is the resolved shell")
        XCTAssertEqual(argv[1], "-c", "default is `-c` (non-login)")
        XCTAssertEqual(argv[2], "echo hi", "argv[2] is the verbatim command")
    }

    func testExecArgsLoginShellUsesDashLC() {
        // Mirror `derive_exec_args(command, use_login_shell=true)` → `-lc`.
        let argv = UserShell.execArgs(command: "echo hi", useLoginShell: true)
        XCTAssertEqual(argv[1], "-lc", "login shell uses `-lc`")
    }

    func testResolvedPathIsAbsoluteAndExecutable() {
        let p = UserShell.path
        XCTAssertTrue(p.hasPrefix("/"), "resolved shell must be an absolute path: \(p)")
        // On macOS the resolver prefers the user's shell, then zsh, then bash;
        // the ultimate fallback is /bin/sh. Whatever it is, it must exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: p),
                      "resolved shell must exist on disk: \(p)")
    }

    func testResolvedShellActuallyRunsCommands() throws {
        // The resolved shell must be able to run a `-c` command and return its
        // output — proving the argv shape is launchable (not just a string).
        let argv = UserShell.execArgs(command: "printf usershell-ok")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv[0])
        proc.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                         as: UTF8.self)
        XCTAssertEqual(proc.terminationStatus, 0)
        XCTAssertTrue(out.contains("usershell-ok"),
                      "resolved shell must execute the `-c` command: \(out)")
    }
}
