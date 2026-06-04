import Foundation
import MediaDecode

// codex-mediadecode — the short-lived, sandboxed media-probe child.
//
//   codex-mediadecode <kind> <path>
//   env CODEX_MEDIADECODE_CAPS = <MediaDecodeCaps JSON>   (optional)
//
// Prints exactly one MediaProbeResponse JSON object to stdout and exits 0 on a
// successful probe, 1 on a typed rejection / error. The PARENT
// (SandboxedMediaDecoder) runs this under a Seatbelt read-only/no-network
// profile with a wall-clock kill; this process additionally caps ITSELF with
// POSIX rlimits before it ever opens the untrusted file.
//
// Uses `@main async` (not a `main.swift` + semaphore) so the Swift concurrency
// runtime drives the async probe on the cooperative pool without the main
// thread blocking it into a deadlock.
@main
struct MediaDecodeMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, let kind = MediaKind(rawValue: args[0]), !args[1].isEmpty else {
            emit(.error(.internalError))
        }
        let path = args[1]
        let caps = loadCaps().clamped()

        // FIRST, before touching the untrusted file: self-impose
        // CPU/mem/file-size/fd limits. Best-effort (some are platform-dependent);
        // the header-checked caps in MediaProber + the PARENT's wall-clock/RSS
        // watchdogs are the authoritative guards, these the in-child backstop.
        // Log any limit we couldn't set (stderr is captured/visible on direct
        // runs; nulled by the sandboxed parent) for diagnosis.
        let unsetLimits = ChildResourceLimits.applySelf(caps)
        if !unsetLimits.isEmpty {
            FileHandle.standardError.write(Data(
                "codex-mediadecode: could not set rlimits: \(unsetLimits.joined(separator: ","))\n".utf8))
        }

        let response: MediaProbeResponse
        do {
            let result = try await MediaProber.probe(path: path, declaredKind: kind, caps: caps)
            response = .ok(result)
        } catch let e as MediaProbeError {
            response = .error(e)
        } catch {
            response = .error(.internalError)
        }
        emit(response)
    }

    static func loadCaps() -> MediaDecodeCaps {
        if let s = ProcessInfo.processInfo.environment["CODEX_MEDIADECODE_CAPS"],
           let d = s.data(using: .utf8),
           let c = try? JSONDecoder().decode(MediaDecodeCaps.self, from: d) {
            return c
        }
        return MediaDecodeCaps()
    }

    static func emit(_ resp: MediaProbeResponse) -> Never {
        if let data = try? JSONEncoder().encode(resp),
           let json = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data((json + "\n").utf8))
        }
        exit(resp.isOK ? 0 : 1)
    }
}
