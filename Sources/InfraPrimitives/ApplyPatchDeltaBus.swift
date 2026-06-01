import Foundation

/// In-process fan-out of committed `apply_patch` deltas by `callId`. Lets the
/// `apply_patch` tool surface the per-file textual changes it actually
/// committed to `SessionEngine` without widening the `Tool` protocol or
/// rereading the workspace.
///
/// Wire model: the tool publishes an opaque, already-encoded JSON payload
/// describing the committed `AppliedPatchDelta` (the `Tools` module owns the
/// concrete shape and re-decodes it). `SessionEngine` subscribes per dispatched
/// call and feeds the decoded delta into the per-turn `TurnDiffTracker`, then
/// emits a `turn/diff/updated` notification. Sinks are keyed by `callId`
/// (unique across concurrent sessions); a session subscribes when it dispatches
/// the call and unsubscribes when the dispatch resolves.
///
/// Mirrors the `ShellOutputBus` / `PlanUpdateBus` pattern so plumbing stays
/// uniform. The payload is carried as a JSON string so this lowest-level module
/// stays free of any dependency on the `Tools` model types.
public actor ApplyPatchDeltaBus {
    public static let shared = ApplyPatchDeltaBus()

    /// Sentinel payload meaning "the per-turn `TurnDiffTracker` must be
    /// invalidated" — published when an `apply_patch` fails (or succeeds with no
    /// committed delta). Mirrors upstream `TurnDiffTrackerUpdate::Invalidate`
    /// (core/src/tools/events.rs): the accumulated diff is no longer trustworthy,
    /// so the tracker is flipped invalid and any prior diff is cleared on the
    /// client. Chosen so it can never collide with a real JSON delta payload.
    public static let invalidateSentinel = "\u{0}__APPLY_PATCH_INVALIDATE__"

    public typealias Sink = @Sendable (String) -> Void

    private var sinks: [String: Sink] = [:]

    public init() {}

    public func subscribe(callId: String, _ sink: @escaping Sink) {
        sinks[callId] = sink
    }

    public func unsubscribe(callId: String) {
        sinks.removeValue(forKey: callId)
    }

    public func publish(callId: String, payloadJSON: String) {
        sinks[callId]?(payloadJSON)
    }

    /// Test/diagnostic.
    public func subscriptionCount() -> Int { sinks.count }
}
