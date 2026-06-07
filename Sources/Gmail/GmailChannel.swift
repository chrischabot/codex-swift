import Foundation
import Channels
import GoogleWorkspace

// The Gmail channel: an inbound poller that turns unread email into agent turns
// and a `ChannelOutbound` sink that emails replies/pushes. Runs on the #4
// GoogleAPIClient (Gmail service) which rides the #3 OAuth connector.
//
// SECURITY (the defining rule, ADDONS §5): inbound senders are NON-OWNER BY
// DEFAULT. A `From` header is forgeable and DKIM/SPF/DMARC prove the sending
// DOMAIN, not that the human is the operator — so `senderIsOwner` is only ever
// true for an address the OPERATOR explicitly allowlisted (`ownerEmails`), and
// that allowlist defaults EMPTY. Combined with the non-owner channel dispatch
// gate, an emailed instruction can never drive a privileged tool by default.
// Self-loop protection: our own sends carry `X-Codex-Channel: gmail`; we skip
// any inbound message bearing it so the agent never replies to itself.
public actor GmailChannel: Channel, ChannelOutbound {
    public nonisolated var id: String { "gmail" }

    private let api: GoogleAPIClient
    private let ownerEmails: Set<String>
    private let userId: String
    private let fromAddress: String?
    private let pollMs: Int
    private var pollTask: Task<Void, Never>?
    /// Backstop de-dup: ids we've already routed this run. Normally `markRead`
    /// drops UNREAD so the `is:unread` query never returns them again — but if
    /// the connected account lacks `gmail.modify`, markRead 403s and the same
    /// ids would reprocess every poll. This bounded set prevents that loop.
    private var seen: Set<String> = []

    public init(api: GoogleAPIClient,
                ownerEmails: Set<String> = [],
                userId: String = "me",
                fromAddress: String? = nil,
                pollMs: Int = 15_000) {
        self.api = api
        self.ownerEmails = Set(ownerEmails.map { $0.lowercased() })
        self.userId = userId
        self.fromAddress = fromAddress
        self.pollMs = Swift.max(2_000, pollMs)
    }

    public nonisolated var capabilities: SinkCapabilities { SinkCapabilities(supportsAttachments: false) }

    // MARK: Channel (inbound)

    public func start(_ host: any ChannelHost) async throws {
        pollTask = Task { [weak self] in await self?.pollLoop(host) }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        pollTask?.cancel()
    }

    public func stop() async { pollTask?.cancel(); pollTask = nil }

    private func pollLoop(_ host: any ChannelHost) async {
        while !Task.isCancelled {
            await pollOnce(host)
            try? await Task.sleep(for: .milliseconds(pollMs))
        }
    }

    func pollOnce(_ host: any ChannelHost) async {
        // List unread message ids.
        let listRes = await api.call(service: .gmail, method: "GET",
                                     path: "/users/\(userId)/messages",
                                     query: ["q": "is:unread", "maxResults": "10"])
        guard case .success(let resp) = listRes,
              let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else { return }
        for m in messages {
            guard let mid = m["id"] as? String, !seen.contains(mid) else { continue }
            let getRes = await api.call(service: .gmail, method: "GET",
                                        path: "/users/\(userId)/messages/\(mid)",
                                        query: ["format": "full"])
            guard case .success(let g) = getRes, let parsed = GmailParser.parse(g.body) else { continue }
            _ = await processInbound(parsed, host: host)
            if seen.count > 5_000 { seen.removeAll(keepingCapacity: true) }   // bounded backstop
            seen.insert(mid)
            // Mark read so the next `is:unread` poll skips it (best-effort; needs
            // gmail.modify — `seen` is the backstop when that scope isn't granted).
            await markRead(mid)
        }
    }

    /// The per-message security decision + routing. Returns whether the message
    /// was delivered to the agent (false = skipped self-loop). Testable directly.
    @discardableResult
    func processInbound(_ msg: GmailInboundMessage, host: any ChannelHost) async -> Bool {
        if msg.isSelfLoop { return false }   // never re-ingest our own sends
        // NON-OWNER by default: only an explicitly allowlisted address is owner.
        let isOwner = ownerEmails.contains(msg.fromAddress)
        let inbound = InboundMessage(channelId: id, conversationId: msg.threadId,
                                     senderId: msg.fromAddress, senderIsOwner: isOwner, text: msg.body)
        let reply = await host.deliver(inbound)
        if !reply.text.isEmpty {
            let subject = msg.subject.lowercased().hasPrefix("re:") ? msg.subject : "Re: \(msg.subject)"
            _ = await sendRaw(threadId: msg.threadId, to: msg.fromAddress, subject: subject,
                              body: reply.text, inReplyTo: msg.messageId,
                              references: msg.references ?? msg.messageId)
        }
        return true
    }

    private func markRead(_ id: String) async {
        let body = try? JSONSerialization.data(withJSONObject: ["removeLabelIds": ["UNREAD"]])
        _ = await api.call(service: .gmail, method: "POST",
                           path: "/users/\(userId)/messages/\(id)/modify", body: body)
    }

    // MARK: ChannelOutbound (fresh send to an email address)

    public func send(_ message: OutboundMessage) async -> OutboundReceipt {
        // conversationId is the recipient email for a fresh (push/cron) send.
        await sendRaw(threadId: nil, to: message.conversationId,
                      subject: "Message from Codex", body: message.text,
                      inReplyTo: nil, references: nil)
    }

    private func sendRaw(threadId: String?, to: String, subject: String, body: String,
                         inReplyTo: String?, references: String?) async -> OutboundReceipt {
        let raw = GmailMIME.buildRaw(to: to, subject: subject, body: body,
                                     from: fromAddress, inReplyTo: inReplyTo, references: references)
        var payload: [String: Any] = ["raw": raw]
        if let threadId { payload["threadId"] = threadId }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failedPermanent("gmail payload encode failed")
        }
        let r = await api.call(service: .gmail, method: "POST",
                               path: "/users/\(userId)/messages/send", body: bodyData)
        switch r {
        case .success: return .delivered
        case .failure(let e): return .failed("gmail send: \(e)")
        }
    }
}
