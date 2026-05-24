import Foundation

/// Faithful port of `codex_protocol::protocol::InterAgentCommunication`
/// (codex-rs/protocol/src/protocol.rs:798-846). `AgentPath` is the `/root/...`
/// string path used by the multi-agent tree.
public struct InterAgentCommunication: Sendable, Equatable, Codable {
    public var author: String          // AgentPath
    public var recipient: String       // AgentPath
    public var otherRecipients: [String]
    public var content: String
    public var triggerTurn: Bool

    enum CodingKeys: String, CodingKey {
        case author, recipient
        case otherRecipients = "other_recipients"
        case content
        case triggerTurn = "trigger_turn"
    }

    public init(author: String, recipient: String, otherRecipients: [String] = [],
                content: String, triggerTurn: Bool) {
        self.author = author; self.recipient = recipient
        self.otherRecipients = otherRecipients
        self.content = content; self.triggerTurn = triggerTurn
    }

    public init(from d: any Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        author = try c.decode(String.self, forKey: .author)
        recipient = try c.decode(String.self, forKey: .recipient)
        // serde(default) on other_recipients.
        otherRecipients = (try? c.decode([String].self, forKey: .otherRecipients)) ?? []
        content = try c.decode(String.self, forKey: .content)
        triggerTurn = try c.decode(Bool.self, forKey: .triggerTurn)
    }

    /// Compact JSON exactly as `serde_json::to_string(self)` (key order:
    /// author, recipient, other_recipients, content, trigger_turn).
    public func jsonString() -> String {
        let others = otherRecipients.map { "\"\(mailboxJSONEscape($0))\"" }
            .joined(separator: ",")
        return "{\"author\":\"\(mailboxJSONEscape(author))\","
            + "\"recipient\":\"\(mailboxJSONEscape(recipient))\","
            + "\"other_recipients\":[\(others)],"
            + "\"content\":\"\(mailboxJSONEscape(content))\","
            + "\"trigger_turn\":\(triggerTurn ? "true" : "false")}"
    }

    /// `to_response_input_item` — assistant role, OutputText = JSON, phase
    /// Commentary.
    public func toResponseInputItem() -> (role: String, text: String, phase: String) {
        ("assistant", jsonString(), "commentary")
    }

    /// `from_message_content` — single InputText|OutputText that is the JSON.
    public static func fromText(_ text: String) -> InterAgentCommunication? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(InterAgentCommunication.self, from: d)
    }
}

public actor Mailbox {
    private var queue: [InterAgentCommunication] = []
    private var nextSeq: UInt64 = 0
    private var seq: UInt64 = 0
    private var seqWaiters: [CheckedContinuation<UInt64, Never>] = []
    private let capacity: Int
    public private(set) var droppedCount: Int = 0

    public init(capacity: Int = 4096) {
        self.capacity = Swift.max(1, capacity)
    }

    /// `send` — enqueue, bump the monotonic sequence (returns it), notify
    /// subscribers. Bounded: beyond `capacity` the oldest entry is dropped
    /// (delivery order preserved for the surviving window) so a flood cannot
    /// grow memory without bound.
    @discardableResult
    public func send(_ communication: InterAgentCommunication) -> UInt64 {
        nextSeq &+= 1
        let s = nextSeq
        queue.append(communication)
        if queue.count > capacity {
            queue.removeFirst(queue.count - capacity)
            droppedCount += 1
        }
        seq = s
        let waiters = seqWaiters
        seqWaiters.removeAll()
        for w in waiters { w.resume(returning: s) }
        return s
    }

    /// `subscribe().changed()` analog: await the next sequence bump.
    public func waitForSeqChange() async -> UInt64 {
        await withCheckedContinuation { (c: CheckedContinuation<UInt64, Never>) in
            seqWaiters.append(c)
        }
    }

    public func currentSeq() -> UInt64 { seq }

    /// `MailboxReceiver::has_pending`.
    public func hasPending() -> Bool { !queue.isEmpty }

    /// `MailboxReceiver::has_pending_trigger_turn`.
    public func hasPendingTriggerTurn() -> Bool { queue.contains { $0.triggerTurn } }

    /// `MailboxReceiver::drain` — delivery order, clears the queue.
    public func drain() -> [InterAgentCommunication] {
        let d = queue
        queue.removeAll()
        return d
    }
}

/// Local JSON string escaper (HarnessCore cannot see the Prompts-internal
/// `jsonStringEscape`). Matches `serde_json` string escaping: control chars,
/// quote and backslash.
func mailboxJSONEscape(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out
}