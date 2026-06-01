import Foundation
import WireProtocol

/// Wire mirror of upstream `HookRunSummary`
/// (app-server-protocol/src/protocol/v2/hook.rs:96) plus its nested
/// `HookOutputEntry` and enum payloads. Carried by the `hook/started` and
/// `hook/completed` notifications so a frontend can render live hook-execution
/// rows. All field/enum wire strings are camelCase (upstream
/// `#[serde(rename_all="camelCase")]` / `v2_enum_from_core!`).
public struct HookRunSummary: Sendable, Codable, Equatable {
    public var id: String
    public var eventName: String          // preToolUse | postToolUse | ...
    public var handlerType: String        // command | prompt | agent
    public var executionMode: String      // sync | async
    public var scope: String              // thread | turn
    public var sourcePath: String
    public var source: String             // system|user|project|mdm|sessionFlags|plugin|...|unknown
    public var displayOrder: Int
    public var status: String             // running | completed | failed | blocked | stopped
    public var statusMessage: String?
    public var startedAt: Int             // Unix seconds
    public var completedAt: Int?          // Unix seconds
    public var durationMs: Int?           // milliseconds
    public var entries: [HookOutputEntry]

    public init(id: String, eventName: String, handlerType: String = "command",
                executionMode: String = "sync", scope: String = "thread",
                sourcePath: String, source: String = "unknown",
                displayOrder: Int, status: String, statusMessage: String? = nil,
                startedAt: Int, completedAt: Int? = nil, durationMs: Int? = nil,
                entries: [HookOutputEntry] = []) {
        self.id = id; self.eventName = eventName; self.handlerType = handlerType
        self.executionMode = executionMode; self.scope = scope
        self.sourcePath = sourcePath; self.source = source
        self.displayOrder = displayOrder; self.status = status
        self.statusMessage = statusMessage; self.startedAt = startedAt
        self.completedAt = completedAt; self.durationMs = durationMs
        self.entries = entries
    }

    // `statusMessage`/`completedAt`/`durationMs` are omitted when nil
    // (upstream `Option`).
    private enum CodingKeys: String, CodingKey {
        case id, eventName, handlerType, executionMode, scope, sourcePath
        case source, displayOrder, status, statusMessage, startedAt
        case completedAt, durationMs, entries
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(eventName, forKey: .eventName)
        try c.encode(handlerType, forKey: .handlerType)
        try c.encode(executionMode, forKey: .executionMode)
        try c.encode(scope, forKey: .scope)
        try c.encode(sourcePath, forKey: .sourcePath)
        try c.encode(source, forKey: .source)
        try c.encode(displayOrder, forKey: .displayOrder)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encode(entries, forKey: .entries)
    }
}

/// Upstream `HookOutputEntry` (v2/hook.rs:81): `{ kind, text }` where `kind`
/// is one of `warning|stop|feedback|context|error`.
public struct HookOutputEntry: Sendable, Codable, Equatable {
    public var kind: String
    public var text: String
    public init(kind: String, text: String) { self.kind = kind; self.text = text }
}
