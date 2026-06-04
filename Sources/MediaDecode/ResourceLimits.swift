import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX rlimits the decode CHILD imposes on ITSELF, first thing in `main`,
/// before it opens the untrusted file. Lowering a soft limit is always
/// permitted (you can only raise up to the hard limit), so this works even
/// under the Seatbelt sandbox. These backstop the header-checked ratio/pixel
/// caps: if a codec still manages to run away, the kernel kills the process.
///
/// We set the SOFT limit only and leave the hard limit alone — the kernel
/// enforces the soft limit and signals (SIGXCPU / SIGXFSZ) or fails allocation
/// (RLIMIT_AS) when it is crossed.
public enum ChildResourceLimits {
    /// Apply CPU-seconds, address-space, file-size, fd-count and no-core-dump
    /// limits derived from `caps`. Returns the list of limits it could not set
    /// (best-effort: some limits — notably RLIMIT_AS — are not enforced on every
    /// platform; the caller logs but does not abort, because the in-code caps
    /// remain the primary defense).
    @discardableResult
    public static func applySelf(_ caps: MediaDecodeCaps) -> [String] {
        let c = caps.clamped()
        var failed: [String] = []

        // No core dumps: a crash on malicious input must not write a
        // (potentially large) core file.
        if !setLimit(rlimitCore, soft: 0) { failed.append("RLIMIT_CORE") }

        // CPU seconds → SIGXCPU. The wall-clock (parent side) is the normal
        // timeout; this catches a tight busy-loop that never sleeps.
        if !setLimit(rlimitCPU, soft: rlim_t(c.cpuSeconds)) { failed.append("RLIMIT_CPU") }

        // Max bytes any single write/file may produce → SIGXFSZ. Bounds a
        // decoder that tries to spill a huge temp/output file.
        if !setLimit(rlimitFsize, soft: rlim_t(c.maxOutputBytes)) { failed.append("RLIMIT_FSIZE") }

        // Open file descriptors — a small ceiling blunts fd exhaustion. Keep
        // enough for stdio + the input + a few framework handles.
        if !setLimit(rlimitNofile, soft: 64) { failed.append("RLIMIT_NOFILE") }

        // Address space (virtual memory). Enforced on Linux; best-effort on
        // macOS (the ratio/pixel caps are the real memory guard there).
        if !setLimit(rlimitAS, soft: rlim_t(c.addressSpaceBytes)) { failed.append("RLIMIT_AS") }

        return failed
    }

    /// Set `resource`'s SOFT limit to `soft`, clamped to the inherited HARD
    /// limit — we may only lower (raising above hard would EPERM). `min` also
    /// handles an infinite hard limit (a huge sentinel) for free. Returns false
    /// if the syscall failed.
    private static func setLimit(_ resource: Int32, soft: rlim_t) -> Bool {
        var lim = rlimit()
        guard getrlimit(resource, &lim) == 0 else { return false }
        lim.rlim_cur = Swift.min(soft, lim.rlim_max)
        return setrlimit(resource, &lim) == 0
    }

    // Resource constants differ in type between platforms: on Darwin they are
    // already Int32; on Glibc they are an enum carrying `.rawValue`.
    #if canImport(Darwin)
    private static var rlimitCore: Int32 { RLIMIT_CORE }
    private static var rlimitCPU: Int32 { RLIMIT_CPU }
    private static var rlimitFsize: Int32 { RLIMIT_FSIZE }
    private static var rlimitNofile: Int32 { RLIMIT_NOFILE }
    private static var rlimitAS: Int32 { RLIMIT_AS }
    #else
    private static var rlimitCore: Int32 { Int32(RLIMIT_CORE.rawValue) }
    private static var rlimitCPU: Int32 { Int32(RLIMIT_CPU.rawValue) }
    private static var rlimitFsize: Int32 { Int32(RLIMIT_FSIZE.rawValue) }
    private static var rlimitNofile: Int32 { Int32(RLIMIT_NOFILE.rawValue) }
    private static var rlimitAS: Int32 { Int32(RLIMIT_AS.rawValue) }
    #endif
}
