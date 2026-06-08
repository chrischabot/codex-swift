import Foundation
import Tools
import Mem0Core

/// `mem0_search` — query long-term memory (the native mem0 engine) for relevant
/// facts. Read-only → `parallelSafe`.
public struct Mem0SearchTool: Tool {
    public let name = "mem0_search"
    public let parallelSafe = true
    public var toolDescription: String {
        "Search the user's long-term memory (mem0) for facts relevant to a query. "
            + "Returns the most relevant stored memories."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"query":{"type":"string","description":"What to recall from memory."},"limit":{"type":"integer","description":"Maximum memories to return (defaults to the configured top_k)."}},"required":["query"],"additionalProperties":false}"#
    }

    let engine: Mem0Engine
    let scope: Mem0Scope
    let defaultLimit: Int
    public init(engine: Mem0Engine, scope: Mem0Scope, defaultLimit: Int) {
        self.engine = engine; self.scope = scope; self.defaultLimit = defaultLimit
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable { let query: String; let limit: Int? }
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              let query = clean(args.query) else {
            return ToolResult(callId: call.callId, output: "invalid mem0_search arguments",
                              success: false, truncated: false)
        }
        do {
            let limit = try validatedLimit(args.limit, defaultValue: defaultLimit, max: 50)
            let res = try await engine.search(query, scope.filters, SearchOptions(topK: limit))
            return ToolResult(callId: call.callId, output: res.jsonString(sortedKeys: true),
                              success: true, truncated: false)
        } catch {
            return failed(call.callId, "mem0_search failed: \(error)")
        }
    }
}

/// `mem0_add` — store a durable fact in long-term memory (the native mem0
/// engine). Mutating → not `parallelSafe`.
public struct Mem0AddTool: Tool {
    public let name = "mem0_add"
    public let parallelSafe = false
    public var toolDescription: String {
        "Store a durable fact about the user in long-term memory (mem0) so it can "
            + "be recalled in future sessions."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"text":{"type":"string","description":"The fact or statement to remember."}},"required":["text"],"additionalProperties":false}"#
    }

    let engine: Mem0Engine
    let scope: Mem0Scope
    let infer: Bool
    public init(engine: Mem0Engine, scope: Mem0Scope, infer: Bool) {
        self.engine = engine; self.scope = scope; self.infer = infer
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable { let text: String }
        guard let data = call.argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data),
              !args.text.isEmpty else {
            return ToolResult(callId: call.callId, output: "invalid mem0_add arguments",
                              success: false, truncated: false)
        }
        guard !Mem0PrivacyGuard.containsDisallowedSecret(args.text) else {
            return ToolResult(callId: call.callId,
                              output: "mem0_add refused to store a likely secret or credential",
                              success: false, truncated: false)
        }
        let opts = AddOptions(userID: scope.userId, agentID: scope.agentId, runID: scope.runId, infer: infer)
        do {
            _ = try await engine.add(.many([.user(args.text)]), opts)
            return ToolResult(callId: call.callId, output: #"{"ok":true}"#, success: true, truncated: false)
        } catch {
            return ToolResult(callId: call.callId, output: "mem0_add failed: \(error)",
                              success: false, truncated: false)
        }
    }
}

/// `mem0_list` — inspect personal memories in the selected scope.
public struct Mem0ListTool: Tool {
    public let name = "mem0_list"
    public let parallelSafe = true
    public var toolDescription: String {
        "List the user's long-term memories in the current mem0 scope, optionally filtered by category or sensitivity."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"limit":{"type":"integer","description":"Maximum memories to return; clamped to 1..200."},"category":{"type":"string"},"sensitivity":{"type":"string"}},"additionalProperties":false}"#
    }

    let engine: Mem0Engine
    let scope: Mem0Scope
    let defaultLimit: Int

    public init(engine: Mem0Engine, scope: Mem0Scope, defaultLimit: Int) {
        self.engine = engine
        self.scope = scope
        self.defaultLimit = defaultLimit
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable { let limit: Int?; let category: String?; let sensitivity: String? }
        guard let args = decodeArgs(Args.self, call.argumentsJSON) else {
            return failed(call.callId, "invalid mem0_list arguments")
        }
        var filters = scope.filters
        if let category = clean(args.category) { filters["category"] = .string(category) }
        if let sensitivity = clean(args.sensitivity) { filters["sensitivity"] = .string(sensitivity) }
        do {
            let limit = try validatedLimit(args.limit, defaultValue: defaultLimit)
            let result = try await engine.getAll(filters, topK: limit)
            return jsonResult(call.callId, result)
        } catch {
            return failed(call.callId, "mem0_list failed: \(error)")
        }
    }
}

/// `mem0_update` — correct a scoped memory by id while preserving metadata.
public struct Mem0UpdateTool: Tool {
    public let name = "mem0_update"
    public let parallelSafe = false
    public var toolDescription: String {
        "Correct an existing long-term memory in the current mem0 scope."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"id":{"type":"string","description":"Memory id to update."},"text":{"type":"string","description":"Corrected memory text."},"metadata":{"type":"object","additionalProperties":true}},"required":["id","text"],"additionalProperties":false}"#
    }

    let engine: Mem0Engine
    let scope: Mem0Scope

    public init(engine: Mem0Engine, scope: Mem0Scope) {
        self.engine = engine
        self.scope = scope
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable { let id: String; let text: String; let metadata: JSONObject? }
        guard let args = decodeArgs(Args.self, call.argumentsJSON),
              let id = clean(args.id), let text = clean(args.text) else {
            return failed(call.callId, "invalid mem0_update arguments")
        }
        guard !Mem0PrivacyGuard.containsDisallowedSecret(text) else {
            return failed(call.callId, "mem0_update refused to store a likely secret or credential")
        }
        do {
            let existing = try await scopedMemory(engine: engine, scope: scope, id: id)
            let merged = mergeMetadata(from: existing, patch: args.metadata)
            let result = try await engine.update(id, data: text, metadata: merged)
            return jsonResult(call.callId, result)
        } catch {
            return failed(call.callId, "mem0_update failed: \(error)")
        }
    }
}

/// `mem0_delete` — delete one scoped memory, or a confirmed scoped set.
public struct Mem0DeleteTool: Tool {
    public let name = "mem0_delete"
    public let parallelSafe = false
    public var toolDescription: String {
        "Delete memories from the current mem0 scope. Broad deletes require exact confirmation."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"id":{"type":"string","description":"Memory id to delete."},"delete_all":{"type":"boolean","description":"Delete all memories in the current scope or category/sensitivity filter."},"category":{"type":"string"},"sensitivity":{"type":"string"},"confirm":{"type":"string","description":"Required for delete_all: DELETE MEM0 SCOPE"}},"additionalProperties":false}"#
    }

    let engine: Mem0Engine
    let scope: Mem0Scope

    public init(engine: Mem0Engine, scope: Mem0Scope) {
        self.engine = engine
        self.scope = scope
    }

    public func approvalRequirement(_ call: ToolCall) -> ToolApprovalRequirement {
        .required(summary: "delete long-term mem0 memory")
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable {
            let id: String?
            let deleteAll: Bool?
            let category: String?
            let sensitivity: String?
            let confirm: String?

            enum CodingKeys: String, CodingKey {
                case id
                case deleteAll = "delete_all"
                case category
                case sensitivity
                case confirm
            }
        }
        guard let args = decodeArgs(Args.self, call.argumentsJSON) else {
            return failed(call.callId, "invalid mem0_delete arguments")
        }
        do {
            if let id = clean(args.id) {
                _ = try await scopedMemory(engine: engine, scope: scope, id: id)
                let result = try await engine.delete(id)
                return jsonResult(call.callId, result)
            }
            guard args.deleteAll == true else {
                return failed(call.callId, "mem0_delete requires either id or delete_all=true")
            }
            guard args.confirm == "DELETE MEM0 SCOPE" else {
                return failed(call.callId, #"mem0_delete delete_all requires confirm="DELETE MEM0 SCOPE""#)
            }
            var filters = scope.filters
            if let category = clean(args.category) { filters["category"] = .string(category) }
            if let sensitivity = clean(args.sensitivity) { filters["sensitivity"] = .string(sensitivity) }
            let all = try await engine.getAll(filters, topK: nil)
            let ids = (all.objectValue?["results"]?.arrayValue ?? [])
                .compactMap { $0.objectValue?["id"]?.stringValue }
            for id in ids {
                _ = try await engine.delete(id)
            }
            return jsonResult(call.callId, .object([
                "ok": .bool(true),
                "deleted": .int(Int64(ids.count)),
            ]))
        } catch {
            return failed(call.callId, "mem0_delete failed: \(error)")
        }
    }
}

/// `mem0_history` — inspect the audit trail for a scoped memory id.
public struct Mem0HistoryTool: Tool {
    public let name = "mem0_history"
    public let parallelSafe = true
    public var toolDescription: String {
        "Show the add/update/delete history for a memory in the current mem0 scope."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"id":{"type":"string","description":"Memory id."}},"required":["id"],"additionalProperties":false}"#
    }

    let engine: Mem0Engine
    let scope: Mem0Scope

    public init(engine: Mem0Engine, scope: Mem0Scope) {
        self.engine = engine
        self.scope = scope
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable { let id: String }
        guard let args = decodeArgs(Args.self, call.argumentsJSON),
              let id = clean(args.id) else {
            return failed(call.callId, "invalid mem0_history arguments")
        }
        do {
            let history = try await scopedHistory(engine: engine, scope: scope, id: id)
            return jsonResult(call.callId, .object([
                "history": .array(history.map(historyJSON)),
            ]))
        } catch {
            return failed(call.callId, "mem0_history failed: \(error)")
        }
    }
}

/// `mem0_privacy` — expose scoped memory policy and export controls.
public struct Mem0PrivacyTool: Tool {
    public let name = "mem0_privacy"
    public let parallelSafe = true
    public var toolDescription: String {
        "Inspect mem0 privacy policy or export memories in the current scope."
    }
    public var jsonSchema: String {
        #"{"type":"object","properties":{"operation":{"type":"string","enum":["summary","export"],"description":"Defaults to summary."},"limit":{"type":"integer","description":"Export limit; clamped to 1..1000."}},"additionalProperties":false}"#
    }

    let engine: Mem0Engine
    let scope: Mem0Scope

    public init(engine: Mem0Engine, scope: Mem0Scope) {
        self.engine = engine
        self.scope = scope
    }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Decodable { let operation: String?; let limit: Int? }
        guard let args = decodeArgs(Args.self, call.argumentsJSON) else {
            return failed(call.callId, "invalid mem0_privacy arguments")
        }
        let operation = clean(args.operation) ?? "summary"
        let policy: JSONObject = [
            "scope": .object(scope.filters),
            "default_sensitivity": .string("normal"),
            "sensitive_categories": .array(["health", "wardrobe", "household", "pets", "projects"].map { .string($0) }),
            "disallowed": .array(["secrets", "credentials", "tokens", "api_keys"].map { .string($0) }),
            "delete_tool": .string("mem0_delete"),
            "update_tool": .string("mem0_update"),
        ]
        do {
            switch operation {
            case "summary":
                return jsonResult(call.callId, .object(["privacy": .object(policy)]))
            case "export":
                let limit = try validatedLimit(args.limit, defaultValue: 200, max: 1000)
                let memories = try await engine.getAll(scope.filters, topK: limit)
                return jsonResult(call.callId, .object([
                    "privacy": .object(policy),
                    "export": memories,
                ]))
            default:
                return failed(call.callId, "invalid mem0_privacy operation")
            }
        } catch {
            return failed(call.callId, "mem0_privacy failed: \(error)")
        }
    }
}

private func decodeArgs<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

private func clean(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
}

private func validatedLimit(_ value: Int?, defaultValue: Int, max: Int = 200) throws -> Int {
    let raw = value ?? defaultValue
    guard raw > 0 else { throw Mem0Error.validation("limit must be a positive integer") }
    return Swift.min(raw, max)
}

private func failed(_ callId: String, _ output: String) -> ToolResult {
    ToolResult(callId: callId, output: output, success: false, truncated: false)
}

private func jsonResult(_ callId: String, _ value: JSONValue) -> ToolResult {
    ToolResult(callId: callId, output: value.jsonString(sortedKeys: true), success: true, truncated: false)
}

private func scopedMemory(engine: Mem0Engine, scope: Mem0Scope, id: String) async throws -> JSONObject {
    guard let item = try await engine.get(id)?.objectValue else {
        throw Mem0Error.notFound("Memory with id \(id) not found")
    }
    try verifyMemoryScope(item, scope: scope, id: id)
    return item
}

private func scopedHistory(engine: Mem0Engine, scope: Mem0Scope, id: String) async throws -> [HistoryRecord] {
    if let item = try await engine.get(id)?.objectValue {
        try verifyMemoryScope(item, scope: scope, id: id)
        return try await engine.history(id)
    }
    let history = try await engine.history(id)
    guard !history.isEmpty else {
        throw Mem0Error.notFound("Memory with id \(id) not found")
    }
    for row in history {
        try verifyHistoryScope(row, scope: scope, id: id)
    }
    return history
}

private func verifyMemoryScope(_ item: JSONObject, scope: Mem0Scope, id: String) throws {
    for (key, expected) in scope.filters where item[key] != expected {
        throw Mem0Error.notFound("Memory with id \(id) not found in current scope")
    }
}

private func verifyHistoryScope(_ row: HistoryRecord, scope: Mem0Scope, id: String) throws {
    for (key, expected) in scope.filters {
        let actual: String?
        switch key {
        case "user_id": actual = row.userID
        case "agent_id": actual = row.agentID
        case "run_id": actual = row.runID
        default: actual = nil
        }
        guard let actual, expected == .string(actual) else {
            throw Mem0Error.notFound("Memory with id \(id) not found in current scope")
        }
    }
}

private func mergeMetadata(from item: JSONObject, patch: JSONObject?) -> JSONObject {
    var metadata = item["metadata"]?.objectValue ?? [:]
    if let patch {
        for (key, value) in patch where !reservedMetadataKeys.contains(key) {
            metadata[key] = value
        }
    }
    return metadata
}

private let reservedMetadataKeys: Set<String> = [
    "id", "memory", "data", "hash", "created_at", "updated_at", "text_lemmatized",
    "user_id", "agent_id", "run_id", "actor_id", "role", "score",
]

private func historyJSON(_ h: HistoryRecord) -> JSONValue {
    .object([
        "id": .string(h.id),
        "memory_id": .string(h.memoryID),
        "old_memory": h.oldMemory.map { .string($0) } ?? .null,
        "new_memory": h.newMemory.map { .string($0) } ?? .null,
        "event": .string(h.event),
        "created_at": h.createdAt.map { .string($0) } ?? .null,
        "updated_at": h.updatedAt.map { .string($0) } ?? .null,
        "is_deleted": .bool(h.isDeleted),
        "actor_id": h.actorID.map { .string($0) } ?? .null,
        "role": h.role.map { .string($0) } ?? .null,
        "user_id": h.userID.map { .string($0) } ?? .null,
        "agent_id": h.agentID.map { .string($0) } ?? .null,
        "run_id": h.runID.map { .string($0) } ?? .null,
    ])
}
