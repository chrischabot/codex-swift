import Foundation

/// Daemon-resident driver: loops `ledger.advance()` on an interval so QUEUED
/// (async-provider) tasks reach `done` and undelivered-but-done tasks get their
/// bounded delivery retries. Cancellable — codexd stops it on SIGTERM/SIGINT so
/// the loop doesn't outlive the daemon.
///
/// For an INLINE-only provider (the MVP stub) the poller is a harmless no-op
/// (every task is already terminal + delivered on submit). It exists so the
/// moment a `.queued` provider is configured, queued work is driven.
public actor MediaPoller {
    private let ledger: MediaTaskLedger
    private let intervalNanos: UInt64
    private var task: Task<Void, Never>?

    public init(ledger: MediaTaskLedger, intervalMs: UInt64 = 1000) {
        self.ledger = ledger
        self.intervalNanos = intervalMs * 1_000_000
    }

    /// Start the drive loop. Idempotent — a second call while running is a no-op.
    public func start() {
        guard task == nil else { return }
        let ledger = ledger
        let intervalNanos = intervalNanos
        task = Task {
            while !Task.isCancelled {
                _ = await ledger.advance()
                try? await Task.sleep(nanoseconds: intervalNanos)
            }
        }
    }

    /// Stop the loop (cancellation). Safe to call when not running.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Test seam: is the drive loop currently active?
    public var isRunning: Bool { task != nil }
}
