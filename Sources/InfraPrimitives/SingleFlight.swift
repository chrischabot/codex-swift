import Foundation

/// Coalesces concurrent work for the same key into a single in-flight
/// operation; all callers await the same result. Hardening §6 (auth-refresh /
/// catalog-refresh stampede) / decision #8.
public actor SingleFlight<Key: Hashable & Sendable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Error>] = [:]
    public private(set) var coalescedCount: Int = 0

    public init() {}

    /// Run `operation` for `key`; if one is already running, await it instead
    /// of starting another. Exactly one upstream call happens per key per
    /// in-flight window.
    public func run(_ key: Key,
                    _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let existing = inFlight[key] {
            coalescedCount += 1
            return try await existing.value
        }
        let task = Task<Value, Error> { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}