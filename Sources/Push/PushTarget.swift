import Foundation

// ADDONS.md #7 — the Push primitive. A decoupled outbound-delivery layer: a
// fleet of `DeliverySink`s (ntfy, generic webhook, native channel relays)
// addressed by a uniform `target` STRING, fronted by a durable, retrying router
// built on the Phase 0 #4 durable-outbound core and the #1 outbound seam. It is
// the write-half of the channel spine — `codex send` / `outbound/send` /
// `push_send` all funnel through here.

/// A parsed push target: `"<scheme>:<rest>"`. The scheme selects the sink; the
/// rest is the sink-specific destination (an ntfy topic, a webhook URL, a
/// channel conversation id). Splitting on the FIRST `:` keeps URLs (which
/// contain `:`) intact in `rest`.
public struct PushTarget: Sendable, Equatable {
    public let scheme: String
    public let rest: String

    public init(scheme: String, rest: String) {
        self.scheme = scheme
        self.rest = rest
    }

    /// Parse `"ntfy:alerts"`, `"webhook:https://h/x"`, `"telegram:12345"`.
    /// Returns nil if there is no scheme or the rest is empty.
    public static func parse(_ target: String) -> PushTarget? {
        guard let idx = target.firstIndex(of: ":") else { return nil }
        let scheme = String(target[target.startIndex..<idx]).lowercased()
        let rest = String(target[target.index(after: idx)...])
        guard !scheme.isEmpty, !rest.isEmpty else { return nil }
        return PushTarget(scheme: scheme, rest: rest)
    }
}
