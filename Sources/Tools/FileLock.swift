import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX advisory file-locking helpers. Mirrors upstream
/// `codex-rs/execpolicy/src/amend.rs::append_locked_line` semantics —
/// `file.lock()` in Rust maps to `flock(LOCK_EX)` on Unix; the reader-side
/// equivalent is `flock(LOCK_SH)`.
///
/// The helpers `withExclusiveLock` / `withSharedLock` open the file, acquire
/// the lock, run the closure with the underlying file descriptor, and ensure
/// the lock is released and the descriptor closed before returning — even on
/// throw. Used by `RulesStore` (and any future caller) so multi-process reads
/// and writes against `$CODEX_HOME/rules/default.rules` cannot tear.
enum FileLock {
    enum LockError: Error, LocalizedError {
        case open(path: String, message: String)
        case lock(path: String, message: String)

        var errorDescription: String? {
            switch self {
            case .open(let path, let message):
                return "failed to open \(path): \(message)"
            case .lock(let path, let message):
                return "failed to lock \(path): \(message)"
            }
        }
    }

    /// Acquire `LOCK_EX` on `path` (creating it if needed; mode 0644). Matches
    /// upstream's `OpenOptions::new().create(true).read(true).append(true)`
    /// open flags so multiple writers can take turns appending under the lock.
    static func withExclusiveLock<T>(
        path: String,
        _ body: (Int32) throws -> T
    ) throws -> T {
        try withLock(path: path,
                     openFlags: O_RDWR | O_CREAT,
                     lockOp: LOCK_EX,
                     body: body)
    }

    /// Acquire `LOCK_SH` on `path`. The file must already exist — pre-check
    /// with `FileManager.fileExists` before calling.
    static func withSharedLock<T>(
        path: String,
        _ body: (Int32) throws -> T
    ) throws -> T {
        try withLock(path: path,
                     openFlags: O_RDONLY,
                     lockOp: LOCK_SH,
                     body: body)
    }

    private static func withLock<T>(
        path: String,
        openFlags: Int32,
        lockOp: Int32,
        body: (Int32) throws -> T
    ) throws -> T {
        // 0644 — match upstream's default file mode when create is requested.
        let fd: Int32 = path.withCString { c in
            // O_CREAT requires a mode argument on Darwin/Linux.
            open(c, openFlags, mode_t(0o644))
        }
        if fd < 0 {
            throw LockError.open(path: path,
                                 message: String(cString: strerror(errno)))
        }
        defer { _ = close(fd) }

        // Retry through EINTR — slow disks / signals can briefly interrupt
        // flock the same way they interrupt other syscalls.
        while true {
            let rc = flock(fd, lockOp)
            if rc == 0 { break }
            if errno == EINTR { continue }
            throw LockError.lock(path: path,
                                 message: String(cString: strerror(errno)))
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try body(fd)
    }
}
