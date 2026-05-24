import Foundation
import IPC
import ProtocolModel
import InfraPrimitives

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Spawns `codex-session` as a real OS process per session, bridged over a
/// `socketpair` with the Codable IPC envelope. This is the portable
/// realization of the process-per-session isolation model (rework §6.1/§6.3).
/// The child fd is passed as fd 3 (`CODEXKIT_IPC_FD=3`). XPC remains an
/// optional future transport behind the same `WorkerFactory` boundary if the
/// product becomes app-bundled.
public enum SpawnWorker {

    /// Resolve the `codex-session` binary: explicit override, else a sibling
    /// of the current executable (where SwiftPM puts both binaries).
    public static func sessionBinaryPath() -> String {
        if let p = ProcessInfo.processInfo.environment["CODEXKIT_SESSION_BIN"],
           !p.isEmpty { return p }
        let argv0 = CommandLine.arguments.first ?? "codexd"
        let dir = (argv0 as NSString).deletingLastPathComponent
        return dir.isEmpty ? "codex-session"
            : (dir as NSString).appendingPathComponent("codex-session")
    }

    /// A `WorkerFactory` that spawns one `codex-session` process per session.
    public static func factory(codexHome: String,
                               extraEnv: [String: String] = [:]) -> WorkerFactory {
        { cfg in
            var sv: [Int32] = [0, 0]
            #if canImport(Glibc)
            let rc = sv.withUnsafeMutableBufferPointer {
                socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, $0.baseAddress)
            }
            #else
            let rc = sv.withUnsafeMutableBufferPointer {
                socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress)
            }
            #endif
            let link = WorkerLink.make()
            guard rc == 0 else {
                // Fall back: report finished immediately (supervisor cleans up).
                let t = Task { link.sendToSupervisor(.finished) }
                return WorkerHandle(link: link, task: t)
            }
            let parentFD = sv[0]
            let childFD = sv[1]

            var env = ProcessInfo.processInfo.environment
            env["CODEXKIT_IPC_FD"] = "3"
            env["CODEX_HOME"] = codexHome
            for (k, v) in extraEnv { env[k] = v }

            let bin = sessionBinaryPath()
            var pid: pid_t = 0
            #if canImport(Darwin)
            var fa: posix_spawn_file_actions_t? = nil
            #else
            var fa = posix_spawn_file_actions_t()
            #endif
            posix_spawn_file_actions_init(&fa)
            posix_spawn_file_actions_adddup2(&fa, childFD, 3)
            posix_spawn_file_actions_addclose(&fa, childFD)
            posix_spawn_file_actions_addclose(&fa, parentFD)

            #if canImport(Darwin)
            var attrs: posix_spawnattr_t? = nil
            #else
            var attrs = posix_spawnattr_t()
            #endif
            posix_spawnattr_init(&attrs)
            posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attrs, 0)

            let argv: [UnsafeMutablePointer<CChar>?] =
                [strdup(bin), nil]
            let envp: [UnsafeMutablePointer<CChar>?] =
                env.map { strdup("\($0.key)=\($0.value)") } + [nil]

            let spawnRC = posix_spawn(&pid, bin, &fa, &attrs, argv, envp)
            posix_spawn_file_actions_destroy(&fa)
            posix_spawnattr_destroy(&attrs)
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
            close(childFD)   // parent keeps only its end

            guard spawnRC == 0 else {
                close(parentFD)
                let t = Task { link.sendToSupervisor(.finished) }
                return WorkerHandle(link: link, task: t)
            }

            let spawnedPID = pid
            ProcessIPC.runSupervisorBridge(link: link, fd: parentFD)
            let reaper = Task<Void, Never>.detached {
                var status: Int32 = 0
                _ = waitpid(spawnedPID, &status, 0)
                close(parentFD)
            }
            // The `task` is the child reaper; lifecycle parity with the
            // in-process handle (cancel ⇒ stop awaiting).
            return WorkerHandle(link: link, task: reaper, pid: Int32(spawnedPID)) {
                terminateWorkerProcess(spawnedPID)
            }
        }
    }

    static func terminateWorkerProcess(_ pid: pid_t) {
        guard pid > 0 else { return }
        _ = kill(-pid, SIGTERM)
        usleep(100_000)
        if kill(-pid, 0) == 0 {
            _ = kill(-pid, SIGKILL)
        }
        _ = kill(pid, SIGKILL)
    }
}
