import Foundation

/// A chat message. Ported from the Rust port's `Message`.
public struct Message: Sendable, Equatable {
    public var role: String
    public var content: String
    public var name: String?

    public init(role: String, content: String, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }

    public static func user(_ content: String) -> Message { Message(role: "user", content: content) }
    public static func system(_ content: String) -> Message { Message(role: "system", content: content) }
    public static func assistant(_ content: String) -> Message { Message(role: "assistant", content: content) }

    /// Wire form for OpenAI-compatible chat requests.
    public func wire() -> [String: String] {
        var d = ["role": role, "content": content]
        if let name { d["name"] = name }
        return d
    }
}

/// Accepts a bare string, one message, or many — the `add` input shape.
/// Port of `MessagesInput`.
public enum MessagesInput: Sendable, ExpressibleByStringLiteral {
    case text(String)
    case one(Message)
    case many([Message])

    public init(stringLiteral value: String) { self = .text(value) }

    public func intoMessages() -> [Message] {
        switch self {
        case .text(let s): return [Message.user(s)]
        case .one(let m): return [m]
        case .many(let a): return a
        }
    }
}

/// A vector-store search result. Port of `SearchHit`.
public struct SearchHit: Sendable, Equatable {
    public var id: String
    public var score: Double
    public var payload: JSONObject
    public init(id: String, score: Double, payload: JSONObject) {
        self.id = id; self.score = score; self.payload = payload
    }
}

/// A record to insert into the vector store. Port of `VectorRecord`.
public struct VectorRecord: Sendable, Equatable {
    public var id: String
    public var vector: [Float]
    public var payload: JSONObject
    public init(id: String, vector: [Float], payload: JSONObject) {
        self.id = id; self.vector = vector; self.payload = payload
    }
}

/// One result of `add`. Port of `AddResult`.
public struct AddResult: Sendable, Equatable {
    public var id: String
    public var memory: String
    public var event: String
    public var actorID: String?
    public var role: String?
    public init(id: String, memory: String, event: String,
                actorID: String? = nil, role: String? = nil) {
        self.id = id; self.memory = memory; self.event = event
        self.actorID = actorID; self.role = role
    }
}

/// A history row. Port of `HistoryRecord`.
public struct HistoryRecord: Sendable, Equatable {
    public var id: String
    public var memoryID: String
    public var oldMemory: String?
    public var newMemory: String?
    public var event: String
    public var createdAt: String?
    public var updatedAt: String?
    public var isDeleted: Bool
    public var actorID: String?
    public var role: String?
    public var userID: String?
    public var agentID: String?
    public var runID: String?
    public init(id: String, memoryID: String, oldMemory: String?, newMemory: String?,
                event: String, createdAt: String?, updatedAt: String?, isDeleted: Bool,
                actorID: String?, role: String?, userID: String? = nil,
                agentID: String? = nil, runID: String? = nil) {
        self.id = id; self.memoryID = memoryID
        self.oldMemory = oldMemory; self.newMemory = newMemory
        self.event = event; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.isDeleted = isDeleted; self.actorID = actorID; self.role = role
        self.userID = userID; self.agentID = agentID; self.runID = runID
    }
}

/// A pending history insert. Port of `NewHistory`.
public struct NewHistory: Sendable, Equatable {
    public var memoryID: String
    public var oldMemory: String?
    public var newMemory: String?
    public var event: String
    public var createdAt: String?
    public var updatedAt: String?
    public var isDeleted: Int
    public var actorID: String?
    public var role: String?
    public var userID: String?
    public var agentID: String?
    public var runID: String?
    public init(memoryID: String, oldMemory: String?, newMemory: String?, event: String,
                createdAt: String?, updatedAt: String?, isDeleted: Int,
                actorID: String?, role: String?, userID: String? = nil,
                agentID: String? = nil, runID: String? = nil) {
        self.memoryID = memoryID; self.oldMemory = oldMemory; self.newMemory = newMemory
        self.event = event; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.isDeleted = isDeleted; self.actorID = actorID; self.role = role
        self.userID = userID; self.agentID = agentID; self.runID = runID
    }
}

/// A buffered recent message (per session scope). Port of the messages-table row.
public struct StoredMessage: Sendable, Equatable {
    public var role: String?
    public var content: String?
    public var name: String?
    public var createdAt: String?
    public init(role: String?, content: String?, name: String?, createdAt: String?) {
        self.role = role; self.content = content; self.name = name; self.createdAt = createdAt
    }
}
