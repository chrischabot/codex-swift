import Foundation
import Crypto

/// Persists the gateway's media-signing HMAC key to disk so signed
/// `/media/:token` URLs survive a daemon restart (otherwise every launch mints
/// a fresh `MediaToken.Signer.random()` and all previously-delivered URLs 403).
///
/// The key lives at `<dir>/media-signer.key` as 32 raw bytes with `0600`
/// permissions (owner read/write only — it is signing-key material; whoever
/// holds it can forge media tokens). First call creates it via an EXCLUSIVE
/// `open(O_CREAT | O_EXCL, 0600)` so concurrent first-callers (threads or
/// processes) can never clobber each other — exactly one wins the create and
/// everyone else adopts that key. A truncated file (crash mid-write before this
/// hardening) is treated as absent and regenerated. Subsequent calls read it
/// back. Round-trippable: `loadOrCreate` twice over the same directory yields a
/// signer with identical `keyBytes`.
public struct MediaTokenSignerStore {
    public static let fileName = "media-signer.key"
    private static let keyLength = 32

    /// Load the persisted key (reconstructing the signer) or, on first use,
    /// generate + atomically persist a fresh 32-byte key. Throws on I/O failure
    /// so the caller can fall back to a per-launch random signer (path-only mode)
    /// rather than silently running without delivery.
    public static func loadOrCreate(directory: String) throws -> MediaToken.Signer {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let path = directory + "/" + fileName

        if let existing = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            if existing.count >= keyLength {
                // Harden perms on an existing file in case it was created loosely.
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                return MediaToken.Signer(keyBytes: Array(existing.prefix(keyLength)))
            }
            // A short/truncated file (crash mid-write before the O_EXCL+write
            // hardening, or external tampering) is NOT a usable key — remove it
            // so the exclusive-create below regenerates a full 32-byte key.
            try? fm.removeItem(atPath: path)
        }

        // Generate + persist atomically via TEMP-WRITE + `link()`. We write the
        // full 32-byte key into a per-caller-unique temp file (O_EXCL, 0600),
        // fsync it, then `link()` it onto the final path. `link()` fails with
        // EEXIST if the final path already exists — so exactly one caller's link
        // lands and the final path NEVER exists in a partially-written state (it
        // is a hardlink to an already-complete inode). This closes the
        // create-then-write window of a bare `O_CREAT|O_EXCL` (where a loser
        // could read a zero-length file and wrongly fall back to a random key,
        // splitting the signer across processes). Everyone else adopts the
        // winner's complete key, so all callers converge on one 32-byte key.
        let keyBytes = (0..<keyLength).map { _ in UInt8.random(in: 0...255) }
        let tmp = path + ".tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))"
        let tfd = tmp.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        if tfd >= 0 {
            var written = 0
            var ok = true
            keyBytes.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                while written < keyLength {
                    let n = write(tfd, base + written, keyLength - written)
                    if n <= 0 { ok = false; break }
                    written += n
                }
            }
            if ok { fsync(tfd) }
            close(tfd)
            if !ok {
                try? fm.removeItem(atPath: tmp)
                throw CocoaError(.fileWriteUnknown)
            }
            // Atomic publish. 0 → we won; EEXIST → another caller already
            // published a complete key (adopt it below).
            let linked = tmp.withCString { t in path.withCString { p in link(t, p) } }
            try? fm.removeItem(atPath: tmp)   // temp is now redundant either way
            if linked == 0 {
                return MediaToken.Signer(keyBytes: keyBytes)
            }
        }

        // Either we lost the link race, or we couldn't open a temp — adopt the
        // winner's COMPLETE key (the final path only ever appears fully written,
        // so a present file is always a usable 32-byte key). A bounded retry
        // covers the sub-millisecond gap between a peer's link and our read.
        for _ in 0..<200 {
            if let published = try? Data(contentsOf: URL(fileURLWithPath: path)),
               published.count >= keyLength {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                return MediaToken.Signer(keyBytes: Array(published.prefix(keyLength)))
            }
            usleep(1000)
        }
        throw CocoaError(.fileReadUnknown)
    }
}
