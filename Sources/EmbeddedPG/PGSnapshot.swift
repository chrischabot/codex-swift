import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// APFS copy-on-write cloning of a data directory — the macOS-native trick that
/// gives near-instant, near-zero-space snapshots of a whole Postgres cluster (or
/// any directory). `clonefile`/`copyfile(COPYFILE_CLONE)` shares blocks until one
/// side is written, so a clone of a multi-GB `PGDATA` is effectively free.
///
/// CONSISTENCY CONTRACT (important): a recursive clone of a *live*, concurrently
/// written `PGDATA` is per-file non-atomic and can produce a TORN snapshot. Always
/// quiesce first. Two safe protocols, exposed below:
///   • `cloneQuiesced` — caller guarantees no writes are in flight (held a store
///     lock and issued `CHECKPOINT`). Fast; good for backups/fixtures.
///   • cold snapshot — stop the postmaster, clone, restart (see PostgresLifecycle).
public enum PGSnapshot {
    public enum SnapshotError: Error, CustomStringConvertible, Sendable {
        case sourceMissing(String)
        case destinationExists(String)
        case cloneFailed(String, Int32)
        public var description: String {
            switch self {
            case .sourceMissing(let s): return "pg-snapshot: source missing: \(s)"
            case .destinationExists(let s): return "pg-snapshot: destination already exists: \(s)"
            case .cloneFailed(let s, let e): return "pg-snapshot: clone of \(s) failed (errno \(e): \(String(cString: strerror(e))))"
            }
        }
    }

    /// Copy-on-write clone `src` → `dst`. The destination must NOT already exist.
    /// On non-APFS volumes `COPYFILE_CLONE` transparently degrades to a full copy.
    ///
    /// The caller is responsible for quiescing the source (hold the store lock and
    /// `CHECKPOINT` before calling) — see the consistency contract above.
    public static func cloneQuiesced(from src: String, to dst: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src) else { throw SnapshotError.sourceMissing(src) }
        guard !fm.fileExists(atPath: dst) else { throw SnapshotError.destinationExists(dst) }
        try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        #if canImport(Darwin)
        // COPYFILE_CLONE = clone-if-possible-else-copy; RECURSIVE for the tree.
        // COPYFILE_CLONE already implies metadata+data+xattrs.
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
        let rc = src.withCString { s in dst.withCString { d in copyfile(s, d, nil, flags) } }
        if rc != 0 { throw SnapshotError.cloneFailed(src, errno) }
        #else
        try fm.copyItem(atPath: src, toPath: dst)
        #endif
    }

    /// Whether a path lives on a clone-capable (APFS) volume. Best-effort: probes
    /// the volume's supported-clone capability; returns true when unknown so the
    /// graceful `COPYFILE_CLONE` fallback path is still attempted.
    public static func supportsCloning(at path: String) -> Bool {
        #if canImport(Darwin)
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]),
           let supported = values.volumeSupportsFileCloning {
            return supported
        }
        #endif
        return true
    }
}
