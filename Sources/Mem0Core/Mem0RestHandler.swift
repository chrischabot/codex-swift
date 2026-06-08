import Foundation

/// An HTTP response from the REST handler: a status code and a JSON body.
public struct Mem0RestResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

/// Pure REST dispatch over a `Mem0Engine`, mirroring the mem0-rs server routes:
///   GET  /health
///   POST /v1/memories            (add)
///   GET  /v1/memories            (get_all; scope via query)
///   DELETE /v1/memories          (delete_all; scope via query)
///   POST /v1/memories/search     (search)
///   GET/PUT/DELETE /v1/memories/:id
///   GET  /v1/memories/:id/history
///   POST /v1/reset
///
/// The `codex-mem0` executable supplies a transport (Hummingbird) and forwards
/// here, so all routing/serialization is unit-testable without a server.
public enum Mem0RestHandler {
    private static func encode(_ v: JSONValue) -> Data {
        (try? JSONEncoder().encode(v)) ?? Data("null".utf8)
    }

    private static func ok(_ v: JSONValue) -> Mem0RestResponse {
        Mem0RestResponse(status: 200, body: encode(v))
    }

    private static func error(_ e: Mem0Error) -> Mem0RestResponse {
        let status: Int
        switch e.kind {
        case .validation: status = 400
        case .authentication: status = 401
        case .notFound: status = 404
        case .rateLimit: status = 429
        default: status = 500
        }
        return Mem0RestResponse(status: status,
                                body: encode(.object(["error": .string(e.description), "code": .string(e.code)])))
    }

    private static func anyError(_ e: any Error) -> Mem0RestResponse {
        if let m = e as? Mem0Error { return error(m) }
        return Mem0RestResponse(status: 500, body: encode(.object(["error": .string("\(e)")])))
    }

    private static func notFoundResponse(_ method: String, _ path: String) -> Mem0RestResponse {
        Mem0RestResponse(status: 404, body: encode(.object(["error": .string("not found: \(method) \(path)")])))
    }

    // MARK: - body/message parsing

    private static func messageFrom(_ v: JSONValue) -> Message? {
        guard let o = v.objectValue, let content = o["content"]?.stringValue else { return nil }
        return Message(role: o["role"]?.stringValue ?? "user", content: content, name: o["name"]?.stringValue)
    }

    private static func messagesInput(_ v: JSONValue?) -> MessagesInput {
        switch v {
        case .some(.string(let s)): return .text(s)
        case .some(.array(let arr)): return .many(arr.compactMap { messageFrom($0) })
        case .some(.object): return messageFrom(v!).map { .one($0) } ?? .text("")
        default: return .text("")
        }
    }

    private static func addResultJSON(_ r: AddResult) -> JSONValue {
        var o: JSONObject = ["id": .string(r.id), "memory": .string(r.memory), "event": .string(r.event)]
        if let a = r.actorID { o["actor_id"] = .string(a) }
        if let role = r.role { o["role"] = .string(role) }
        return .object(o)
    }

    private static func historyJSON(_ h: HistoryRecord) -> JSONValue {
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

    private static func scopeFilters(_ query: [String: String]) -> JSONObject {
        var f: JSONObject = [:]
        for k in ["user_id", "agent_id", "run_id"] {
            if let v = query[k], !v.isEmpty { f[k] = .string(v) }
        }
        return f
    }

    private static func validatedScopeFilters(_ values: [String: String]) throws -> JSONObject {
        let userID = values["user_id"].flatMap { $0.isEmpty ? nil : $0 }
        let agentID = values["agent_id"].flatMap { $0.isEmpty ? nil : $0 }
        let runID = values["run_id"].flatMap { $0.isEmpty ? nil : $0 }
        let (_, filters) = try Mem0Filters.buildFiltersAndMetadata(userID: userID,
                                                                    agentID: agentID,
                                                                    runID: runID)
        return filters
    }

    private static func validatedScopeFilters(_ object: JSONObject) throws -> JSONObject {
        try validatedScopeFilters([
            "user_id": object["user_id"]?.stringValue ?? "",
            "agent_id": object["agent_id"]?.stringValue ?? "",
            "run_id": object["run_id"]?.stringValue ?? "",
        ])
    }

    private static func verifyMemoryScope(_ item: JSONObject, scope: JSONObject, id: String) throws {
        for (key, expected) in scope where item[key] != expected {
            throw Mem0Error.notFound("Memory with id \(id) not found in requested scope")
        }
    }

    private static func verifyHistoryScope(_ row: HistoryRecord, scope: JSONObject, id: String) throws {
        for (key, expected) in scope {
            let actual: String?
            switch key {
            case "user_id": actual = row.userID
            case "agent_id": actual = row.agentID
            case "run_id": actual = row.runID
            default: actual = nil
            }
            guard let actual, expected == .string(actual) else {
                throw Mem0Error.notFound("Memory with id \(id) not found in requested scope")
            }
        }
    }

    private static func scopedMemory(_ engine: Mem0Engine, id: String, scope: JSONObject) async throws -> JSONObject {
        guard let item = try await engine.get(id)?.objectValue else {
            throw Mem0Error.notFound("Memory with id \(id) not found")
        }
        try verifyMemoryScope(item, scope: scope, id: id)
        return item
    }

    private static func scopedHistory(_ engine: Mem0Engine, id: String, scope: JSONObject) async throws -> [HistoryRecord] {
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

    private static func updateMetadataPatch(_ metadata: JSONObject?) -> JSONObject? {
        guard var metadata else { return nil }
        for key in ["id", "memory", "data", "hash", "created_at", "updated_at", "text_lemmatized",
                    "user_id", "agent_id", "run_id", "actor_id", "role", "score"] {
            metadata[key] = nil
        }
        return metadata.isEmpty ? nil : metadata
    }

    // MARK: - dispatch

    public static func handle(method: String, path: String, query: [String: String],
                              body: Data?, engine: Mem0Engine) async -> Mem0RestResponse {
        let comps = path.split(separator: "/").map(String.init)
        let m = method.uppercased()
        let bodyObj: JSONObject = (body.flatMap { JSONValue.parse($0)?.objectValue }) ?? [:]

        do {
            if m == "GET" && comps == ["health"] {
                return ok(.object(["status": .string("ok")]))
            }
            if m == "POST" && comps == ["v1", "reset"] {
                try await engine.reset()
                return ok(.object(["message": .string("All memories reset")]))
            }

            if comps.count >= 2, comps[0] == "v1", comps[1] == "memories" {
                let rest = Array(comps.dropFirst(2))

                if rest.isEmpty {
                    switch m {
                    case "POST":
                        let opts = AddOptions(
                            userID: bodyObj["user_id"]?.stringValue,
                            agentID: bodyObj["agent_id"]?.stringValue,
                            runID: bodyObj["run_id"]?.stringValue,
                            metadata: bodyObj["metadata"]?.objectValue,
                            infer: bodyObj["infer"]?.boolValue,
                            memoryType: bodyObj["memory_type"]?.stringValue,
                            prompt: bodyObj["prompt"]?.stringValue)
                        let res = try await engine.add(messagesInput(bodyObj["messages"]), opts)
                        return ok(.object(["results": .array(res.map { addResultJSON($0) })]))
                    case "GET":
                        let topK = query["top_k"].flatMap { Int($0) } ?? 100
                        return ok(try await engine.getAll(scopeFilters(query), topK: topK))
                    case "DELETE":
                        return ok(try await engine.deleteAll(userID: query["user_id"],
                                                             agentID: query["agent_id"],
                                                             runID: query["run_id"]))
                    default:
                        return notFoundResponse(method, path)
                    }
                }

                if rest == ["search"], m == "POST" {
                    var filters = try validatedScopeFilters(bodyObj)
                    if let extra = bodyObj["filters"]?.objectValue {
                        for (k, v) in extra where !["user_id", "agent_id", "run_id"].contains(k) {
                            filters[k] = v
                        }
                    }
                    let q = bodyObj["query"]?.stringValue ?? ""
                    let opts = SearchOptions(
                        topK: Int(bodyObj["top_k"]?.intValue ?? 20),
                        threshold: bodyObj["threshold"]?.doubleValue ?? 0.1)
                    return ok(try await engine.search(q, filters, opts))
                }

                if rest.count == 1 {
                    let id = rest[0]
                    switch m {
                    case "GET":
                        let scope = try validatedScopeFilters(query)
                        return ok(.object(try await scopedMemory(engine, id: id, scope: scope)))
                    case "PUT":
                        guard let data = bodyObj["data"]?.stringValue else {
                            return error(Mem0Error.validation("'data' is required"))
                        }
                        let scope = try validatedScopeFilters(query)
                        _ = try await scopedMemory(engine, id: id, scope: scope)
                        return ok(try await engine.update(id, data: data,
                                                          metadata: updateMetadataPatch(bodyObj["metadata"]?.objectValue)))
                    case "DELETE":
                        let scope = try validatedScopeFilters(query)
                        _ = try await scopedMemory(engine, id: id, scope: scope)
                        return ok(try await engine.delete(id))
                    default:
                        return notFoundResponse(method, path)
                    }
                }

                if rest.count == 2, rest[1] == "history", m == "GET" {
                    let scope = try validatedScopeFilters(query)
                    let hist = try await scopedHistory(engine, id: rest[0], scope: scope)
                    return ok(.object(["history": .array(hist.map { historyJSON($0) })]))
                }
            }

            return notFoundResponse(method, path)
        } catch {
            return anyError(error)
        }
    }
}
