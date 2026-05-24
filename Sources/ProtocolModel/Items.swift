import Foundation
import WireProtocol

public enum ItemStatus: String, Sendable, Codable {
    case inProgress, completed, failed, declined
}

public struct UserMessageContent: Sendable, Codable, Equatable {
    public var type: String   // "text" | "image" | "localImage"
    public var text: String?
    public var url: String?
    public var path: String?
    public init(text: String) { self.type = "text"; self.text = text }
}

public enum ThreadItem: Sendable, Equatable {
    case userMessage(id: ItemId, content: [UserMessageContent])
    case agentMessage(id: ItemId, text: String)
    case reasoning(id: ItemId, summary: String)
    case commandExecution(id: ItemId, command: [String], cwd: String, status: ItemStatus,
                           aggregatedOutput: String?, exitCode: Int?)
    case fileChange(id: ItemId, changes: [FileChange], status: ItemStatus)
    /// Codex initial-context / settings-diff message: a role ("developer" or
    /// "user") plus the ordered fragment section texts (each is a separate
    /// `ContentItem::InputText` in Codex `build_*_update_item`).
    case contextMessage(id: ItemId, role: String, sections: [String])
    /// Codex `TurnItem::ContextCompaction(ContextCompactionItem)`: a marker
    /// item that brackets a context-compaction event in `itemStarted` /
    /// `itemCompleted` notifications. Distinct from an ordinary
    /// `.agentMessage` so UIs can render compaction as a structured event
    /// rather than an assistant turn whose text happens to be
    /// "<context_compaction>". Upstream carries only `id`.
    case contextCompaction(id: ItemId)
    /// Tolerant fallback for upstream `ThreadItem` variants this Swift port
    /// has not yet modeled (e.g. `mcpToolCall`, `webSearch`, `hookPrompt`,
    /// `dynamicToolCall`, `collabAgentToolCall`, `imageView`,
    /// `imageGeneration`, `enteredReviewMode`, `exitedReviewMode`, `plan`,
    /// or any future `backgroundTerminal`-style additions). Decoding a
    /// `ThreadItem` whose `type` discriminator is unknown stores the entire
    /// JSON object verbatim in `raw` and the discriminator in `typeName`.
    /// Encoding writes the captured object back unchanged, preserving any
    /// fields the Swift surface does not yet know about.
    ///
    /// This prevents `item/started` / `item/completed` notifications from
    /// crashing the pipeline when upstream emits a tool-call item Swift
    /// cannot otherwise model. Subscribers may opt into rendering by
    /// inspecting `raw`; everyone else simply ignores the event.
    case unknown(id: ItemId, typeName: String, raw: JSONValue)

    public struct FileChange: Sendable, Codable, Equatable {
        public var path: String
        public var kind: String   // "add" | "modify" | "delete"
        public var diff: String
        public init(path: String, kind: String, diff: String) {
            self.path = path; self.kind = kind; self.diff = diff
        }
    }

    public var id: ItemId {
        switch self {
        case .userMessage(let i, _), .agentMessage(let i, _), .reasoning(let i, _),
             .commandExecution(let i, _, _, _, _, _), .fileChange(let i, _, _),
             .contextMessage(let i, _, _),
             .contextCompaction(let i),
             .unknown(let i, _, _):
            return i
        }
    }

    /// On-wire discriminator string for this item — matches the JSON `type`
    /// field. Useful for logging/observability of `.unknown` items.
    public var typeName: String {
        switch self {
        case .userMessage: return "userMessage"
        case .agentMessage: return "agentMessage"
        case .reasoning: return "reasoning"
        case .commandExecution: return "commandExecution"
        case .fileChange: return "fileChange"
        case .contextMessage: return "contextMessage"
        case .contextCompaction: return "contextCompaction"
        case .unknown(_, let t, _): return t
        }
    }
}

extension ThreadItem: Codable {
    private enum K: String, CodingKey {
        case type, id, content, text, summary, command, cwd, status
        case aggregatedOutput, exitCode, changes, role, sections
    }
    public func encode(to encoder: any Encoder) throws {
        // `.unknown` round-trips the captured JSON verbatim — write it via a
        // single-value container so any extra fields (beyond `type`/`id`)
        // are preserved exactly as decoded. The other cases use a keyed
        // container.
        if case .unknown(let id, let typeName, let raw) = self {
            let merged: JSONValue = {
                if case .object(var fields) = raw {
                    fields["type"] = .string(typeName)
                    fields["id"] = .string(id.raw)
                    return .object(fields)
                }
                return .object(["type": .string(typeName), "id": .string(id.raw)])
            }()
            var single = encoder.singleValueContainer()
            try single.encode(merged)
            return
        }
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .userMessage(let id, let content):
            try c.encode("userMessage", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(content, forKey: .content)
        case .agentMessage(let id, let text):
            try c.encode("agentMessage", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        case .reasoning(let id, let summary):
            try c.encode("reasoning", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(summary, forKey: .summary)
        case .commandExecution(let id, let cmd, let cwd, let st, let out, let ec):
            try c.encode("commandExecution", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(cmd, forKey: .command)
            try c.encode(cwd, forKey: .cwd)
            try c.encode(st, forKey: .status)
            try c.encodeIfPresent(out, forKey: .aggregatedOutput)
            try c.encodeIfPresent(ec, forKey: .exitCode)
        case .fileChange(let id, let changes, let st):
            try c.encode("fileChange", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(changes, forKey: .changes)
            try c.encode(st, forKey: .status)
        case .contextMessage(let id, let role, let sections):
            try c.encode("contextMessage", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(role, forKey: .role)
            try c.encode(sections, forKey: .sections)
        case .contextCompaction(let id):
            try c.encode("contextCompaction", forKey: .type)
            try c.encode(id, forKey: .id)
        case .unknown:
            // Handled above via singleValueContainer — unreachable here.
            break
        }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        let id = try c.decode(ItemId.self, forKey: .id)
        switch type {
        case "userMessage":
            self = .userMessage(id: id, content: try c.decode([UserMessageContent].self, forKey: .content))
        case "agentMessage":
            self = .agentMessage(id: id, text: try c.decode(String.self, forKey: .text))
        case "reasoning":
            self = .reasoning(id: id, summary: try c.decode(String.self, forKey: .summary))
        case "commandExecution":
            self = .commandExecution(
                id: id,
                command: try c.decode([String].self, forKey: .command),
                cwd: try c.decode(String.self, forKey: .cwd),
                status: try c.decode(ItemStatus.self, forKey: .status),
                aggregatedOutput: try c.decodeIfPresent(String.self, forKey: .aggregatedOutput),
                exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode))
        case "fileChange":
            self = .fileChange(
                id: id,
                changes: try c.decode([FileChange].self, forKey: .changes),
                status: try c.decode(ItemStatus.self, forKey: .status))
        case "contextMessage":
            self = .contextMessage(
                id: id,
                role: try c.decode(String.self, forKey: .role),
                sections: try c.decode([String].self, forKey: .sections))
        case "contextCompaction":
            self = .contextCompaction(id: id)
        default:
            // Tolerant fallback: capture the whole JSON object so the item
            // can be re-emitted verbatim and inspected by future code.
            // We re-decode from the original decoder via a single-value
            // container — Foundation's JSONDecoder lets us layer this on top
            // of an already-opened keyed container because both views share
            // the same underlying value.
            let raw = try decoder.singleValueContainer().decode(JSONValue.self)
            self = .unknown(id: id, typeName: type, raw: raw)
        }
    }
}