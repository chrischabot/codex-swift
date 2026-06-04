import Foundation

/// Process-global handle to the ONE `MediaTaskLedger` so the daemon-resident
/// `MediaPoller` and the per-session `media_generate` tool share a single
/// ledger WITHOUT threading it through the engine factory. Mirrors
/// `PushRouterHolder` / `AutomationStoreHolder`.
///
/// Deny-default: stays nil unless `MediaWiring.makeLedger` returns a ledger
/// (gated on `[features].media`). A nil holder means the tool self-prunes and
/// no poller runs — byte-identical to feature-off.
///
/// CRITICAL: the holder is per-PROCESS. Under spawned workers (the default) the
/// daemon and each worker are separate processes with separate holders, so the
/// daemon's poller can NOT drive a worker's ledger. The inline stub provider is
/// safe there (it delivers synchronously); an async provider would wedge and so
/// requires in-process workers.
public final class MediaLedgerHolder: @unchecked Sendable {
    public static let shared = MediaLedgerHolder()
    private let lock = NSLock()
    private var _ledger: MediaTaskLedger?
    public func set(_ l: MediaTaskLedger) { lock.lock(); _ledger = l; lock.unlock() }
    public func current() -> MediaTaskLedger? { lock.lock(); defer { lock.unlock() }; return _ledger }
    public func reset() { lock.lock(); _ledger = nil; lock.unlock() }
}
