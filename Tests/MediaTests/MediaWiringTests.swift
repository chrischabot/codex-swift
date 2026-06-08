import XCTest
import Foundation
@testable import Media
import Config

/// Severe tests for the #8 media WIRING: config read (deny-default + key
/// gating), the stub provider, the durable file store + crash recovery, the
/// daemon poller, and MediaWiring.makeLedger. Reuses StubProvider / Counter /
/// DeliverRecorder from MediaTests.swift (same target).
final class MediaWiringTests: XCTestCase {

    private func cfg(_ values: [String: ConfigValue]) -> Config {
        Config(layers: [ConfigLayer(name: "test", values: values)])
    }
    private func tmp() -> String {
        let p = NSTemporaryDirectory() + "mw-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    // MARK: config (deny-default + key gating)

    func testConfigDenyDefaultWhenFeatureOff() {
        // No [features].media → nil even with a [media] table present.
        let c = cfg(["media": .object(["provider": .string("stub")])])
        XCTAssertNil(MediaConfig.load(config: c, codexHome: "/h", env: [:]),
                     "feature off → nil (deny-default)")
    }

    func testConfigStubNeedsNoKey() {
        let c = cfg([
            "features": .object(["media": .bool(true)]),
            "media": .object(["provider": .string("stub")]),
        ])
        let mc = MediaConfig.load(config: c, codexHome: "/h", env: [:])
        XCTAssertEqual(mc?.provider, "stub")
        XCTAssertEqual(mc?.mediaRoot, "/h/media", "default media_root")
    }

    func testConfigDefaultsToStubWhenFeatureOnButNoTable() {
        let c = cfg(["features": .object(["media": .bool(true)])])
        let mc = MediaConfig.load(config: c, codexHome: "/h", env: [:])
        XCTAssertEqual(mc?.provider, "stub", "provider defaults to stub")
    }

    func testConfigNonStubRequiresKeyEnvSet() {
        let base: [String: ConfigValue] = [
            "features": .object(["media": .bool(true)]),
            "media": .object(["provider": .string("openai"), "api_key_env": .string("OPENAI_API_KEY")]),
        ]
        // Key env UNSET → nil (fail closed; never advertise a tool that errors).
        XCTAssertNil(MediaConfig.load(config: cfg(base), codexHome: "/h", env: [:]),
                     "non-stub provider without its key → nil")
        // Key env empty → nil.
        XCTAssertNil(MediaConfig.load(config: cfg(base), codexHome: "/h", env: ["OPENAI_API_KEY": ""]))
        // Key env set → config.
        let mc = MediaConfig.load(config: cfg(base), codexHome: "/h", env: ["OPENAI_API_KEY": "sk-x"])
        XCTAssertEqual(mc?.provider, "openai")
        XCTAssertEqual(mc?.apiKeyEnv, "OPENAI_API_KEY")
    }

    func testConfigExpandsCodexHomeAndEnvGate() {
        let c = cfg([
            "media": .object(["provider": .string("stub"),
                              "media_root": .string("$CODEX_HOME/assets")]),
        ])
        // Feature off via table, but CODEX_FEATURE_MEDIA=1 enables.
        let mc = MediaConfig.load(config: c, codexHome: "/home/u",
                                  env: ["CODEX_FEATURE_MEDIA": "1"])
        XCTAssertEqual(mc?.mediaRoot, "/home/u/assets", "$CODEX_HOME expanded")
    }

    /// CLAIM: `resolveMediaRoot` is the single source of truth — it returns the
    /// EXACT root `load` puts on the config, AND it resolves identically whether
    /// or not [media] sets media_root. This is the invariant that keeps the
    /// WebGateway serve/sign root aligned with where the provider writes (the
    /// signed-URL delivery only fires when the two roots match). SEVERITY: strong
    /// — a divergence here silently disables signed media delivery.
    func testResolveMediaRootIsSingleSourceOfTruth() {
        // Default (no media_root) → <codexHome>/media, and load() agrees.
        let def = cfg(["media": .object(["provider": .string("stub")])])
        XCTAssertEqual(MediaConfig.resolveMediaRoot(config: def, codexHome: "/home/u"), "/home/u/media")
        let mcDef = MediaConfig.load(config: def, codexHome: "/home/u", env: ["CODEX_FEATURE_MEDIA": "1"])
        XCTAssertEqual(mcDef?.mediaRoot, MediaConfig.resolveMediaRoot(config: def, codexHome: "/home/u"),
                       "load() and resolveMediaRoot() must never diverge")
        // Explicit override (with $CODEX_HOME) → same on both paths.
        let ovr = cfg(["media": .object(["provider": .string("stub"),
                                          "media_root": .string("$CODEX_HOME/assets")])])
        XCTAssertEqual(MediaConfig.resolveMediaRoot(config: ovr, codexHome: "/home/u"), "/home/u/assets")
        let mcOvr = MediaConfig.load(config: ovr, codexHome: "/home/u", env: ["CODEX_FEATURE_MEDIA": "1"])
        XCTAssertEqual(mcOvr?.mediaRoot, "/home/u/assets")
    }

    // MARK: stub provider

    func testStubProviderWritesAssetAndIsInline() async {
        let root = tmp(); defer { try? FileManager.default.removeItem(atPath: root) }
        let p = StubMediaProvider(mediaRoot: root)
        XCTAssertTrue(p.supports(.image))
        let r = await p.submit(kind: .image, prompt: "a cat")
        guard case .inline(let path) = r else { return XCTFail("stub must be inline, got \(r)") }
        XCTAssertTrue(path.hasPrefix(root), "asset written under mediaRoot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the placeholder file exists")
        // Poll is a no-op for an inline provider.
        let pr = await p.poll(providerTaskId: "x")
        XCTAssertEqual(pr, .pending)
    }

    func testProviderFactoryUnknownProviderIsNil() {
        XCTAssertNotNil(MediaProviderFactory.make(
            MediaConfig(provider: "stub", mediaRoot: "/t", apiKeyEnv: nil), env: [:]))
        XCTAssertNil(MediaProviderFactory.make(
            MediaConfig(provider: "totally-unknown", mediaRoot: "/t", apiKeyEnv: nil), env: [:]),
            "unknown provider → nil (deny-default)")
    }

    // MARK: durable store + crash recovery

    func testFileStoreRoundTripAndRecovery() async {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = FileMediaStore(directory: dir)
        let task = MediaTask(id: "t1", kind: .video, provider: "stub", prompt: "x",
                             status: .running, providerTaskId: "P1", deliverTo: "ntfy:v",
                             createdAt: 1)
        await store.save([task])
        // A FRESH store (simulating a daemon restart) reloads the queued task.
        let store2 = FileMediaStore(directory: dir)
        let loaded = await store2.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "t1")
        XCTAssertEqual(loaded.first?.providerTaskId, "P1")
        XCTAssertEqual(loaded.first?.status, .running)
    }

    func testLedgerRecoversQueuedTaskFromStoreAndPollerDrivesIt() async {
        let dir = tmp(); defer { try? FileManager.default.removeItem(atPath: dir) }
        // Pre-seed the store with a queued task as if a prior run crashed.
        let store = FileMediaStore(directory: dir)
        let queued = MediaTask(id: "t9", kind: .image, provider: "stub", prompt: "x",
                               status: .running, providerTaskId: "P9", deliverTo: "ntfy:a",
                               createdAt: 1)
        await store.save([queued])
        // A provider that completes P9 on the first poll.
        let provider = StubProvider(submit: .queued(providerTaskId: "ignored"),
                                    polls: [.done(assetPath: "/tmp/x.png")])
        let rec = DeliverRecorder()
        let ledger = MediaTaskLedger(providers: [provider], deliver: rec.deliver,
                                     store: store, now: { 2 }, mintId: { "n" })
        await ledger.loadFromStore()
        let before = await ledger.task("t9")
        XCTAssertEqual(before?.status, .running, "recovered as still-queued")
        // The poller drives advance → the task completes + delivers.
        let poller = MediaPoller(ledger: ledger, intervalMs: 5)
        await poller.start()
        let wasRunning = await poller.isRunning
        XCTAssertTrue(wasRunning)
        // Wait for the poller to settle it.
        var done = false
        for _ in 0..<200 {
            if await ledger.task("t9")?.status == .done { done = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await poller.stop()
        let stopped = await poller.isRunning
        XCTAssertFalse(stopped, "stop() halts the loop")
        XCTAssertTrue(done, "the daemon poller drove the recovered task to done")
        let delivered = await rec.count()
        XCTAssertEqual(delivered, 1, "and delivered it on completion")
    }

    // MARK: MediaWiring (composition helper)

    func testMakeLedgerDenyDefault() async {
        let off = cfg(["media": .object(["provider": .string("stub")])])   // feature off
        let l = await MediaWiring.makeLedger(addonConfig: off, codexHome: tmp(),
                                             env: [:], inProcessWorkers: true, deliver: { _ in true })
        XCTAssertNil(l, "feature off → no ledger (pack self-prunes, no poller)")
    }

    func testMakeLedgerOpenAIIsInlineAndRunsInBothModes() async {
        // openai (gpt-image-1) is INLINE — it returns base64 in the response
        // body, so it needs no poller and runs in BOTH spawned and in-process
        // modes. (A FUTURE truly-async backend omitted from inlineProviders would
        // still fail closed in spawned mode; see requiresPoller.)
        let c = cfg([
            "features": .object(["media": .bool(true)]),
            "media": .object(["provider": .string("openai"), "api_key_env": .string("OAI")]),
        ])
        let spawned = await MediaWiring.makeLedger(
            addonConfig: c, codexHome: tmp(), env: ["OAI": "sk-x"],
            inProcessWorkers: false, deliver: { _ in true })
        XCTAssertNotNil(spawned, "inline openai builds even in spawned mode (no poller needed)")
        let inproc = await MediaWiring.makeLedger(
            addonConfig: c, codexHome: tmp(), env: ["OAI": "sk-x"],
            inProcessWorkers: true, deliver: { _ in true })
        XCTAssertNotNil(inproc, "inline openai also builds under in-process workers")
        // Missing key env → still nil (deny-default at the config layer).
        let noKey = await MediaWiring.makeLedger(
            addonConfig: c, codexHome: tmp(), env: [:],
            inProcessWorkers: true, deliver: { _ in true })
        XCTAssertNil(noKey, "openai without its key env → nil (fail closed)")
    }

    func testRequiresPollerFalseForOpenAI() {
        let oai = MediaConfig(provider: "openai", mediaRoot: "/t", apiKeyEnv: "OAI")
        XCTAssertFalse(oai.requiresPoller, "openai is inline → no poller required")
        let stub = MediaConfig(provider: "stub", mediaRoot: "/t", apiKeyEnv: nil)
        XCTAssertFalse(stub.requiresPoller)
        let async = MediaConfig(provider: "fal", mediaRoot: "/t", apiKeyEnv: "FAL")
        XCTAssertTrue(async.requiresPoller, "an unknown/async provider still requires the poller")
    }

    func testMakeLedgerBuildsAndDeliversInlineEndToEnd() async {
        let home = tmp(); defer { try? FileManager.default.removeItem(atPath: home) }
        let c = cfg([
            "features": .object(["media": .bool(true)]),
            "media": .object(["provider": .string("stub")]),
        ])
        let rec = DeliverRecorder()
        guard let ledger = await MediaWiring.makeLedger(
            addonConfig: c, codexHome: home, env: [:],
            inProcessWorkers: true, deliver: rec.deliver) else {
            return XCTFail("media configured → ledger expected")
        }
        // Inline stub: submit completes synchronously and delivers via the
        // injected closure (no poller needed in this path).
        let t = await ledger.submit(kind: .image, prompt: "a dog", deliverTo: "ntfy:art")
        XCTAssertEqual(t.status, .done)
        XCTAssertTrue(t.assetPath?.hasPrefix(home + "/media") ?? false,
                      "asset under the configured media root: \(String(describing: t.assetPath))")
        let delivered = await rec.count()
        XCTAssertEqual(delivered, 1, "the injected deliver closure fired on the inline result")
    }

    // MARK: bounded retention (no unbounded ledger growth)

    func testTerminalTasksArePrunedBeyondRetentionCap() async {
        // Generate far more than maxRetainedTerminal inline (terminal) tasks; the
        // ledger must drop the oldest so the dict + file don't grow unbounded.
        let counter = Counter()
        let ledger = MediaTaskLedger(providers: [StubProvider(submit: .inline(assetPath: "/a"))],
                                     deliver: { _ in true },
                                     now: { 0 }, mintId: { counter.next() })
        let cap = MediaTaskLedger.maxRetainedTerminal
        for _ in 0..<(cap + 50) { _ = await ledger.submit(kind: .image, prompt: "x") }
        let all = await ledger.all()
        XCTAssertLessThanOrEqual(all.count, cap,
            "terminal tasks are pruned to the retention cap (got \(all.count))")
        XCTAssertGreaterThan(all.count, 0)
    }

    func testNonTerminalTasksAreNeverPruned() async {
        // Queued (non-terminal) tasks must survive retention even past the cap.
        let counter = Counter()
        let ledger = MediaTaskLedger(providers: [StubProvider(submit: .queued(providerTaskId: "P"))],
                                     deliver: { _ in true },
                                     now: { 0 }, mintId: { counter.next() })
        let cap = MediaTaskLedger.maxRetainedTerminal
        for _ in 0..<(cap + 50) { _ = await ledger.submit(kind: .image, prompt: "x") }
        let all = await ledger.all()
        XCTAssertEqual(all.count, cap + 50, "non-terminal tasks are never dropped")
    }

    // MARK: holder

    func testLedgerHolderSetCurrentReset() async {
        MediaLedgerHolder.shared.reset()
        XCTAssertNil(MediaLedgerHolder.shared.current())
        let ledger = MediaTaskLedger(providers: [StubProvider(submit: .inline(assetPath: "/a"))],
                                     deliver: { _ in true })
        MediaLedgerHolder.shared.set(ledger)
        XCTAssertNotNil(MediaLedgerHolder.shared.current())
        MediaLedgerHolder.shared.reset()
        XCTAssertNil(MediaLedgerHolder.shared.current(), "reset clears (feature-off / test seam)")
    }
}
