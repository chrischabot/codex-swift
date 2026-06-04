import Foundation
import Channels
import EgressGuard

// The HTTP-backed sinks (ntfy, generic webhook) + the injectable HTTP seam. Both
// route their outbound HTTP through the EgressGuard chokepoint (Phase 0 #5)
// BEFORE connecting, so a model- or config-supplied target can never be turned
// into an SSRF probe of loopback / RFC1918 / link-local / metadata. Native
// channel relays (Telegram, Gmail) are plain `ChannelOutbound`s registered
// directly — they have their own vetted transports — so they need no HTTP seam.

/// The result of one HTTP POST: a status code, or a transport error string.
public enum PushHTTPResult: Sendable, Equatable {
    case status(Int)
    case failure(String)
}

/// The injectable HTTP POST seam. Production uses URLSession; tests stub it. The
/// caller has ALREADY vetted `url` through EgressGuard; a hardened production
/// client additionally pins the vetted IP (the `EgressApproval.pinnedIPs`) at
/// connect time — documented as the caller's duty, same as the rest of #5.
public protocol PushHTTPClient: Sendable {
    func post(url: URL, body: Data, contentType: String) async -> PushHTTPResult
}

/// Shared pre-flight: vet a URL through EgressGuard, returning a typed failure
/// receipt on deny (so a sink never connects to a blocked target).
func vetOrReject(_ url: URL, _ egress: EgressGuard) -> OutboundReceipt? {
    switch egress.vet(url) {
    case .deny(let reason): return .failed("egress denied: \(reason)")
    case .allow:            return nil
    }
}

func httpReceipt(_ result: PushHTTPResult, _ what: String) -> OutboundReceipt {
    switch result {
    case .status(let code) where (200..<300).contains(code): return .delivered
    case .status(let code): return .failed("\(what) HTTP \(code)")
    case .failure(let e):   return .failed("\(what): \(e)")
    }
}

/// ntfy.sh (or a self-hosted ntfy) sink: POST the message text to
/// `<base>/<topic>`. The topic is the target's `rest`. ntfy is the zero-signup
/// default sink (friction-to-first-push ≈ 0).
public struct NtfySink: ChannelOutbound {
    public let id = "ntfy"
    public var capabilities: SinkCapabilities { SinkCapabilities(supportsAttachments: false) }

    private let baseURL: String
    private let egress: EgressGuard
    private let http: any PushHTTPClient

    public init(baseURL: String = "https://ntfy.sh", egress: EgressGuard, http: any PushHTTPClient) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.egress = egress
        self.http = http
    }

    public func send(_ message: OutboundMessage) async -> OutboundReceipt {
        // The topic must not smuggle path/query segments (no "/", "?", "..").
        let topic = message.conversationId
        guard !topic.isEmpty, !topic.contains("/"), !topic.contains("?"), !topic.contains("..") else {
            return .failed("invalid ntfy topic")
        }
        guard let url = URL(string: "\(baseURL)/\(topic)") else { return .failed("invalid ntfy url") }
        if let denied = vetOrReject(url, egress) { return denied }
        return httpReceipt(await http.post(url: url, body: Data(message.text.utf8), contentType: "text/plain"),
                           "ntfy")
    }
}

/// Generic webhook sink: POST `{"text": ...}` JSON to the URL given as the
/// target's `rest`. The URL is vetted through EgressGuard, so an attacker-chosen
/// webhook can't reach internal services.
public struct WebhookSink: ChannelOutbound {
    public let id = "webhook"
    public var capabilities: SinkCapabilities { SinkCapabilities(supportsAttachments: false) }

    private let egress: EgressGuard
    private let http: any PushHTTPClient

    public init(egress: EgressGuard, http: any PushHTTPClient) {
        self.egress = egress
        self.http = http
    }

    public func send(_ message: OutboundMessage) async -> OutboundReceipt {
        guard let url = URL(string: message.conversationId), url.scheme != nil else {
            return .failed("invalid webhook url")
        }
        if let denied = vetOrReject(url, egress) { return denied }
        let payload: [String: String] = ["text": message.text]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failed("webhook payload encode failed")
        }
        return httpReceipt(await http.post(url: url, body: body, contentType: "application/json"),
                           "webhook")
    }
}

/// Production URLSession-backed HTTP client. (Tests inject a stub.)
public struct URLSessionPushHTTPClient: PushHTTPClient {
    private let session: URLSession
    private let timeout: TimeInterval
    public init(session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }
    public func post(url: URL, body: Data, contentType: String) async -> PushHTTPResult {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await session.data(for: req)
            return .status((resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .failure("\(error)")
        }
    }
}
