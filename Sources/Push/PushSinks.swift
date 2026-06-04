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
/// caller has ALREADY vetted `url` through EgressGuard and passes the vetted
/// `pinnedIPs`. The production client DISABLES redirects (a 3xx → internal would
/// otherwise bypass the pre-POST vet) and threads the pins for connect-time
/// verification. (Full connect-time IP pinning against DNS rebinding needs a
/// socket-level HTTP client — a documented residual; redirects-off + the egress
/// vet + permanent-deny-no-retry are the current defenses.)
public protocol PushHTTPClient: Sendable {
    func post(url: URL, body: Data, contentType: String, pinnedIPs: [String]) async -> PushHTTPResult
}

enum VetOutcome {
    case ok(EgressApproval)
    case denied(OutboundReceipt)
}

/// Shared pre-flight: vet a URL through EgressGuard. On allow, the approval (its
/// pinned IPs flow to the HTTP client); on deny, a PERMANENT failure receipt (an
/// SSRF target must never be retried).
func vet(_ url: URL, _ egress: EgressGuard) -> VetOutcome {
    switch egress.vet(url) {
    case .deny(let reason):    return .denied(.failedPermanent("egress denied: \(reason)"))
    case .allow(let approval): return .ok(approval)
    }
}

func httpReceipt(_ result: PushHTTPResult, _ what: String) -> OutboundReceipt {
    switch result {
    case .status(let code) where (200..<300).contains(code): return .delivered
    // A 4xx is a client error that won't fix itself on retry → permanent.
    case .status(let code) where (400..<500).contains(code): return .failedPermanent("\(what) HTTP \(code)")
    case .status(let code): return .failed("\(what) HTTP \(code)")   // 5xx etc → transient
    case .failure(let e):   return .failed("\(what): \(e)")          // transport → transient
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
        // Strict topic whitelist: a single path segment of safe chars only — no
        // "/", "?", "#", "%", "\", "..", control chars — so a topic can never
        // smuggle a path/host/encoded-separator into the URL.
        let topic = message.conversationId
        let ok = !topic.isEmpty && topic.count <= 256 && topic.allSatisfy { c in
            c.isLetter || c.isNumber || c == "-" || c == "_" || c == "."
        } && !topic.contains("..")
        guard ok else { return .failedPermanent("invalid ntfy topic") }
        guard let url = URL(string: "\(baseURL)/\(topic)") else { return .failedPermanent("invalid ntfy url") }
        let approval: EgressApproval
        switch vet(url, egress) { case .denied(let r): return r; case .ok(let a): approval = a }
        return httpReceipt(await http.post(url: url, body: Data(message.text.utf8),
                                           contentType: "text/plain", pinnedIPs: approval.pinnedIPs), "ntfy")
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
        guard let url = URL(string: message.conversationId),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failedPermanent("invalid webhook url (must be http/https)")
        }
        let approval: EgressApproval
        switch vet(url, egress) { case .denied(let r): return r; case .ok(let a): approval = a }
        let payload: [String: String] = ["text": message.text]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failedPermanent("webhook payload encode failed")
        }
        return httpReceipt(await http.post(url: url, body: body,
                                           contentType: "application/json", pinnedIPs: approval.pinnedIPs), "webhook")
    }
}

/// Production URLSession-backed HTTP client that DISABLES redirects (so a vetted
/// host cannot 3xx the request to an un-vetted internal target). (Tests inject a
/// stub.) `pinnedIPs` is accepted for connect-time verification; URLSession does
/// not expose pre-connect peer pinning, so the redirect block + the egress vet
/// are the enforced controls and the residual DNS-rebinding gap is documented.
public final class URLSessionPushHTTPClient: NSObject, PushHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
        super.init()
    }

    public func post(url: URL, body: Data, contentType: String, pinnedIPs: [String]) async -> PushHTTPResult {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // A per-call session with self as delegate so redirects are blocked.
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        do {
            let (_, resp) = try await s.data(for: req)
            return .status((resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .failure("\(error)")
        }
    }

    /// Refuse ALL redirects — completionHandler(nil) returns the 3xx response as-is
    /// instead of following it to a possibly-unvetted location.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
