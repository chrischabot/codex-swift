import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Resolve the user's default login shell and build the argv for running a
/// free-form command string under it, mirroring upstream `core/src/shell.rs`
/// (`default_user_shell` + `Shell::derive_exec_args`).
///
/// Upstream derives `[shell_path, use_login_shell ? "-lc" : "-c", command]` for
/// the user's actual shell. On macOS it prefers the user's configured shell
/// (from `$SHELL` / `getpwuid`), then falls back to zsh, then bash; on other
/// unixes it prefers the user shell, then bash, then zsh. The legacy `/bin/sh`
/// hardcode (POSIX dash-like) broke zsh/bash-specific syntax that
/// upstream-trained models rely on.
public enum UserShell {

    /// Cached resolved shell path; resolution is process-stable.
    private static let resolvedPath: String = resolveDefaultShellPath()

    /// The resolved default shell binary (absolute path). Always non-empty;
    /// falls back to `/bin/sh` only if nothing else is found.
    public static var path: String { resolvedPath }

    /// Build the launch argv for a free-form command string, matching
    /// `Shell::derive_exec_args`. `useLoginShell` selects `-lc` vs `-c`.
    public static func execArgs(command: String,
                                useLoginShell: Bool = false) -> [String] {
        [resolvedPath, useLoginShell ? "-lc" : "-c", command]
    }

    private static func fileExists(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    /// Mirror upstream `get_user_shell_path`: the login shell from the passwd
    /// database for the current uid. We also accept `$SHELL` as a faster path
    /// (it is set to the same value in normal interactive sessions).
    private static func userShellPath() -> String? {
        if let s = ProcessInfo.processInfo.environment["SHELL"],
           !s.isEmpty, fileExists(s) {
            return s
        }
        let uid = getuid()
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = nil
        var bufLen = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        if bufLen <= 0 { bufLen = 1024 }
        var buffer = [CChar](repeating: 0, count: Int(bufLen))
        let rc = buffer.withUnsafeMutableBufferPointer { buf -> Int32 in
            getpwuid_r(uid, &pwd, buf.baseAddress, buf.count, &result)
        }
        guard rc == 0, result != nil, let shellC = pwd.pw_shell else {
            return nil
        }
        let shell = String(cString: shellC)
        return shell.isEmpty ? nil : shell
    }

    private static func resolveDefaultShellPath() -> String {
        // 1. User's configured login shell.
        if let s = userShellPath(), fileExists(s) { return s }
        // 2/3. Platform-ordered fallbacks (macOS: zsh then bash; else bash
        //      then zsh), then the ultimate `/bin/sh` fallback.
        #if os(macOS)
        let fallbacks = ["/bin/zsh", "/bin/bash"]
        #else
        let fallbacks = ["/bin/bash", "/usr/bin/bash", "/bin/zsh"]
        #endif
        for p in fallbacks where fileExists(p) { return p }
        return "/bin/sh"
    }
}
