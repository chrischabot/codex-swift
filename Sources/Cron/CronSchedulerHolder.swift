import Foundation

/// Process-global handle to the daemon's `CronScheduler` so the `cron/*` RPC
/// handlers (in Supervisor.RequestRouter) reach it WITHOUT threading it through
/// the router init. Mirrors `AutomationStoreHolder` / `PushRouterHolder`.
///
/// Deny-default: stays nil unless codexd builds a scheduler (gated on
/// `[features].cron`). A nil holder means the feature is off — cron/list replies
/// empty and cron/add refuses.
public final class CronSchedulerHolder: @unchecked Sendable {
    public static let shared = CronSchedulerHolder()
    private let lock = NSLock()
    private var _scheduler: CronScheduler?
    public func set(_ s: CronScheduler) { lock.lock(); _scheduler = s; lock.unlock() }
    public func current() -> CronScheduler? { lock.lock(); defer { lock.unlock() }; return _scheduler }
    public func reset() { lock.lock(); _scheduler = nil; lock.unlock() }
}
