import Foundation

/// In-process bus for `request_permissions` (H-17 / P3.4). The tool publishes
/// the parsed `{reason?, permissions:{network?, file_system?}}` JSON to the
/// bus and blocks until the host returns a `RequestPermissionsResponse` JSON
/// (`{permissions, scope, strict_auto_review?}`). The host is expected to
/// route the request through its approval coordinator and possibly the user
/// before responding.
///
/// Mirrors `RequestUserInputBus`. Buses are kept narrow on purpose so the
/// `Tool` protocol stays single-method while the host owns the higher-level
/// approval-coordinator wiring.
public actor RequestPermissionsBus {
    public static let shared = RequestPermissionsBus()

    public typealias RequestSink = @Sendable (String) -> Void

    private var sinks: [String: RequestSink] = [:]
    private var pending: [String: CheckedContinuation<String?, Never>] = [:]

    public init() {}

    public func subscribe(callId: String, _ sink: @escaping RequestSink) {
        sinks[callId] = sink
    }

    public func unsubscribe(callId: String) {
        sinks.removeValue(forKey: callId)
        if let pending = pending.removeValue(forKey: callId) {
            pending.resume(returning: nil)
        }
    }

    public func ask(callId: String, payloadJSON: String) async -> String? {
        sinks[callId]?(payloadJSON)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            if let prev = pending[callId] {
                prev.resume(returning: nil)
            }
            pending[callId] = cont
        }
    }

    public func respond(callId: String, replyJSON: String) {
        if let cont = pending.removeValue(forKey: callId) {
            cont.resume(returning: replyJSON)
        }
    }

    public func subscriptionCount() -> Int { sinks.count }
    public func pendingCount() -> Int { pending.count }
}
