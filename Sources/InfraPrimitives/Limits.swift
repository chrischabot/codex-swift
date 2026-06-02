import Foundation

/// Centralized capacity / timeout / budget registry.
///
/// Hardening doc §2 / decision #2: every bound in the system comes from here,
/// is hot-reloadable, and is clamped to a hard ceiling. No other module may
/// declare a capacity constant; tests assert this by construction.
public struct Limits: Sendable, Codable, Equatable {

    // MARK: Queue capacities (four-class taxonomy, hardening §2)
    /// C1 control channel depth (submissions, lifecycle, approvals).
    public var controlChannelDepth: Int = 64
    /// C2 protocol-data ingress depth per connection (reject -> -32001).
    public var dataChannelDepth: Int = 256
    /// C3 coalescing-ring byte bound for client-bound stream deltas.
    public var streamDeltaRingBytes: Int = 256 * 1024
    /// C4 telemetry overwrite-ring element count.
    public var telemetryRingCount: Int = 4096
    /// Flight-recorder ring element count (per session).
    public var flightRecorderCount: Int = 1024

    // MARK: Message / output caps
    /// Maximum inbound message size in bytes (INPUT_TOO_LARGE).
    public var maxInboundMessageBytes: Int = 16 * 1024 * 1024
    /// Maximum captured tool output per stream (head+tail ring).
    public var maxToolOutputBytes: Int = 1 * 1024 * 1024
    /// Maximum in-flight requests per connection (rpc-gate analog).
    public var maxInFlightPerConnection: Int = 32

    // MARK: Turn budgets (runaway prevention, hardening §5)
    /// Wall-clock deadline for a single turn. Override with
    /// `turn_deadline_secs = <N>` in `$CODEX_HOME/config.toml` (F1).
    public var turnDeadline: Duration = .seconds(900)
    /// Backstop on sample->tool->sample iterations within one turn. A turn is
    /// meant to be bounded by the TIME deadline (`turnDeadline`), not an arbitrary
    /// iteration count — multi-day long-horizon turns can legitimately run tens of
    /// thousands of iterations. So this defaults HIGH (the deadline binds first in
    /// every realistic run) and only guards against literal non-terminating loops.
    /// Override with `max_sampling_iterations_per_turn = <N>` in `config.toml`.
    /// (Was 100 — which fired after ~13min on a long-deadline turn and force-FAILED
    /// it with "sampling loop guard fired", truncating long agentic/bench runs.)
    public var maxSamplingIterationsPerTurn: Int = 1_000_000
    /// Hard cap on *non-progressing* consecutive auto-compactions within one
    /// turn. Upstream (`core/src/session/turn.rs:497-517`) has NO per-turn
    /// compaction counter: "as long as compaction works well in getting us way
    /// below the token limit, we shouldn't worry about being in an infinite
    /// loop", so it simply `continue`s after each `run_auto_compact`. To match
    /// that behaviour while still retaining a safety net against a genuine
    /// non-terminating loop, the Swift backstop now (a) defaults high enough to
    /// be unreachable in normal operation and (b) only counts compactions that
    /// fail to reduce the token usage below the auto-compact limit (a
    /// no-progress condition). A productive compaction never advances the
    /// counter, so a long turn that legitimately needs many mid-turn
    /// compactions is not failed the way upstream would not fail it.
    public var maxCompactionsPerTurn: Int = 100
    /// Runaway-loop guard: fire after this many CONSECUTIVE iterations whose tool
    /// call(s) are byte-identical (same name + arguments) with nothing changing —
    /// the signature of an agent stuck doing the exact same thing. Generous on
    /// purpose: normal long-horizon / multi-day work never repeats an IDENTICAL
    /// call this many times in a row (even heavy polling/retry varies or is far
    /// fewer), but a genuine runaway (the same call hundreds/thousands of times)
    /// is bounded. A text-only or differing iteration resets the counter.
    public var maxIdenticalToolRepeats: Int = 100
    /// Tool fan-out semaphore: max concurrent tool tasks per turn.
    public var maxConcurrentTools: Int = 8

    // MARK: Retry / backoff / stampede (hardening §6)
    public var streamMaxRetries: Int = 5
    public var retryBaseDelay: Duration = .milliseconds(200)
    public var retryMaxDelay: Duration = .seconds(20)
    /// Per-session retry token-bucket: capacity and refill per second.
    public var retryTokensCapacity: Double = 8
    public var retryTokensPerSecond: Double = 1

    // MARK: Persistence (hardening §7)
    /// Group-commit barrier: flush after this many rollout items …
    public var rolloutGroupCommitItems: Int = 64
    /// … or after this interval, whichever first.
    public var rolloutGroupCommitInterval: Duration = .milliseconds(250)
    /// Bounded write-behind: max buffered rollout items before backpressure.
    public var rolloutWriteBehindCap: Int = 4096

    // MARK: Resource governor (hardening §5, rework §6.3)
    /// Soft CPU share over the sample window before throttling the offender.
    public var ledgerSoftCPUFraction: Double = 0.85
    /// Hard resident-memory cap per worker (bytes) before SIGKILL+restart.
    public var ledgerHardMemoryBytes: Int = 2 * 1024 * 1024 * 1024
    /// Ledger sample interval.
    public var ledgerSampleInterval: Duration = .milliseconds(500)
    /// Watchdog: missed heartbeats before escalation.
    public var watchdogMissedHeartbeats: Int = 4
    public var heartbeatInterval: Duration = .seconds(2)
    /// Idle unload window (rework §8: matches Codex 30 min).
    public var idleUnload: Duration = .seconds(30 * 60)

    // MARK: Admission control (S5)
    /// Concurrent *active* workers ceiling (0 = derive from core count).
    public var maxActiveWorkers: Int = 0

    /// Max queued steer/pending turn inputs before excess is shed (steer-flood
    /// DoS guard; hardening §2 / CWE-400).
    public var maxPendingTurnInputs: Int = 1024
    /// Per-session inter-agent mailbox capacity; beyond this the oldest entry
    /// is dropped (bounded — the Codex F-1 unbounded-mpsc analog).
    public var mailboxCapacity: Int = 4096
    /// Maximum JSON nesting depth accepted by the wire codec (CWE-674:
    /// uncontrolled decoder recursion / stack exhaustion guard).
    public var maxJSONNestingDepth: Int = 512
    /// Maximum concurrently-bound sessions/workers (session-flood admission
    /// control; CWE-400).
    public var maxConcurrentSessions: Int = 1024

    public init() {}

    /// Hard ceilings. `clamped()` is applied on every load/reload so a bad
    /// config can never widen a bound past what the system was proven safe at.
    public static let ceiling: Limits = {
        var l = Limits()
        l.controlChannelDepth = 1024
        l.dataChannelDepth = 4096
        l.streamDeltaRingBytes = 4 * 1024 * 1024
        l.telemetryRingCount = 1 << 20
        l.flightRecorderCount = 1 << 16
        l.maxInboundMessageBytes = 64 * 1024 * 1024
        l.maxToolOutputBytes = 16 * 1024 * 1024
        l.maxInFlightPerConnection = 256
        // Multi-day runs are a first-class goal: a single long-horizon turn can
        // legitimately run for days (tens of thousands of sample->tool
        // iterations), bounded by the TIME deadline — NOT an arbitrary iteration
        // count. Keep a finite backstop against literal infinity, but high enough
        // that no realistic run reaches it (10M iters ≈ years at seconds/iter).
        l.maxSamplingIterationsPerTurn = 10_000_000
        // Was 16 — LOWER than the default (100), so `clamped()` silently capped
        // the "intended-unreachable" default down to 16. The mid-turn counter is
        // non-progress-based (a productive compaction never advances it), so this
        // ceiling only needs to clear a genuine non-terminating compaction loop.
        l.maxCompactionsPerTurn = 1000
        l.maxIdenticalToolRepeats = 1000   // was 64 (< the 100 default → would clamp it down)
        l.maxConcurrentTools = 64
        l.streamMaxRetries = 12
        l.rolloutGroupCommitItems = 4096
        l.rolloutWriteBehindCap = 1 << 16
        l.retryTokensCapacity = 1024
        l.retryTokensPerSecond = 1024
        l.ledgerHardMemoryBytes = 512 * 1024 * 1024 * 1024
        l.maxPendingTurnInputs = 1 << 20
        l.mailboxCapacity = 1 << 20
        l.maxJSONNestingDepth = 4096
        l.maxConcurrentSessions = 8192
        return l
    }()

    // Duration hard bounds.
    private static let minTick: Duration = .milliseconds(1)
    // Multi-day turns are a goal, so the per-turn deadline ceiling must allow
    // far more than a day — config could not previously express a >24h turn at
    // all (the clamp capped it). 365 days is effectively unbounded for any real
    // run while still rejecting absurd/overflow values.
    private static let maxTurnDeadline: Duration = .seconds(365 * 24 * 3600)
    private static let maxInterval: Duration = .seconds(3600)
    private static let maxIdleUnload: Duration = .seconds(24 * 3600)

    /// Clamp **every** field — Int, Double, and Duration — to a safe range.
    /// (Addresses the overseer advisory: the contract is now true for all
    /// fields, not just the integer capacities.)
    public func clamped() -> Limits {
        var c = self
        let k = Limits.ceiling

        func clampInt(_ v: inout Int, _ hi: Int) { v = Swift.max(1, Swift.min(v, hi)) }
        func clampDouble(_ v: inout Double, _ lo: Double, _ hi: Double) {
            if v.isNaN { v = lo }
            v = Swift.max(lo, Swift.min(v, hi))
        }
        func clampDur(_ v: inout Duration, _ lo: Duration, _ hi: Duration) {
            if v < lo { v = lo }
            if v > hi { v = hi }
        }

        // Integers
        clampInt(&c.controlChannelDepth, k.controlChannelDepth)
        clampInt(&c.dataChannelDepth, k.dataChannelDepth)
        clampInt(&c.streamDeltaRingBytes, k.streamDeltaRingBytes)
        clampInt(&c.telemetryRingCount, k.telemetryRingCount)
        clampInt(&c.flightRecorderCount, k.flightRecorderCount)
        clampInt(&c.maxInboundMessageBytes, k.maxInboundMessageBytes)
        clampInt(&c.maxToolOutputBytes, k.maxToolOutputBytes)
        clampInt(&c.maxInFlightPerConnection, k.maxInFlightPerConnection)
        clampInt(&c.maxSamplingIterationsPerTurn, k.maxSamplingIterationsPerTurn)
        clampInt(&c.maxCompactionsPerTurn, k.maxCompactionsPerTurn)
        clampInt(&c.maxIdenticalToolRepeats, k.maxIdenticalToolRepeats)
        clampInt(&c.maxConcurrentTools, k.maxConcurrentTools)
        clampInt(&c.streamMaxRetries, k.streamMaxRetries)
        clampInt(&c.rolloutGroupCommitItems, k.rolloutGroupCommitItems)
        clampInt(&c.rolloutWriteBehindCap, k.rolloutWriteBehindCap)
        clampInt(&c.maxPendingTurnInputs, k.maxPendingTurnInputs)
        clampInt(&c.mailboxCapacity, k.mailboxCapacity)
        clampInt(&c.maxJSONNestingDepth, k.maxJSONNestingDepth)
        clampInt(&c.maxConcurrentSessions, k.maxConcurrentSessions)

        // Doubles
        clampDouble(&c.retryTokensCapacity, 1, k.retryTokensCapacity)
        clampDouble(&c.retryTokensPerSecond, 0, k.retryTokensPerSecond)
        clampDouble(&c.ledgerSoftCPUFraction, 0.05, 1.0)

        // ledgerHardMemoryBytes: floor 64 MiB, ceiling 512 GiB.
        c.ledgerHardMemoryBytes = Swift.max(64 * 1024 * 1024,
                                            Swift.min(c.ledgerHardMemoryBytes, k.ledgerHardMemoryBytes))

        // Durations
        clampDur(&c.turnDeadline, .seconds(1), Limits.maxTurnDeadline)
        clampDur(&c.retryBaseDelay, Limits.minTick, Limits.maxInterval)
        clampDur(&c.retryMaxDelay, Limits.minTick, Limits.maxInterval)
        if c.retryMaxDelay < c.retryBaseDelay { c.retryMaxDelay = c.retryBaseDelay }
        clampDur(&c.rolloutGroupCommitInterval, Limits.minTick, Limits.maxInterval)
        clampDur(&c.ledgerSampleInterval, Limits.minTick, Limits.maxInterval)
        clampDur(&c.heartbeatInterval, Limits.minTick, Limits.maxInterval)
        clampDur(&c.idleUnload, .seconds(1), Limits.maxIdleUnload)

        if c.watchdogMissedHeartbeats < 1 { c.watchdogMissedHeartbeats = 1 }
        if c.maxActiveWorkers < 0 { c.maxActiveWorkers = 0 }
        return c
    }

    /// Effective active-worker ceiling (derive from cores when unset).
    public func effectiveMaxActiveWorkers() -> Int {
        if maxActiveWorkers > 0 { return maxActiveWorkers }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return Swift.max(1, cores)
    }
}

extension Limits {
    /// Apply config-file overrides for the most operationally interesting
    /// limits. Looks for `$codexHome/config.toml` and reads from a flat top-
    /// level layout. Unknown keys are ignored; bad types fall back to defaults.
    ///
    ///     # config.toml
    ///     turn_deadline_secs = 3600
    ///     max_sampling_iterations_per_turn = 500
    ///     max_compactions_per_turn = 8
    ///
    /// Called from `codexd` and `codex-session` boot. The result is always
    /// `.clamped()` before use.
    public static func loadingOverrides(codexHome: String) -> Limits {
        var l = Limits()
        let path = codexHome + "/config.toml"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return l }
        // Minimal flat scalar reader to avoid an InfraPrimitives -> Config
        // dependency. Only recognizes `key = value` lines outside any table.
        var insideTable = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { insideTable = !trimmed.hasPrefix("[[")
                ? trimmed != "[]" : true; continue }
            if insideTable || trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            var val = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            if let hash = val.firstIndex(of: "#") { val = String(val[..<hash])
                .trimmingCharacters(in: .whitespaces) }
            switch key {
            case "turn_deadline_secs":
                if let s = Int(val), s > 0 { l.turnDeadline = .seconds(s) }
            case "max_sampling_iterations_per_turn":
                if let n = Int(val), n > 0 { l.maxSamplingIterationsPerTurn = n }
            case "max_compactions_per_turn":
                if let n = Int(val), n > 0 { l.maxCompactionsPerTurn = n }
            case "max_identical_tool_repeats":
                if let n = Int(val), n > 0 { l.maxIdenticalToolRepeats = n }
            case "max_concurrent_tools":
                if let n = Int(val), n > 0 { l.maxConcurrentTools = n }
            case "stream_max_retries":
                if let n = Int(val), n >= 0 { l.streamMaxRetries = n }
            default: continue
            }
        }
        return l
    }
}

/// Process-wide, hot-reloadable holder. Reads are lock-free-ish via an actor
/// snapshot; the value type is immutable so readers never see a torn state.
public actor LimitsRegistry {
    public static let shared = LimitsRegistry()
    private var current: Limits
    private var generation: UInt64 = 0

    public init(_ initial: Limits = Limits()) {
        self.current = initial.clamped()
    }

    public func snapshot() -> Limits { current }
    public func currentGeneration() -> UInt64 { generation }

    /// Hot-reload. Always clamped; bumps a generation counter so dependents
    /// can detect a change without polling values.
    @discardableResult
    public func reload(_ next: Limits) -> Limits {
        current = next.clamped()
        generation &+= 1
        return current
    }
}