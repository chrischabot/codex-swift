import Foundation

/// Process-global handle to the LIVE `MediaToken.Signer` (plus the gateway's
/// public base URL and media root) used by the running web gateway. Mirrors
/// `MediaLedgerHolder` / `PushRouterHolder`.
///
/// Why a holder: the codexd media-delivery closure (`MediaGlue.push`) must mint
/// a `/media/:token` URL with the EXACT SAME signing key the `/media` route
/// verifies against. The signer is created inside `WebGateway.run()`; this
/// holder is the seam that publishes it back out so the deliver closure can
/// reach it WITHOUT threading it through the daemon's construction graph.
///
/// Deny-default: stays nil unless the gateway publishes a signer. A nil holder
/// means the deliver closure falls back to pushing the local asset PATH
/// (byte-identical to pre-#4 behavior).
///
/// CRITICAL: per-PROCESS. Under spawned workers the daemon and the gateway run
/// in the SAME daemon process (the gateway task is launched from codexd.main),
/// so the holder is populated where `MediaGlue.push` runs. If media generation
/// ever moves to a separate worker process, that worker's holder is nil and it
/// correctly degrades to path delivery.
public final class MediaTokenSignerHolder: @unchecked Sendable {
    public static let shared = MediaTokenSignerHolder()

    /// The published gateway media context: signer + base URL + media root.
    public struct Context: Sendable {
        public let signer: MediaToken.Signer
        /// Public origin the browser reaches the gateway at, e.g.
        /// `https://127.0.0.1:8443` — NO trailing slash.
        public let baseURL: String
        /// Symlink-resolved media root the `/media` route serves under; the
        /// deliver closure mints a token only for assets contained here.
        public let mediaRoot: String

        public init(signer: MediaToken.Signer, baseURL: String, mediaRoot: String) {
            self.signer = signer
            // Normalize away a trailing slash so URL composition is unambiguous.
            self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            self.mediaRoot = mediaRoot
        }
    }

    private let lock = NSLock()
    private var _context: Context?

    public func set(_ c: Context) { lock.lock(); _context = c; lock.unlock() }
    public func current() -> Context? { lock.lock(); defer { lock.unlock() }; return _context }
    public func reset() { lock.lock(); _context = nil; lock.unlock() }

    /// If a signer is published AND `assetPath` resolves under the published
    /// media root, mint a signed `<baseURL>/media/<token>` URL. Returns nil to
    /// signal the caller should fall back to path delivery (no signer, asset
    /// outside the root, an unsafe rel-path, or signing failure).
    public func signedURL(forAssetPath assetPath: String, ttlSeconds: Int = 3600) -> String? {
        guard let ctx = current() else { return nil }
        let root = URL(fileURLWithPath: ctx.mediaRoot).resolvingSymlinksInPath().path
        let abs = URL(fileURLWithPath: assetPath).resolvingSymlinksInPath().path
        let prefix = root + "/"
        guard abs.hasPrefix(prefix) else { return nil }
        let relPath = String(abs.dropFirst(prefix.count))
        guard !relPath.isEmpty, let token = ctx.signer.sign(relPath: relPath, ttlSeconds: ttlSeconds) else {
            return nil
        }
        return ctx.baseURL + "/media/" + token
    }
}
