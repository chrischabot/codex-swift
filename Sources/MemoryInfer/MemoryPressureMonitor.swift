import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// macOS memory-pressure monitor. Wraps `DispatchSourceMemoryPressure` and
/// publishes a `Level` to subscribers. The design doc §9 mandates an unload
/// order on the way down: reranker first, then embedder, then halt ingestion
/// before the extractor is ever evicted. This actor surfaces the signal;
/// callers (the daemon assembly) bind handlers that act on it.
///
/// On Linux this is a no-op — pressure detection there would require
/// cgroup memory pressure files, which the design doc treats as a future
/// item ("Linux is a degraded-mode target for this subsystem").
public actor MemoryPressureMonitor {
    public enum Level: Sendable, Equatable, Comparable {
        case normal, warning, critical
        public static func < (lhs: Level, rhs: Level) -> Bool {
            func r(_ l: Level) -> Int {
                switch l { case .normal: 0; case .warning: 1; case .critical: 2 }
            }
            return r(lhs) < r(rhs)
        }
    }

    public typealias Handler = @Sendable (Level) -> Void

    private var handlers: [UUID: Handler] = [:]
    private var lastLevel: Level = .normal
    #if canImport(Darwin) && os(macOS)
    private var source: (any DispatchSourceMemoryPressure)?
    #endif

    public init() {}

    /// Start watching. Must be called before any handler subscribes.
    public func start() {
        #if canImport(Darwin) && os(macOS)
        let s = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility))
        s.setEventHandler { [weak self] in
            let mask = s.data
            let level: Level
            if mask.contains(.critical) { level = .critical }
            else if mask.contains(.warning) { level = .warning }
            else { level = .normal }
            Task { await self?.publish(level) }
        }
        s.resume()
        source = s
        #endif
    }

    public func stop() {
        #if canImport(Darwin) && os(macOS)
        source?.cancel()
        source = nil
        #endif
        handlers.removeAll()
    }

    public func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    public func unsubscribe(_ id: UUID) {
        handlers[id] = nil
    }

    public func currentLevel() -> Level { lastLevel }

    /// Synthesise a level transition. Useful for tests and for the daemon's
    /// own panic-eject path when an external probe (e.g. RSS sampling) wants
    /// to drive the unload order without waiting on the kernel signal.
    public func inject(_ level: Level) {
        publish(level)
    }

    private func publish(_ level: Level) {
        guard level != lastLevel else { return }
        lastLevel = level
        for handler in handlers.values { handler(level) }
    }
}

/// Lightweight knobs that MemoryInfer reads when configuring the underlying
/// inference backend. MLX-bound builds use these to call
/// `MLX.GPU.set(cacheLimit:)` and `MLX.GPU.set(memoryLimit:relaxed:)`. The
/// remote / mock providers ignore them.
public struct InferenceResourceCaps: Sendable, Equatable {
    /// MLX GPU buffer cache ceiling, in bytes. Defaults to 4 GiB per design doc.
    public var mlxGPUCacheBytes: Int64
    /// MLX hard memory ceiling, in bytes. Defaults to 32 GiB on M3 Max 48 GB.
    public var mlxMemoryLimitBytes: Int64
    /// Whether MLX may exceed the cache ceiling temporarily. Kept for source
    /// compatibility — the modern `MLX.Memory.memoryLimit` property no
    /// longer accepts a separate `relaxed:` flag (the soft-ceiling semantics
    /// are baked in), so this field is currently informational.
    public var mlxRelaxed: Bool
    /// Optional MB target for the warning-level shed step. When set, the
    /// MemoryPressureMonitor's `warning` handler unloads the reranker once
    /// resident RSS estimates exceed this.
    public var shedRerankerAboveBytes: Int64?

    public init(mlxGPUCacheBytes: Int64 = 4 << 30,
                mlxMemoryLimitBytes: Int64 = 32 << 30,
                mlxRelaxed: Bool = true,
                shedRerankerAboveBytes: Int64? = nil) {
        self.mlxGPUCacheBytes = mlxGPUCacheBytes
        self.mlxMemoryLimitBytes = mlxMemoryLimitBytes
        self.mlxRelaxed = mlxRelaxed
        self.shedRerankerAboveBytes = shedRerankerAboveBytes
    }

    public static let `default` = InferenceResourceCaps()
}
