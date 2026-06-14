import Foundation
import Sandbox
#if canImport(Darwin)
import Darwin
#endif

/// Daemon-side entry point: spawn the `codex-mediadecode` helper under a
/// read-only, no-network Seatbelt profile, with a parent-side wall-clock kill
/// and stdout byte cap, and return the parsed metadata. This is the ONLY API
/// `codexd` / the media suite should call for UNTRUSTED media — never the
/// in-process `MediaProber` directly.
///
/// `sandbox-exec` applies the profile to itself and `execv`s the target, so the
/// spawned `Process`'s pid IS the helper after exec — killing it on timeout
/// terminates the decode directly (no orphaned process-group to chase).
public struct SandboxedMediaDecoder: Sendable {
    /// Explicit helper-binary path; when nil it is auto-resolved next to the
    /// running daemon (then `.build/debug`, then `/usr/local/bin`).
    public let helperPath: String?

    public init(helperPath: String? = nil) { self.helperPath = helperPath }

    /// Probe `path` (asserted to be `kind`) under confinement. Never throws —
    /// every failure is a `MediaProbeError` so a malicious file can only ever
    /// produce a typed rejection, never an exception that bubbles into the
    /// daemon.
    public func probe(path: String,
                      kind: MediaKind,
                      caps rawCaps: MediaDecodeCaps = MediaDecodeCaps())
    async -> Result<MediaProbeResult, MediaProbeError> {
        let caps = rawCaps.clamped()

        // Parent-side early gate: the file must exist and be within the size cap
        // before we pay to spawn anything. (The child re-checks; this is cheap
        // defense-in-depth and avoids a spawn for the common oversize case.)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              fm.isReadableFile(atPath: path) else {
            return .failure(.unreadable)
        }
        if let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
           size > caps.maxInputBytes {
            return .failure(.oversizeInput)
        }

        guard let helper = helperPath ?? Self.resolveHelper(), fm.isExecutableFile(atPath: helper) else {
            return .failure(.helperUnavailable)
        }

        // Confinement: the shared `.readOnly` Seatbelt profile. It denies the
        // NETWORK (no exfiltration path for a compromised codec) and confines
        // writes to the base policy's temp allowance only (no project / home /
        // arbitrary-path writes) — combined with no network, a temp write has
        // nowhere to go. The helper itself only READS the input and writes its
        // tiny JSON to the inherited stdout pipe. The real resource guards
        // (memory, CPU, wall-clock) are the rlimits + the parent watchdogs below,
        // NOT the profile.
        let policy = SandboxPolicy(mode: .readOnly, writableRoots: [], networkAllowed: false)
        let sandbox = WorkspaceSandbox(policy)
        let dir = (path as NSString).deletingLastPathComponent
        let cwd = dir.isEmpty ? "/" : dir
        let argv: [String]
        switch sandbox.sandboxedInvocation(argv: [helper, kind.rawValue, path], cwd: cwd) {
        case .run(let a): argv = a
        case .deny:
            // Sandbox required but unavailable → FAIL CLOSED. Untrusted media is
            // never decoded without confinement.
            return .failure(.helperUnavailable)
        }
        return await runChild(argv: argv, caps: caps, parse: Self.parse, killFailure: { $0 })
    }

    /// Extract text (PDF → markdown) under the SAME confinement as `probe`. Never
    /// throws — every failure is a typed `MediaExtractError`. An image-only PDF
    /// returns a result with `extractionStatus: .ocrNeeded`, not an error.
    public func extract(path: String,
                        kind: MediaKind,
                        caps rawCaps: MediaDecodeCaps = .extractDefaults)
    async -> Result<MediaExtractResult, MediaExtractError> {
        let caps = rawCaps.clamped()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              fm.isReadableFile(atPath: path) else { return .failure(.unreadable) }
        if let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
           size > caps.maxInputBytes { return .failure(.oversizeInput) }
        guard let helper = helperPath ?? Self.resolveHelper(), fm.isExecutableFile(atPath: helper) else {
            return .failure(.helperUnavailable)
        }
        let policy = SandboxPolicy(mode: .readOnly, writableRoots: [], networkAllowed: false)
        let sandbox = WorkspaceSandbox(policy)
        let dir = (path as NSString).deletingLastPathComponent
        let cwd = dir.isEmpty ? "/" : dir
        let argv: [String]
        switch sandbox.sandboxedInvocation(argv: [helper, MediaVerb.extract.rawValue, kind.rawValue, path], cwd: cwd) {
        case .run(let a): argv = a
        case .deny: return .failure(.helperUnavailable)
        }
        return await runChild(argv: argv, caps: caps,
                              parse: Self.parseExtract,
                              killFailure: { MediaExtractError(probe: $0) })
    }

    // MARK: child process

    private func runChild<S, F: Error>(argv: [String], caps: MediaDecodeCaps,
                                       parse: @Sendable @escaping (Data, Int, Bool) -> Result<S, F>,
                                       killFailure: @Sendable @escaping (MediaProbeError) -> F)
    async -> Result<S, F> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv[0])
        proc.arguments = Array(argv.dropFirst())
        // Minimal, scrubbed environment + the caps the child re-clamps and uses
        // to set its own rlimits. No inherited secrets.
        var env = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        if let d = try? JSONEncoder().encode(caps), let s = String(data: d, encoding: .utf8) {
            env["CODEX_MEDIADECODE_CAPS"] = s
        }
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        let exit = ExitBox()
        proc.terminationHandler = { p in
            let code = Int(p.terminationStatus)
            let signalled = (p.terminationReason == .uncaughtSignal)
            Task { await exit.signal(code: code, signalled: signalled) }
        }
        do { try proc.run() } catch { return .failure(killFailure(.helperUnavailable)) }
        let pid = proc.processIdentifier

        // Drain stdout CONCURRENTLY (not after exit): a child writing past the OS
        // pipe capacity (~16-64 KB) would otherwise block in write() and never
        // exit, stalling us for the full wall-clock. The reader caps the kept
        // bytes but keeps draining to EOF so the child can finish/exit.
        let readFD = outPipe.fileHandleForReading.fileDescriptor
        let reader = Task.detached { Self.drainCapped(fd: readFD, cap: caps.maxOutputBytes) }

        // If WE kill the child (timeout / memory), record why. The verdict only
        // HONORS that reason when the child actually died BY SIGNAL (below) — so a
        // probe that completes the instant a watchdog fires is trusted, and a
        // stale/recycled-pid `kill` (a no-op) never turns a clean exit into a
        // false rejection. `claim` is first-writer-wins so two watchdogs can't
        // both kill.
        let killed = KillReason()

        // Wall-clock backstop.
        let waller = Task {
            do { try await Task.sleep(for: .milliseconds(caps.wallClockMs)) } catch { return }
            if Task.isCancelled { return }                       // re-check after sleep
            if await killed.claim(.timedOut) { kill(pid, SIGKILL) }
        }
        // RSS watchdog: RLIMIT_AS is inert for mmap on macOS, so the in-child
        // memory cap is best-effort there. The parent samples the child's
        // resident size and SIGKILLs it past the address-space cap — the real
        // memory ceiling on Darwin, backstopping a structural parse that balloons
        // before the header math (first line of defense) would have caught it.
        let rssCap = caps.addressSpaceBytes
        let rssWatch = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                if Task.isCancelled { return }                   // re-check after sleep
                if let rss = Self.residentBytes(pid), rss > rssCap {
                    if await killed.claim(.resourceExhausted) { kill(pid, SIGKILL) }
                    return
                }
            }
        }

        let (code, signalled) = await exit.wait()
        // Cancel AND AWAIT the watchdogs so none is still in flight when we read
        // the reason — no leaked task, no post-read kill of a recycled pid.
        waller.cancel()
        rssWatch.cancel()
        _ = await waller.value
        _ = await rssWatch.value
        proc.waitUntilExit()               // ensure the child is fully reaped
        let data = await reader.value       // EOF reached once the child is gone
        let killReason = await killed.get()

        // Honor a parent kill ONLY if it actually landed (the child died by
        // signal). A near-deadline clean exit, or a kill aimed at an
        // already-exited pid, is NOT signalled → fall through and trust the exit.
        if let r = killReason, signalled { return .failure(killFailure(r)) }
        return parse(data, code, signalled)
    }

    /// Read up to `cap` bytes from `fd`, then keep draining/discarding to EOF so
    /// the writer never blocks on a full pipe. Operates on the raw fd so it is
    /// Sendable-safe in a detached task; the owning `Pipe` closes the fd.
    static func drainCapped(fd: Int32, cap: Int) -> Data {
        var acc = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        let chunk = buf.count
        while acc.count < cap {
            let want = Swift.min(chunk, cap - acc.count)
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if n <= 0 { return acc }
            acc.append(contentsOf: buf[0..<n])
        }
        // Past the cap: discard the rest so the child can exit, bounded by the
        // wall-clock/RSS kill closing the write end.
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
            if n <= 0 { break }
        }
        return acc
    }

    static func parse(data: Data, exitCode: Int, signalled: Bool) -> Result<MediaProbeResult, MediaProbeError> {
        // A child that died by SIGNAL (an rlimit SIGXCPU/SIGXFSZ, a SIGSEGV from
        // a codec, an OOM kill) must NEVER be reported as success or a clean
        // typed rejection — even if it printed an optimistic line before dying.
        // Check `signalled` FIRST, before trusting any stdout.
        if signalled { return .failure(.childCrashed) }
        if !data.isEmpty, let resp = try? JSONDecoder().decode(MediaProbeResponse.self, from: data) {
            switch resp {
            // The child's wire contract: a successful probe exits 0, a typed
            // rejection exits 1 (Entry.swift). An `ok` payload on a NONZERO exit
            // is an inconsistent/subverted child — do not trust it as success.
            case .ok(let r):    return exitCode == 0 ? .success(r) : .failure(.childCrashed)
            case .error(let e): return .failure(e)
            }
        }
        return .failure(exitCode == 0 ? .internalError : .childCrashed)
    }

    /// Extract-verb counterpart of `parse` (same signalled-first / nonzero-exit
    /// distrust discipline, MediaExtractResponse wire shape).
    static func parseExtract(_ data: Data, _ exitCode: Int, _ signalled: Bool)
    -> Result<MediaExtractResult, MediaExtractError> {
        if signalled { return .failure(.childCrashed) }
        if !data.isEmpty, let resp = try? JSONDecoder().decode(MediaExtractResponse.self, from: data) {
            switch resp {
            case .ok(let r):    return exitCode == 0 ? .success(r) : .failure(.childCrashed)
            case .error(let e): return .failure(e)
            }
        }
        return .failure(exitCode == 0 ? .internalError : .childCrashed)
    }

    /// The child's resident set size in bytes (Darwin), or nil if unavailable.
    static func residentBytes(_ pid: pid_t) -> Int? {
        #if canImport(Darwin)
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rp)
            }
        }
        return rc == 0 ? Int(info.ri_resident_size) : nil
        #else
        return nil
        #endif
    }

    // MARK: helper resolution

    static func resolveHelper() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        // 1. Sibling of the running executable (the deployed layout).
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append(exe + "/codex-mediadecode")
        }
        if let argv0 = CommandLine.arguments.first {
            let dir = (argv0 as NSString).deletingLastPathComponent
            if !dir.isEmpty { candidates.append(dir + "/codex-mediadecode") }
        }
        // 2. SwiftPM debug/release build products (tests + dev).
        candidates.append(fm.currentDirectoryPath + "/.build/debug/codex-mediadecode")
        candidates.append(fm.currentDirectoryPath + "/.build/release/codex-mediadecode")
        // 3. Conventional install path.
        candidates.append("/usr/local/bin/codex-mediadecode")
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}

/// One-shot child-exit latch (terminationHandler may fire before or after the
/// awaiter calls `wait()`).
private actor ExitBox {
    private var pending: (code: Int, signalled: Bool)?
    private var cont: CheckedContinuation<(Int, Bool), Never>?
    func signal(code: Int, signalled: Bool) {
        if let c = cont { cont = nil; c.resume(returning: (code, signalled)) }
        else if pending == nil { pending = (code, signalled) }
    }
    func wait() async -> (Int, Bool) {
        if let p = pending { return (p.code, p.signalled) }
        return await withCheckedContinuation { cont = $0 }
    }
}

/// First-writer-wins record of which watchdog claimed the kill, so two watchdogs
/// can't both SIGKILL. The verdict additionally requires the child to have died
/// BY SIGNAL before honoring this reason (see `runChild`), so a stale-pid claim
/// can never turn a clean exit into a false rejection.
private actor KillReason {
    private var reason: MediaProbeError?
    func claim(_ r: MediaProbeError) -> Bool {
        guard reason == nil else { return false }
        reason = r
        return true
    }
    func get() -> MediaProbeError? { reason }
}
