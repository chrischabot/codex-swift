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
        // `stat <path>` → statOnly (kind-agnostic byte stat). Handled first because it
        // takes no MediaKind. Never returns.
        if args.count == 2, MediaVerb(rawValue: args[0]) == .statOnly, !args[1].isEmpty {
            runStat(path: args[1])
        }
        // 2 args = `<kind> <path>` → probe (back-compat). 3 args = `<verb> <kind> <path>`.
        let verb: MediaVerb
        let kindStr: String
        let path: String
        if args.count == 2 {
            verb = .probe; kindStr = args[0]; path = args[1]
        } else if args.count == 3, let v = MediaVerb(rawValue: args[0]) {
            verb = v; kindStr = args[1]; path = args[2]
        } else {
            emit(.error(.internalError))   // shared {"error":...} envelope; exits 1
        }
        guard let kind = MediaKind(rawValue: kindStr), !path.isEmpty else { emit(.error(.internalError)) }
        let caps = loadCaps().clamped()

        // FIRST, before touching the untrusted file: self-impose
        // CPU/mem/file-size/fd limits. Best-effort; the header-checked caps + the
        // PARENT's wall-clock/RSS watchdogs are authoritative, these the backstop.
        let unsetLimits = ChildResourceLimits.applySelf(caps)
        if !unsetLimits.isEmpty {
            FileHandle.standardError.write(Data(
                "codex-mediadecode: could not set rlimits: \(unsetLimits.joined(separator: ","))\n".utf8))
        }

        switch verb {
        case .probe:
            let response: MediaProbeResponse
            do { response = .ok(try await MediaProber.probe(path: path, declaredKind: kind, caps: caps)) }
            catch let e as MediaProbeError { response = .error(e) }
            catch { response = .error(.internalError) }
            emit(response)
        case .extract:
            let response: MediaExtractResponse
            do { response = .ok(try MediaExtractor.extract(path: path, declaredKind: kind, caps: caps)) }
            catch let e as MediaExtractError { response = .error(e) }
            catch { response = .error(.internalError) }
            emitExtract(response)
        case .statOnly:
            runStat(path: path)   // unreachable (handled before kind parse); defensive
        }
    }

    /// The `statOnly` path: self-limit, then bounded byte-stat. Kind-agnostic, so it
    /// never goes through the MediaKind parse. Never returns.
    static func runStat(path: String) -> Never {
        let caps = loadCaps().clamped()
        let unset = ChildResourceLimits.applySelf(caps)
        if !unset.isEmpty {
            FileHandle.standardError.write(Data("codex-mediadecode: could not set rlimits: \(unset.joined(separator: ","))\n".utf8))
        }
        let response: MediaStatResponse
        do { response = .ok(try MediaStatter.stat(path: path, caps: caps)) }
        catch let e as MediaExtractError { response = .error(e) }
        catch { response = .error(.internalError) }
        emitStat(response)
    }

    static func emitStat(_ resp: MediaStatResponse) -> Never {
        if let data = try? JSONEncoder().encode(resp), let json = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data((json + "\n").utf8))
        }
        exit(resp.isOK ? 0 : 1)
    }

    static func emitExtract(_ resp: MediaExtractResponse) -> Never {
        if let data = try? JSONEncoder().encode(resp), let json = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data((json + "\n").utf8))
        }
        exit(resp.isOK ? 0 : 1)
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
