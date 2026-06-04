import Foundation
import Config

/// Composition helper for the #8 media suite. Builds the ONE shared ledger from
/// `[media]` config + an injected `deliver` closure. The closure is supplied by
/// the executable's composition root (which owns Push) so the Media module stays
/// Push-agnostic — Media never imports Push, avoiding a dependency cycle.
///
/// Deny-default: returns nil when the feature is off / provider unknown, so the
/// pack self-prunes and no poller is started.
public enum MediaWiring {
    /// Build (and store-recover) the shared ledger, or nil when unconfigured.
    /// `deliver` mints the user-facing notification (e.g. a push) for a finished
    /// task; returning false marks it undelivered so the poller retries.
    public static func makeLedger(addonConfig: Config, codexHome: String,
                                  env: [String: String],
                                  deliver: @escaping MediaTaskLedger.Deliver) async
    -> MediaTaskLedger? {
        guard let cfg = MediaConfig.load(config: addonConfig, codexHome: codexHome, env: env),
              let provider = MediaProviderFactory.make(cfg) else { return nil }
        // The asset write-root and (future) gateway serve-root MUST be the same
        // mediaRoot or a minted URL 404s; the provider writes under cfg.mediaRoot.
        try? FileManager.default.createDirectory(
            atPath: cfg.mediaRoot, withIntermediateDirectories: true)
        let store = FileMediaStore(directory: codexHome + "/media")
        let ledger = MediaTaskLedger(providers: [provider], deliver: deliver, store: store)
        await ledger.loadFromStore()   // recover any queued tasks from a prior run
        return ledger
    }
}
