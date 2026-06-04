import Foundation

// ADDONS.md #1 — the OUTBOUND seam. Where `ChannelHost.deliver` turns an
// INBOUND message into a turn, `ChannelOutbound` turns any output (a finished
// turn, a cron tick #6, a generated media asset #8, a `codex send` / push #7)
// into an UNSOLICITED outbound push to a channel. This is the one structural
// gap the prior inbound-only contract left open. The vocabulary defined here
// (`OutboundMessage` / `OutboundAttachment` / `SinkCapabilities` /
// `OutboundReceipt`) is SHARED with the Push primitive (#7) so there is one
// outbound language across every proactive primitive.
//
// NB: this `OutboundReceipt` is deliberately distinct from
// `DeliveryCore.DeliveryReceipt` (Phase 0 #4) — that one is the durable-queue's
// per-job lifecycle record; this is a transport's immediate send acknowledgement.

/// A media asset to attach/render in an outbound message. `url` is a signed
/// media-root URL (`MediaToken`) or a local path the sink knows how to read; the
/// sink decides inline-vs-attachment by `mimeType`.
public struct OutboundAttachment: Sendable, Equatable, Codable {
    public let url: String
    public let mimeType: String?
    public let filename: String?
    public init(url: String, mimeType: String? = nil, filename: String? = nil) {
        self.url = url; self.mimeType = mimeType; self.filename = filename
    }
}

/// An unsolicited message bound for a specific conversation on some channel.
/// `conversationId` is the transport-addressable destination (a chat id, an
/// email address, an ntfy topic) — its meaning is the sink's to interpret.
public struct OutboundMessage: Sendable, Equatable, Codable {
    public let conversationId: String
    public let text: String
    public let attachments: [OutboundAttachment]
    /// Optional caller-supplied idempotency key so a durable retry layer (#4/#7)
    /// can collapse duplicate sends.
    public let idempotencyKey: String?
    public init(conversationId: String, text: String,
                attachments: [OutboundAttachment] = [], idempotencyKey: String? = nil) {
        self.conversationId = conversationId; self.text = text
        self.attachments = attachments; self.idempotencyKey = idempotencyKey
    }
}

/// What a sink supports, so a router can validate/shape a message before sending
/// (e.g. split overlong text, drop attachments a sink can't carry).
public struct SinkCapabilities: Sendable, Equatable, Codable {
    public let supportsAttachments: Bool
    /// Max text bytes per message (nil = effectively unbounded).
    public let maxTextBytes: Int?
    public init(supportsAttachments: Bool = false, maxTextBytes: Int? = nil) {
        self.supportsAttachments = supportsAttachments
        self.maxTextBytes = maxTextBytes
    }
}

/// A transport's immediate acknowledgement of one outbound send attempt.
/// `permanent` distinguishes a non-retryable failure (an egress deny, an invalid
/// destination, a 4xx client error) from a transient one (5xx / transport) so a
/// durable retry layer dead-letters the former immediately instead of hammering
/// — critical so a blocked SSRF target is not re-attempted N times.
public struct OutboundReceipt: Sendable, Equatable, Codable {
    public let ok: Bool
    public let detail: String
    public let permanent: Bool
    public init(ok: Bool, detail: String = "", permanent: Bool = false) {
        self.ok = ok; self.detail = detail; self.permanent = permanent
    }
    public static let delivered = OutboundReceipt(ok: true, detail: "delivered")
    /// A TRANSIENT failure — worth retrying.
    public static func failed(_ why: String) -> OutboundReceipt {
        OutboundReceipt(ok: false, detail: why, permanent: false)
    }
    /// A PERMANENT failure — must NOT be retried (deny / invalid / 4xx).
    public static func failedPermanent(_ why: String) -> OutboundReceipt {
        OutboundReceipt(ok: false, detail: why, permanent: true)
    }
}

/// A transport that can push an UNSOLICITED message. A `Channel` that is also a
/// `ChannelOutbound` is bidirectional (Telegram, Gmail); a pure sink (ntfy,
/// webhook — #7) is outbound-only. The Push router (#7) registers concrete
/// sinks behind this protocol; cron (#6) and media (#8) deliver through it.
public protocol ChannelOutbound: Sendable {
    /// Stable transport id (e.g. "telegram", "ntfy", "gmail").
    var id: String { get }
    var capabilities: SinkCapabilities { get }
    func send(_ message: OutboundMessage) async -> OutboundReceipt
}

public extension ChannelOutbound {
    var capabilities: SinkCapabilities { SinkCapabilities() }
}
