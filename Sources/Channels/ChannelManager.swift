import Foundation

// ADDONS.md #1 — the daemon-resident channel lifecycle. A `ChannelManager`
// constructs, starts, SUPERVISES (restart-with-exponential-backoff), and stops
// configured channels, all bound to one `ChannelHost`. A channel's `start(host)`
// is a long-running loop (e.g. Telegram long-poll); if it returns or throws
// unexpectedly the manager restarts it with backoff, UNLESS it was explicitly
// stopped. A per-channel `generation` counter invalidates stale restart timers
// across rapid start/stop cycles. The `sleep` seam is injected so tests drive
// backoff deterministically without real delays.
public actor ChannelManager {
    public enum RunState: String, Sendable, Equatable {
        case stopped    // never started, or explicitly stopped
        case running    // start(host) loop is live (set on spawn; see the doc on
                        // `spawn` — it flickers here briefly before a fast failure)
        case backoff    // waiting to restart after a failure
        case stopping   // stop() in progress: cancelled, awaiting transport
                        // teardown. A BARRIER — start() refuses to spawn until it
                        // settles to .stopped, so a new task can't overlap the old
                        // task's / transport's cleanup across the external await.
    }

    public struct ChannelStatus: Sendable, Equatable {
        public let id: String
        public let state: RunState
        public let attempt: Int
        public let lastError: String?
    }

    private struct Managed {
        let channel: any Channel
        var task: Task<Void, Never>?
        var state: RunState
        var attempt: Int
        var lastError: String?
        var generation: Int
    }

    private var managed: [String: Managed] = [:]
    private let host: any ChannelHost
    private let maxBackoffSeconds: Double
    private let sleep: @Sendable (Double) async -> Void

    public init(host: any ChannelHost,
                maxBackoffSeconds: Double = 60,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.host = host
        self.maxBackoffSeconds = Swift.max(0, maxBackoffSeconds)
        self.sleep = sleep
    }

    /// Register a channel (idempotent by id). Does not start it.
    public func register(_ channel: any Channel) {
        if managed[channel.id] == nil {
            managed[channel.id] = Managed(channel: channel, task: nil, state: .stopped,
                                          attempt: 0, lastError: nil, generation: 0)
        }
    }

    public func registered() -> [String] { managed.keys.sorted() }

    /// Start (or force-restart from `.backoff`) a channel. Refuses while already
    /// `.running` or mid-`.stopping` (the barrier), so a new task never overlaps
    /// an in-progress teardown. Resets the attempt counter and bumps the
    /// generation so any pending backoff restart is voided.
    public func start(_ id: String) {
        guard var m = managed[id], m.state == .stopped || m.state == .backoff else { return }
        m.task?.cancel()   // cancel a pending backoff timer when restarting from .backoff
        m.attempt = 0
        m.generation += 1
        m.task = nil
        managed[id] = m
        spawn(id, generation: m.generation)
    }

    public func startAll() { for id in managed.keys { start(id) } }

    private func spawn(_ id: String, generation: Int) {
        guard var m = managed[id], m.generation == generation else { return }
        let channel = m.channel
        let host = self.host
        m.state = .running
        let task = Task { [weak self] in
            var err: String?
            do { try await channel.start(host) }
            catch is CancellationError { return }   // explicit stop → no restart
            catch { err = "\(error)" }
            await self?.onExit(id, generation: generation, error: err)
        }
        m.task = task
        managed[id] = m
    }

    /// Called when a channel's run loop ends. Restarts with backoff unless the
    /// channel was stopped (or this is a stale generation).
    private func onExit(_ id: String, generation: Int, error: String?) async {
        guard var m = managed[id], m.generation == generation else { return }
        m.task = nil
        m.lastError = error
        // Don't restart a channel that is stopped or being stopped.
        if m.state == .stopped || m.state == .stopping { managed[id] = m; return }
        m.attempt = Swift.min(m.attempt + 1, 8)
        m.state = .backoff
        let delay = Swift.min(maxBackoffSeconds, pow(2.0, Double(m.attempt - 1)))
        let gen = generation
        // The backoff timer is OWNED by the manager (held in the task slot) so
        // stop() can cancel a pending restart. `[weak self]` prevents a runaway
        // if the owner drops the manager mid-backoff; codexd retains the manager
        // for the daemon's whole lifetime, so a legitimate restart is never
        // dropped (the only context where weak-self could lose one is a caller
        // that fails to retain the manager — a misuse).
        let timer = Task { [weak self, sleep] in
            await sleep(delay)
            await self?.restartIfBackoff(id, generation: gen)
        }
        m.task = timer
        managed[id] = m
    }

    private func restartIfBackoff(_ id: String, generation: Int) {
        guard let m = managed[id], m.generation == generation, m.state == .backoff else { return }
        spawn(id, generation: generation)
    }

    /// Stop a channel: enter the `.stopping` barrier (locks out start()), cancel
    /// the run loop / pending backoff, tell the transport to clean up, then
    /// settle to `.stopped`. The barrier is what prevents a concurrent start()
    /// from spawning a new task that races the old task's / transport's teardown
    /// across the external `channel.stop()` await.
    public func stop(_ id: String) async {
        guard var m = managed[id], m.state != .stopped else { return }   // idempotent
        m.state = .stopping
        m.generation += 1   // void any pending backoff restart
        let task = m.task
        let channel = m.channel
        m.task = nil
        managed[id] = m
        task?.cancel()
        await channel.stop()
        // Settle only if still .stopping (start() is locked out during the
        // barrier, so nothing should have changed it; re-check defensively).
        if var m2 = managed[id], m2.state == .stopping {
            m2.state = .stopped
            managed[id] = m2
        }
    }

    /// Stop every channel. Two-phase so a concurrent startAll() can't interleave:
    /// phase 1 marks all live channels `.stopping` + detaches their tasks
    /// SYNCHRONOUSLY (no await → atomic on the actor), phase 2 then awaits each
    /// transport teardown.
    public func stopAll() async {
        var pending: [(id: String, task: Task<Void, Never>?, channel: any Channel)] = []
        for (id, var m) in managed where m.state != .stopped {
            m.state = .stopping
            m.generation += 1
            let t = m.task
            let ch = m.channel
            m.task = nil
            managed[id] = m
            pending.append((id, t, ch))
        }
        for p in pending {
            p.task?.cancel()
            await p.channel.stop()
            if var m = managed[p.id], m.state == .stopping {
                m.state = .stopped
                managed[p.id] = m
            }
        }
    }

    public func status() -> [ChannelStatus] {
        managed.values
            .map { ChannelStatus(id: $0.channel.id, state: $0.state, attempt: $0.attempt, lastError: $0.lastError) }
            .sorted { $0.id < $1.id }
    }

    public func status(_ id: String) -> ChannelStatus? {
        managed[id].map { ChannelStatus(id: $0.channel.id, state: $0.state, attempt: $0.attempt, lastError: $0.lastError) }
    }
}
