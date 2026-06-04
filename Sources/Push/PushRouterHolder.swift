import Foundation

/// Process-global handle to the DAEMON-scope durable PushRouter so the
/// `outbound/send` RPC handler (in Supervisor.RequestRouter) and the Media
/// deliver closure can reach the one router constructed in codexd's
/// composition root WITHOUT threading it through the (large) router init.
///
/// Deny-default: stays nil unless codexd builds a router (gated on
/// `[features].push`). A nil holder means the feature is off — the dispatch
/// arm refuses with "push feature is not enabled".
///
/// Mirrors `AutomationStoreHolder` (Supervisor/Automations.swift). The NSLock
/// makes set/get safe across the daemon thread (set once at startup) and the
/// concurrent stdio/UDS/web router reads.
public final class PushRouterHolder: @unchecked Sendable {
    public static let shared = PushRouterHolder()
    private let lock = NSLock()
    private var _router: PushRouter?
    public func set(_ r: PushRouter) { lock.lock(); _router = r; lock.unlock() }
    public func current() -> PushRouter? { lock.lock(); defer { lock.unlock() }; return _router }
    /// Drop the router (feature toggled off / test seam). After this, the
    /// `outbound/send` dispatch arm refuses with "push feature is not enabled".
    public func reset() { lock.lock(); _router = nil; lock.unlock() }
}
