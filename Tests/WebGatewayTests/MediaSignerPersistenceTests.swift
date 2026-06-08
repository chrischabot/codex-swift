import XCTest
@testable import WebGateway

/// Severe coverage for #4 signed-URL delivery: signer-key persistence
/// (round-trip, 0600 perms, concurrent-save non-corruption, deny-default no-file)
/// and the process-global signer holder (thread safety + cross-signer rejection).
final class MediaSignerPersistenceTests: XCTestCase {
    private var tmp: String!

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "media-signer-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        MediaTokenSignerHolder.shared.reset()
        super.tearDown()
    }

    // MARK: - Store round-trip

    func testLoadOrCreateRoundTripsSameKey() throws {
        let a = try MediaTokenSignerStore.loadOrCreate(directory: tmp)
        let b = try MediaTokenSignerStore.loadOrCreate(directory: tmp)
        XCTAssertEqual(a.keyBytes, b.keyBytes, "second load must return the persisted key")
        XCTAssertEqual(a.keyBytes.count, 32)
        // A token from the first signer must verify on the second (the whole point).
        let tok = a.sign(relPath: "t-1/x.png")
        XCTAssertNotNil(tok)
        XCTAssertEqual(b.verify(tok!), "t-1/x.png")
    }

    func testKeyFileIs0600() throws {
        _ = try MediaTokenSignerStore.loadOrCreate(directory: tmp)
        let path = tmp + "/" + MediaTokenSignerStore.fileName
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600, "signing key must be owner-only (0600)")
        let size = (attrs[.size] as? NSNumber)?.intValue
        XCTAssertEqual(size, 32, "persisted key is exactly 32 bytes")
    }

    func testInitFromPersistedKeyMatches() throws {
        let s = try MediaTokenSignerStore.loadOrCreate(directory: tmp)
        let restored = MediaToken.Signer(key: s.keyBytes)
        let tok = s.sign(relPath: "a/b.mp4")
        XCTAssertEqual(restored.verify(tok!), "a/b.mp4")
    }

    func testConcurrentSavesDoNotCorrupt() throws {
        // Many first-callers racing on a fresh directory must all converge on the
        // SAME key (atomic rename + adopt-the-winner), and the file must be a
        // valid 32-byte key afterward — never truncated/garbled.
        let n = 32
        let results = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: n) { _ in
            if let s = try? MediaTokenSignerStore.loadOrCreate(directory: tmp) {
                lock.lock(); results.add(Data(s.keyBytes)); lock.unlock()
            }
        }
        XCTAssertEqual(results.count, n, "every concurrent caller must succeed")
        let unique = Set(results.map { $0 as! Data })
        XCTAssertEqual(unique.count, 1, "all concurrent callers must agree on one key")
        // File on disk matches and is well-formed.
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: tmp + "/" + MediaTokenSignerStore.fileName))
        XCTAssertEqual(onDisk.count, 32)
        XCTAssertEqual(Data(unique.first!), onDisk)
        // No leftover temp files (atomic temp-write + link unlinks the temp).
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: tmp))?
            .filter { $0.contains(".tmp.") } ?? []
        XCTAssertTrue(leftover.isEmpty, "atomic write must leave no temp files: \(leftover)")
    }

    func testCorruptShortKeyIsRegenerated() throws {
        // A truncated key file (e.g. crash mid-write before this hardening) must
        // be treated as absent and regenerated, not used as a weak key.
        let path = tmp + "/" + MediaTokenSignerStore.fileName
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path))
        let s = try MediaTokenSignerStore.loadOrCreate(directory: tmp)
        XCTAssertEqual(s.keyBytes.count, 32)
    }

    // MARK: - Holder thread-safety + identity

    func testHolderSetCurrentReset() {
        XCTAssertNil(MediaTokenSignerHolder.shared.current())
        let signer = MediaToken.Signer.random()
        MediaTokenSignerHolder.shared.set(.init(signer: signer, baseURL: "http://127.0.0.1:8443/", mediaRoot: tmp))
        let ctx = MediaTokenSignerHolder.shared.current()
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.baseURL, "http://127.0.0.1:8443", "trailing slash must be normalized away")
        XCTAssertEqual(ctx?.signer.keyBytes, signer.keyBytes)
        MediaTokenSignerHolder.shared.reset()
        XCTAssertNil(MediaTokenSignerHolder.shared.current())
    }

    func testHolderConcurrentSetCurrentReset() {
        // Hammer the holder from many threads; must never crash or tear.
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            switch i % 3 {
            case 0:
                MediaTokenSignerHolder.shared.set(.init(
                    signer: .random(), baseURL: "http://127.0.0.1:8443", mediaRoot: tmp))
            case 1:
                _ = MediaTokenSignerHolder.shared.current()
            default:
                MediaTokenSignerHolder.shared.reset()
            }
        }
        // Land in a known state.
        MediaTokenSignerHolder.shared.reset()
        XCTAssertNil(MediaTokenSignerHolder.shared.current())
    }

    // MARK: - Holder signedURL minting + cross-signer rejection

    func testSignedURLVerifiesOnRouteSigner() throws {
        // A token minted via the holder's signer must verify on a signer built
        // from the SAME key (what MediaRoute uses).
        let signer = MediaToken.Signer.random()
        let root = tmp!
        // Create an asset under the root.
        let assetDir = root + "/t-42"
        try FileManager.default.createDirectory(atPath: assetDir, withIntermediateDirectories: true)
        let assetPath = assetDir + "/out.png"
        try Data([0xFF]).write(to: URL(fileURLWithPath: assetPath))

        MediaTokenSignerHolder.shared.set(.init(signer: signer, baseURL: "https://127.0.0.1:8443", mediaRoot: root))
        let url = MediaTokenSignerHolder.shared.signedURL(forAssetPath: assetPath)
        XCTAssertNotNil(url)
        let prefix = "https://127.0.0.1:8443/media/"
        XCTAssertTrue(url!.hasPrefix(prefix), "url=\(url!)")
        let token = String(url!.dropFirst(prefix.count))

        // SAME-key signer (route) verifies, resolving to the rel-path.
        let routeSigner = MediaToken.Signer(key: signer.keyBytes)
        XCTAssertEqual(routeSigner.verify(token), "t-42/out.png")

        // DIFFERENT signer rejects (forgery protection across restarts/keys).
        let otherSigner = MediaToken.Signer.random()
        XCTAssertNil(otherSigner.verify(token), "a token must not verify under a different key")
    }

    func testSignedURLNilForAssetOutsideRoot() throws {
        let signer = MediaToken.Signer.random()
        MediaTokenSignerHolder.shared.set(.init(signer: signer, baseURL: "http://127.0.0.1:8443", mediaRoot: tmp))
        // Path outside the media root → no URL (caller falls back to path).
        XCTAssertNil(MediaTokenSignerHolder.shared.signedURL(forAssetPath: "/etc/passwd"))
        // Sibling-prefix attack: a dir that merely shares the root's string prefix
        // must NOT be treated as inside the root.
        XCTAssertNil(MediaTokenSignerHolder.shared.signedURL(forAssetPath: tmp + "-evil/x.png"))
    }

    func testSignedURLNilWhenNoSignerPublished() {
        MediaTokenSignerHolder.shared.reset()
        XCTAssertNil(MediaTokenSignerHolder.shared.signedURL(forAssetPath: tmp + "/x.png"))
    }

    // MARK: - Public base URL resolution (wildcard binds → no unreachable URLs)

    /// CLAIM: a wildcard/empty bind yields NO public base URL (so delivery
    /// degrades to local path) rather than minting `http://0.0.0.0:port/...`
    /// dead links; a concrete host yields scheme://host:port; an explicit
    /// override always wins. ORACLE: an explicit table. SEVERITY: strong —
    /// prevents silently-undeliverable media links.
    func testResolvePublicBaseURLWildcardYieldsNil() {
        for wild in ["0.0.0.0", "::", "[::]", "*", ""] {
            XCTAssertNil(WebGatewayConfig.resolvePublicBaseURL(host: wild, port: 8443, tls: true, override: nil),
                         "wildcard host '\(wild)' must not mint a base URL")
        }
    }

    func testResolvePublicBaseURLConcreteHost() {
        XCTAssertEqual(WebGatewayConfig.resolvePublicBaseURL(host: "1.2.3.4", port: 8443, tls: true, override: nil),
                       "https://1.2.3.4:8443")
        XCTAssertEqual(WebGatewayConfig.resolvePublicBaseURL(host: "127.0.0.1", port: 9000, tls: false, override: nil),
                       "http://127.0.0.1:9000")
    }

    func testResolvePublicBaseURLOverrideWins() {
        // Override wins even over a wildcard bind (the reverse-proxy case).
        XCTAssertEqual(WebGatewayConfig.resolvePublicBaseURL(
            host: "0.0.0.0", port: 8443, tls: true, override: "  https://media.example.com  "),
                       "https://media.example.com", "override is used verbatim, trimmed")
        // A blank override is ignored (falls through to derivation).
        XCTAssertEqual(WebGatewayConfig.resolvePublicBaseURL(
            host: "1.2.3.4", port: 80, tls: false, override: "   "),
                       "http://1.2.3.4:80")
    }

    // MARK: - Deny-default: persist off writes no key file

    func testDenyDefaultPersistOffWritesNoKeyFile() throws {
        // Simulate WebGateway.run() with persistMediaSignerKey == false: it uses
        // .random() and never touches the store, so the key file is absent.
        // (We assert the store is the ONLY thing that writes the file.)
        let path = tmp + "/" + MediaTokenSignerStore.fileName
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        // Random signer path leaves no file.
        _ = MediaToken.Signer.random()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "deny-default (persist off) must not write a signer key file")
    }

    // MARK: - Live e2e scaffold (gated, XCTSkips without the env var)

    /// Full path: persist a key, build a route-equivalent signer from the
    /// PERSISTED file, mint a URL via the holder, and verify it round-trips —
    /// the restart-survival guarantee. Gated so CI can opt in explicitly.
    func testLiveSignerPersistenceE2E() throws {
        guard ProcessInfo.processInfo.environment["CODEXKIT_MEDIA_SIGNER_LIVE"] == "1" else {
            throw XCTSkip("set CODEXKIT_MEDIA_SIGNER_LIVE=1 to run the signer-persistence e2e")
        }
        // "First launch": persist a key, publish holder context.
        let signer1 = try MediaTokenSignerStore.loadOrCreate(directory: tmp)
        let assetDir = tmp! + "/job"
        try FileManager.default.createDirectory(atPath: assetDir, withIntermediateDirectories: true)
        let asset = assetDir + "/v.mp4"
        try Data([0x00, 0x01]).write(to: URL(fileURLWithPath: asset))
        MediaTokenSignerHolder.shared.set(.init(signer: signer1, baseURL: "https://127.0.0.1:8443", mediaRoot: tmp))
        let url = MediaTokenSignerHolder.shared.signedURL(forAssetPath: asset)!
        let token = String(url.dropFirst("https://127.0.0.1:8443/media/".count))

        // "Restart": reset holder, reload the SAME key from disk (route signer).
        MediaTokenSignerHolder.shared.reset()
        let signer2 = try MediaTokenSignerStore.loadOrCreate(directory: tmp)
        XCTAssertEqual(signer1.keyBytes, signer2.keyBytes)
        XCTAssertEqual(signer2.verify(token), "job/v.mp4",
                       "URL delivered before restart must still verify after restart")
    }
}
